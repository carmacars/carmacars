-- 0215: the owner pipeline, owner recruitment that follows up by itself (Release 22, item 4). SCHEMA_MARKER 0215.
-- docs/changes/2026-11-02-owner-pipeline.md.
--   1. Every prospective owner is one lead in one pipeline: the website's owner form (kind owner_program), a classified ad
--      (owner_recruit, 0167), a referral by an owner, or one added by hand. Stages: new, contacted, call booked, agreement
--      sent, signed, car onboarded, lost. Staff move a lead; agreement sent, signed and car onboarded also follow the owner's
--      records by themselves (an owner agreement sent or signed, a car on the site).
--   2. Follow-ups (on by default, program_settings.owner_followup_enabled): emails on day 0, 2, 5 and 10
--      (owner_followup_days) after the lead comes in, the owner program's words (docs/guides: the car goes on CarmaCars'
--      fleet insurance policy, CarmaCars rents it out in Toronto and pays the owner every month; fees apply), through the
--      owner_recruit_outreach email (marketing: the lowest priority class under the daily cap, the sending hours, the
--      unsubscribe link). Only with consent: an inquiry (implied, 6 months) for the website form and a referral, the
--      consent log (0167) for a classified lead. The sequence stops on a reply (a text or call from the lead, or "They
--      replied"), on any stage change, on an unsubscribe or "do not contact", and after the last step.
--   3. Owner referrals: an owner's link (carmacars.ca/r/<code>?to=owner, the same code as their renter referral link) puts
--      the owner on the lead. The credit follows the referral kickback rules (0007): the Kickback Rate (20%) of the Rental
--      Charge of the first completed rental of the referred owner's car, due once that rental is completed, paid by hand
--      with the referring owner's payout (Admin marks it paid).
--   4. The door: admin_read/va_read 'owner_pipeline'; admin_do/va_do 'owner_pipeline_add', 'owner_pipeline_save',
--      'owner_pipeline_replied', 'owner_pipeline_followups'; admin_do 'owner_referral_credit_paid'. Admins, and staff
--      working as Sales or Customer service.
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

alter table program_settings
  add column if not exists owner_followup_enabled boolean not null default true,
  add column if not exists owner_followup_days integer[] not null default array[0, 2, 5, 10] check (cardinality(owner_followup_days) between 1 and 8);
comment on column program_settings.owner_followup_enabled is 'Owner pipeline (0215): follow-up emails to prospective owners on owner_followup_days, until they reply or the stage changes.';
comment on column program_settings.owner_followup_days is 'Owner pipeline (0215): the days after a lead comes in when a follow-up email goes (0, 2, 5, 10).';

alter table leads
  add column if not exists pipeline_stage text check (pipeline_stage is null or pipeline_stage in ('new', 'contacted', 'call_booked', 'agreement_sent', 'signed', 'car_onboarded', 'lost')),
  add column if not exists pipeline_stage_at timestamptz,
  add column if not exists pipeline_source text check (pipeline_source is null or pipeline_source in ('website', 'referral', 'manual', 'classified')),
  add column if not exists pipeline_note text,
  add column if not exists followup_step smallint not null default 0,
  add column if not exists followup_next_at timestamptz,
  add column if not exists followup_stopped_at timestamptz,
  add column if not exists followup_stop_reason text,
  add column if not exists replied_at timestamptz,
  add column if not exists referred_by_owner_id uuid references owners (id) on delete set null;
create index if not exists leads_followup_due_idx on leads (followup_next_at) where followup_next_at is not null and followup_stopped_at is null;
comment on column leads.pipeline_stage is 'Owner pipeline (0215): new, contacted, call_booked, agreement_sent, signed, car_onboarded or lost; owner_program and owner_recruit leads only.';
comment on column leads.referred_by_owner_id is 'Owner pipeline (0215): the owner whose link brought this prospective owner (the referral credit, 0215).';

create table if not exists owner_referral_credits (
  id              uuid primary key default gen_random_uuid(),
  lead_id         uuid not null unique references leads (id) on delete cascade,
  referrer_owner_id uuid not null references owners (id),
  referred_owner_id uuid references owners (id),
  booking_id      uuid references bookings (id),
  rental_charge_cents bigint,
  kickback_bps    integer,
  amount_cents    bigint,
  status          text not null default 'waiting' check (status in ('waiting', 'due', 'paid', 'void')),
  paid_at         timestamptz,
  paid_by         uuid references users (id),
  note            text,
  created_at      timestamptz not null default now(),
  updated_at      timestamptz not null default now()
);
comment on table owner_referral_credits is 'Owner pipeline (0215): an owner who referred a new owner. Waiting until the referred owner''s car completes its first rental, then due: the Kickback Rate (program_settings.kickback_bps, 20%) of that Rental Charge, as for a renter referral (0007). Paid by hand with the referrer''s payout.';

-- the stages: a stage from the lead's old status for the leads already on file; their follow-ups are not started
update leads set pipeline_stage = case status when 'contacted' then 'contacted' when 'qualified' then 'contacted' when 'converted' then 'signed'
                                              when 'closed' then 'lost' when 'spam' then 'lost' else 'new' end,
                 pipeline_stage_at = updated_at,
                 pipeline_source = case when kind = 'owner_recruit' then 'classified' when source = 'referral' then 'referral' when source = 'web' then 'website' else 'manual' end,
                 followup_stopped_at = now(), followup_stop_reason = 'On file before the automatic follow-ups'
 where kind in ('owner_program', 'owner_recruit') and pipeline_stage is null;

-- a new prospective owner enters the pipeline, with its follow-ups due from now
create or replace function app.owner_pipeline_lead_in() returns trigger
language plpgsql security definer set search_path = public, app as $$
declare
  v_code text := upper(nullif(btrim(coalesce(new.payload ->> 'referral_code', '')), ''));
  s program_settings := app.settings();
begin
  if new.kind not in ('owner_program', 'owner_recruit') then return new; end if;
  if v_code is not null and new.referred_by_owner_id is null then
    select id into new.referred_by_owner_id from owners where upper(referral_code) = v_code;
  end if;
  new.pipeline_stage := coalesce(new.pipeline_stage, 'new');
  new.pipeline_stage_at := coalesce(new.pipeline_stage_at, now());
  new.pipeline_source := coalesce(new.pipeline_source, case when new.referred_by_owner_id is not null or new.source = 'referral' then 'referral'
                                                            when new.kind = 'owner_recruit' or new.source = 'classified' then 'classified'
                                                            when new.source = 'web' then 'website' else 'manual' end);
  if new.followup_stopped_at is null and new.followup_next_at is null and s.owner_followup_enabled and new.email is not null then
    new.followup_next_at := now() + make_interval(days => coalesce(s.owner_followup_days[1], 0));
  end if;
  return new;
end $$;
drop trigger if exists leads_owner_pipeline_in on leads;
create trigger leads_owner_pipeline_in before insert on leads for each row execute function app.owner_pipeline_lead_in();

-- the old status and the stage stay in step; a stage change stops the follow-ups
create or replace function app.owner_pipeline_status_sync() returns trigger
language plpgsql security definer set search_path = public, app as $$
begin
  if new.kind not in ('owner_program', 'owner_recruit') or new.pipeline_stage is null then return new; end if;
  if new.status is distinct from old.status and new.pipeline_stage is not distinct from old.pipeline_stage then
    new.pipeline_stage := case when new.status in ('closed', 'spam') then 'lost'
                               when new.status = 'converted' and old.pipeline_stage not in ('signed', 'car_onboarded') then 'signed'
                               when new.status in ('contacted', 'qualified') and old.pipeline_stage = 'new' then 'contacted'
                               else old.pipeline_stage end;
  end if;
  if new.do_not_contact_at is not null and old.do_not_contact_at is null then new.pipeline_stage := 'lost'; end if;
  if new.pipeline_stage is distinct from old.pipeline_stage then
    new.pipeline_stage_at := now();
    if new.followup_stopped_at is null and new.followup_next_at is not null then
      new.followup_stopped_at := now(); new.followup_stop_reason := 'Stage changed to ' || replace(new.pipeline_stage, '_', ' ');
    end if;
    new.status := case new.pipeline_stage when 'lost' then case when new.status = 'spam' then 'spam' else 'closed' end
                                          when 'signed' then 'converted' when 'car_onboarded' then 'converted'
                                          when 'new' then new.status else case when new.status = 'new' then 'contacted' else new.status end end;
  end if;
  return new;
end $$;
drop trigger if exists leads_owner_pipeline_sync on leads;
create trigger leads_owner_pipeline_sync before update on leads for each row execute function app.owner_pipeline_status_sync();

-- ================================================================ the follow-ups
create or replace function app.owner_followup_text(p_step integer, l leads, p_site text, p_phone text) returns jsonb
language sql stable as $$
  select case p_step
    when 1 then jsonb_build_object('subject', 'The CarmaCars owner program' || coalesce(': your ' || nullif(l.vehicle_text, ''), ''),
      'body', 'Thank you for your interest in the CarmaCars owner program. In short: your car goes on our fleet insurance policy, we rent it out in Toronto and we pay you every month. Fees apply; the page below explains them.' || E'\n\n' || p_site || '/list-your-car' || E'\n\n' || 'Reply to this email or call ' || p_phone || ' with any question.')
    when 2 then jsonb_build_object('subject', 'How the CarmaCars owner program works',
      'body', 'A quick follow-up. You apply online, we check your car, it goes on our fleet insurance policy and we list it. We handle the renters, the handovers and the cleaning, and pay you monthly with a statement for each rental. Fees apply.' || E'\n\n' || 'Applying takes a few minutes: ' || p_site || '/list-your-car' || E'\n\n' || 'Or reply with a good time for a short call.')
    when 3 then jsonb_build_object('subject', 'Questions about listing your car with CarmaCars?',
      'body', 'Owners often ask what they need: the car''s VIN, its ownership permit and insurance details, and a Canadian bank account for fees and payouts. Your owner portal then shows each booking, your statements and your payouts.' || E'\n\n' || 'Start here: ' || p_site || '/list-your-car' || E'\n\n' || 'Reply or call ' || p_phone || ' and we will walk you through it.')
    else jsonb_build_object('subject', 'Last note about the CarmaCars owner program',
      'body', 'This is our last email about the owner program unless you reply. If the timing is not right, no problem: the page stays here when you are ready.' || E'\n\n' || p_site || '/list-your-car' || E'\n\n' || 'Thank you.')
  end
$$;

-- whether a follow-up may go to this lead: the consent log for a classified lead; an inquiry (6 months) or a referral otherwise
create or replace function app.owner_followup_consent(l leads) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
begin
  if l.email is null then return jsonb_build_object('allowed', false, 'reason', 'No email address'); end if;
  if l.do_not_contact_at is not null then return jsonb_build_object('allowed', false, 'reason', 'Do not contact'); end if;
  if app.email_suppressed(lower(btrim(l.email)), true) then return jsonb_build_object('allowed', false, 'reason', 'They unsubscribed'); end if;
  if l.kind = 'owner_recruit' then return app.recruit_consent_state(l.id, 'email'); end if;
  -- a referral typed by staff (they did not ask us themselves): one message, naming no one
  if l.pipeline_source = 'referral' and l.payload ? 'added_by' then
    return case when l.followup_step = 0 then jsonb_build_object('allowed', true, 'basis', 'referral', 'last', true)
                else jsonb_build_object('allowed', false, 'reason', 'A referral allows one message, and it was sent') end;
  end if;
  if l.created_at < now() - interval '6 months' then return jsonb_build_object('allowed', false, 'reason', 'Their inquiry is more than 6 months old'); end if;
  return jsonb_build_object('allowed', true, 'basis', case when l.pipeline_source = 'referral' then 'referral' else 'implied_inquiry' end);
end $$;

create or replace function app.owner_followup_send(p_lead uuid) returns text
language plpgsql security definer set search_path = public, app as $$
declare
  s program_settings := app.settings();
  l leads;
  v_state jsonb;
  v_text jsonb;
  v_step integer;
  v_token uuid := gen_random_uuid();
  v_out uuid;
  v_id uuid := gen_random_uuid();
  v_site text;
  v_phone text;
  v_replied timestamptz;
begin
  select * into l from leads where id = p_lead for update;
  if l.id is null or l.followup_stopped_at is not null or l.followup_next_at is null then return 'not due'; end if;
  -- a reply stops the sequence: a text or a call from them since it started
  select max(a.created_at) into v_replied from phone_activity a left join phone_threads t on t.id = a.thread_id
   where (a.lead_id = l.id or t.lead_id = l.id) and a.direction = 'in' and a.created_at >= l.created_at;
  if v_replied is not null or l.replied_at is not null then
    update leads set replied_at = coalesce(replied_at, v_replied), followup_stopped_at = now(), followup_stop_reason = 'They replied', followup_next_at = null where id = l.id;
    return 'replied';
  end if;
  if not s.owner_followup_enabled then return 'off'; end if;
  if l.pipeline_stage is distinct from 'new' then
    update leads set followup_stopped_at = now(), followup_stop_reason = 'Stage is ' || replace(coalesce(l.pipeline_stage, 'none'), '_', ' '), followup_next_at = null where id = l.id;
    return 'stage';
  end if;
  v_state := app.owner_followup_consent(l);
  if not coalesce((v_state ->> 'allowed')::boolean, false) then
    update leads set followup_stopped_at = now(), followup_stop_reason = 'Not sent: ' || coalesce(v_state ->> 'reason', 'no consent'), followup_next_at = null where id = l.id;
    return 'no consent';
  end if;
  v_step := l.followup_step + 1;
  v_site := rtrim(coalesce((select nullif(site_url, '') from site_settings limit 1), s.notify_base_url), '/');
  v_phone := coalesce((select coalesce(phone_display, phone) from site_settings limit 1), s.company_phone, 'the number on carmacars.ca');
  v_text := app.owner_followup_text(case when v_step >= cardinality(s.owner_followup_days) then 4 else least(v_step, 3) end, l, v_site, v_phone);
  insert into notification_outbox (code, category, priority, audience, to_address, to_name, entity, entity_id, payload, dedupe_key, status, send_after, unsubscribe_token)
  values ('owner_recruit_outreach', 'marketing', coalesce((select priority from notification_catalogue where code = 'owner_recruit_outreach'), 5), 'owner', lower(btrim(l.email)), l.name, 'lead', l.id,
          jsonb_build_object('first_name', coalesce(nullif(split_part(btrim(coalesce(l.name, '')), ' ', 1), ''), 'there'), 'subject_line', v_text ->> 'subject', 'message_body', v_text ->> 'body',
                             'sender_name', 'The CarmaCars team',
                             'consent_reason', case v_state ->> 'basis' when 'express' then 'you agreed to hear from CarmaCars about the owner program'
                               when 'implied_business' then 'you do business with CarmaCars' when 'implied_published' then 'your business published this address'
                               when 'referral' then 'someone you know suggested we write to you' else 'you asked CarmaCars about the owner program' end,
                             'unsubscribe_url', s.notify_base_url || s.notify_unsubscribe_path || '?token=' || v_token::text),
          'owner_followup:' || l.id || ':' || v_step, 'queued', now(), v_token)
  on conflict do nothing
  returning id into v_out;
  if l.kind = 'owner_recruit' and v_out is not null then
    insert into recruit_messages (id, lead_id, channel, template, subject, body, to_address, consent_id, basis, outbox_id)
    values (v_id, l.id, 'email', 'followup_' || v_step, v_text ->> 'subject', v_text ->> 'body', lower(btrim(l.email)), nullif(v_state ->> 'consent_id', '')::uuid, v_state ->> 'basis', v_out);
  end if;
  if coalesce((v_state ->> 'last')::boolean, false) then
    update leads set followup_step = v_step, followup_next_at = null, followup_stopped_at = now(), followup_stop_reason = 'A referral allows one message' where id = l.id;
    return 'sent ' || v_step;
  end if;
  update leads set followup_step = v_step,
         followup_next_at = case when v_step < cardinality(s.owner_followup_days) then l.created_at + make_interval(days => s.owner_followup_days[v_step + 1]) end,
         followup_stopped_at = case when v_step >= cardinality(s.owner_followup_days) then now() end,
         followup_stop_reason = case when v_step >= cardinality(s.owner_followup_days) then 'All follow-ups sent' end
   where id = l.id;
  return 'sent ' || v_step;
end $$;

-- the stages that follow the owner's records, and the referral credit
create or replace function app.owner_pipeline_advance() returns integer
language plpgsql security definer set search_path = public, app as $$
declare
  r record;
  n integer := 0;
  v_stage text;
  v_rank constant text[] := array['new', 'contacted', 'call_booked', 'agreement_sent', 'signed', 'car_onboarded'];
begin
  -- the owner an application made from the lead
  update leads l set owner_id = a.owner_id from owner_applications a
   where a.lead_id = l.id and l.owner_id is null and a.owner_id is not null and l.kind in ('owner_program', 'owner_recruit');
  for r in select l.id, l.owner_id, l.pipeline_stage from leads l where l.owner_id is not null and l.kind in ('owner_program', 'owner_recruit')
             and l.pipeline_stage not in ('car_onboarded', 'lost') loop
    v_stage := case when exists (select 1 from vehicles v where v.owner_id = r.owner_id and v.retired_at is null and app.public_listing_row(v.id) is not null) then 'car_onboarded'
                    when exists (select 1 from owner_agreements a where a.owner_id = r.owner_id and a.status = 'signed') then 'signed'
                    when exists (select 1 from owner_agreements a where a.owner_id = r.owner_id and a.status = 'sent') then 'agreement_sent' end;
    if v_stage is not null and array_position(v_rank, v_stage) > coalesce(array_position(v_rank, r.pipeline_stage), 0) then
      update leads set pipeline_stage = v_stage where id = r.id;
      n := n + 1;
    end if;
  end loop;
  -- referral credits: waiting while the referred owner signs up; due at the first completed rental of their car
  insert into owner_referral_credits (lead_id, referrer_owner_id, referred_owner_id)
  select l.id, l.referred_by_owner_id, l.owner_id from leads l
   where l.referred_by_owner_id is not null and l.kind in ('owner_program', 'owner_recruit') and l.referred_by_owner_id is distinct from l.owner_id
  on conflict (lead_id) do update set referred_owner_id = coalesce(owner_referral_credits.referred_owner_id, excluded.referred_owner_id)
   where owner_referral_credits.referred_owner_id is null and excluded.referred_owner_id is not null;
  for r in select c.id, c.referred_owner_id from owner_referral_credits c where c.status = 'waiting' and c.referred_owner_id is not null loop
    update owner_referral_credits c set status = 'due', booking_id = b.id, rental_charge_cents = b.rental_charge_cents - b.discount_cents - b.staff_discount_cents - b.promo_discount_cents,
           kickback_bps = (app.settings()).kickback_bps,
           amount_cents = public.calc_bps(b.rental_charge_cents - b.discount_cents - b.staff_discount_cents - b.promo_discount_cents, (app.settings()).kickback_bps), updated_at = now()
      from (select x.* from bookings x join vehicles v on v.id = x.vehicle_id where v.owner_id = r.referred_owner_id and x.status = 'closed' and x.booking_type <> 'owner'
             order by x.return_at limit 1) b
     where c.id = r.id;
  end loop;
  return n;
end $$;

create or replace function app.job_owner_pipeline() returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  r record;
  v jsonb := '{}'::jsonb;
  x text;
begin
  for r in select id from leads where kind in ('owner_program', 'owner_recruit') and followup_stopped_at is null and followup_next_at <= now() order by followup_next_at limit 200 loop
    x := app.owner_followup_send(r.id);
    v := v || jsonb_build_object(x, coalesce((v ->> x)::int, 0) + 1);
  end loop;
  return v || jsonb_build_object('advanced', app.owner_pipeline_advance());
end $$;

do $$
begin
  if to_regclass('cron.job') is not null then
    perform cron.schedule('carmacars-owner-pipeline', '7,22,37,52 * * * *', $q$select app.job_owner_pipeline()$q$);
  end if;
end $$;

-- ================================================================ reads and actions
create or replace function app.owner_pipeline_allowed(p_by uuid) returns boolean
language sql stable security definer set search_path = public, app as $$
  select app.user_is_admin(p_by) or app.user_va_has(p_by, 'sales', 'cs')
$$;

create or replace function app.owner_pipeline_read(p_by uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  v_admin boolean := app.user_is_admin(p_by);
  v_q text := nullif(lower(btrim(coalesce(p ->> 'q', ''))), '');
  v_site text := rtrim(coalesce((select nullif(site_url, '') from site_settings limit 1), (app.settings()).notify_base_url), '/');
begin
  if not app.owner_pipeline_allowed(p_by) then raise exception 'Admins, Sales and Customer service only' using errcode = '42501'; end if;
  perform app.owner_pipeline_advance();
  return jsonb_build_object('admin', v_admin, 'followups_enabled', (app.settings()).owner_followup_enabled, 'followup_days', to_jsonb((app.settings()).owner_followup_days),
    'kickback_bps', (app.settings()).kickback_bps,
    'leads', (select coalesce(jsonb_agg(jsonb_build_object('id', l.id, 'kind', l.kind, 'name', l.name, 'business_name', l.business_name, 'email', l.email, 'phone', l.phone,
                 'vehicle', coalesce(l.vehicle_text, l.payload ->> 'vehicle', nullif(concat_ws(' ', l.payload ->> 'year', l.payload ->> 'make', l.payload ->> 'model'), '')),
                 'stage', l.pipeline_stage, 'stage_at', l.pipeline_stage_at, 'source', l.pipeline_source, 'note', l.pipeline_note, 'message', l.message,
                 'created_at', l.created_at, 'assignee', (select full_name from users where id = l.assigned_to),
                 'followup_step', l.followup_step, 'followup_next_at', case when l.followup_stopped_at is null then l.followup_next_at end, 'followup_stop_reason', l.followup_stop_reason,
                 'replied_at', l.replied_at, 'referred_by', (select coalesce(o.corporation_name, o.legal_name) from owners o where o.id = l.referred_by_owner_id),
                 'owner_id', l.owner_id) order by l.pipeline_stage_at desc nulls last, l.created_at desc), '[]'::jsonb)
                from (select * from leads x where x.kind in ('owner_program', 'owner_recruit') and x.pipeline_stage is not null
                        and (x.pipeline_stage <> 'lost' or x.pipeline_stage_at > now() - interval '60 days')
                        and (v_q is null or strpos(lower(concat_ws(' ', x.name, x.business_name, x.email, x.phone, x.vehicle_text)), v_q) > 0)
                      order by x.created_at desc limit 500) l),
    'credits', case when v_admin then (select coalesce(jsonb_agg(jsonb_build_object('id', c.id, 'status', c.status, 'referrer', (select coalesce(o.corporation_name, o.legal_name) from owners o where o.id = c.referrer_owner_id),
                 'referred', coalesce((select coalesce(o.corporation_name, o.legal_name) from owners o where o.id = c.referred_owner_id), (select name from leads where id = c.lead_id)),
                 'booking', (select booking_number from bookings where id = c.booking_id), 'rental_charge_cents', c.rental_charge_cents, 'amount_cents', c.amount_cents, 'paid_at', c.paid_at)
                 order by c.created_at desc), '[]'::jsonb) from owner_referral_credits c) end,
    'owner_links', case when v_admin then (select coalesce(jsonb_agg(jsonb_build_object('owner', coalesce(o.corporation_name, o.legal_name), 'code', o.referral_code,
                      'url', v_site || '/r/' || o.referral_code || '?to=owner') order by o.legal_name), '[]'::jsonb)
                    from owners o where o.referral_code is not null and o.status = 'active' and coalesce(o.is_test, false) = false) end);
end $$;

create or replace function app.owner_pipeline_do(p_by uuid, p_name text, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  l leads;
  v_email text := nullif(lower(btrim(coalesce(p ->> 'email', ''))), '');
  v_phone text := nullif(btrim(coalesce(p ->> 'phone', '')), '');
  v_src text := coalesce(nullif(p ->> 'source', ''), 'manual');
begin
  if not app.owner_pipeline_allowed(p_by) then raise exception 'Admins, Sales and Customer service only' using errcode = '42501'; end if;
  if p_name = 'owner_pipeline_add' then
    if v_email is null and v_phone is null then raise exception 'Give a phone number or an email address' using errcode = '22023'; end if;
    if v_email is not null and v_email !~ '^[^@\s]+@[^@\s]+\.[^@\s]+$' then raise exception 'Enter a full email address, for example name@example.com' using errcode = '22023'; end if;
    if v_src not in ('manual', 'referral') then raise exception 'Choose by hand or a referral (classified ads: Owner recruitment)' using errcode = '22023'; end if;
    insert into leads (kind, name, email, phone, message, source, vehicle_text, assigned_to, pipeline_source, payload, consent_text, consent_at)
    values ('owner_program', nullif(btrim(coalesce(p ->> 'name', '')), ''), v_email, v_phone, nullif(btrim(coalesce(p ->> 'note', '')), ''), v_src,
            nullif(btrim(coalesce(p ->> 'vehicle_text', '')), ''), p_by, v_src,
            jsonb_strip_nulls(jsonb_build_object('referral_code', nullif(btrim(coalesce(p ->> 'referral_code', '')), ''), 'added_by', p_by)),
            'Asked about the owner program (' || v_src || ', recorded by staff)', now())
    returning * into l;
    if not coalesce((p ->> 'asked_us')::boolean, true) then
      update leads set followup_stopped_at = now(), followup_stop_reason = 'Added without an inquiry: no automatic emails', followup_next_at = null where id = l.id;
    end if;
  elsif p_name = 'owner_pipeline_save' then
    if nullif(p ->> 'stage', '') is not null and p ->> 'stage' not in ('new', 'contacted', 'call_booked', 'agreement_sent', 'signed', 'car_onboarded', 'lost') then
      raise exception 'Choose a stage' using errcode = '22023'; end if;
    update leads set pipeline_stage = coalesce(nullif(p ->> 'stage', ''), pipeline_stage),
           pipeline_note = case when p ? 'note' then nullif(btrim(coalesce(p ->> 'note', '')), '') else pipeline_note end,
           closed_reason = case when p ->> 'stage' = 'lost' then coalesce(nullif(btrim(coalesce(p ->> 'reason', '')), ''), closed_reason) else closed_reason end,
           assigned_to = case when coalesce((p ->> 'take')::boolean, false) then p_by else assigned_to end, updated_at = now()
     where id = nullif(p ->> 'id', '')::uuid and kind in ('owner_program', 'owner_recruit') returning * into l;
  elsif p_name = 'owner_pipeline_replied' then
    update leads set replied_at = coalesce(replied_at, now()), followup_stopped_at = coalesce(followup_stopped_at, now()),
           followup_stop_reason = coalesce(followup_stop_reason, 'They replied'), followup_next_at = null, updated_at = now()
     where id = nullif(p ->> 'id', '')::uuid and kind in ('owner_program', 'owner_recruit') returning * into l;
  elsif p_name = 'owner_pipeline_followups' then
    if coalesce((p ->> 'on')::boolean, false) then
      update leads set followup_stopped_at = null, followup_stop_reason = null, replied_at = null,
             followup_next_at = greatest(now(), created_at + make_interval(days => coalesce((app.settings()).owner_followup_days[least(followup_step + 1, cardinality((app.settings()).owner_followup_days))], 0))),
             updated_at = now()
       where id = nullif(p ->> 'id', '')::uuid and kind in ('owner_program', 'owner_recruit') and pipeline_stage = 'new'
         and followup_step < cardinality((app.settings()).owner_followup_days) returning * into l;
      if l.id is null then raise exception 'Follow-ups restart only for a new lead with steps left' using errcode = '22023'; end if;
    else
      update leads set followup_stopped_at = now(), followup_stop_reason = 'Stopped by ' || coalesce((select full_name from users where id = p_by), 'staff'), followup_next_at = null, updated_at = now()
       where id = nullif(p ->> 'id', '')::uuid and kind in ('owner_program', 'owner_recruit') returning * into l;
    end if;
  elsif p_name = 'owner_referral_credit_paid' then
    perform app.assert_admin(p_by);
    update owner_referral_credits set status = 'paid', paid_at = now(), paid_by = p_by, note = nullif(btrim(coalesce(p ->> 'note', '')), ''), updated_at = now()
     where id = nullif(p ->> 'id', '')::uuid and status = 'due';
    if not found then raise exception 'Only a credit that is due can be marked paid' using errcode = '22023'; end if;
    insert into audit_log (actor_user_id, action, entity_table, entity_id, after) values (p_by, p_name, 'owner_referral_credits', p ->> 'id', p);
    return jsonb_build_object('paid', p ->> 'id');
  else
    raise exception 'Unknown owner pipeline call %', p_name using errcode = '22023';
  end if;
  if l.id is null then raise exception 'Lead not found' using errcode = 'P0002'; end if;
  insert into audit_log (actor_user_id, action, entity_table, entity_id, after) values (p_by, p_name, 'leads', l.id::text, p);
  return jsonb_build_object('id', l.id, 'stage', l.pipeline_stage, 'followup_next_at', l.followup_next_at, 'followup_stop_reason', l.followup_stop_reason);
end $$;

-- every active owner has a referral code (for renters and, with ?to=owner, for new owners), now and from now on
create or replace function app.owner_referral_code_default() returns trigger
language plpgsql security definer set search_path = public, app as $$
begin
  if new.referral_code is null and new.status = 'active' then
    new.referral_code := 'O' || substr(translate(upper(md5(new.id::text || clock_timestamp()::text)), '01', ''), 1, 7);
  end if;
  return new;
end $$;
drop trigger if exists owners_referral_code_default on owners;
create trigger owners_referral_code_default before insert or update of status on owners for each row execute function app.owner_referral_code_default();
update owners set referral_code = 'O' || substr(translate(upper(md5(id::text || clock_timestamp()::text)), '01', ''), 1, 7)
 where referral_code is null and status = 'active';

alter function app.door(uuid, text, text, text, jsonb) rename to door_pre0215;
create function app.door(p_user uuid, p_aal text, p_call text, p_name text, p jsonb default '{}'::jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
begin
  if p_call in ('admin_read', 'va_read') and p_name = 'owner_pipeline' then
    perform app.door_begin(p_user, p_aal);
    return app.owner_pipeline_read(p_user, coalesce(p, '{}'::jsonb) - '_va');
  end if;
  if (p_call in ('admin_do', 'va_do') and p_name in ('owner_pipeline_add', 'owner_pipeline_save', 'owner_pipeline_replied', 'owner_pipeline_followups'))
     or (p_call = 'admin_do' and p_name = 'owner_referral_credit_paid') then
    perform app.door_begin(p_user, p_aal);
    return app.owner_pipeline_do(p_user, p_name, coalesce(p, '{}'::jsonb) - '_va');
  end if;
  return app.door_pre0215(p_user, p_aal, p_call, p_name, p);
end $$;
select pg_temp.copy_grants('app.door(uuid, text, text, text, jsonb)'::regprocedure, 'app.door_pre0215(uuid, text, text, text, jsonb)'::regprocedure);

alter table owner_referral_credits enable row level security;
revoke all on owner_referral_credits from anon, authenticated;
grant all on owner_referral_credits to service_role;
drop policy if exists admin_all on owner_referral_credits;
create policy admin_all on owner_referral_credits for all to authenticated using (app.is_admin()) with check (app.is_admin());
drop trigger if exists audit_owner_referral_credits on owner_referral_credits;
create trigger audit_owner_referral_credits after insert or update or delete on owner_referral_credits for each row execute function app.audit_row();
do $$
declare f record;
begin
  for f in select p.oid::regprocedure as sig from pg_proc p join pg_namespace n on n.oid = p.pronamespace
            where n.nspname = 'app' and (p.proname like 'owner\_pipeline%' or p.proname like 'owner\_followup%' or p.proname in ('job_owner_pipeline', 'door_pre0215', 'owner_referral_code_default')) loop
    execute format('revoke all on function %s from public, anon, authenticated', f.sig);
    execute format('grant execute on function %s to service_role', f.sig);
  end loop;
end $$;
