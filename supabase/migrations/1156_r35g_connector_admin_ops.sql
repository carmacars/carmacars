-- 1156_r35g_connector_admin_ops.sql
-- Release 35, part G: the Claude connector (/api/mcp; 0562, 0732, 0810) does the Admin's daily operations without a browser.
--   Reads (scope admin:read): booking photos; a booking's agreements and who signed; claims (list, one); expenses; owner
--   statements (list, one), owner invoices (with how each is paid and "deduct from payouts starting"), payouts, staff
--   commissions and insurer invoices, each with paid or unpaid; tolls and tickets; leads (with who holds each, the marketing
--   source), live chats, visitor leads and each rep's leads and bookings; To do queues; a car's calendar; field jobs; staff
--   onboarding (where each person is, who waits for approval); deposit reviews.
--   Every list tool (the earlier ones too: bookings, requests, owners, cars, candidates, staff) pages past 50 rows with a
--   cursor (limit up to 200; the answer's next_cursor) and hides test records unless include_test is true.
--   Writes (scope admin:write), each previewed then confirmed as before (0732): resend an agreement; update a claim; add an
--   expense; set how an owner invoice is paid and from which payout it is deducted; match a toll or ticket to a booking;
--   complete a To do; assign a field job; approve or reject a person's onboarding; end (0732) or restore staff access;
--   record a past trip; upload a booking photo (pickup, return or damage: the bytes are stored by the web layer).
--   Money out (a refund, a deposit release, a payout, a charge) is prepared only: prepare_money_action, previewed then
--   confirmed, puts an Admin To do with the prepared action and its link; the connector never moves money.
--   Identity: every key belongs to one Admin and has a name (Admin > Settings > API access); the booking history and the
--   audit log of a change made through the connector say "via Claude: <person> (key <name>)", and the call log keeps the key.
-- No applied migration is edited: app.api_call, app.api_action and app.api_target are wrapped, the via line patched.
set local check_function_bodies = off;

create function pg_temp.copy_grants(p_new regprocedure, p_old regprocedure) returns void
language plpgsql as $$
declare g text;
begin
  execute format('revoke all on function %s from public, anon, authenticated', p_new);
  foreach g in array array['anon', 'authenticated', 'service_role'] loop
    if has_function_privilege(g, p_old, 'execute') then execute format('grant execute on function %s to %I', p_new, g); end if;
  end loop;
end $$;
create function pg_temp.patch_fn(p_sig regprocedure, p_old text, p_new text) returns void
language plpgsql as $$
declare d text := pg_get_functiondef(p_sig);
begin
  if position(p_old in d) = 0 then raise exception '1156: the text to change was not found in %: %', p_sig, left(p_old, 120); end if;
  execute replace(d, p_old, p_new);
end $$;

-- ================================================================ identity: whose Claude made the change
create function app.api_via(k api_keys) returns text
language sql stable security definer set search_path = public, app as $$
  select left(format('via Claude: %s (key %s)', coalesce((select coalesce(nullif(btrim(u.full_name), ''), u.email) from users u where u.id = k.user_id), 'an Admin'), coalesce(k.name, k.prefix)), 200)
$$;
select pg_temp.patch_fn('app.api_call(text, text, jsonb, text)'::regprocedure,
  'perform set_config(''app.via'', ''via Claude connector'', true);',
  'perform set_config(''app.via'', app.api_via(k), true);');

-- ================================================================ the writes: each one door action of the screens
alter function app.api_action(text) rename to api_action_pre1156;
create function app.api_action(p_tool text) returns jsonb
language sql immutable as $$
  select case p_tool
    when 'resend_agreement'        then '{"call":"ops_do","name":"agreement_resend","target":"booking"}'::jsonb
    when 'update_claim'            then '{"call":"admin_do","name":"claim_status","target":"claim"}'::jsonb
    when 'add_expense'             then '{"call":"admin_do","name":"api_expense_add","target":"none"}'::jsonb
    when 'set_invoice_collect_by'  then '{"call":"admin_do","name":"owner_invoice_collect_by","target":"invoice"}'::jsonb
    when 'set_invoice_deduct_from' then '{"call":"admin_do","name":"owner_invoice_deduct_from","target":"invoice"}'::jsonb
    when 'match_toll'              then '{"call":"admin_do","name":"toll_rematch","target":"toll"}'::jsonb
    when 'complete_todo'           then '{"call":"admin_do","name":"task_complete","target":"task"}'::jsonb
    when 'assign_field_job'        then '{"call":"ops_do","name":"field_job_assign","target":"field_job"}'::jsonb
    when 'approve_onboarding'      then '{"call":"ops_do","name":"staff_onboarding_approve","target":"onboarding"}'::jsonb
    when 'reject_onboarding'       then '{"call":"ops_do","name":"staff_onboarding_reject","target":"onboarding"}'::jsonb
    when 'restore_staff_access'    then '{"call":"admin_do","name":"staff_restore","target":"staff"}'::jsonb
    when 'record_past_trip'        then '{"call":"ops_do","name":"handover_override","target":"booking"}'::jsonb
    else app.api_action_pre1156(p_tool) end
$$;

alter function app.api_target(text, jsonb) rename to api_target_pre1156;
create function app.api_target(p_kind text, a jsonb) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
begin
  case p_kind
  when 'claim' then
    return (select jsonb_build_object('claim_id', c.id, 'claim_number', c.claim_number, 'status', c.status, 'damage_cost_cents', c.damage_cost_cents, 'insurer_claim_ref', c.insurer_claim_ref,
                     'denied_reason', c.denied_reason, 'admin_path', '/admin/claims/' || c.id) from claims c where c.id::text = a ->> 'id' or c.claim_number = a ->> 'id');
  when 'task' then
    return (select jsonb_build_object('id', t.id, 'queue', t.queue, 'title', t.title, 'status', t.status, 'assigned_to', t.assigned_to, 'completed_at', t.completed_at) from tasks t where t.id::text = a ->> 'id');
  when 'toll' then
    return (select jsonb_build_object('id', t.id, 'kind', t.kind, 'notice_number', t.notice_number, 'status', t.status, 'matched_to', t.matched_to, 'booking_id', t.booking_id,
                     'booking_number', (select b.booking_number from bookings b where b.id = t.booking_id)) from toll_tickets t where t.id::text = a ->> 'id');
  when 'field_job' then
    return (select jsonb_build_object('id', j.id, 'kind', j.kind, 'status', j.status, 'scheduled_at', j.scheduled_at, 'assigned_to', j.assigned_to,
                     'assignee', (select u.full_name from users u where u.id = j.assigned_to)) from field_jobs j where j.id::text = a ->> 'id');
  when 'onboarding' then
    return (select jsonb_build_object('user_id', sp.user_id, 'name', app.staff_display_name(sp.user_id), 'step', app.staff_onboarding_state(sp.user_id) ->> 'step',
                     'approved_at', sp.onboarding_approved_at, 'reject_reason', sp.onboarding_reject_reason) from staff_profiles sp where sp.user_id::text = coalesce(a ->> 'user', a ->> 'user_id'));
  when 'none' then return null;
  else return app.api_target_pre1156(p_kind, a);
  end case;
exception when invalid_text_representation then return null;
end $$;

-- add an expense (Admin > Expenses' form): p {expense_on, category, description, amount_cents, hst_cents, vehicle_id}
create function app.api_expense_add(p_by uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare v_id uuid;
begin
  perform app.assert_admin(p_by);
  if not exists (select 1 from company_expense_categories c where c.code = p ->> 'category' and c.is_active) then
    raise exception 'Unknown expense category: %', coalesce(p ->> 'category', '(none)') using errcode = '22023';
  end if;
  if coalesce((p ->> 'amount_cents')::bigint, 0) <= 0 then raise exception 'The amount, in cents, above zero' using errcode = '22023'; end if;
  if length(btrim(coalesce(p ->> 'description', ''))) < 3 then raise exception 'Describe the expense' using errcode = '22023'; end if;
  insert into company_expenses (expense_on, category, description, amount_cents, hst_cents, vehicle_id, created_by)
  values (coalesce(nullif(p ->> 'expense_on', '')::date, app.today()), p ->> 'category', left(btrim(p ->> 'description'), 500), (p ->> 'amount_cents')::bigint,
          coalesce(nullif(p ->> 'hst_cents', '')::bigint, 0), nullif(p ->> 'vehicle_id', '')::uuid, p_by)
  returning id into v_id;
  return jsonb_build_object('id', v_id, 'admin_path', '/admin/expenses');
end $$;

-- ================================================================ the reads: one source per list, paged by a cursor
-- (k, id) orders a list newest first; test marks a test record (a verify or test account, a sample car)
create function app.api_src(p_tool text, a jsonb) returns table (k timestamptz, id uuid, test boolean)
language plpgsql stable security definer set search_path = public, app as $$
declare
  v_q text := nullif(btrim(coalesce(a ->> 'query', '')), '');
  v_status text := nullif(a ->> 'status', '');
  v_unpaid boolean := coalesce((a ->> 'unpaid')::boolean, false);
  v_from timestamptz := nullif(a ->> 'from', '')::timestamptz;
  v_to timestamptz := nullif(a ->> 'to', '')::timestamptz;
begin
  case p_tool
  when 'list_bookings', 'list_requests' then
    return query select b.pickup_at, b.id, app.booking_is_test(b.id) from bookings b left join renters r on r.id = b.renter_id left join vehicles v on v.id = b.vehicle_id
     where not coalesce(b.is_placeholder, false)
       and (case when p_tool = 'list_requests' then b.status::text in ('requested', 'offered', 'tentative') else v_status is null or b.status::text = v_status end)
       and (v_from is null or b.return_at >= v_from) and (v_to is null or b.pickup_at <= v_to)
       and (v_q is null or app.search_key(b.booking_number) like '%' || app.search_key(v_q) || '%' or lower(coalesce(r.legal_name, '')) like app.search_like(v_q)
            or lower(coalesce(r.email, '')) like app.search_like(v_q) or app.search_key(v.plate) = app.search_key(v_q));
  when 'list_owners' then
    return query select o.created_at, o.id, coalesce(o.is_test, false) from owners o
     where o.kind = 'program' and (v_q is null or lower(o.legal_name) like app.search_like(v_q) or lower(coalesce(o.email, '')) like app.search_like(v_q));
  when 'list_cars' then
    return query select v.created_at, v.id, coalesce(v.is_sample, false) from vehicles v
     where v.retired_at is null and (v_status is null or v.status::text = v_status)
       and (v_q is null or app.search_key(v.plate) = app.search_key(v_q) or lower(app.vehicle_name(v.id)) like app.search_like(v_q) or v.vin = upper(v_q));
  when 'list_applicants' then
    return query select j.created_at, j.id, app.email_is_test(j.email) from job_applications j
     where j.purged_at is null and (v_status is null or j.status = v_status)
       and (v_q is null or lower(j.full_name) like app.search_like(v_q) or lower(coalesce(j.email, '')) like app.search_like(v_q));
  when 'list_staff' then
    return query select u.created_at, u.id, app.staff_is_test(u.id) from users u
     where exists (select 1 from user_roles r where r.user_id = u.id and r.role in ('va', 'field', 'admin'))
       and (v_q is null or lower(coalesce(u.full_name, '')) like app.search_like(v_q) or lower(u.email) like app.search_like(v_q));
  when 'list_claims' then
    return query select c.created_at, c.id, app.booking_is_test(c.booking_id) from claims c
     where (v_status is null or c.status = v_status) and (v_q is null or c.claim_number ilike '%' || v_q || '%' or c.insurer_claim_ref ilike '%' || v_q || '%');
  when 'list_expenses' then
    return query select e.expense_on::timestamptz, e.id, false from company_expenses e
     where e.voided_at is null and (v_from is null or e.expense_on >= v_from::date) and (v_to is null or e.expense_on <= v_to::date)
       and (nullif(a ->> 'category', '') is null or e.category = a ->> 'category');
  when 'list_owner_statements' then
    return query select s.statement_month::timestamptz, s.id, coalesce(o.is_test, false) from owner_statements s join owners o on o.id = s.owner_id
     where (v_status is null or s.status = v_status) and (nullif(a ->> 'owner_id', '') is null or s.owner_id::text = a ->> 'owner_id');
  when 'list_owner_invoices' then
    return query select i.billing_date::timestamptz, i.id, coalesce(o.is_test, false) from owner_invoices i join owners o on o.id = i.owner_id
     where (v_status is null or i.status = v_status) and (nullif(a ->> 'owner_id', '') is null or i.owner_id::text = a ->> 'owner_id')
       and (not v_unpaid or (i.balance_cents > 0 and i.status not in ('void', 'paid', 'deducted', 'draft')));
  when 'list_payouts' then
    return query select coalesce(p.scheduled_for::timestamptz, p.created_at), p.id,
                        coalesce((select o.is_test from owners o where o.id = p.owner_id), false) or (p.staff_user_id is not null and app.staff_is_test(p.staff_user_id)) from payouts p
     where (v_status is null or p.status = v_status) and (nullif(a ->> 'payee_type', '') is null or p.payee_type = a ->> 'payee_type')
       and (not v_unpaid or p.status not in ('paid', 'cancelled'));
  when 'list_commissions' then
    return query select coalesce(c.earned_at, c.created_at), c.id, app.staff_is_test(c.staff_id) from staff_commissions c
     where (v_status is null or c.status = v_status) and (nullif(a ->> 'staff_id', '') is null or c.staff_id::text = a ->> 'staff_id')
       and (not v_unpaid or c.paid_at is null);
  when 'list_insurer_invoices' then
    return query select i.created_at, i.id, app.booking_is_test(i.booking_id) from insurer_invoices i
     where (v_status is null or i.status = v_status) and (not v_unpaid or (i.balance_cents > 0 and i.written_off_at is null));
  when 'list_tolls' then
    return query select coalesce(t.occurred_at, t.created_at), t.id, app.booking_is_test(t.booking_id) from toll_tickets t
     where (v_status is null or t.status = v_status) and (not coalesce((a ->> 'unmatched')::boolean, false) or t.booking_id is null)
       and (v_q is null or t.notice_number ilike '%' || v_q || '%' or app.search_key(t.plate) = app.search_key(v_q));
  when 'list_leads' then
    return query select l.created_at, l.id, app.email_is_test(l.email) from leads l
     where (v_status is null or l.status = v_status) and (nullif(a ->> 'assigned_to', '') is null or l.assigned_to::text = a ->> 'assigned_to')
       and (nullif(a ->> 'source', '') is null or l.source = a ->> 'source' or l.utm_source = a ->> 'source')
       and (v_from is null or l.created_at >= v_from) and (v_to is null or l.created_at <= v_to)
       and (v_q is null or lower(coalesce(l.name, '')) like app.search_like(v_q) or lower(coalesce(l.email, '')) like app.search_like(v_q)
            or (length(app.search_digits(v_q)) >= 4 and app.search_digits(l.phone) like '%' || app.search_digits(v_q) || '%'));
  when 'list_chats' then
    return query select coalesce(c.last_message_at, c.created_at), c.id, app.email_is_test(c.email) from chat_conversations c
     where (v_status is null or c.status = v_status);
  when 'list_visitor_leads' then
    return query select s.last_seen_at, s.id, app.email_is_test(s.known_email) from visitor_sessions s
     where (s.has_contact or s.hot_at is not null or s.known_email is not null) and (v_from is null or s.last_seen_at >= v_from);
  when 'list_todos' then
    return query select t.created_at, t.id, false from tasks t
     where (case when v_status is null then t.status in ('open', 'in_progress', 'waiting') else t.status = v_status end)
       and (nullif(a ->> 'queue', '') is null or t.queue = a ->> 'queue') and (nullif(a ->> 'assigned_to', '') is null or t.assigned_to::text = a ->> 'assigned_to');
  when 'list_field_jobs' then
    return query select j.scheduled_at, j.id, app.booking_is_test(j.booking_id) from field_jobs j
     where (v_status is null or j.status = v_status) and (v_from is null or j.scheduled_at >= v_from) and (v_to is null or j.scheduled_at <= v_to);
  when 'list_deposit_reviews' then
    return query select coalesce(d.returned_at, d.created_at), d.booking_id, app.booking_is_test(d.booking_id) from deposit_reviews d
     where (coalesce((a ->> 'all')::boolean, false) or d.finance_done_at is null);
  when 'list_booking_photos' then
    return query select p.taken_at, p.id, false from condition_report_photos p join condition_reports r on r.id = p.condition_report_id
     where r.booking_id = (select b.id from bookings b where b.booking_number = upper(btrim(coalesce(a ->> 'booking', ''))) or b.id::text = a ->> 'booking');
  end case;
end $$;

-- one row of a list, as the answer shows it
create function app.api_row(p_tool text, p_id uuid) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
begin
  return case p_tool
  when 'list_bookings' then app.api_booking_row(p_id)
  when 'list_requests' then app.api_booking_row(p_id)
  when 'list_cars' then app.api_vehicle_row(p_id)
  when 'list_staff' then app.api_staff_row(p_id) || jsonb_build_object('onboarding', app.staff_onboarding_state(p_id) ->> 'step')
  when 'list_owners' then (select jsonb_build_object('owner_id', o.id, 'name', o.legal_name, 'email', o.email, 'phone', o.phone, 'status', o.status,
      'cars', (select count(*) from vehicles v where v.owner_id = o.id and v.retired_at is null), 'admin_path', '/admin/owners/' || o.id) from owners o where o.id = p_id)
  when 'list_applicants' then (select jsonb_build_object('application_id', x.id, 'name', x.full_name, 'email', x.email, 'role', (select r.title from hiring_roles r where r.id = x.role_id),
      'status', x.status, 'score', x.score, 'applied_at', x.created_at, 'admin_path', '/admin/hiring/' || x.id) from job_applications x where x.id = p_id)
  when 'list_claims' then (select to_jsonb(c) || jsonb_build_object('claim_id', c.id, 'booking_number', (select b.booking_number from bookings b where b.id = c.booking_id),
      'car', app.vehicle_name(c.vehicle_id), 'admin_path', '/admin/claims/' || c.id) from claims c where c.id = p_id)
  when 'list_expenses' then (select to_jsonb(e) || jsonb_build_object('car', case when e.vehicle_id is not null then app.vehicle_name(e.vehicle_id) end) from company_expenses e where e.id = p_id)
  when 'list_owner_statements' then (select jsonb_build_object('id', s.id, 'statement_number', s.statement_number, 'owner', (select o.legal_name from owners o where o.id = s.owner_id), 'owner_id', s.owner_id,
      'statement_month', s.statement_month, 'period_starts_on', s.period_starts_on, 'period_ends_on', s.period_ends_on, 'payout_date', s.payout_date, 'status', s.status,
      'owner_revenue_cents', s.owner_revenue_cents, 'payout_cents', s.payout_cents, 'balance_carried_forward_cents', s.balance_carried_forward_cents,
      'paid', exists (select 1 from payouts p where p.owner_statement_id = s.id and p.status = 'paid'), 'admin_path', '/admin/statements/' || s.id) from owner_statements s where s.id = p_id)
  when 'list_owner_invoices' then (select jsonb_build_object('id', i.id, 'invoice_number', i.invoice_number, 'owner', (select o.legal_name from owners o where o.id = i.owner_id), 'owner_id', i.owner_id,
      'car', case when i.vehicle_id is not null then app.vehicle_name(i.vehicle_id) end, 'kind', i.kind, 'status', i.status, 'billing_date', i.billing_date, 'total_cents', i.total_cents,
      'paid_cents', i.paid_cents, 'deducted_cents', i.deducted_cents, 'balance_cents', i.balance_cents, 'paid', i.balance_cents <= 0 or i.status in ('paid', 'deducted'),
      'how_paid', case when i.collect_by = 'payout' then 'deducted from payouts' else 'bank debit' end, 'deduct_from_payout_on', i.deduct_from_payout_on,
      'admin_path', '/admin/invoices/' || i.invoice_number) from owner_invoices i where i.id = p_id)
  when 'list_payouts' then (select jsonb_build_object('id', p.id, 'payee_type', p.payee_type, 'kind', p.kind, 'payee', coalesce((select o.legal_name from owners o where o.id = p.owner_id), (select u.full_name from users u where u.id = p.staff_user_id)),
      'amount_cents', p.amount_cents, 'currency', p.currency, 'method', p.method, 'scheduled_for', p.scheduled_for, 'status', p.status, 'paid', p.status = 'paid', 'paid_at', p.paid_at, 'reference', p.reference) from payouts p where p.id = p_id)
  when 'list_commissions' then (select jsonb_build_object('id', c.id, 'staff', (select u.full_name from users u where u.id = c.staff_id), 'staff_id', c.staff_id, 'kind', c.kind, 'month', c.month,
      'booking_number', (select b.booking_number from bookings b where b.id = c.booking_id), 'amount_cents', c.amount_cents, 'status', c.status, 'paid', c.paid_at is not null, 'paid_at', c.paid_at) from staff_commissions c where c.id = p_id)
  when 'list_insurer_invoices' then (select jsonb_build_object('id', i.id, 'invoice_number', i.invoice_number, 'booking_number', (select b.booking_number from bookings b where b.id = i.booking_id),
      'claim_number', i.claim_number, 'period_start', i.period_start, 'period_end', i.period_end, 'total_cents', i.total_cents, 'paid_cents', i.paid_cents, 'balance_cents', i.balance_cents,
      'status', i.status, 'paid', i.balance_cents <= 0, 'written_off', i.written_off_at is not null, 'sent_at', i.sent_at) from insurer_invoices i where i.id = p_id)
  when 'list_tolls' then (select jsonb_build_object('id', t.id, 'kind', t.kind, 'notice_number', t.notice_number, 'authority', t.authority, 'plate', t.plate, 'occurred_at', t.occurred_at,
      'amount_cents', t.amount_cents, 'status', t.status, 'matched_to', t.matched_to, 'booking_number', (select b.booking_number from bookings b where b.id = t.booking_id), 'due_on', t.due_on) from toll_tickets t where t.id = p_id)
  when 'list_leads' then (select jsonb_build_object('lead_id', l.id, 'kind', l.kind, 'name', l.name, 'email', l.email, 'phone', l.phone, 'status', l.status, 'created_at', l.created_at,
      'source', l.source, 'marketing_source', coalesce(l.utm_source, l.source), 'utm_campaign', l.utm_campaign, 'assigned_to', (select u.full_name from users u where u.id = l.assigned_to),
      'claimed_by', (select u.full_name from lead_claims c join users u on u.id = c.claimed_by where c.lead_id = l.id and c.expires_at > now()),
      'claim_expires_at', (select c.expires_at from lead_claims c where c.lead_id = l.id and c.expires_at > now()), 'message', left(l.message, 500)) from leads l where l.id = p_id)
  when 'list_chats' then (select jsonb_build_object('id', c.id, 'number', c.number, 'name', c.name, 'email', c.email, 'phone', c.phone, 'status', c.status, 'page', c.page,
      'assigned_to', (select u.full_name from users u where u.id = c.assigned_to), 'human_requested_at', c.human_requested_at, 'last_message_at', c.last_message_at,
      'last_messages', (select coalesce(jsonb_agg(m.j order by m.at), '[]'::jsonb) from (select jsonb_build_object('from', x.sender, 'body', left(x.body, 400), 'at', x.at) j, x.at at
                          from chat_messages x where x.conversation_id = c.id order by x.at desc limit 5) m)) from chat_conversations c where c.id = p_id)
  when 'list_visitor_leads' then (select jsonb_build_object('session_id', s.id, 'name', s.known_name, 'email', s.known_email, 'city', s.city, 'country', s.country, 'score', s.score, 'hot_at', s.hot_at,
      'source', coalesce(s.utm ->> 'source', s.referrer), 'landing_path', s.landing_path, 'pages', s.page_views, 'last_seen_at', s.last_seen_at,
      'assigned_to', (select u.full_name from users u where u.id = s.assigned_to)) from visitor_sessions s where s.id = p_id)
  when 'list_todos' then (select jsonb_build_object('id', t.id, 'queue', t.queue, 'type', t.task_type, 'title', t.title, 'detail', left(t.detail, 500), 'priority', t.priority, 'status', t.status,
      'due_at', t.due_at, 'assigned_to', (select u.full_name from users u where u.id = t.assigned_to), 'booking_number', (select b.booking_number from bookings b where b.id = t.booking_id),
      'created_at', t.created_at) from tasks t where t.id = p_id)
  when 'list_field_jobs' then (select jsonb_build_object('id', j.id, 'kind', j.kind, 'status', j.status, 'scheduled_at', j.scheduled_at, 'place', j.place,
      'booking_number', (select b.booking_number from bookings b where b.id = j.booking_id), 'car', app.vehicle_name(j.vehicle_id),
      'assigned_to', j.assigned_to, 'assignee', (select u.full_name from users u where u.id = j.assigned_to), 'completed_at', j.completed_at) from field_jobs j where j.id = p_id)
  when 'list_deposit_reviews' then (select jsonb_build_object('booking_number', (select b.booking_number from bookings b where b.id = d.booking_id), 'plate', d.plate, 'returned_at', d.returned_at,
      'places', d.places, 'fleet_done_at', d.fleet_done_at, 'finance_done_at', d.finance_done_at,
      'deposit', (select jsonb_build_object('status', x.status, 'amount_cents', x.amount_cents, 'method', x.method) from deposits x where x.booking_id = d.booking_id)) from deposit_reviews d where d.booking_id = p_id)
  when 'list_booking_photos' then (select jsonb_build_object('id', p.id, 'stage', r.kind, 'shot', p.shot, 'damage_id', p.damage_id, 'taken_at', p.taken_at, 'path', p.storage_path)
      from condition_report_photos p join condition_reports r on r.id = p.condition_report_id where p.id = p_id)
  end;
end $$;

-- the page: newest first, after the cursor ("<k>|<id>" of the last row), test records hidden unless include_test
create function app.api_page(p_tool text, a jsonb) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare
  v_lim integer := least(greatest(coalesce(nullif(a ->> 'limit', '')::integer, 20), 1), 200);
  v_test boolean := coalesce((a ->> 'include_test')::boolean, false);
  v_ck timestamptz;
  v_cid uuid;
  v_rows jsonb;
  v_next text;
  v_n integer;
begin
  if nullif(a ->> 'cursor', '') is not null then
    begin
      v_ck := split_part(a ->> 'cursor', '|', 1)::timestamptz; v_cid := split_part(a ->> 'cursor', '|', 2)::uuid;
    exception when others then raise exception 'Not a cursor from this list: start again without one' using errcode = '22023';
    end;
  end if;
  select coalesce(jsonb_agg(app.api_row(p_tool, x.id) order by x.n) filter (where x.n <= v_lim), '[]'::jsonb), count(*)::integer,
         (array_agg(x.k::text || '|' || x.id) filter (where x.n = v_lim))[1]
    into v_rows, v_n, v_next
    from (select row_number() over (order by s.k desc, s.id desc) as n, s.k, s.id
            from (select coalesce(z.k, '-infinity'::timestamptz) as k, z.id from app.api_src(p_tool, a) z
                   where (v_test or not coalesce(z.test, false))
                     and (v_ck is null or (coalesce(z.k, '-infinity'::timestamptz), z.id) < (v_ck, v_cid))
                   order by coalesce(z.k, '-infinity'::timestamptz) desc, z.id desc limit v_lim + 1) s) x;
  return jsonb_build_object('items', v_rows, 'count', least(v_n, v_lim),
    'next_cursor', case when v_n > v_lim then v_next end,
    'test_hidden', not v_test);
end $$;

-- the reads that are one record or a summary
create function app.api_read(p_by uuid, p_tool text, a jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  v_b uuid := (select b.id from bookings b where b.booking_number = upper(btrim(coalesce(a ->> 'booking', ''))) or b.id::text = a ->> 'booking');
  v_from timestamptz := coalesce(nullif(a ->> 'from', '')::timestamptz, now() - interval '30 days');
  v_to timestamptz := coalesce(nullif(a ->> 'to', '')::timestamptz, now() + interval '60 days');
  v jsonb;
begin
  case p_tool
  when 'get_agreement' then
    if v_b is null then raise exception 'No booking %', a ->> 'booking' using errcode = 'P0002'; end if;
    return jsonb_build_object('booking', (select b.booking_number from bookings b where b.id = v_b),
      'agreements', coalesce((select jsonb_agg(jsonb_build_object('agreement_number', g.agreement_number, 'status', g.status, 'period', g.period_seq, 'opened_at', g.opened_at,
          'renter_signed_at', g.renter_signed_at, 'completed_at', g.completed_at, 'voided_at', g.voided_at,
          'signers', (select coalesce(jsonb_agg(jsonb_build_object('role', s.signer_role, 'name', s.signer_name, 'email', s.signer_email, 'signed_at', s.signed_at,
                        'link_sent_at', s.link_sent_at, 'sent_count', s.link_sent_count) order by s.created_at), '[]'::jsonb) from rental_agreement_signers s where s.agreement_id = g.id)) order by g.period_seq, g.opened_at)
        from rental_agreements g where g.booking_id = v_b), '[]'::jsonb),
      'signed', exists (select 1 from rental_agreements g where g.booking_id = v_b and g.completed_at is not null and g.voided_at is null),
      'admin_path', '/admin/bookings/' || (select b.booking_number from bookings b where b.id = v_b));
  when 'get_claim' then
    v := app.api_row('list_claims', (select c.id from claims c where c.id::text = a ->> 'claim' or c.claim_number = a ->> 'claim'));
    if v is null then raise exception 'No claim %', a ->> 'claim' using errcode = 'P0002'; end if;
    return v || jsonb_build_object('damages', (select coalesce(jsonb_agg(jsonb_build_object('id', d.id, 'label', d.label, 'location', d.location, 'description', d.description, 'kind', d.kind) order by d.label), '[]'::jsonb)
                from condition_report_damages d where d.incident_id = (select c.incident_id from claims c where c.id = (v ->> 'claim_id')::uuid)));
  when 'get_owner_statement' then
    v := app.api_row('list_owner_statements', nullif(a ->> 'id', '')::uuid);
    if v is null then raise exception 'No statement %', a ->> 'id' using errcode = 'P0002'; end if;
    return v || jsonb_build_object('lines', (select coalesce(jsonb_agg(jsonb_build_object('type', l.line_type, 'description', l.description, 'car', case when l.vehicle_id is not null then app.vehicle_name(l.vehicle_id) end,
                 'booking_number', (select b.booking_number from bookings b where b.id = l.booking_id), 'amount_cents', l.amount_cents, 'partial', l.partial) order by l.vehicle_id nulls last, l.starts_on nulls last), '[]'::jsonb)
               from owner_statement_lines l where l.owner_statement_id = (v ->> 'id')::uuid));
  when 'rep_summary' then
    return coalesce((select jsonb_agg(jsonb_build_object('user_id', u.id, 'name', u.full_name,
        'leads_claimed', (select count(distinct h.lead_id) from lead_claim_log h where h.user_id = u.id and h.action = 'claim' and h.at between v_from and v_to),
        'leads_held_now', (select count(*) from lead_claims c where c.claimed_by = u.id and c.expires_at > now()),
        'leads_brought', (select count(*) from leads l where l.sourced_by = u.id and l.created_at between v_from and v_to),
        'bookings', (select count(*) from bookings b where b.sales_staff_id = u.id and b.created_at between v_from and v_to and b.status::text not in ('cancelled', 'declined', 'expired')),
        'onboarded', app.staff_fully_onboarded(u.id)) order by u.full_name)
      from users u where exists (select 1 from staff_profiles sp where sp.user_id = u.id and 'sales' = any (sp.functions) and sp.is_active)
        and (coalesce((a ->> 'include_test')::boolean, false) or not app.staff_is_test(u.id))), '[]'::jsonb);
  when 'car_calendar' then
    return jsonb_build_object('vehicle_id', a ->> 'vehicle_id', 'car', app.vehicle_name(nullif(a ->> 'vehicle_id', '')::uuid), 'from', v_from, 'to', v_to,
      'bookings', coalesce((select jsonb_agg(jsonb_build_object('booking_number', b.booking_number, 'status', b.status, 'pickup_at', b.pickup_at, 'return_at', b.return_at,
          'renter', (select r.legal_name from renters r where r.id = b.renter_id), 'type', b.booking_type) order by b.pickup_at)
        from bookings b where b.vehicle_id = nullif(a ->> 'vehicle_id', '')::uuid and b.pickup_at < v_to and b.return_at > v_from
          and b.status::text not in ('cancelled', 'declined', 'expired', 'no_show')), '[]'::jsonb));
  when 'staff_onboarding_status' then
    return jsonb_build_object('people', app.staff_onboarding_list(p_by, '{}'::jsonb), 'waiting_for_approval', app.staff_onboarding_approvals(p_by, '{}'::jsonb));
  end case;
  return null;
end $$;

create function app.api_list_tools() returns text[]
language sql immutable as $$
  select array['list_bookings', 'list_requests', 'list_owners', 'list_cars', 'list_applicants', 'list_staff', 'list_claims', 'list_expenses', 'list_owner_statements',
               'list_owner_invoices', 'list_payouts', 'list_commissions', 'list_insurer_invoices', 'list_tolls', 'list_leads', 'list_chats', 'list_visitor_leads',
               'list_todos', 'list_field_jobs', 'list_deposit_reviews', 'list_booking_photos']
$$;
create function app.api_one_reads() returns text[]
language sql immutable as $$ select array['get_agreement', 'get_claim', 'get_owner_statement', 'rep_summary', 'car_calendar', 'staff_onboarding_status'] $$;

-- ================================================================ the call
-- the checks of 0562 and 0732 (the switch, the key, the Admin, the scope, the rate limit): the key, or the refusal
create function app.api_key_check(p_hash text, p_scope text, p_tool text, a jsonb, p_client text) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  s program_settings := app.settings();
  k api_keys;
  v_n integer;
begin
  if not s.api_access_enabled then return jsonb_build_object('ok', false, 'status', 403, 'error', 'API access is turned off in Admin > Settings > Program.'); end if;
  if p_hash is null or p_hash !~ '^[0-9a-f]{64}$' then return jsonb_build_object('ok', false, 'status', 401, 'error', 'Missing or malformed key.'); end if;
  select * into k from api_keys where key_hash = p_hash;
  if k.id is null or k.revoked_at is not null or (k.expires_at is not null and k.expires_at <= now()) then
    return jsonb_build_object('ok', false, 'status', 401, 'error', 'This key is not valid (unknown, revoked or expired).');
  end if;
  if not app.user_is_admin(k.user_id) then return jsonb_build_object('ok', false, 'status', 403, 'error', 'Only an active Admin may use API access.'); end if;
  if not (p_scope = any (k.scopes)) then
    insert into api_calls (key_id, user_id, tool, args, ok, error, client) values (k.id, k.user_id, p_tool, a, false, 'scope ' || p_scope || ' not granted', left(p_client, 64));
    return jsonb_build_object('ok', false, 'status', 403, 'error', format('This key does not have the %s scope. Make a new key with it in Admin > Settings > API access, or reconnect Claude.', p_scope));
  end if;
  select count(*) into v_n from api_calls c where c.key_id = k.id and c.created_at > now() - interval '1 minute';
  if v_n >= s.api_calls_per_minute then
    return jsonb_build_object('ok', false, 'status', 429, 'error', format('Too many calls: at most %s a minute. Wait a moment.', s.api_calls_per_minute));
  end if;
  update api_keys set last_used_at = now() where id = k.id;
  return jsonb_build_object('ok', true, 'key', to_jsonb(k));
end $$;

alter function app.api_call(text, text, jsonb, text) rename to api_call_pre1156;
create function app.api_call(p_hash text, p_tool text, p_args jsonb, p_client text default null) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  a jsonb := case when jsonb_typeof(p_args) = 'object' then p_args else '{}'::jsonb end;
  v_list boolean := p_tool = any (app.api_list_tools());
  v_one boolean := p_tool = any (app.api_one_reads());
  v_own boolean := p_tool in ('prepare_money_action', 'upload_booking_photo');
  v_scope text;
  chk jsonb;
  k api_keys;
  v_result jsonb;
  v_door jsonb;
  v_confirm boolean;
  pv api_previews;
  v_before jsonb;
  v_target text;
  v_b bookings;
  v_rep uuid;
  v_task uuid;
begin
  -- record a past trip: the screen's past-trip form (kind past_trip), whatever the caller sends as kind
  if p_tool = 'record_past_trip' then return app.api_call_pre1156(p_hash, p_tool, a || '{"kind": "past_trip"}'::jsonb, p_client); end if;
  if not (v_list or v_one or v_own) then return app.api_call_pre1156(p_hash, p_tool, p_args, p_client); end if;
  v_scope := case when v_own then 'admin:write'
                  when p_tool in ('list_bookings') then 'bookings:read' when p_tool = 'list_requests' then 'requests:read' when p_tool = 'list_owners' then 'owners:read'
                  else 'admin:read' end;
  chk := app.api_key_check(p_hash, v_scope, p_tool, a, p_client);
  if not (chk ->> 'ok')::boolean then return chk; end if;
  k := jsonb_populate_record(null::api_keys, chk -> 'key');
  perform app.door_begin(k.user_id, 'aal2');
  v_confirm := coalesce((a ->> 'confirm')::boolean, false);
  -- the photo's bytes never go to the log or the preview: their fingerprint does
  v_door := a - 'confirm' - 'preview_id' - 'image_base64'
            || case when a ? 'image_base64' then jsonb_build_object('image_sha256', encode(sha256(convert_to(coalesce(a ->> 'image_base64', ''), 'UTF8')), 'hex'),
                                                                   'image_chars', length(coalesce(a ->> 'image_base64', ''))) else '{}'::jsonb end;
  begin
    if v_list then
      v_result := app.api_page(p_tool, v_door);
      v_target := p_tool;
    elsif v_one then
      v_result := app.api_read(k.user_id, p_tool, v_door);
      v_target := coalesce(v_door ->> 'booking', v_door ->> 'claim', v_door ->> 'id', v_door ->> 'vehicle_id', p_tool);
    else
      -- the two tools that do not run a screen's action: checked here, previewed, confirmed
      if p_tool = 'prepare_money_action' then
        if coalesce(v_door ->> 'kind', '') not in ('refund', 'deposit_release', 'payout', 'charge') then raise exception 'kind: refund, deposit_release, payout or charge' using errcode = '22023'; end if;
        if coalesce((v_door ->> 'amount_cents')::bigint, 0) <= 0 then raise exception 'The amount, in cents, above zero' using errcode = '22023'; end if;
        if length(btrim(coalesce(v_door ->> 'reason', ''))) < 5 then raise exception 'Say why (at least 5 characters)' using errcode = '22023'; end if;
        if v_door ? 'booking' then
          select * into v_b from bookings where booking_number = upper(btrim(v_door ->> 'booking')) or id::text = v_door ->> 'booking';
          if v_b.id is null then raise exception 'No booking %', v_door ->> 'booking' using errcode = 'P0002'; end if;
        elsif v_door ->> 'kind' <> 'payout' then raise exception 'Name the booking' using errcode = '22023';
        end if;
        v_before := case when v_b.id is not null then app.api_booking_row(v_b.id) end;
      else
        select * into v_b from bookings where booking_number = upper(btrim(coalesce(v_door ->> 'booking', ''))) or id::text = v_door ->> 'booking';
        if v_b.id is null then raise exception 'No booking %', v_door ->> 'booking' using errcode = 'P0002'; end if;
        if coalesce(v_door ->> 'stage', '') not in ('pickup', 'return', 'damage') then raise exception 'stage: pickup, return or damage' using errcode = '22023'; end if;
        if coalesce((v_door ->> 'image_chars')::integer, 0) = 0 then raise exception 'image_base64: the photo (JPEG or PNG), base64' using errcode = '22023'; end if;
        if v_door ->> 'stage' = 'damage' then
          select d.condition_report_id into v_rep from condition_report_damages d join condition_reports r on r.id = d.condition_report_id
           where d.id::text = v_door ->> 'damage_id' and r.booking_id = v_b.id;
          if v_rep is null then raise exception 'damage_id: a damage on this booking''s condition reports' using errcode = '22023'; end if;
        else
          select r.id into v_rep from condition_reports r where r.booking_id = v_b.id and r.kind = v_door ->> 'stage' order by r.performed_at desc nulls last, r.created_at desc limit 1;
          if v_rep is null then raise exception 'This booking has no % condition report yet: record the % first', v_door ->> 'stage', v_door ->> 'stage' using errcode = '23514'; end if;
        end if;
        v_before := jsonb_build_object('booking', v_b.booking_number, 'condition_report_id', v_rep,
          'photos', (select count(*) from condition_report_photos p where p.condition_report_id = v_rep));
      end if;
      v_target := coalesce(v_b.booking_number, v_door ->> 'payout_id', p_tool);
      if not v_confirm then
        insert into api_previews (key_id, user_id, tool, args, before, after) values (k.id, k.user_id, p_tool, v_door, v_before, null) returning * into pv;
        v_result := jsonb_build_object('preview', true, 'preview_id', pv.id, 'tool', p_tool, 'expires_at', pv.created_at + interval '10 minutes', 'before', v_before,
          'will_do', case when p_tool = 'prepare_money_action'
                          then format('Prepare a %s of %s (%s) as an Admin To do with its link. No money moves: an Admin does it in the portal.', replace(v_door ->> 'kind', '_', ' '), app.fmt_money((v_door ->> 'amount_cents')::bigint), v_door ->> 'reason')
                          else format('Store the photo (%s) on booking %s.', v_door ->> 'stage', v_b.booking_number) end,
          'next', 'Nothing was changed. To do it, call this tool again with exactly the same arguments plus "confirm": true and "preview_id": "' || pv.id || '".');
      else
        select * into pv from api_previews where id = nullif(a ->> 'preview_id', '')::uuid for update;
        if pv.id is null or pv.key_id <> k.id or pv.tool <> p_tool then raise exception 'Preview first: call without confirm, then confirm with its preview_id' using errcode = '22023'; end if;
        if pv.used_at is not null then raise exception 'This preview was already used: preview again' using errcode = '22023'; end if;
        if pv.created_at < now() - interval '10 minutes' then raise exception 'This preview is more than 10 minutes old: preview again' using errcode = '22023'; end if;
        if pv.args is distinct from v_door then raise exception 'The arguments differ from the preview: preview again with these' using errcode = '22023'; end if;
        update api_previews set used_at = now() where id = pv.id;
        if p_tool = 'prepare_money_action' then
          v_task := app.raise_task(p_type => 'api_prepared_money', p_title => format('Prepared by Claude: %s of %s%s', replace(v_door ->> 'kind', '_', ' '), app.fmt_money((v_door ->> 'amount_cents')::bigint),
                                     case when v_b.id is not null then ' on ' || v_b.booking_number else '' end),
            p_detail => format('%s. %s. Check it and do it in the portal: the connector never moves money.', v_door ->> 'reason', app.api_via(k)),
            p_related_table => case when v_b.id is not null then 'bookings' else 'payouts' end,
            p_related_id => coalesce(v_b.id, nullif(v_door ->> 'payout_id', '')::uuid), p_due_at => now(), p_priority => 'high',
            p_dedupe => 'api_money:' || pv.id, p_queue => 'admin', p_created_by => k.user_id);
          update tasks set booking_id = v_b.id where id = v_task and v_b.id is not null;
          v_result := jsonb_build_object('done', true, 'prepared', true, 'tool', p_tool, 'task_id', v_task, 'money_moved', false,
            'admin_path', case when v_b.id is not null then '/admin/bookings/' || v_b.booking_number else '/admin/todo' end);
        else
          -- the web layer stores the bytes it holds (checked against the fingerprint) and records the photo
          v_result := jsonb_build_object('run', 'photo', 'actor', k.user_id, 'params', v_door || jsonb_build_object('condition_report_id', v_rep, 'booking_id', v_b.id));
        end if;
      end if;
    end if;
  exception when others then
    insert into api_calls (key_id, user_id, tool, target, args, ok, error, client) values (k.id, k.user_id, p_tool, left(v_target, 200), v_door, false, left(sqlerrm, 500), left(p_client, 64));
    return jsonb_build_object('ok', false, 'status', case sqlstate when 'P0002' then 404 when '42501' then 403 else 400 end, 'error', regexp_replace(sqlerrm, '^.*?ERROR:\s*', ''));
  end;
  insert into api_calls (key_id, user_id, tool, target, args, before, ok, client)
  values (k.id, k.user_id, case when v_own and not v_confirm then p_tool || ':preview' else p_tool end, left(v_target, 200), v_door, v_before, true, left(p_client, 64));
  return jsonb_build_object('ok', true, 'result', v_result);
end $$;
select pg_temp.copy_grants('app.api_call(text, text, jsonb, text)'::regprocedure, 'app.api_call_pre1156(text, text, jsonb, text)'::regprocedure);

-- the web layer stored a connector photo: record it on the condition report (the key and the confirmed preview checked again)
create function app.api_photo_record(p_hash text, p_preview uuid, p_path text, p_width integer, p_height integer, p_client text default null) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  k api_keys;
  pv api_previews;
  v_id uuid;
  v_seq integer;
  v_rep uuid;
begin
  select * into k from api_keys where key_hash = p_hash and revoked_at is null;
  select * into pv from api_previews where id = p_preview;
  if k.id is null or pv.id is null or pv.key_id <> k.id or pv.tool <> 'upload_booking_photo' or pv.used_at is null or pv.used_at < now() - interval '5 minutes' then
    raise exception 'Not a confirmed photo upload' using errcode = '42501';
  end if;
  if exists (select 1 from api_calls c where c.key_id = k.id and c.tool = 'upload_booking_photo:stored' and c.target = p_preview::text) then raise exception 'Already stored' using errcode = '23505'; end if;
  v_rep := (pv.before ->> 'condition_report_id')::uuid;
  if p_path !~ ('^bookings/' || (select b.id from bookings b where b.booking_number = pv.before ->> 'booking') || '/claude/[0-9a-f-]{36}\.(jpg|png)$') then raise exception 'Unexpected path' using errcode = '22023'; end if;
  select coalesce(max(seq), 0) + 1 into v_seq from condition_report_photos where condition_report_id = v_rep;
  insert into condition_report_photos (condition_report_id, seq, shot, damage_id, storage_path, uploaded_by, width, height, angle)
  values (v_rep, v_seq, case when pv.args ->> 'stage' = 'damage' then 'damage_closeup' else coalesce(nullif(pv.args ->> 'shot', ''), 'front') end,
          case when pv.args ->> 'stage' = 'damage' then (pv.args ->> 'damage_id')::uuid end, p_path, k.user_id, nullif(p_width, 0), nullif(p_height, 0), null)
  returning id into v_id;
  insert into api_calls (key_id, user_id, tool, target, args, after, ok, client)
  values (k.id, k.user_id, 'upload_booking_photo:stored', p_preview::text, pv.args, jsonb_build_object('photo_id', v_id, 'path', p_path), true, left(p_client, 64));
  return jsonb_build_object('done', true, 'tool', 'upload_booking_photo', 'photo_id', v_id, 'booking', pv.before ->> 'booking', 'stage', pv.args ->> 'stage',
                            'admin_path', '/admin/bookings/' || (pv.before ->> 'booking'));
end $$;
create function public.server_api_photo_record(p_hash text, p_preview uuid, p_path text, p_width integer, p_height integer, p_client text default null) returns jsonb
language sql security definer set search_path = public, app as $$ select app.api_photo_record(p_hash, p_preview, p_path, p_width, p_height, p_client) $$;

-- the door: the expense form's action for the connector
alter function app.door(uuid, text, text, text, jsonb) rename to door_pre1156;
create function app.door(p_user uuid, p_aal text, p_call text, p_name text, p jsonb default '{}'::jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
begin
  if p_call = 'admin_do' and p_name = 'api_expense_add' then
    perform app.door_begin(p_user, p_aal);
    return app.api_expense_add(p_user, coalesce(p, '{}'::jsonb) - '_va');
  end if;
  return app.door_pre1156(p_user, p_aal, p_call, p_name, p);
end $$;
select pg_temp.copy_grants('app.door(uuid, text, text, text, jsonb)'::regprocedure, 'app.door_pre1156(uuid, text, text, text, jsonb)'::regprocedure);

-- ================================================================ privileges: the server only
do $$
declare f record;
begin
  for f in select p.oid::regprocedure as sig from pg_proc p join pg_namespace n on n.oid = p.pronamespace
            where n.nspname = 'app' and p.proname = any (array['api_via', 'api_action_pre1156', 'api_target_pre1156', 'api_expense_add', 'api_src', 'api_row', 'api_page',
                     'api_read', 'api_list_tools', 'api_one_reads', 'api_key_check', 'api_call_pre1156', 'api_photo_record', 'door_pre1156'])
  loop
    execute format('revoke all on function %s from public, anon, authenticated', f.sig);
    execute format('grant execute on function %s to service_role', f.sig);
  end loop;
end $$;
revoke all on function public.server_api_photo_record(text, uuid, text, integer, integer, text) from public, anon, authenticated;
grant execute on function public.server_api_photo_record(text, uuid, text, integer, integer, text) to service_role;
