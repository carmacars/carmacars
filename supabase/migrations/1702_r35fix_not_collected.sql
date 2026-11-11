-- 1702_r35fix_not_collected.sql
-- Release 35, fix helper, task 3 (docs/changes/2026-11-11-r35fix-owner-decisions.md). The owner, November 11, 2026:
-- revenue counts when it is earned (1155), so owner statements and payouts must show what is not yet collected: "Of
-- this, $X is not yet collected", with the bookings behind it (billed to an insurer and not paid yet, an unpaid balance,
-- a past trip recorded and not paid yet).
--   1. app.owner_statement_not_collected(statement): from the data, at the time it is read. For each rental line of the
--      statement, the booking's Owner Revenue lines charged and not linked to a succeeded payment (the same test as
--      booking_splits.uncollected_cents, 0007/0025), as a share of its Owner Revenue, applied to the line's amount (the
--      owner's own money on that line). The reason: insurer (bill_to insurer or split, with an insurer invoice not paid or
--      none yet), past_trip (recorded with Record a past trip, 0770/0910), else balance.
--      {total_cents, line ("Of this, $X is not yet collected"), bookings [{booking_id, booking_number, vehicle_id, cents,
--      reason, reason_label}], by_vehicle {vehicle_id: cents}}; total 0: line null.
--   2. Where it shows: the owner's statement (app.owner_portal_statement), the statement PDF and Admin's statement page
--      (app.owner_statement_breakdown), Admin's payout and statement lists and Finance's statement list (app.admin_enrich:
--      not_collected_cents on an owner statement row and on a payout row of a statement), and the statement email
--      (owner_statement_ready: has_not_collected, not_collected_line, not_collected_rows).
-- No applied migration is edited: the four functions are wrapped.
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

-- ================================================================ 1. what is not yet collected
create function app.owner_statement_not_collected(p_statement uuid) returns jsonb
language sql stable security definer set search_path = public, app as $$
  with l as (
    select l.vehicle_id, l.booking_id, sum(l.amount_cents)::bigint as amount
      from owner_statement_lines l
     where l.owner_statement_id = p_statement and l.line_type = 'rental' and l.booking_id is not null
     group by l.vehicle_id, l.booking_id
    having sum(l.amount_cents) > 0
  ),
  b as (
    select l.*, bk.booking_number, bk.bill_to,
           coalesce(sum(li.amount_cents), 0)::bigint as rev,
           coalesce(sum(li.amount_cents) filter (where not exists (select 1 from payments p where p.id = li.payment_id and p.status = 'succeeded')), 0)::bigint as unpaid,
           exists (select 1 from booking_overrides o where o.booking_id = l.booking_id and o.action = 'past_trip' and o.status = 'used') as past_trip,
           (not exists (select 1 from insurer_invoices ii where ii.booking_id = l.booking_id and ii.status <> 'draft')
              or exists (select 1 from insurer_invoices ii where ii.booking_id = l.booking_id and ii.status in ('sent', 'part_paid'))) as insurer_open
      from l join bookings bk on bk.id = l.booking_id
      left join booking_line_items li on li.booking_id = l.booking_id and li.voided_at is null and li.charged_to_renter and li.revenue_class = 'owner_revenue'
     group by l.vehicle_id, l.booking_id, l.amount, bk.booking_number, bk.bill_to
  ),
  x as (
    select b.*,
           case when b.rev > 0 and b.unpaid > 0 then least(b.amount, round(b.amount * least(1.0, b.unpaid::numeric / b.rev)))::bigint else 0 end as cents,
           case when b.bill_to <> 'renter' and b.insurer_open then 'insurer' when b.past_trip then 'past_trip' else 'balance' end as reason
      from b
  ),
  y as (select * from x where cents > 0)
  select jsonb_build_object(
    'total_cents', coalesce((select sum(cents) from y), 0)::bigint,
    'line', (select format('Of this, %s is not yet collected', app.fmt_money(sum(cents))) from y having sum(cents) > 0),
    'bookings', coalesce((select jsonb_agg(jsonb_build_object('booking_id', y.booking_id, 'booking_number', y.booking_number, 'vehicle_id', y.vehicle_id,
                   'cents', y.cents, 'reason', y.reason,
                   'reason_label', case y.reason when 'insurer' then 'Billed to the insurer, not paid yet' when 'past_trip' then 'Past trip, not paid yet' else 'Unpaid balance' end)
                   order by y.booking_number) from y), '[]'::jsonb),
    'by_vehicle', coalesce((select jsonb_object_agg(v.vehicle_id, v.cents) from (select vehicle_id, sum(cents)::bigint as cents from y group by vehicle_id) v), '{}'::jsonb))
