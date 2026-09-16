-- sky-member: 관리자용 백업 파일 안전 복원 기능
-- Supabase SQL Editor에서 한 번 실행하세요.
-- 복원은 현재 선택한 모임에만 적용되며, 백업에 없는 현재 회원·회비·메모는 삭제하지 않습니다.

create table if not exists public.group_restore_archives (
  id uuid primary key default gen_random_uuid(),
  group_id uuid not null references public.groups(id) on delete cascade,
  backup_data jsonb not null,
  source_backup_hash text not null,
  source_exported_at text,
  created_by uuid references auth.users(id) on delete set null,
  created_at timestamptz not null default now(),
  restore_summary jsonb not null default '{}'::jsonb
);

create index if not exists group_restore_archives_group_created_idx
  on public.group_restore_archives (group_id, created_at desc);

alter table public.group_restore_archives enable row level security;

-- 업로드된 JSON을 서버에서 다시 검사합니다. 브라우저의 검사는 편의를 위한 것이며,
-- 실제 복원 권한·형식·범위 검사는 이 함수와 아래 RPC에서만 판단합니다.
create or replace function public.validate_group_restore_backup(p_backup jsonb)
returns void
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_members jsonb;
  v_payments jsonb;
  v_notes jsonb;
  v_settings jsonb;
  v_item jsonb;
  v_text text;
