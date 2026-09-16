-- sky-member: 통장 잔액과 장부 잔액의 차이를 사유와 함께 기록하는 잔액 조정 기능
-- Supabase SQL Editor에서 이 파일 전체를 한 번 실행하세요.
-- 기존 회계(지출·이자·기타 수입) SQL과 안전 백업/복원 SQL이 적용된 상태를 전제로 합니다.
-- 조정은 삭제하거나 현재 잔액을 직접 덮어쓰지 않습니다. 잘못 입력한 경우 반대 금액으로 새 기록을 추가하세요.

begin;

create table if not exists public.group_balance_adjustments (
  id uuid primary key default gen_random_uuid(),
  group_id uuid not null references public.groups(id) on delete cascade,
  adjustment_date date not null default current_date,
  amount numeric(12, 0) not null check (amount <> 0 and amount between -999999999999 and 999999999999),
  reason text not null default '',
  created_by uuid references auth.users(id) on delete set null,
  created_at timestamptz not null default now(),
  updated_by uuid references auth.users(id) on delete set null,
  updated_at timestamptz not null default now(),
  constraint group_balance_adjustments_reason_length check (char_length(btrim(reason)) between 1 and 160)
);

create index if not exists group_balance_adjustments_group_date_idx
  on public.group_balance_adjustments (group_id, adjustment_date desc, created_at desc);

drop trigger if exists group_balance_adjustments_touch_updated_at on public.group_balance_adjustments;
create trigger group_balance_adjustments_touch_updated_at
before update on public.group_balance_adjustments
for each row execute function public.touch_updated_at();

-- 잔액 조정 원본은 관리자만 직접 관리합니다. 회원 화면에는 아래 보고 RPC로만 공개합니다.
alter table public.group_balance_adjustments enable row level security;
drop policy if exists "group balance adjustments admin manage" on public.group_balance_adjustments;
create policy "group balance adjustments admin manage"
on public.group_balance_adjustments
for all
to authenticated
using (public.is_group_admin(group_id))
with check (public.is_group_admin(group_id));

create or replace function public.create_group_balance_adjustment(
  p_group_id uuid,
  p_adjustment_date date,
  p_amount numeric,
  p_reason text
)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_id uuid;
  v_reason text := btrim(coalesce(p_reason, ''));
begin
  if auth.uid() is null or not public.is_group_admin(p_group_id) then
    raise exception '이 모임의 관리자만 잔액을 조정할 수 있습니다.';
  end if;
  if p_adjustment_date is null then
    raise exception '조정일을 입력해 주세요.';
  end if;
  if v_reason = '' or char_length(v_reason) > 160 then
    raise exception '조정 사유를 160자 이내로 입력해 주세요.';
  end if;
  if coalesce(p_amount, 0) = 0
    or p_amount <> trunc(p_amount)
    or p_amount < -999999999999
    or p_amount > 999999999999 then
    raise exception '조정 금액은 0원이 아닌 원 단위 정수로 입력해 주세요.';
  end if;

  insert into public.group_balance_adjustments (
    group_id, adjustment_date, amount, reason, created_by, updated_by
  ) values (
    p_group_id, p_adjustment_date, p_amount, v_reason, auth.uid(), auth.uid()
  ) returning id into v_id;

  return v_id;
end;
$$;