$$;
comment on function app.owner_statement_not_collected(uuid) is 'Owner statements (1702): the part of a statement''s rental lines whose booking is not paid yet (insurer-billed, an unpaid balance, a past trip not paid), with the bookings; read from the data each time.';
revoke all on function app.owner_statement_not_collected(uuid) from public, anon, authenticated;
grant execute on function app.owner_statement_not_collected(uuid) to service_role;

-- ================================================================ 2. where it shows
-- the statement for Admin and the PDF
alter function app.owner_statement_breakdown(uuid, uuid) rename to owner_statement_breakdown_pre1702;
create function app.owner_statement_breakdown(p_statement uuid, p_by uuid) returns jsonb
language sql stable security definer set search_path = public, app as $$
  select case when r is null then r else r || jsonb_build_object('not_collected', app.owner_statement_not_collected(p_statement)) end
    from (select app.owner_statement_breakdown_pre1702(p_statement, p_by) as r) x
$$;
select pg_temp.copy_grants('app.owner_statement_breakdown(uuid, uuid)'::regprocedure, 'app.owner_statement_breakdown_pre1702(uuid, uuid)'::regprocedure);

-- the owner's statement in the owner portal
alter function app.owner_portal_statement(uuid, uuid) rename to owner_portal_statement_pre1702;
create function app.owner_portal_statement(p_by uuid, p_statement uuid) returns jsonb
language sql stable security definer set search_path = public, app as $$
  select case when r is null then r else r || jsonb_build_object('not_collected', app.owner_statement_not_collected(p_statement)) end
    from (select app.owner_portal_statement_pre1702(p_by, p_statement) as r) x
$$;
select pg_temp.copy_grants('app.owner_portal_statement(uuid, uuid)'::regprocedure, 'app.owner_portal_statement_pre1702(uuid, uuid)'::regprocedure);

-- the lists: an owner statement row and a payout row of a statement (Admin's lists, Finance's through va_list)
alter function app.admin_enrich(jsonb) rename to admin_enrich_pre1702;
create function app.admin_enrich(r jsonb) returns jsonb
language sql stable security definer set search_path = public, app as $$
  select case
    when jsonb_typeof(r) <> 'object' then app.admin_enrich_pre1702(r)
    when r ? 'statement_month' and r ? 'payout_cents' and r ? 'balance_carried_forward_cents' and coalesce(r ->> 'id', '') ~ '^[0-9a-f-]{36}$'
      then app.admin_enrich_pre1702(r) || jsonb_build_object('not_collected_cents', (app.owner_statement_not_collected((r ->> 'id')::uuid) ->> 'total_cents')::bigint)
    when r ? 'owner_statement_id' and r ? 'scheduled_for' and coalesce(r ->> 'owner_statement_id', '') ~ '^[0-9a-f-]{36}$'
      then app.admin_enrich_pre1702(r) || jsonb_build_object('not_collected_cents', (app.owner_statement_not_collected((r ->> 'owner_statement_id')::uuid) ->> 'total_cents')::bigint)
    else app.admin_enrich_pre1702(r) end
$$;
select pg_temp.copy_grants('app.admin_enrich(jsonb)'::regprocedure, 'app.admin_enrich_pre1702(jsonb)'::regprocedure);

-- the statement email
alter function app.notification_payload(text, app_events, jsonb) rename to ntf_payload_pre1702;
create function app.notification_payload(p_code text, p_event app_events, p_to jsonb) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare
  x jsonb := app.ntf_payload_pre1702(p_code, p_event, p_to);
  n jsonb;