begin
  if p_backup is null or jsonb_typeof(p_backup) <> 'object' then
    raise exception '백업 파일 형식이 올바르지 않습니다.';
  end if;
  if octet_length(p_backup::text) > 10485760 then
    raise exception '백업 파일은 10MB 이하만 복원할 수 있습니다.';
  end if;
  if p_backup->>'format' <> 'sky-member-backup' or p_backup->>'version' <> '1' then
    raise exception '지원하지 않는 백업 파일입니다.';
  end if;
  if exists (
    select 1 from jsonb_object_keys(p_backup) as keys(key_name)
    where key_name not in ('format','version','exported_at','group','dues_settings','members','dues_payments','admin_notes','excluded_data')
  ) then
    raise exception '허용되지 않은 백업 항목이 포함되어 있습니다.';
  end if;
  if jsonb_typeof(p_backup->'group') <> 'object'
    or jsonb_typeof(p_backup->'dues_settings') <> 'object'
    or jsonb_typeof(p_backup->'members') <> 'array'
    or jsonb_typeof(p_backup->'dues_payments') <> 'array'
    or jsonb_typeof(p_backup->'admin_notes') <> 'array' then
    raise exception '백업 파일의 구성 항목이 올바르지 않습니다.';
  end if;

  if exists (
    select 1 from jsonb_object_keys(p_backup->'group') as keys(key_name)
    where key_name not in ('name','description','bylaws')
  ) or exists (
    select 1 from jsonb_object_keys(p_backup->'dues_settings') as keys(key_name)
    where key_name not in ('monthly_amount','account_bank','account_number','account_holder','due_day','updated_at')
  ) then
    raise exception '백업 파일의 모임 설정 항목이 올바르지 않습니다.';
  end if;

  if nullif(btrim(coalesce(p_backup->'group'->>'name','')), '') is null
    or char_length(coalesce(p_backup->'group'->>'name','')) > 80
    or char_length(coalesce(p_backup->'group'->>'description','')) > 500
    or char_length(coalesce(p_backup->'group'->>'bylaws','')) > 10000 then
    raise exception '백업 파일의 모임 정보가 올바르지 않습니다.';
  end if;

  v_settings := p_backup->'dues_settings';
  v_text := btrim(coalesce(v_settings->>'monthly_amount',''));
  if v_text <> '' and v_text !~ '^[0-9]+$' then
    raise exception '백업 파일의 회비 금액이 올바르지 않습니다.';
  end if;
  -- 금액은 원 단위 정수입니다. 형식 검사를 먼저 끝낸 뒤에만 형변환합니다.
  if v_text <> '' and v_text::numeric > 999999999999 then
    raise exception '백업 파일의 회비 금액이 너무 큽니다.';
  end if;
  v_text := btrim(coalesce(v_settings->>'due_day',''));
  if v_text <> '' and v_text !~ '^[0-9]{1,2}$' then
    raise exception '백업 파일의 납부일이 올바르지 않습니다.';
  end if;
  if v_text <> '' and v_text::integer not between 1 and 31 then
    raise exception '백업 파일의 납부일이 올바르지 않습니다.';
  end if;
  if char_length(coalesce(v_settings->>'account_bank','')) > 100
    or char_length(coalesce(v_settings->>'account_number','')) > 200
    or char_length(coalesce(v_settings->>'account_holder','')) > 100 then
    raise exception '백업 파일의 계좌 정보가 너무 깁니다.';
  end if;

  v_members := p_backup->'members';
  v_payments := p_backup->'dues_payments';
  v_notes := p_backup->'admin_notes';
  if jsonb_array_length(v_members) > 2000
    or jsonb_array_length(v_payments) > 48000
    or jsonb_array_length(v_notes) > 2000 then
    raise exception '복원할 데이터가 허용 범위를 초과합니다.';
  end if;

  if exists (select 1 from jsonb_array_elements(v_members) as items(value) where jsonb_typeof(value) <> 'object')
    or exists (select 1 from jsonb_array_elements(v_payments) as items(value) where jsonb_typeof(value) <> 'object')
    or exists (select 1 from jsonb_array_elements(v_notes) as items(value) where jsonb_typeof(value) <> 'object') then
    raise exception '백업 목록 항목이 올바르지 않습니다.';
  end if;
  if exists (
    select 1
    from jsonb_array_elements(v_members) as items(value), lateral jsonb_object_keys(items.value) as keys(key_name)
    where key_name not in ('membership_no','name','nickname','phone','email','join_date','approval_status','member_status','created_at')
  ) or exists (
    select 1
    from jsonb_array_elements(v_payments) as items(value), lateral jsonb_object_keys(items.value) as keys(key_name)
    where key_name not in ('member_membership_no','member_name','member_email','due_month','amount','status','paid_at','note','created_at','updated_at')
  ) or exists (
    select 1
    from jsonb_array_elements(v_notes) as items(value), lateral jsonb_object_keys(items.value) as keys(key_name)
    where key_name not in ('member_membership_no','member_name','member_email','memo','updated_at')
  ) then
    raise exception '허용되지 않은 회원·회비·메모 항목이 포함되어 있습니다.';
  end if;

  if exists (
    select 1 from jsonb_array_elements(v_members) as items(value)
    where nullif(btrim(coalesce(value->>'membership_no','')), '') is null
      or btrim(value->>'membership_no') !~ '^[0-9]{5}$'
      or nullif(btrim(coalesce(value->>'name','')), '') is null
      or char_length(coalesce(value->>'name','')) > 80
      or nullif(btrim(coalesce(value->>'email','')), '') is null
      or char_length(coalesce(value->>'email','')) > 254
      or regexp_replace(coalesce(value->>'phone',''), '[^0-9]', '', 'g') !~ '^[0-9]{9,11}$'
      or (nullif(btrim(coalesce(value->>'nickname','')), '') is not null and char_length(value->>'nickname') > 40)
      or coalesce(value->>'join_date','') !~ '^[0-9]{4}-[0-9]{2}-[0-9]{2}$'
      or coalesce(nullif(btrim(value->>'approval_status'),''),'approved') not in ('pending','approved')
      or char_length(coalesce(value->>'member_status','')) > 40
  ) then
    raise exception '백업 파일의 회원 정보가 올바르지 않습니다.';
  end if;
  if exists (
    select 1
    from jsonb_array_elements(v_members) as items(value)
    group by btrim(value->>'membership_no')
    having count(*) > 1
  ) or exists (
    select 1
    from jsonb_array_elements(v_members) as items(value)
    group by lower(btrim(value->>'email'))
    having count(*) > 1
  ) or exists (
    select 1
    from jsonb_array_elements(v_members) as items(value)
    where nullif(btrim(coalesce(value->>'nickname','')), '') is not null
    group by lower(btrim(value->>'nickname'))
    having count(*) > 1
  ) then
    raise exception '백업 파일에 중복된 회원번호·이메일·닉네임이 있습니다.';
  end if;

  if exists (
    select 1 from jsonb_array_elements(v_payments) as items(value)
    where btrim(coalesce(value->>'member_membership_no','')) !~ '^[0-9]{5}$'
      or coalesce(value->>'due_month','') !~ '^[0-9]{4}-[0-9]{2}-01$'
      or coalesce(value->>'amount','') !~ '^[0-9]+$'
      or coalesce(value->>'status','') not in ('pending','paid')
      or char_length(coalesce(value->>'note','')) > 2000
  ) then
    raise exception '백업 파일의 회비 내역이 올바르지 않습니다.';
  end if;
  -- 위의 형식 검사 이후에만 금액을 숫자로 변환합니다.
  if exists (
    select 1 from jsonb_array_elements(v_payments) as items(value)
    where (value->>'amount')::numeric > 999999999999
  ) then
    raise exception '백업 파일의 회비 금액이 너무 큽니다.';
  end if;
  if exists (
    select 1
    from jsonb_array_elements(v_payments) as items(value)
    group by btrim(value->>'member_membership_no'), value->>'due_month'
    having count(*) > 1
  ) or exists (
    select 1
    from jsonb_array_elements(v_payments) as payment(value)
    where not exists (
      select 1 from jsonb_array_elements(v_members) as member(value)
      where btrim(member.value->>'membership_no') = btrim(payment.value->>'member_membership_no')
    )
  ) then
    raise exception '회비 내역의 회원 연결 정보가 올바르지 않습니다.';
  end if;

  if exists (
    select 1 from jsonb_array_elements(v_notes) as items(value)
    where btrim(coalesce(value->>'member_membership_no','')) !~ '^[0-9]{5}$'
      or char_length(coalesce(value->>'memo','')) > 2000
  ) or exists (
    select 1
    from jsonb_array_elements(v_notes) as items(value)
    group by btrim(value->>'member_membership_no')
    having count(*) > 1
  ) or exists (
    select 1
    from jsonb_array_elements(v_notes) as note(value)
    where not exists (
      select 1 from jsonb_array_elements(v_members) as member(value)
      where btrim(member.value->>'membership_no') = btrim(note.value->>'member_membership_no')
    )
  ) then
    raise exception '운영자 메모의 회원 연결 정보가 올바르지 않습니다.';
  end if;

  for v_item in select value from jsonb_array_elements(v_members) as items(value) loop
    begin
      perform (v_item->>'join_date')::date;
    exception when others then
      raise exception '백업 파일의 가입일이 올바르지 않습니다.';
    end;
  end loop;
  for v_item in select value from jsonb_array_elements(v_payments) as items(value) loop
    begin
      perform (v_item->>'due_month')::date;
      if nullif(btrim(coalesce(v_item->>'paid_at','')), '') is not null then
        perform (v_item->>'paid_at')::timestamptz;
      end if;
    exception when others then
      raise exception '백업 파일의 회비 날짜가 올바르지 않습니다.';
    end;
  end loop;