-- 관리자용: 회비·이자·기타 수입·지출·잔액 조정을 모두 반영한 월별 보고입니다.
create or replace function public.get_group_accounting_report(
  p_group_id uuid,
  p_report_month date default current_date
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_month date := date_trunc('month', coalesce(p_report_month, current_date))::date;
  v_previous_dues numeric := 0;
  v_previous_incomes numeric := 0;
  v_previous_expenses numeric := 0;
  v_previous_adjustments numeric := 0;
  v_dues_paid numeric := 0;
  v_dues_unpaid numeric := 0;
  v_interest_income numeric := 0;
  v_other_income numeric := 0;
  v_expenses_total numeric := 0;
  v_adjustments_total numeric := 0;
  v_paid_count integer := 0;
  v_pending_count integer := 0;
  v_expenses jsonb := '[]'::jsonb;
  v_incomes jsonb := '[]'::jsonb;
  v_adjustments jsonb := '[]'::jsonb;
begin
  if auth.uid() is null or not public.is_group_admin(p_group_id) then
    raise exception '이 모임의 관리자만 회계 보고를 볼 수 있습니다.';
  end if;

  select coalesce(sum(amount), 0)
  into v_previous_dues
  from public.dues_payments
  where group_id = p_group_id and status = 'paid' and due_month < v_month;

  select coalesce(sum(amount), 0)
  into v_previous_incomes
  from public.group_incomes
  where group_id = p_group_id and income_date < v_month;

  select coalesce(sum(amount), 0)
  into v_previous_expenses
  from public.group_expenses
  where group_id = p_group_id and expense_date < v_month;

  select coalesce(sum(amount), 0)
  into v_previous_adjustments
  from public.group_balance_adjustments
  where group_id = p_group_id and adjustment_date < v_month;

  select
    coalesce(sum(amount) filter (where status = 'paid'), 0),
    coalesce(sum(amount) filter (where status <> 'paid'), 0),
    count(*) filter (where status = 'paid'),
    count(*) filter (where status <> 'paid')
  into v_dues_paid, v_dues_unpaid, v_paid_count, v_pending_count
  from public.dues_payments
  where group_id = p_group_id and due_month = v_month;

  select
    coalesce(sum(amount) filter (where income_type = 'interest'), 0),
    coalesce(sum(amount) filter (where income_type = 'other'), 0)
  into v_interest_income, v_other_income
  from public.group_incomes
  where group_id = p_group_id
    and income_date >= v_month
    and income_date < (v_month + interval '1 month')::date;

  select coalesce(sum(amount), 0)
  into v_expenses_total
  from public.group_expenses
  where group_id = p_group_id
    and expense_date >= v_month
    and expense_date < (v_month + interval '1 month')::date;

  select coalesce(sum(amount), 0)
  into v_adjustments_total
  from public.group_balance_adjustments
  where group_id = p_group_id
    and adjustment_date >= v_month
    and adjustment_date < (v_month + interval '1 month')::date;

  select coalesce(jsonb_agg(jsonb_build_object(
    'id', id,
    'expense_date', expense_date,
    'category', category,
    'description', description,
    'amount', amount,
    'receipt_url', receipt_url,
    'note', note,
    'created_at', created_at,
    'updated_at', updated_at
  ) order by expense_date desc, created_at desc), '[]'::jsonb)
  into v_expenses
  from public.group_expenses
  where group_id = p_group_id
    and expense_date >= v_month
    and expense_date < (v_month + interval '1 month')::date;

  select coalesce(jsonb_agg(jsonb_build_object(
    'id', id,
    'income_date', income_date,
    'income_type', income_type,
    'description', description,
    'amount', amount,
    'receipt_url', receipt_url,
    'note', note,
    'created_at', created_at,
    'updated_at', updated_at
  ) order by income_date desc, created_at desc), '[]'::jsonb)
  into v_incomes
  from public.group_incomes
  where group_id = p_group_id
    and income_date >= v_month
    and income_date < (v_month + interval '1 month')::date;

  select coalesce(jsonb_agg(jsonb_build_object(
    'id', id,
    'adjustment_date', adjustment_date,
    'amount', amount,
    'reason', reason,
    'created_at', created_at
  ) order by adjustment_date desc, created_at desc), '[]'::jsonb)
  into v_adjustments
  from public.group_balance_adjustments
  where group_id = p_group_id
    and adjustment_date >= v_month
    and adjustment_date < (v_month + interval '1 month')::date;

  return jsonb_build_object(
    'report_month', v_month,
    'summary', jsonb_build_object(
      'previous_balance', v_previous_dues + v_previous_incomes - v_previous_expenses + v_previous_adjustments,
      'dues_paid_total', v_dues_paid,
      'dues_unpaid_total', v_dues_unpaid,
      'interest_income_total', v_interest_income,
      'other_income_total', v_other_income,
      'additional_income_total', v_interest_income + v_other_income,
      'income_total', v_dues_paid + v_interest_income + v_other_income,
      'expense_total', v_expenses_total,
      'balance_adjustment_total', v_adjustments_total,
      'current_balance', (v_previous_dues + v_previous_incomes - v_previous_expenses + v_previous_adjustments) + v_dues_paid + v_interest_income + v_other_income + v_adjustments_total - v_expenses_total,
      'paid_count', v_paid_count,
      'pending_count', v_pending_count
    ),
    'expenses', v_expenses,
    'incomes', v_incomes,
    'adjustments', v_adjustments
  );
end;
$$;

-- 회원용: 본인 회비와 모임의 공개 회계 내역을 반환합니다.
create or replace function public.get_member_accounting_report(
  p_group_id uuid,
  p_report_month date default current_date
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_month date := date_trunc('month', coalesce(p_report_month, current_date))::date;
  v_member_id uuid;
  v_payment jsonb;
  v_previous_dues numeric := 0;
  v_previous_incomes numeric := 0;
  v_previous_expenses numeric := 0;
  v_previous_adjustments numeric := 0;
  v_dues_paid numeric := 0;
  v_interest_income numeric := 0;
  v_other_income numeric := 0;
  v_expenses_total numeric := 0;
  v_adjustments_total numeric := 0;
  v_expenses jsonb := '[]'::jsonb;
  v_incomes jsonb := '[]'::jsonb;
  v_adjustments jsonb := '[]'::jsonb;
begin
  if auth.uid() is null or not public.is_group_member(p_group_id) then
    raise exception '승인된 회원만 회계 보고를 볼 수 있습니다.';
  end if;

  select id into v_member_id
  from public.members
  where group_id = p_group_id
    and auth_user_id = auth.uid()
    and approval_status = 'approved'
  limit 1;
  if v_member_id is null then
    raise exception '이 모임의 회원 정보를 찾을 수 없습니다.';
  end if;

  select jsonb_build_object(
    'due_month', due_month,
    'amount', amount,
    'status', status,
    'paid_at', paid_at
  )
  into v_payment
  from public.dues_payments
  where member_id = v_member_id and due_month = v_month;

  select coalesce(sum(amount), 0)
  into v_previous_dues
  from public.dues_payments
  where group_id = p_group_id and status = 'paid' and due_month < v_month;

  select coalesce(sum(amount), 0)
  into v_previous_incomes
  from public.group_incomes
  where group_id = p_group_id and income_date < v_month;

  select coalesce(sum(amount), 0)
  into v_previous_expenses
  from public.group_expenses
  where group_id = p_group_id and expense_date < v_month;

  select coalesce(sum(amount), 0)
  into v_previous_adjustments
  from public.group_balance_adjustments
  where group_id = p_group_id and adjustment_date < v_month;

  select coalesce(sum(amount), 0)
  into v_dues_paid
  from public.dues_payments
  where group_id = p_group_id and due_month = v_month and status = 'paid';

  select
    coalesce(sum(amount) filter (where income_type = 'interest'), 0),
    coalesce(sum(amount) filter (where income_type = 'other'), 0)
  into v_interest_income, v_other_income
  from public.group_incomes
  where group_id = p_group_id
    and income_date >= v_month
    and income_date < (v_month + interval '1 month')::date;

  select coalesce(sum(amount), 0)
  into v_expenses_total
  from public.group_expenses
  where group_id = p_group_id
    and expense_date >= v_month
    and expense_date < (v_month + interval '1 month')::date;

  select coalesce(sum(amount), 0)
  into v_adjustments_total
  from public.group_balance_adjustments
  where group_id = p_group_id
    and adjustment_date >= v_month
    and adjustment_date < (v_month + interval '1 month')::date;

  select coalesce(jsonb_agg(jsonb_build_object(
    'expense_date', expense_date,
    'category', category,
    'description', description,
    'amount', amount,
    'note', note
  ) order by expense_date desc, created_at desc), '[]'::jsonb)
  into v_expenses
  from public.group_expenses
  where group_id = p_group_id
    and expense_date >= v_month
    and expense_date < (v_month + interval '1 month')::date;

  select coalesce(jsonb_agg(jsonb_build_object(
    'income_date', income_date,
    'income_type', income_type,
    'description', description,
    'amount', amount,
    'note', note
  ) order by income_date desc, created_at desc), '[]'::jsonb)
  into v_incomes
  from public.group_incomes
  where group_id = p_group_id
    and income_date >= v_month
    and income_date < (v_month + interval '1 month')::date;

  select coalesce(jsonb_agg(jsonb_build_object(
    'adjustment_date', adjustment_date,
    'amount', amount,
    'reason', reason
  ) order by adjustment_date desc, created_at desc), '[]'::jsonb)
  into v_adjustments
  from public.group_balance_adjustments
  where group_id = p_group_id
    and adjustment_date >= v_month
    and adjustment_date < (v_month + interval '1 month')::date;

  return jsonb_build_object(
    'report_month', v_month,
    'payment', v_payment,
    'summary', jsonb_build_object(
      'member_due_amount', coalesce((v_payment->>'amount')::numeric, 0),
      'member_due_status', coalesce(v_payment->>'status', 'none'),
      'previous_balance', v_previous_dues + v_previous_incomes - v_previous_expenses + v_previous_adjustments,
      'dues_paid_total', v_dues_paid,
      'interest_income_total', v_interest_income,
      'other_income_total', v_other_income,
      'additional_income_total', v_interest_income + v_other_income,
      'income_total', v_dues_paid + v_interest_income + v_other_income,
      'expense_total', v_expenses_total,
      'balance_adjustment_total', v_adjustments_total,
      'current_balance', (v_previous_dues + v_previous_incomes - v_previous_expenses + v_previous_adjustments) + v_dues_paid + v_interest_income + v_other_income + v_adjustments_total - v_expenses_total
    ),
    'expenses', v_expenses,
    'incomes', v_incomes,
    'adjustments', v_adjustments
  );
end;
$$;

-- 기존 백업 포맷을 유지하면서 잔액 조정 배열만 확장합니다.
create or replace function public.validate_group_balance_adjustments_backup(p_backup jsonb)
returns void
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_adjustments jsonb := coalesce(p_backup->'balance_adjustments', '[]'::jsonb);
  v_item jsonb;
begin
  if p_backup is null or jsonb_typeof(p_backup) <> 'object' then
    raise exception '백업 파일 형식이 올바르지 않습니다.';
  end if;
  if octet_length(p_backup::text) > 10485760 then
    raise exception '백업 파일은 10MB 이하만 복원할 수 있습니다.';
  end if;
  if jsonb_typeof(v_adjustments) <> 'array' then
    raise exception '백업 파일의 잔액 조정 내역 형식이 올바르지 않습니다.';
  end if;

  perform public.validate_group_accounting_backup(p_backup - 'balance_adjustments');

  if jsonb_array_length(v_adjustments) > 10000 then
    raise exception '복원할 잔액 조정 내역이 허용 범위를 초과합니다.';
  end if;
  if exists (
    select 1 from jsonb_array_elements(v_adjustments) as items(value)
    where jsonb_typeof(value) <> 'object'
  ) then
    raise exception '백업 파일의 잔액 조정 항목이 올바르지 않습니다.';
  end if;
  if exists (
    select 1
    from jsonb_array_elements(v_adjustments) as items(value), lateral jsonb_object_keys(items.value) as keys(key_name)
    where key_name not in ('id', 'adjustment_date', 'amount', 'reason')
  ) then
    raise exception '허용되지 않은 잔액 조정 항목이 포함되어 있습니다.';
  end if;
  if exists (
    select 1 from jsonb_array_elements(v_adjustments) as items(value)
    where coalesce(value->>'id', '') !~ '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$'
      or coalesce(value->>'adjustment_date', '') !~ '^[0-9]{4}-[0-9]{2}-[0-9]{2}$'
      or coalesce(value->>'amount', '') !~ '^-?[0-9]+$'
      or nullif(btrim(coalesce(value->>'reason', '')), '') is null
      or char_length(coalesce(value->>'reason', '')) > 160
  ) then
    raise exception '백업 파일의 잔액 조정 내역이 올바르지 않습니다.';
  end if;
  if exists (
    select 1 from jsonb_array_elements(v_adjustments) as items(value)
    where (value->>'amount')::numeric = 0
      or (value->>'amount')::numeric < -999999999999
      or (value->>'amount')::numeric > 999999999999
  ) then
    raise exception '백업 파일의 잔액 조정 금액이 올바르지 않습니다.';
  end if;
  if exists (
    select 1 from jsonb_array_elements(v_adjustments) as items(value)
    group by value->>'id'
    having count(*) > 1
  ) then
    raise exception '백업 파일에 중복된 잔액 조정 내역이 있습니다.';
  end if;
  for v_item in select value from jsonb_array_elements(v_adjustments) as items(value) loop
    begin
      perform (v_item->>'adjustment_date')::date;
    exception when others then
      raise exception '백업 파일의 잔액 조정일이 올바르지 않습니다.';
    end;
  end loop;
end;
$$;

create or replace function public.export_group_backup_with_balance_adjustments(p_group_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_backup jsonb;
  v_adjustments jsonb;
begin
  if auth.uid() is null or not public.is_group_admin(p_group_id) then
    raise exception '이 모임의 관리자만 데이터를 백업할 수 있습니다.';
  end if;

  select public.export_group_backup_with_expenses(p_group_id) into v_backup;
  select coalesce(jsonb_agg(jsonb_build_object(
    'id', id,
    'adjustment_date', adjustment_date,
    'amount', amount,
    'reason', reason
  ) order by adjustment_date desc, created_at desc), '[]'::jsonb)
  into v_adjustments
  from public.group_balance_adjustments
  where group_id = p_group_id;

  return v_backup || jsonb_build_object('balance_adjustments', v_adjustments);
end;
$$;

create or replace function public.preview_group_backup_restore_with_balance_adjustments(
  p_group_id uuid,
  p_backup jsonb
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_preview jsonb;
  v_adjustment_count integer;
begin
  if auth.uid() is null or not public.is_group_admin(p_group_id) then
    raise exception '이 모임의 관리자만 백업 파일을 확인할 수 있습니다.';
  end if;
  perform public.validate_group_balance_adjustments_backup(p_backup);
  select public.preview_group_backup_restore_with_expenses(p_group_id, p_backup - 'balance_adjustments') into v_preview;
  select count(*) into v_adjustment_count
  from jsonb_array_elements(coalesce(p_backup->'balance_adjustments', '[]'::jsonb));
  return jsonb_set(v_preview, '{counts,balance_adjustments}', to_jsonb(v_adjustment_count), true);
end;
$$;

create or replace function public.restore_group_backup_with_balance_adjustments(
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
  v_before_adjustments jsonb := '[]'::jsonb;
  v_result jsonb;
  v_archive_id uuid;
  v_adjustment jsonb;
  v_adjustment_id uuid;
  v_existing_group_id uuid;
  v_created integer := 0;
  v_updated integer := 0;
begin
  if auth.uid() is null or not public.is_group_admin(p_group_id) then
    raise exception '이 모임의 관리자만 백업 파일을 복원할 수 있습니다.';
  end if;
  perform public.validate_group_balance_adjustments_backup(p_backup);
  -- 복원 전 자동 백업과 실제 반영 사이에 다른 회계 기록이 끼어들지 않도록 모임 단위로 잠급니다.
  perform pg_advisory_xact_lock(hashtextextended('sky-member-restore:' || p_group_id::text, 0));

  select coalesce(jsonb_agg(jsonb_build_object(
    'id', id,
    'adjustment_date', adjustment_date,
    'amount', amount,
    'reason', reason
  ) order by adjustment_date desc, created_at desc), '[]'::jsonb)
  into v_before_adjustments
  from public.group_balance_adjustments
  where group_id = p_group_id;

  select public.restore_group_backup_with_expenses(
    p_group_id,
    p_backup - 'balance_adjustments',
    p_confirmation
  ) into v_result;

  for v_adjustment in select value from jsonb_array_elements(coalesce(p_backup->'balance_adjustments', '[]'::jsonb)) as items(value) loop
    v_adjustment_id := (v_adjustment->>'id')::uuid;
    v_existing_group_id := null;
    select group_id into v_existing_group_id
    from public.group_balance_adjustments
    where id = v_adjustment_id
    for update;

    if v_existing_group_id is null then
      insert into public.group_balance_adjustments (
        id, group_id, adjustment_date, amount, reason, created_by, updated_by
      ) values (
        v_adjustment_id,
        p_group_id,
        (v_adjustment->>'adjustment_date')::date,
        (v_adjustment->>'amount')::numeric,
        btrim(v_adjustment->>'reason'),
        auth.uid(), auth.uid()
      );
      v_created := v_created + 1;
    elsif v_existing_group_id = p_group_id then
      update public.group_balance_adjustments
      set adjustment_date = (v_adjustment->>'adjustment_date')::date,
          amount = (v_adjustment->>'amount')::numeric,
          reason = btrim(v_adjustment->>'reason'),
          updated_by = auth.uid()
      where id = v_adjustment_id;
      v_updated := v_updated + 1;
    else
      raise exception '다른 모임에 이미 사용 중인 잔액 조정 식별자가 포함되어 있습니다.';
    end if;
  end loop;

  v_archive_id := nullif(v_result->>'archive_id', '')::uuid;
  if v_archive_id is not null then
    update public.group_restore_archives
    set backup_data = backup_data || jsonb_build_object('balance_adjustments', v_before_adjustments),
        source_backup_hash = encode(extensions.digest(p_backup::text, 'sha256'), 'hex'),
        source_exported_at = p_backup->>'exported_at',
        restore_summary = restore_summary || jsonb_build_object(
          'balance_adjustments_created', v_created,
          'balance_adjustments_updated', v_updated
        )
    where id = v_archive_id;
  end if;

  return v_result || jsonb_build_object(
    'balance_adjustments_created', v_created,
    'balance_adjustments_updated', v_updated
  );
end;
$$;

revoke all on table public.group_balance_adjustments from anon, authenticated;
revoke all on function public.create_group_balance_adjustment(uuid, date, numeric, text) from public;
revoke all on function public.get_group_accounting_report(uuid, date) from public;
revoke all on function public.get_member_accounting_report(uuid, date) from public;
revoke all on function public.validate_group_balance_adjustments_backup(jsonb) from public;
revoke all on function public.export_group_backup_with_balance_adjustments(uuid) from public;
revoke all on function public.preview_group_backup_restore_with_balance_adjustments(uuid, jsonb) from public;
revoke all on function public.restore_group_backup_with_balance_adjustments(uuid, jsonb, text) from public;

grant execute on function public.create_group_balance_adjustment(uuid, date, numeric, text) to authenticated;
grant execute on function public.get_group_accounting_report(uuid, date) to authenticated;
grant execute on function public.get_member_accounting_report(uuid, date) to authenticated;
grant execute on function public.export_group_backup_with_balance_adjustments(uuid) to authenticated;
grant execute on function public.preview_group_backup_restore_with_balance_adjustments(uuid, jsonb) to authenticated;
grant execute on function public.restore_group_backup_with_balance_adjustments(uuid, jsonb, text) to authenticated;

notify pgrst, 'reload schema';

commit;