begin
  if p_code <> 'owner_statement_ready' or p_event.entity <> 'owner_statement' then return x; end if;
  n := app.owner_statement_not_collected(p_event.entity_id);
  return coalesce(x, '{}'::jsonb) || jsonb_build_object('has_not_collected', (n ->> 'total_cents')::bigint > 0,
    'not_collected_line', coalesce(n ->> 'line', ''),
    'not_collected_rows', coalesce((select jsonb_agg(jsonb_build_object('booking', e ->> 'booking_number', 'reason', e ->> 'reason_label', 'amount', app.fmt_money((e ->> 'cents')::bigint)))
                                      from jsonb_array_elements(n -> 'bookings') e), '[]'::jsonb));
end $$;
select pg_temp.copy_grants('app.notification_payload(text, app_events, jsonb)'::regprocedure, 'app.ntf_payload_pre1702(text, app_events, jsonb)'::regprocedure);

-- CATALOGUE 1702 START (generated by supabase/seed/1702_gen_catalogue.mjs; do not edit by hand)
insert into notification_catalogue (code, audience, also_sent_to, category, is_digest, digest_slot, from_address, reply_to,
    subject, preheader, timing, trigger_text, replaces_template, link_path, variables, template_html, template_text) values
  ('owner_statement_ready', 'owner', '{}'::text[], 'transactional', false, null, 'CarmaCars <billing@carmacars.ca>', 'billing@carmacars.ca', 'Your {{statement_month}} statement: {{payout_amount}}', 'Owner Revenue {{owner_revenue_total}}. {{payout_summary}}', '10th of each month', 'An owner statement changes to issued: on the 10th of the month, after an admin approves the payout run, for the previous month. One statement and one email per owner, covering all their vehicles. (Message template T26, statement part.)', 'T26', '/owner/statements/{{statement_number}}', '[{"name":"balance_forward","type":"string"},{"name":"company_address","type":"string","global":true},{"name":"contact_email","type":"string","global":true},{"name":"deductions_total","type":"string"},{"name":"first_name","type":"string"},{"name":"has_balance_forward","type":"boolean"},{"name":"has_not_collected","type":"boolean"},{"name":"has_payout_hst","type":"boolean"},{"name":"instagram_url","type":"url","global":true},{"name":"kickbacks_deducted","type":"string"},{"name":"kickbacks_earned","type":"string"},{"name":"link_expiry","type":"string"},{"name":"not_collected_line","type":"string"},{"name":"not_collected_rows","type":"list","fields":["booking","reason","amount"]},{"name":"opening_hours","type":"string","global":true},{"name":"owner_revenue_total","type":"string"},{"name":"payee_name","type":"string"},{"name":"payout_amount","type":"string"},{"name":"payout_hst","type":"string"},{"name":"payout_label","type":"string"},{"name":"payout_summary","type":"string"},{"name":"rentals_total","type":"string"},{"name":"reply_time","type":"string","global":true},{"name":"revenue_share_total","type":"string"},{"name":"statement_month","type":"string"},{"name":"statement_number","type":"string"},{"name":"statement_url","type":"url"},{"name":"statement_vehicles","type":"list","fields":["name","owner_revenue","payable"]},{"name":"support_phone","type":"string","global":true},{"name":"tiktok_url","type":"url","global":true}]'::jsonb, 'templates/owner_statement_ready.html', 'templates/owner_statement_ready.txt')
on conflict (code) do update set
  audience = excluded.audience, also_sent_to = excluded.also_sent_to, category = excluded.category,
  is_digest = excluded.is_digest, digest_slot = excluded.digest_slot, from_address = excluded.from_address,
  reply_to = excluded.reply_to, subject = excluded.subject, preheader = excluded.preheader, timing = excluded.timing,
  trigger_text = excluded.trigger_text, replaces_template = excluded.replaces_template, link_path = excluded.link_path,
  variables = excluded.variables, template_html = excluded.template_html, template_text = excluded.template_text,
  in_catalogue = true, updated_at = now();
select app.notification_catalogue_refresh();
-- CATALOGUE 1702 END