end;
$$;

create or replace function public.preview_group_backup_restore(p_group_id uuid, p_backup jsonb)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_target_name text;
  v_member_total integer;
  v_member_by_no integer;
  v_member_by_email integer;
  v_payment_total integer;
  v_note_total integer;
begin
  if auth.uid() is null or not public.is_group_admin(p_group_id) then
    raise exception '이 모임의 관리자만 백업 파일을 확인할 수 있습니다.';
  end if;
  perform public.validate_group_restore_backup(p_backup);

  select name into v_target_name from public.groups where id = p_group_id;
  if v_target_name is null then
    raise exception '모임 정보를 찾을 수 없습니다.';
  end if;

  if exists (
    select 1
    from jsonb_array_elements(p_backup->'members') as source(value)
    join public.members by_no
      on by_no.group_id = p_group_id
     and by_no.membership_no = btrim(source.value->>'membership_no')
    join public.members by_email
      on by_email.group_id = p_group_id
     and lower(btrim(by_email.email)) = lower(btrim(source.value->>'email'))
    where by_no.id <> by_email.id
  ) then
    raise exception '회원번호와 이메일이 서로 다른 현재 회원을 가리킵니다. 복원 전에 회원 정보를 확인해 주세요.';
  end if;

  select count(*) into v_member_total from jsonb_array_elements(p_backup->'members');
  select count(*) into v_member_by_no
  from jsonb_array_elements(p_backup->'members') as source(value)
  where exists (
    select 1 from public.members member_row
    where member_row.group_id = p_group_id
      and member_row.membership_no = btrim(source.value->>'membership_no')
  );
  select count(*) into v_member_by_email
  from jsonb_array_elements(p_backup->'members') as source(value)
  where not exists (
      select 1 from public.members member_row
      where member_row.group_id = p_group_id
        and member_row.membership_no = btrim(source.value->>'membership_no')
    )
    and exists (
      select 1 from public.members member_row
      where member_row.group_id = p_group_id
        and lower(btrim(member_row.email)) = lower(btrim(source.value->>'email'))
    );
  select count(*) into v_payment_total from jsonb_array_elements(p_backup->'dues_payments');
  select count(*) into v_note_total from jsonb_array_elements(p_backup->'admin_notes');

  return jsonb_build_object(
    'restore_mode', 'safe_merge',
    'backup', jsonb_build_object(
      'group_name', p_backup->'group'->>'name',
      'exported_at', p_backup->>'exported_at'
    ),
    'target', jsonb_build_object(
      'group_name', v_target_name,
      'name_mismatch', lower(btrim(coalesce(v_target_name,''))) <> lower(btrim(coalesce(p_backup->'group'->>'name','')))
    ),
    'counts', jsonb_build_object(
      'members', v_member_total,
      'payments', v_payment_total,
      'notes', v_note_total,
      'members_matched_by_number', v_member_by_no,
      'members_matched_by_email', v_member_by_email,
      'members_to_add', greatest(v_member_total - v_member_by_no - v_member_by_email, 0)
    ),
    'warnings', jsonb_build_array(
      '백업에 없는 현재 회원·회비·메모는 삭제하지 않습니다.',
      '로그인 비밀번호, 인증 계정 연결 정보, 관리자 권한, 초대코드는 복원하지 않습니다.',
      '현재 모임 데이터는 복원 직전에 자동 백업됩니다.'
    )
  );
