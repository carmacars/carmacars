-- 3192 (release 48, part FE; docs/changes/2026-11-20-r48-fees-evidence-hiring.md): the dispute kit, hardened.
--
-- public.server_dispute_evidence (0154) now also carries, for the PDF (web/src/server/agreements/dispute-pack.ts):
--   charges   every extra charge (speeding, smoking, cleaning, non-return, improper return, theft recovery, tires and
--             roadside, tolls and tickets, late, km, fuel, damage, ...) with: the clause and the agreement version the
--             renter signed (and its certificate), the notice sent before billing with its delivery (the email's
--             status, provider id and time; the text's), the receipts and documents, the evidence found by the registry
--             (3190), the Tracker readings (speed series around a speeding reading, the location at the return, the
--             route), staff notes and the renter's replies.
--   identity  the signing proof: IP, device and time of each signature (already in signing), the ID check and the selfie
--             match (identity_verifications: method, status, face match score, who verified, when).
--   history   previous trips by the same person (renter, or the same email) and by the same card (brand, last 4 and
--             expiry on another renter).
--   variant   card (Stripe), etransfer_cash, insurer (insurer billing) or small_claims (a court bundle): dispute_packs.variant.
-- The pack is built by itself on the Stripe dispute webhook (0154's trigger on disputes, unchanged), and Admins get deadline
-- alerts 5, 2 and 1 days before the evidence is due while the pack is not submitted (staff alert dispute_deadline, from
-- the hourly task hygiene job). An Admin builds a non-card pack from the booking (ops_do dispute_pack_build with variant).
-- No applied migration is edited: public.server_dispute_evidence and app.job_task_hygiene are wrapped (_pre3192);
-- app.dispute_pack_queue is wrapped to take the variant; app.door is wrapped.
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

alter table dispute_packs add column if not exists variant text not null default 'card' check (variant in ('card', 'etransfer_cash', 'insurer', 'small_claims'));
comment on column dispute_packs.variant is 'What the pack is for (3192): card (a Stripe dispute), etransfer_cash (a renter who paid by e-Transfer or cash disputes a charge), insurer (insurer billing), small_claims (a court bundle).';
alter table dispute_packs add column if not exists alerts_sent integer[] not null default '{}';

-- the rental agreement clause of each charge (the numbering of docs/source/v2_rental.md)
create function app.fee_clause(p_code text) returns text
language sql immutable as $$
  select case
    when p_code like 'speeding_%' then '10.5 Speeding charges'
    when p_code in ('non_return_fee') then '10.6 Non-return'
    when p_code in ('improper_return_fee') then '10.7 Improper return'
    when p_code in ('theft_recovery_fee') then '10.8 Theft recovery'
    when p_code in ('recovery_cost') then '10.6 to 10.8 Recovery costs; 12.5 Repossession'
    when p_code in ('tire_cost', 'roadside_callout', 'roadside_admin_fee') then '11.6 Tires and roadside call-outs; 11.4 Call-outs you cause'
    when p_code in ('late_return_fee', 'late_return_extra_days') then '3.2 Extensions and late return; Part 3 Late return fee'
    when p_code in ('mileage_overage') then 'Part 1 Mileage allowance; Part 3 Mileage overage'
    when p_code in ('fuel', 'recharging', 'fuel_service_fee') then 'Part 3 Fuel or recharging fee'
    when p_code in ('cleaning', 'cleaning_heavy', 'pet_cleaning') then 'Part 3 Cleaning fee'
    when p_code = 'smoking' then 'Part 3 Smoking fee; 10.2 Prohibited uses'
    when p_code in ('toll_amount', 'toll_admin_fee', 'ticket_amount', 'ticket_admin_fee') then '10 Tolls and tickets; Part 3 Toll and ticket administration fee'
    when p_code in ('damage_at_cost', 'deductible', 'loss_of_use', 'admin_fee_claim', 'admin_fee_other') then '9 Damage; Part 3 Administration fee and Loss of use'
    when p_code in ('lost_key_cost', 'lost_key_fee') then '10.4 Care; Part 3 Lost key or fob fee'
    when p_code = 'declined_payment' then 'Part 3 Declined payment fee'
    when p_code = 'interest' then 'Part 3 Interest'
    else 'Part 3 Fee Schedule' end
$$;

-- each extra charge with its proof
create function app.dispute_charges(p_booking uuid) returns jsonb
language sql stable security definer set search_path = public, app as $$
  select coalesce(jsonb_agg(jsonb_build_object(
      'line_item_id', li.id, 'charge_type', li.charge_type, 'label', coalesce(ft.label, li.charge_type), 'description', li.description,
      'amount_cents', li.amount_cents, 'hst_cents', li.hst_cents, 'created_at', li.created_at, 'stage', li.stage,
      'statement', (select jsonb_build_object('number', s.statement_number, 'issued_at', s.issued_at) from booking_statements s where s.id = li.statement_id),
      'clause', app.fee_clause(li.charge_type),
      'agreement', (select jsonb_build_object('agreement_number', a.agreement_number, 'template_version', a.template_version, 'signed_at', coalesce(a.renter_signed_at, a.completed_at),
                                             'document_id', a.document_id, 'sha256', a.document_sha256)
                      from rental_agreements a where a.booking_id = li.booking_id and a.voided_at is null and coalesce(a.renter_signed_at, a.completed_at) is not null
                     order by coalesce(a.renter_signed_at, a.completed_at) desc limit 1),
      'evidence_status', coalesce(li.evidence_status, 'not_required'), 'evidence_override', li.evidence_override_reason,
      'evidence', app.fee_evidence_have(li.id),
      -- the notice before billing: the extra charge email (or the statement email) and its delivery
      'notices', coalesce((select jsonb_agg(jsonb_build_object('code', o.code, 'channel', coalesce(o.channel, 'email'), 'to', app.esign_mask_email(o.to_address), 'status', o.status,
                                                             'queued_at', o.created_at, 'sent_at', o.sent_at, 'provider_id', o.provider_id) order by o.created_at)
                             from notification_outbox o
                            where o.booking_id = li.booking_id and o.audience = 'renter'
                              and (o.payload ->> 'line_item_id' = li.id::text or o.entity_id = li.id or (li.statement_id is not null and o.payload ->> 'statement_id' = li.statement_id::text)
                                   or (o.code in ('renter_extra_charge', 'renter_statement_issued') and o.created_at between li.created_at - interval '1 minute' and li.created_at + interval '2 days'))),
                          '[]'::jsonb),
      'documents', coalesce((select jsonb_agg(jsonb_build_object('id', d.id, 'title', d.title, 'bucket', d.storage_bucket, 'path', d.storage_path, 'mime', d.mime_type, 'sha256', d.sha256, 'created_at', d.created_at))
                               from documents d where d.purged_at is null and d.storage_path is not null
                                and (d.id = li.supporting_document_id or d.id in (select e.document_id from fee_evidence e where e.line_item_id = li.id)
                                     or d.id = (select t.document_id from toll_tickets t where t.id = li.toll_ticket_id)
                                     or d.id = (select t.tracker_proof_document_id from toll_tickets t where t.id = li.toll_ticket_id))), '[]'::jsonb),
      'attached', coalesce((select jsonb_agg(jsonb_build_object('kind', e.kind, 'note', e.note, 'at', e.added_at, 'by', (select u.full_name from users u where u.id = e.added_by)) order by e.added_at)
                              from fee_evidence e where e.line_item_id = li.id), '[]'::jsonb),
      'tracker', case
        when li.supporting_refs ? 'speed_kmh' then (select jsonb_build_object('kind', 'speed_series', 'points', coalesce(jsonb_agg(jsonb_build_object('at', t.at, 'speed_kmh', t.speed_kmh, 'lat', t.lat_e6 / 1e6, 'lng', t.lng_e6 / 1e6) order by t.at), '[]'::jsonb))
                from tracker_points t join bookings b on b.id = li.booking_id
               where t.vehicle_id = b.vehicle_id and t.at between (li.supporting_refs ->> 'at')::timestamptz - interval '5 minutes' and (li.supporting_refs ->> 'at')::timestamptz + interval '5 minutes')
        when li.charge_type in ('non_return_fee', 'theft_recovery_fee', 'improper_return_fee', 'recovery_cost', 'late_return_fee', 'late_return_extra_days') then
             (select jsonb_build_object('kind', 'route', 'points', coalesce(jsonb_agg(x order by x ->> 'at'), '[]'::jsonb)) from (
                select jsonb_build_object('at', t.at, 'speed_kmh', t.speed_kmh, 'lat', t.lat_e6 / 1e6, 'lng', t.lng_e6 / 1e6, 'ignition', t.ignition) x
                  from tracker_points t join bookings b on b.id = li.booking_id
                 where t.vehicle_id = b.vehicle_id and t.at between coalesce(b.return_at, b.pickup_at) - interval '1 hour' and coalesce(b.checked_in_at, now())
                 order by t.at desc limit 60) q)
        when li.toll_ticket_id is not null then (select jsonb_build_object('kind', 'route', 'points', coalesce(jsonb_agg(jsonb_build_object('at', t.at, 'lat', t.lat_e6 / 1e6, 'lng', t.lng_e6 / 1e6) order by t.at), '[]'::jsonb))
                from tracker_points t join toll_tickets tt on tt.id = li.toll_ticket_id
               where t.vehicle_id = tt.vehicle_id and t.at between tt.occurred_at - interval '15 minutes' and tt.occurred_at + interval '15 minutes')
        end) order by li.created_at), '[]'::jsonb)
    from booking_line_items li left join fee_types ft on ft.code = li.charge_type
   where li.booking_id = p_booking and li.voided_at is null and li.charged_to_renter and li.stage in ('check_in', 'after_return', 'on_decline')
$$;

alter function public.server_dispute_evidence(uuid) rename to server_dispute_evidence_pre3192;
create function public.server_dispute_evidence(p_pack uuid) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare
  v jsonb := public.server_dispute_evidence_pre3192(p_pack);
  k dispute_packs;
  b bookings;
  r renters;
begin
  select * into k from dispute_packs where id = p_pack;
  select * into b from bookings where id = k.booking_id;
  select * into r from renters where id = b.renter_id;
  return v || jsonb_build_object(
    'variant', k.variant,
    'charges', app.dispute_charges(b.id),
    'return_location', (select jsonb_build_object('at', t.at, 'lat', t.lat_e6 / 1e6, 'lng', t.lng_e6 / 1e6) from tracker_points t
                         where t.vehicle_id = b.vehicle_id and b.checked_in_at is not null and t.at <= b.checked_in_at + interval '30 minutes' order by t.at desc limit 1),
    'staff_notes', coalesce((select jsonb_agg(jsonb_build_object('at', n.created_at, 'by', coalesce(n.author_name, n.author_role), 'body', left(n.body, 600)) order by n.created_at)
                               from renter_notes n where n.removed_at is null and (n.booking_id = b.id or (n.booking_id is null and n.renter_id = b.renter_id))), '[]'::jsonb)
                   || coalesce((select jsonb_agg(jsonb_build_object('at', c.created_at, 'by', 'condition report', 'body', left(c.notes, 600)) order by c.created_at)
                               from condition_reports c where c.booking_id = b.id and nullif(btrim(coalesce(c.notes, '')), '') is not null), '[]'::jsonb),
    'renter_replies', coalesce((select jsonb_agg(jsonb_build_object('at', m.occurred_at, 'channel', m.channel, 'subject', m.subject, 'body', left(m.body, 600)) order by m.occurred_at)
                                  from messages m where m.direction = 'inbound' and (m.booking_id = b.id or (m.booking_id is null and m.renter_id = b.renter_id
                                        and m.occurred_at between coalesce(b.pickup_at, b.created_at) - interval '7 days' and coalesce(b.checked_in_at, now()) + interval '60 days'))), '[]'::jsonb),
    'identity', coalesce((select jsonb_agg(jsonb_build_object('driver', (select dv.full_name from drivers dv where dv.id = iv.driver_id), 'method', iv.method, 'status', iv.status,
                                    'provider', iv.provider, 'face_match_score', iv.face_match_score, 'checks', iv.checks, 'verified_at', iv.verified_at,
                                    'verified_by', (select u.full_name from users u where u.id = iv.verified_by)) order by iv.created_at)
                            from identity_verifications iv where iv.booking_id = b.id or iv.driver_id in (select d.id from drivers d where d.renter_id = b.renter_id)), '[]'::jsonb),
    'history', jsonb_build_object(
      'same_person', coalesce((select jsonb_agg(jsonb_build_object('booking_number', x.booking_number, 'pickup_at', x.pickup_at, 'return_at', x.return_at, 'status', x.status, 'total_cents', x.total_due_at_booking_cents,
                                  'disputed', exists (select 1 from disputes d where d.booking_id = x.id)) order by x.pickup_at desc)
                                 from bookings x where x.id <> b.id and x.status::text in ('returned', 'closed', 'on_rent')
                                   and (x.renter_id = b.renter_id or (nullif(r.email, '') is not null and x.renter_id in (select r2.id from renters r2 where lower(r2.email) = lower(r.email))))), '[]'::jsonb),
      'same_card', coalesce((select jsonb_agg(distinct jsonb_build_object('booking_number', x.booking_number, 'pickup_at', x.pickup_at, 'status', x.status, 'card', upper(coalesce(p2.card_brand, '')) || ' ' || p2.card_last4))
                              from payments p1 join payments p2 on p2.card_last4 = p1.card_last4 and coalesce(p2.card_brand, '') = coalesce(p1.card_brand, '') and p2.booking_id <> p1.booking_id
                              join bookings x on x.id = p2.booking_id
                             where p1.booking_id = b.id and p1.card_last4 is not null and p2.status in ('succeeded', 'authorized') and x.status::text in ('returned', 'closed', 'on_rent')
                               and (x.renter_id = b.renter_id or exists (select 1 from payment_methods m1 join payment_methods m2 on m2.card_last4 = m1.card_last4 and m2.exp_month = m1.exp_month and m2.exp_year = m1.exp_year
                                                                         where m1.id = p1.payment_method_id and m2.id = p2.payment_method_id))), '[]'::jsonb)),
    'offline', case when k.variant in ('etransfer_cash', 'small_claims') then coalesce((select jsonb_agg(jsonb_build_object('method', p.method, 'amount_cents', p.amount_cents, 'status', p.status,
                       'at', coalesce(p.processed_at, p.created_at), 'reference', p.reason_note) order by p.created_at)
                     from payments p where p.booking_id = b.id and p.method::text not in ('card')), '[]'::jsonb) end,
    'insurer', case when k.variant = 'insurer' then coalesce((select jsonb_agg(jsonb_build_object('invoice_number', i.invoice_number, 'claim_number', i.claim_number, 'period_start', i.period_start,
                       'period_end', i.period_end, 'total_cents', i.total_cents, 'balance_cents', i.balance_cents, 'status', i.status, 'sent_at', i.sent_at, 'document_id', i.document_id) order by i.created_at)
                     from insurer_invoices i where i.booking_id = b.id), '[]'::jsonb) end,
    'balance', (select jsonb_build_object('charged_cents', coalesce(sum(s.charges_cents + s.hst_cents), 0)) from booking_statements s where s.booking_id = b.id));
end $$;
select pg_temp.copy_grants('public.server_dispute_evidence(uuid)'::regprocedure, 'public.server_dispute_evidence_pre3192(uuid)'::regprocedure);

-- an Admin builds a pack for a dispute without a card: the variant on the pack
create function app.dispute_pack_build_variant(p_by uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  b bookings;
  v_variant text := coalesce(nullif(p ->> 'variant', ''), 'card');
  v_id uuid;
begin
  if not (app.user_is_admin(p_by) or app.user_runs_finance(p_by)) then raise exception 'An Admin or Finance builds a dispute pack' using errcode = '42501'; end if;
  if v_variant not in ('card', 'etransfer_cash', 'insurer', 'small_claims') then raise exception 'The pack: card, etransfer_cash, insurer or small_claims' using errcode = '22023'; end if;
  select * into b from bookings where id::text = p ->> 'booking' or booking_number = upper(btrim(coalesce(p ->> 'booking', '')));
  if b.id is null then raise exception 'Booking not found' using errcode = 'P0002'; end if;
  v_id := app.dispute_pack_queue(b.id, (select d.id from disputes d where d.booking_id = b.id and v_variant = 'card' order by d.created_at desc limit 1), p_by);
  update dispute_packs set variant = v_variant where id = v_id;
  return jsonb_build_object('id', v_id, 'variant', v_variant);
end $$;

-- deadline alerts: 5, 2 and 1 days before the evidence is due, while not submitted
insert into staff_alert_rules (rule, label, grp, who, tier, topic, enabled, wired, fixed, hint, sort)
values ('dispute_deadline', 'Card dispute: evidence due soon', 'Money', '{admin}', 'urgent', 'alerts', true, true, false,
        '5, 2 and 1 days before the dispute''s evidence is due while the pack is not submitted (3192).', 118)
on conflict (rule) do nothing;

create function app.dispute_deadline_alerts(p_now timestamptz default now()) returns integer
language plpgsql security definer set search_path = public, app as $$
declare
  k record;
  v_day integer;
  n integer := 0;
begin
  for k in select p.id, p.booking_id, p.alerts_sent, d.evidence_due_at, d.amount_cents, d.reason, b.booking_number
             from dispute_packs p join disputes d on d.id = p.dispute_id join bookings b on b.id = p.booking_id
            where p.status <> 'submitted' and d.status = 'open' and d.evidence_due_at is not null
              and d.evidence_due_at > p_now and d.evidence_due_at <= p_now + interval '5 days' loop
    v_day := case when k.evidence_due_at <= p_now + interval '1 day' then 1 when k.evidence_due_at <= p_now + interval '2 days' then 2 else 5 end;
    if v_day = any (k.alerts_sent) then continue; end if;
    update dispute_packs set alerts_sent = alerts_sent || v_day where id = k.id;
    perform app.staff_alert('dispute_deadline', 'dispute_packs', k.id, v_day::text,
      format('Dispute evidence due in %s: %s', case v_day when 1 then 'under a day' else v_day || ' days' end, k.booking_number),
      format('%s, reason %s. Check the evidence pack on the booking and press Submit to Stripe before %s.', app.fmt_money(k.amount_cents), coalesce(k.reason, 'not given'),
             to_char(k.evidence_due_at at time zone 'America/Toronto', 'Mon FMDD at FMHH12:MI a.m.')),
      jsonb_build_object('path_admin', '/admin/bookings/' || k.booking_number));
    n := n + 1;
  end loop;
  return n;
end $$;

alter function app.job_task_hygiene(timestamptz) rename to job_task_hygiene_pre3192;
create function app.job_task_hygiene(p_now timestamptz default now()) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare v jsonb := app.job_task_hygiene_pre3192(p_now); n integer := 0;
begin
  begin n := app.dispute_deadline_alerts(p_now); exception when others then raise warning 'dispute deadline alerts: %', sqlerrm; end;
  return coalesce(v, '{}'::jsonb) || jsonb_build_object('dispute_alerts', n);
end $$;
select pg_temp.copy_grants('app.job_task_hygiene(timestamptz)'::regprocedure, 'app.job_task_hygiene_pre3192(timestamptz)'::regprocedure);

alter function app.door(uuid, text, text, text, jsonb) rename to door_pre3192;
create function app.door(p_user uuid, p_aal text, p_call text, p_name text, p jsonb default '{}'::jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
begin
  if p_call = 'ops_do' and p_name = 'dispute_pack_build' and coalesce(p ->> 'variant', 'card') <> 'card' then
    perform app.door_begin(p_user, p_aal);
    return app.dispute_pack_build_variant(p_user, coalesce(p, '{}'::jsonb) - '_va');
  end if;
  return app.door_pre3192(p_user, p_aal, p_call, p_name, p);
end $$;
select pg_temp.copy_grants('app.door(uuid, text, text, text, jsonb)'::regprocedure, 'app.door_pre3192(uuid, text, text, text, jsonb)'::regprocedure);

revoke all on function app.fee_clause(text), app.dispute_charges(uuid), public.server_dispute_evidence_pre3192(uuid), app.dispute_pack_build_variant(uuid, jsonb),
  app.dispute_deadline_alerts(timestamptz), app.job_task_hygiene_pre3192(timestamptz), app.door_pre3192(uuid, text, text, text, jsonb) from public, anon, authenticated;
grant execute on function app.fee_clause(text), app.dispute_charges(uuid), public.server_dispute_evidence_pre3192(uuid), app.dispute_pack_build_variant(uuid, jsonb),
  app.dispute_deadline_alerts(timestamptz), app.job_task_hygiene_pre3192(timestamptz), app.door_pre3192(uuid, text, text, text, jsonb) to service_role;
