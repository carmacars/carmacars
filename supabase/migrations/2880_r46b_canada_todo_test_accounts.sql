-- 2880 (release 46, part B): the Admin To do "Send N staff in Canada a new agreement" (2862) and the "Lives in Canada:
-- needs the Canadian terms" badge of Settings > Staff, Staff agreements, listed the test accounts the live checks make
-- (the invitation check's "Verify Invitation"). A test account never needs a new agreement: app.staff_agreement_needs_canada
-- leaves out every account app.staff_is_test names (0440: users.is_test, verify- and +verify- addresses, resend.dev and
-- Site settings' admin test addresses). The badge, the To do's closing rule (2862's sign_request_create) and the To do
-- read it, so all three follow.
--
-- Once: the open To do is written again from the real staff only (its count in the title, their names in the detail), or
-- closed when nobody real is left.

create or replace function app.staff_agreement_needs_canada(p_user uuid) returns boolean
language sql stable security definer set search_path = public, app as $$
  select app.staff_is_member(p_user) and app.staff_in_canada(p_user) and not app.staff_is_test(p_user)
     and coalesce((select app.staff_terms_canadian(a.extra) = false from app.staff_current_agreement(p_user) a where a.id is not null), false)
$$;
comment on function app.staff_agreement_needs_canada(uuid) is 'r45 (2862), r46 (2880): an active staff member in Canada, not a test account, whose current staff agreement (waiting, or signed) carries terms that are not Canadian.';

do $$
declare
  v_names text;
  v_n integer;
  v_fixed integer;
begin
  select count(*), string_agg(coalesce(nullif(btrim(u.greeting_name), ''), u.full_name, u.email), ', ' order by u.full_name)
    into v_n, v_names
    from staff_profiles sp join users u on u.id = sp.user_id
   where app.staff_agreement_needs_canada(sp.user_id);
  if coalesce(v_n, 0) = 0 then
    update tasks set status = 'done', completed_at = now(), completion_note = 'Nobody real needs a new agreement (test accounts left out, 2880)'
     where task_type = 'staff_agreement_canada' and status in ('open', 'in_progress', 'waiting');
  else
    update tasks set title = format('Send %s staff in Canada a new agreement with Canadian terms', v_n),
           detail = left(format('Their agreement says the Philippines, USD or OnlineJobs.ph: %s. Settings > Staff, Staff agreements: press Send a new agreement beside each (it is filled with Canada, CAD and Interac e-Transfer or direct deposit). A signed one stays on file as superseded.', v_names), 1000)
     where task_type = 'staff_agreement_canada' and status in ('open', 'in_progress', 'waiting');
  end if;
  get diagnostics v_fixed = row_count;
  raise notice '2880: % real staff need a new agreement; % open To do rewritten or closed', coalesce(v_n, 0), v_fixed;
end $$;

revoke all on function app.staff_agreement_needs_canada(uuid) from public, anon, authenticated;
grant execute on function app.staff_agreement_needs_canada(uuid) to service_role;
