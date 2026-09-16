-- sky-member: 관리자용 모임 데이터 백업 함수
-- Supabase SQL Editor에서 한 번 실행하세요.
-- 이 함수는 현재 로그인한 모임 관리자에게만 해당 모임의 백업 데이터를 반환합니다.

create or replace function public.export_group_backup(p_group_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_group jsonb;
  v_dues_settings jsonb;
  v_members jsonb;
  v_dues_payments jsonb;
  v_admin_notes jsonb;
begin
  if auth.uid() is null or not public.is_group_admin(p_group_id) then
    raise exception '이 모임의 관리자만 데이터를 백업할 수 있습니다.';
  end if;

  select jsonb_build_object(
    'name', g.name,
    'description', coalesce(g.description, ''),
    'bylaws', coalesce(g.bylaws, '')
  )
  into v_group
  from public.groups g
  where g.id = p_group_id;

  if v_group is null then
    raise exception '모임 정보를 찾을 수 없습니다.';
  end if;

  select jsonb_build_object(
    'monthly_amount', ds.monthly_amount,
    'account_bank', ds.account_bank,
    'account_number', ds.account_number,
    'account_holder', ds.account_holder,
    'due_day', ds.due_day,
    'updated_at', ds.updated_at
  )
  into v_dues_settings
  from public.dues_settings ds
  where ds.group_id = p_group_id;

  select coalesce(jsonb_agg(jsonb_build_object(
    'membership_no', m.membership_no,
    'name', m.name,
    'nickname', m.member_id,
    'phone', m.phone,
    'email', m.email,
    'join_date', m.join_date,
    'approval_status', coalesce(m.approval_status, 'approved'),
    'member_status', m.status,
    'created_at', m.created_at
  ) order by m.created_at asc, m.name asc), '[]'::jsonb)
  into v_members
  from public.members m
  where m.group_id = p_group_id;

  select coalesce(jsonb_agg(jsonb_build_object(
    'member_membership_no', m.membership_no,
    'member_name', m.name,
    'member_email', m.email,
    'due_month', dp.due_month,
    'amount', dp.amount,
    'status', dp.status,
    'paid_at', dp.paid_at,
    'note', dp.note,
    'created_at', dp.created_at,
    'updated_at', dp.updated_at
  ) order by dp.due_month desc, m.name asc), '[]'::jsonb)
  into v_dues_payments
  from public.dues_payments dp
  join public.members m on m.id = dp.member_id
  where dp.group_id = p_group_id;

  select coalesce(jsonb_agg(jsonb_build_object(
    'member_membership_no', m.membership_no,
    'member_name', m.name,
    'member_email', m.email,
    'memo', n.memo,
    'updated_at', n.updated_at
  ) order by m.name asc), '[]'::jsonb)
  into v_admin_notes
  from public.member_admin_notes n
  join public.members m on m.id = n.member_id
  where m.group_id = p_group_id;

  return jsonb_build_object(
    'format', 'sky-member-backup',
    'version', 1,
    'exported_at', now(),
    'group', v_group,
    'dues_settings', coalesce(v_dues_settings, '{}'::jsonb),
    'members', v_members,
    'dues_payments', v_dues_payments,
    'admin_notes', v_admin_notes,
    'excluded_data', jsonb_build_array('로그인 비밀번호', '인증 계정 연결 정보', '초대코드')
  );
end;
$$;

revoke all on function public.export_group_backup(uuid) from public;
grant execute on function public.export_group_backup(uuid) to authenticated;