end;
$$;

create or replace function public.restore_group_backup(
  p_group_id uuid,
  p_backup jsonb,
  p_confirmation text
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_before_backup jsonb;
  v_archive_id uuid;
  v_source jsonb;
  v_payment jsonb;
  v_note jsonb;
  v_source_number text;
  v_actual_number text;
  v_name text;
  v_nickname text;
  v_phone text;
  v_email text;
  v_join_date date;
  v_approval text;
  v_status text;
  v_member_id uuid;
  v_email_member_id uuid;
  v_auth_user_id uuid;
  v_current_approval text;
  v_payment_id uuid;
  v_due_month date;
  v_amount numeric(12,0);
  v_payment_status text;
  v_paid_at timestamptz;
  v_member_map jsonb := '{}'::jsonb;
  v_changed_numbers jsonb := '[]'::jsonb;
  v_members_created integer := 0;
  v_members_updated integer := 0;
  v_payments_created integer := 0;
  v_payments_updated integer := 0;
  v_notes_created integer := 0;
  v_notes_updated integer := 0;
  v_settings jsonb;
begin
  if auth.uid() is null or not public.is_group_admin(p_group_id) then
    raise exception '이 모임의 관리자만 백업 파일을 복원할 수 있습니다.';
  end if;
  if btrim(coalesce(p_confirmation,'')) <> '복원' then
    raise exception '복원 확인 문구가 일치하지 않습니다.';
  end if;

  perform pg_advisory_xact_lock(hashtextextended('sky-member-restore:' || p_group_id::text, 0));
  perform 1 from public.groups where id = p_group_id for update;
  if not found then
    raise exception '모임 정보를 찾을 수 없습니다.';
  end if;
  perform public.preview_group_backup_restore(p_group_id, p_backup);

  select public.export_group_backup(p_group_id) into v_before_backup;
  insert into public.group_restore_archives (group_id, backup_data, source_backup_hash, source_exported_at, created_by)
  values (
    p_group_id,
    v_before_backup,
    encode(extensions.digest(p_backup::text, 'sha256'), 'hex'),
    p_backup->>'exported_at',
    auth.uid()
  )
  returning id into v_archive_id;

  update public.groups
  set name = btrim(p_backup->'group'->>'name'),
      description = nullif(left(btrim(coalesce(p_backup->'group'->>'description','')), 500), ''),
      bylaws = left(btrim(coalesce(p_backup->'group'->>'bylaws','')), 10000)
  where id = p_group_id;

  v_settings := p_backup->'dues_settings';
  insert into public.dues_settings (group_id, monthly_amount, account_bank, account_number, account_holder, due_day, updated_by)
  values (
    p_group_id,
    coalesce(nullif(btrim(v_settings->>'monthly_amount'), '')::numeric, 0),
    left(btrim(coalesce(v_settings->>'account_bank','')), 100),
    left(btrim(coalesce(v_settings->>'account_number','')), 200),
    left(btrim(coalesce(v_settings->>'account_holder','')), 100),
    coalesce(nullif(btrim(v_settings->>'due_day'), '')::integer, 25),
    auth.uid()
  )
  on conflict (group_id) do update
  set monthly_amount = excluded.monthly_amount,
      account_bank = excluded.account_bank,
      account_number = excluded.account_number,
      account_holder = excluded.account_holder,
      due_day = excluded.due_day,
      updated_by = excluded.updated_by;

  for v_source in select value from jsonb_array_elements(p_backup->'members') as items(value) loop
    v_member_id := null;
    v_email_member_id := null;
    v_actual_number := null;
    v_auth_user_id := null;
    v_current_approval := null;
    v_source_number := btrim(v_source->>'membership_no');
    v_name := left(btrim(v_source->>'name'), 80);
    v_nickname := nullif(left(btrim(coalesce(v_source->>'nickname','')), 40), '');
    v_phone := btrim(v_source->>'phone');
    v_email := lower(btrim(v_source->>'email'));
    v_join_date := (v_source->>'join_date')::date;
    v_approval := coalesce(nullif(btrim(v_source->>'approval_status'),''), 'approved');
    v_status := coalesce(nullif(left(btrim(coalesce(v_source->>'member_status','')), 40), ''), '활성');

    select id, membership_no, auth_user_id, approval_status
    into v_member_id, v_actual_number, v_auth_user_id, v_current_approval
    from public.members
    where group_id = p_group_id and membership_no = v_source_number
    for update;

    select id into v_email_member_id
    from public.members
    where group_id = p_group_id and lower(btrim(email)) = v_email
    for update;

    if v_member_id is not null and v_email_member_id is not null and v_member_id <> v_email_member_id then
      raise exception '회원번호 %와 이메일 %이 서로 다른 현재 회원을 가리킵니다.', v_source_number, v_email;
    end if;

    if v_member_id is not null then
      if exists (
        select 1 from public.members
        where group_id = p_group_id
          and lower(btrim(member_id)) = lower(coalesce(v_nickname,''))
          and nullif(v_nickname,'') is not null
          and id <> v_member_id
      ) then
        raise exception '닉네임 %은(는) 현재 다른 회원이 사용 중입니다.', v_nickname;
      end if;
      update public.members
      set name = v_name,
          member_id = v_nickname,
          phone = v_phone,
          email = v_email,
          join_date = v_join_date,
          status = v_status,
          approval_status = case when v_auth_user_id is not null and v_current_approval = 'approved' then 'approved' else v_approval end
      where id = v_member_id;
      v_members_updated := v_members_updated + 1;
    elsif v_email_member_id is not null then
      select membership_no, auth_user_id, approval_status
      into v_actual_number, v_auth_user_id, v_current_approval
      from public.members where id = v_email_member_id;
      if exists (
        select 1 from public.members
        where group_id = p_group_id
          and lower(btrim(member_id)) = lower(coalesce(v_nickname,''))
          and nullif(v_nickname,'') is not null
          and id <> v_email_member_id
      ) then
        raise exception '닉네임 %은(는) 현재 다른 회원이 사용 중입니다.', v_nickname;
      end if;
      update public.members
      set name = v_name,
          member_id = v_nickname,
          phone = v_phone,
          email = v_email,
          join_date = v_join_date,
          status = v_status,
          approval_status = case when v_auth_user_id is not null and v_current_approval = 'approved' then 'approved' else v_approval end
      where id = v_email_member_id;
      v_member_id := v_email_member_id;
      v_members_updated := v_members_updated + 1;
    else
      if v_nickname is not null and exists (
        select 1 from public.members
        where group_id = p_group_id and lower(btrim(member_id)) = lower(v_nickname)
      ) then
        raise exception '닉네임 %은(는) 현재 다른 회원이 사용 중입니다.', v_nickname;
      end if;
      insert into public.members (group_id, name, member_id, phone, email, join_date, grade, status, approval_status)
      values (p_group_id, v_name, v_nickname, v_phone, v_email, v_join_date, '회원', v_status, v_approval)
      returning id, membership_no into v_member_id, v_actual_number;
      v_members_created := v_members_created + 1;
    end if;

    v_member_map := v_member_map || jsonb_build_object(v_source_number, v_member_id::text);
    if v_actual_number <> v_source_number then
      v_changed_numbers := v_changed_numbers || jsonb_build_array(jsonb_build_object('backup_membership_no',v_source_number,'restored_membership_no',v_actual_number));
    end if;
  end loop;

  for v_payment in select value from jsonb_array_elements(p_backup->'dues_payments') as items(value) loop
    v_member_id := nullif(v_member_map ->> btrim(v_payment->>'member_membership_no'), '')::uuid;
    if v_member_id is null then
      raise exception '회비 내역의 회원을 연결하지 못했습니다.';
    end if;
    select membership_no, approval_status into v_actual_number, v_current_approval from public.members where id = v_member_id;
    if v_current_approval <> 'approved' then
      raise exception '가입 승인 대기 회원의 회비 내역은 복원할 수 없습니다.';
    end if;
    v_due_month := (v_payment->>'due_month')::date;
    v_amount := (v_payment->>'amount')::numeric;
    v_payment_status := v_payment->>'status';
    v_paid_at := case when v_payment_status = 'paid' then coalesce(nullif(btrim(v_payment->>'paid_at'),'')::timestamptz, now()) else null end;
    select id into v_payment_id from public.dues_payments where member_id = v_member_id and due_month = v_due_month for update;
    if v_payment_id is null then
      insert into public.dues_payments (group_id, member_id, due_month, amount, status, paid_at, confirmed_by, note)
      values (p_group_id, v_member_id, v_due_month, v_amount, v_payment_status, v_paid_at, case when v_payment_status='paid' then auth.uid() else null end, left(coalesce(v_payment->>'note',''),2000));
      v_payments_created := v_payments_created + 1;
    else
      update public.dues_payments
      set amount = v_amount,
          status = v_payment_status,
          paid_at = v_paid_at,
          confirmed_by = case when v_payment_status='paid' then auth.uid() else null end,
          note = left(coalesce(v_payment->>'note',''),2000)
      where id = v_payment_id;
      v_payments_updated := v_payments_updated + 1;
    end if;
  end loop;

  for v_note in select value from jsonb_array_elements(p_backup->'admin_notes') as items(value) loop
    v_member_id := nullif(v_member_map ->> btrim(v_note->>'member_membership_no'), '')::uuid;
    if v_member_id is null then
      raise exception '운영자 메모의 회원을 연결하지 못했습니다.';
    end if;
    if exists (select 1 from public.member_admin_notes where member_id = v_member_id) then
      update public.member_admin_notes
      set memo = left(coalesce(v_note->>'memo',''),2000), updated_by = auth.uid()
      where member_id = v_member_id;
      v_notes_updated := v_notes_updated + 1;
    else
      insert into public.member_admin_notes (member_id, memo, updated_by)
      values (v_member_id, left(coalesce(v_note->>'memo',''),2000), auth.uid());
      v_notes_created := v_notes_created + 1;
    end if;
  end loop;

  update public.group_restore_archives
  set restore_summary = jsonb_build_object(
    'members_created', v_members_created,
    'members_updated', v_members_updated,
    'payments_created', v_payments_created,
    'payments_updated', v_payments_updated,
    'notes_created', v_notes_created,
    'notes_updated', v_notes_updated,
    'membership_number_changes', v_changed_numbers
  )
  where id = v_archive_id;

  return jsonb_build_object(
    'archive_id', v_archive_id,
    'members_created', v_members_created,
    'members_updated', v_members_updated,
    'payments_created', v_payments_created,
    'payments_updated', v_payments_updated,
    'notes_created', v_notes_created,
    'notes_updated', v_notes_updated,
    'membership_number_changes', v_changed_numbers
  );
end;
$$;

create or replace function public.get_latest_group_restore_archive(p_group_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_archive public.group_restore_archives%rowtype;
begin
  if auth.uid() is null or not public.is_group_admin(p_group_id) then
    raise exception '이 모임의 관리자만 자동 백업을 받을 수 있습니다.';
  end if;
  select * into v_archive
  from public.group_restore_archives
  where group_id = p_group_id
  order by created_at desc
  limit 1;
  if not found then
    raise exception '아직 복원 전 자동 백업이 없습니다.';
  end if;
  return jsonb_build_object('created_at',v_archive.created_at,'backup',v_archive.backup_data,'restore_summary',v_archive.restore_summary);
end;
$$;

revoke all on table public.group_restore_archives from anon, authenticated;
revoke all on function public.validate_group_restore_backup(jsonb) from public;
revoke all on function public.preview_group_backup_restore(uuid, jsonb) from public;
revoke all on function public.restore_group_backup(uuid, jsonb, text) from public;
revoke all on function public.get_latest_group_restore_archive(uuid) from public;
grant execute on function public.preview_group_backup_restore(uuid, jsonb) to authenticated;
grant execute on function public.restore_group_backup(uuid, jsonb, text) to authenticated;
grant execute on function public.get_latest_group_restore_archive(uuid) to authenticated;
