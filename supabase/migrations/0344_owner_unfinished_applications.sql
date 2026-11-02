-- 0344: owner leads from the application as it is filled in (Release 26, docs/changes/2026-11-06-sales-owner-recruitment.md).
-- The owner: "the owner leads should be farmed as well, with forms saving their info as they go so we can chase incomplete
-- form fills as leads. they can either input their vin or their year make and model and they need to input their phone
-- number and email and name".
--   1. The application's first step asks for the name, mobile and email, then the car (the VIN, or the year, make and
--      model). The draft saves itself as they type (form_drafts, 0022) and the contact capture of 0090 records the name,
--      email and phone as each becomes valid. Here, that capture's lead becomes an owner lead in the owner pipeline
--      (kind owner_program, source "Website form, unfinished", pipeline_source unfinished_form), deduplicated by email and
--      phone against the owner leads already open: the capture joins that lead instead of making a second one. The car
--      typed into the draft (or priced in the owner earnings calculator and handed to the application) goes on the lead.
--   2. Left unfinished for 30 minutes (program_settings.capture_continue_minutes) it is a lead to chase: the least busy
--      real Sales person gets it with a task in the Sales queue, and the owner recruitment follow-ups start (day 0, 2, 5
--      and 10 of owner_followup_days, with the consent rules of 0217: an inquiry, 6 months, unsubscribe, sending hours).
--      Their words are "finish your application", with a link that opens their saved draft. The capture's own Admin task
--      and "Continue your request" email are not sent for it (one chase, not three).
--   3. The application sent: the lead moves to the new stage Applied (between Call booked and Agreement sent), takes the
--      owner, and its follow-ups and task stop.
-- SCHEMA_MARKER 0344. No applied migration is edited.
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

-- ================================================================ the stage Applied and the source
alter table leads drop constraint if exists leads_pipeline_stage_check;
alter table leads add constraint leads_pipeline_stage_check check (pipeline_stage is null or pipeline_stage in ('new', 'contacted', 'call_booked', 'applied', 'agreement_sent', 'signed', 'car_onboarded', 'lost'));
alter table leads drop constraint if exists leads_pipeline_source_check;
alter table leads add constraint leads_pipeline_source_check check (pipeline_source is null or pipeline_source in ('website', 'referral', 'manual', 'classified', 'unfinished_form'));
comment on column leads.pipeline_stage is 'Owner pipeline (0217; applied 0344): new, contacted, call_booked, applied, agreement_sent, signed, car_onboarded or lost; owner_program and owner_recruit leads only.';

-- the same comparison everywhere: the last 10 digits of a phone number
create or replace function app.phone_key(p text) returns text
language sql immutable as $$ select nullif(right(regexp_replace(coalesce(p, ''), '\D', '', 'g'), 10), '') $$;

-- The car of an application draft in words: the first vehicle's year, make and model, else its VIN.
create or replace function app.owner_draft_car(p_data jsonb) returns text
language sql immutable as $$
  select coalesce(nullif(btrim(concat_ws(' ', p_data #>> '{vehicles,0,year}', p_data #>> '{vehicles,0,make}', p_data #>> '{vehicles,0,model}')), ''),
                  case when length(coalesce(p_data #>> '{vehicles,0,vin}', '')) >= 11 then 'VIN ' || upper(p_data #>> '{vehicles,0,vin}') end,
                  nullif(btrim(concat_ws(' ', p_data #>> '{calc,year}', p_data #>> '{calc,make}', p_data #>> '{calc,model}')), ''))
$$;

-- ================================================================ 1. the capture's lead is an owner lead
-- The open owner lead with this email or phone (not this one), the latest.
create or replace function app.owner_lead_duplicate(p_lead uuid, p_email text, p_phone text) returns uuid
language sql stable security definer set search_path = public, app as $$
  select l.id from leads l
   where l.kind in ('owner_program', 'owner_recruit') and l.id is distinct from p_lead
     and coalesce(l.pipeline_stage, 'new') not in ('lost', 'car_onboarded') and l.do_not_contact_at is null
     and ((p_email is not null and lower(btrim(l.email)) = lower(btrim(p_email))) or (app.phone_key(p_phone) is not null and app.phone_key(l.phone) = app.phone_key(p_phone)))
   order by l.created_at desc limit 1
$$;

create or replace function app.owner_capture_lead(p_capture uuid) returns uuid
language plpgsql security definer set search_path = public, app as $$
declare
  c contact_captures;
  l leads;
  v_dup uuid;
  d form_drafts;
begin
  select * into c from contact_captures where id = p_capture for update;
  if c.id is null or c.form <> 'owner_application' or c.lead_id is null then return null; end if;
  select * into l from leads where id = c.lead_id;
  select * into d from form_drafts where id = c.draft_id;
  v_dup := app.owner_lead_duplicate(l.id, c.email, c.phone);
  if v_dup is not null then
    -- an owner lead with this email or phone is open: the capture joins it; the capture's own lead goes
    update contact_captures set lead_id = v_dup where id = c.id;
    if l.source = 'unfinished_form' and l.payload ->> 'capture_id' = c.id::text
       and not exists (select 1 from tasks t where t.related_table = 'leads' and t.related_id = l.id)
       and not exists (select 1 from contact_captures x where x.lead_id = l.id) then
      delete from leads where id = l.id;
    end if;
    update leads set name = coalesce(name, c.name), email = coalesce(email, c.email), phone = coalesce(phone, c.phone),
           vehicle_text = coalesce(app.owner_draft_car(d.data), vehicle_text),
           payload = payload || jsonb_strip_nulls(jsonb_build_object('draft_id', c.draft_id, 'capture_id', c.id,
                       'unfinished', case when coalesce(pipeline_stage, 'new') = 'new' and owner_id is null then true end,
                       'calculator', d.data -> 'calc')),
           updated_at = now()
     where id = v_dup;
    return v_dup;
  end if;
  if l.kind = 'other' and l.source = 'unfinished_form' then
    update leads set kind = 'owner_program', pipeline_stage = 'new', pipeline_stage_at = now(), pipeline_source = 'unfinished_form',
           message = 'Started the application to list a car on the website and has not finished it yet.',
           vehicle_text = coalesce(app.owner_draft_car(d.data), vehicle_text),
           payload = payload || jsonb_strip_nulls(jsonb_build_object('unfinished', true, 'calculator', d.data -> 'calc')),
           followup_step = 0, followup_next_at = null, followup_stopped_at = null, followup_stop_reason = null, updated_at = now()
     where id = l.id;
  elsif l.kind in ('owner_program', 'owner_recruit') then
    update leads set vehicle_text = coalesce(app.owner_draft_car(d.data), vehicle_text), updated_at = now() where id = l.id;
  end if;
  return l.id;
end $$;

alter function app.capture_contact(jsonb) rename to capture_contact_pre0344;
create function app.capture_contact(p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  v jsonb := app.capture_contact_pre0344(p);
begin
  if p ->> 'form' = 'owner_application' and nullif(v ->> 'capture_id', '') is not null then
    perform app.owner_capture_lead((v ->> 'capture_id')::uuid);
  end if;
  return v;
end $$;
select pg_temp.copy_grants('app.capture_contact(jsonb)'::regprocedure, 'app.capture_contact_pre0344(jsonb)'::regprocedure);

-- the car typed later (or handed over by the calculator) follows the draft onto its lead. A capture made before the
-- draft was first saved (the name, mobile and email are typed before the first autosave) takes this draft when it holds
-- the same email or mobile, so its lead gets the car, the estimate and the link to the draft.
create or replace function app.owner_draft_to_lead() returns trigger
language plpgsql security definer set search_path = public, app as $$
declare
  v_car text;
  v_email text := app.capture_clean_email(new.data #>> '{owner,email}');
  v_phone text := app.phone_key(new.data #>> '{owner,phone}');
begin
  if new.form_code <> 'owner_application' or new.submitted_at is not null then return null; end if;
  if v_email is not null or v_phone is not null then
    update contact_captures c set draft_id = new.id, ref = new.id::text
     where c.form = 'owner_application' and c.draft_id is null and c.done_at is null and c.last_at > now() - interval '1 day'
       and ((v_email is not null and c.email = v_email) or (v_phone is not null and app.phone_key(c.phone) = v_phone))
       and not exists (select 1 from contact_captures y where y.visitor_id = c.visitor_id and y.form = c.form and y.ref = new.id::text);
    update leads l set payload = l.payload || jsonb_build_object('draft_id', new.id), updated_at = now()
      from contact_captures c
     where c.draft_id = new.id and c.lead_id = l.id and l.kind in ('owner_program', 'owner_recruit') and l.payload ->> 'draft_id' is distinct from new.id::text;
  end if;
  v_car := app.owner_draft_car(new.data);
  update leads l set vehicle_text = coalesce(v_car, l.vehicle_text),
         payload = case when new.data ? 'calc' then l.payload || jsonb_build_object('calculator', new.data -> 'calc') else l.payload end, updated_at = now()
    from contact_captures c
   where c.draft_id = new.id and c.lead_id = l.id and l.kind in ('owner_program', 'owner_recruit')
     and (l.vehicle_text is distinct from coalesce(v_car, l.vehicle_text) or (new.data ? 'calc' and l.payload -> 'calculator' is distinct from new.data -> 'calc'));
  return null;
end $$;
drop trigger if exists form_drafts_owner_lead on form_drafts;
create trigger form_drafts_owner_lead after insert or update of data on form_drafts for each row execute function app.owner_draft_to_lead();

-- ================================================================ 2. left unfinished: the chase
create or replace function app.owner_unfinished_chase(p_now timestamptz default now()) returns integer
language plpgsql security definer set search_path = public, app as $$
declare
  ps program_settings := app.settings(app.local_date(p_now));
  r record;
  n integer := 0;
  v_to uuid;
  v_task uuid;
begin
  if not ps.capture_enabled then return 0; end if;
  for r in select distinct on (l.id) cc.id as capture_id, cc.user_id, l.*
             from contact_captures cc join leads l on l.id = cc.lead_id
             left join form_drafts d on d.id = cc.draft_id
            where cc.form = 'owner_application' and cc.done_at is null and (d.id is null or d.submitted_at is null)
              and greatest(cc.last_at, coalesce(d.updated_at, cc.last_at)) <= p_now - make_interval(mins => ps.capture_continue_minutes)
              and cc.last_at > p_now - interval '7 days'
              and l.kind = 'owner_program' and coalesce(l.pipeline_stage, 'new') = 'new' and l.owner_id is null
              and not (l.payload ? 'chased_at') and l.do_not_contact_at is null and (l.email is not null or l.phone is not null)
              -- every capture of the lead has been left 30 minutes
              and not exists (select 1 from contact_captures c2 left join form_drafts d2 on d2.id = c2.draft_id
                               where c2.lead_id = l.id and c2.done_at is null
                                 and greatest(c2.last_at, coalesce(d2.updated_at, c2.last_at)) > p_now - make_interval(mins => ps.capture_continue_minutes))
            order by l.id, cc.last_at desc loop
    v_to := coalesce(r.assigned_to, app.lead_real_assignee());
    update leads set assigned_to = v_to, payload = payload || jsonb_build_object('chased_at', p_now, 'unfinished', true),
           followup_step = 0, followup_stopped_at = null, followup_stop_reason = null,
           followup_next_at = case when ps.owner_followup_enabled and email is not null then p_now end, updated_at = now()
     where id = r.id;
    v_task := app.raise_task(p_type => 'owner_unfinished_application', p_queue => 'sales',
      p_title => left('Unfinished owner application: ' || coalesce(r.name, r.email, r.phone), 200),
      p_detail => format('%s started the application to list %s and stopped %s. Call or text them to finish it. Contact: %s. Follow-up emails go by themselves until they finish.',
                         coalesce(r.name, 'Someone'), coalesce(r.vehicle_text, 'a car'), app.fmt_at(r.updated_at),
                         coalesce(nullif(concat_ws(', ', r.phone, r.email), ''), 'none')),
      p_related_table => 'leads', p_related_id => r.id, p_dedupe => 'owner_unfinished:' || r.id);
    if v_task is not null and v_to is not null then update tasks set assigned_to = v_to where id = v_task and assigned_to is null; end if;
    -- one chase: not also the capture's Admin task and its "Continue your request" email
    update contact_captures set task_id = coalesce(task_id, v_task) where lead_id = r.id and done_at is null;
    update capture_accounts set continue_sent_at = coalesce(continue_sent_at, p_now) where user_id in (select user_id from contact_captures where lead_id = r.id);
    n := n + 1;
  end loop;
  return n;
end $$;

alter function app.job_capture(timestamptz) rename to job_capture_pre0344;
create function app.job_capture(p_now timestamptz default now()) returns text
language plpgsql security definer set search_path = public, app as $$
declare
  n integer := app.owner_unfinished_chase(p_now);
begin
  return app.job_capture_pre0344(p_now) || format(', owner applications chased %s', n);
end $$;
select pg_temp.copy_grants('app.job_capture(timestamptz)'::regprocedure, 'app.job_capture_pre0344(timestamptz)'::regprocedure);

-- The follow-up words (0217), with "finish your application" and a link to the saved draft for an unfinished one. A new
-- link with each email (the draft keeps the latest; it works for form_resume_link_hours).
create or replace function app.owner_followup_text(p_step integer, l leads, p_site text, p_phone text) returns jsonb
language plpgsql volatile security definer set search_path = public, app as $$
declare
  v_link text;
  v_url text := p_site || '/list-your-car/apply';
  v_car text := coalesce(nullif(l.vehicle_text, ''), 'your car');
begin
  if not (l.payload ? 'chased_at') or l.owner_id is not null then
    return case p_step
      when 1 then jsonb_build_object('subject', 'The CarmaCars owner program' || coalesce(': your ' || nullif(l.vehicle_text, ''), ''),
        'body', 'Thank you for your interest in the CarmaCars owner program. In short: your car goes on our fleet insurance policy, we rent it out in Toronto and we pay you every month. Fees apply; the page below explains them.' || E'\n\n' || p_site || '/list-your-car' || E'\n\n' || 'Reply to this email or call ' || p_phone || ' with any question.')
      when 2 then jsonb_build_object('subject', 'How the CarmaCars owner program works',
        'body', 'A quick follow-up. You apply online, we check your car, it goes on our fleet insurance policy and we list it. We handle the renters, the handovers and the cleaning, and pay you monthly with a statement for each rental. Fees apply.' || E'\n\n' || 'Applying takes a few minutes: ' || p_site || '/list-your-car' || E'\n\n' || 'Or reply with a good time for a short call.')
      when 3 then jsonb_build_object('subject', 'Questions about listing your car with CarmaCars?',
        'body', 'Owners often ask what they need: the car''s VIN, its ownership permit and insurance details, and a Canadian bank account for fees and payouts. Your owner portal then shows each booking, your statements and your payouts.' || E'\n\n' || 'Start here: ' || p_site || '/list-your-car' || E'\n\n' || 'Reply or call ' || p_phone || ' and we will walk you through it.')
      else jsonb_build_object('subject', 'Last note about the CarmaCars owner program',
        'body', 'This is our last email about the owner program unless you reply. If the timing is not right, no problem: the page stays here when you are ready.' || E'\n\n' || p_site || '/list-your-car' || E'\n\n' || 'Thank you.')
    end;
  end if;
  -- the saved draft: a fresh link to open it again
  if nullif(l.payload ->> 'draft_id', '') is not null then
    v_link := app.new_token();
    update form_drafts set resume_email = coalesce(lower(btrim(l.email)), resume_email), resume_link_hash = app.token_hash(v_link),
           resume_link_expires_at = now() + make_interval(hours => (app.settings()).form_resume_link_hours)
     where id = (l.payload ->> 'draft_id')::uuid and submitted_at is null and expires_at > now();
    if found then v_url := p_site || '/list-your-car/apply/resume?t=' || v_link; end if;
  end if;
  return case p_step
    when 1 then jsonb_build_object('subject', 'Finish your application to list ' || v_car,
      'body', 'You started your application to list ' || v_car || ' with CarmaCars. Your answers are saved: pick up where you left off here.' || E'\n\n' || v_url || E'\n\n' || 'In short: your car goes on our fleet insurance policy, we rent it out in Toronto and we pay you every month. Fees apply. Reply or call ' || p_phone || ' with any question.')
    when 2 then jsonb_build_object('subject', 'Your CarmaCars application is saved',
      'body', 'A quick reminder: your application is saved and takes a few minutes to finish. We reply within 1 business day with the terms for your car.' || E'\n\n' || 'Finish your application: ' || v_url || E'\n\n' || 'Or reply with a good time for a short call.')
    when 3 then jsonb_build_object('subject', 'Anything stopping you from finishing your application?',
      'body', 'Owners often stop to find the car''s VIN, its ownership permit or insurance details. Have them at hand and it takes a few minutes.' || E'\n\n' || 'Finish your application: ' || v_url || E'\n\n' || 'Reply or call ' || p_phone || ' and we will walk you through it.')
    else jsonb_build_object('subject', 'Last note about your CarmaCars application',
      'body', 'This is our last email about your application unless you reply. Your answers stay saved for a while: finish whenever you are ready.' || E'\n\n' || v_url || E'\n\n' || 'Thank you.')
  end;
end $$;

-- ================================================================ 3. the application sent: Applied
create or replace function app.owner_applications_lead_applied() returns trigger
language plpgsql security definer set search_path = public, app as $$
declare
  o owners;
  l record;
begin
  select * into o from owners where id = new.owner_id;
  for l in select distinct x.id from leads x
            where x.kind in ('owner_program', 'owner_recruit') and coalesce(x.pipeline_stage, 'new') in ('new', 'contacted', 'call_booked')
              and (x.id = new.lead_id
                   or x.id in (select c.lead_id from contact_captures c where new.form_draft_id is not null and c.draft_id = new.form_draft_id)
                   or (x.owner_id is null and ((o.email is not null and lower(btrim(x.email)) = lower(btrim(o.email)))
                                               or (app.phone_key(o.phone) is not null and app.phone_key(x.phone) = app.phone_key(o.phone))))) loop
    update leads set pipeline_stage = 'applied', owner_id = coalesce(owner_id, new.owner_id), payload = payload - 'unfinished', updated_at = now() where id = l.id;
    update leads set followup_next_at = null, followup_stopped_at = coalesce(followup_stopped_at, now()), followup_stop_reason = coalesce(followup_stop_reason, 'They applied')
     where id = l.id and followup_next_at is not null;
    update tasks set status = 'done', completed_at = now(), completion_note = 'They applied: ' || new.application_number
     where related_table = 'leads' and related_id = l.id and task_type in ('owner_unfinished_application', 'owner_lead_follow_up') and status in ('open', 'in_progress', 'waiting');
    if new.lead_id is null then update owner_applications set lead_id = l.id where id = new.id and lead_id is null; end if;
  end loop;
  return null;
end $$;
drop trigger if exists owner_applications_lead_applied on owner_applications;
create trigger owner_applications_lead_applied after insert on owner_applications for each row execute function app.owner_applications_lead_applied();

-- 0217's stages that follow the owner's records, with Applied (an application on file) in its place
create or replace function app.owner_pipeline_advance() returns integer
language plpgsql security definer set search_path = public, app as $$
declare
  r record;
  n integer := 0;
  v_stage text;
  v_rank constant text[] := array['new', 'contacted', 'call_booked', 'applied', 'agreement_sent', 'signed', 'car_onboarded'];
begin
  update leads l set owner_id = a.owner_id from owner_applications a
   where a.lead_id = l.id and l.owner_id is null and a.owner_id is not null and l.kind in ('owner_program', 'owner_recruit');
  for r in select l.id, l.owner_id, l.pipeline_stage from leads l where l.owner_id is not null and l.kind in ('owner_program', 'owner_recruit')
             and l.pipeline_stage not in ('car_onboarded', 'lost') loop
    v_stage := case when exists (select 1 from vehicles v where v.owner_id = r.owner_id and v.retired_at is null and app.public_listing_row(v.id) is not null) then 'car_onboarded'
                    when exists (select 1 from owner_agreements a where a.owner_id = r.owner_id and a.status = 'signed') then 'signed'
                    when exists (select 1 from owner_agreements a where a.owner_id = r.owner_id and a.status = 'sent') then 'agreement_sent'
                    when exists (select 1 from owner_applications a where a.owner_id = r.owner_id) then 'applied' end;
    if v_stage is not null and array_position(v_rank, v_stage) > coalesce(array_position(v_rank, r.pipeline_stage), 0) then
      update leads set pipeline_stage = v_stage where id = r.id;
      n := n + 1;
    end if;
  end loop;
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

-- Move to Applied by hand too (0217 checks its own list of stages)
alter function app.owner_pipeline_do(uuid, text, jsonb) rename to owner_pipeline_do_pre0344;
create function app.owner_pipeline_do(p_by uuid, p_name text, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  v jsonb;
begin
  if p_name = 'owner_pipeline_save' and p ->> 'stage' = 'applied' then
    v := app.owner_pipeline_do_pre0344(p_by, p_name, p - 'stage');
    update leads set pipeline_stage = 'applied', updated_at = now() where id = (v ->> 'id')::uuid and kind in ('owner_program', 'owner_recruit');
    return v || jsonb_build_object('stage', 'applied');
  end if;
  return app.owner_pipeline_do_pre0344(p_by, p_name, p);
end $$;
select pg_temp.copy_grants('app.owner_pipeline_do(uuid, text, jsonb)'::regprocedure, 'app.owner_pipeline_do_pre0344(uuid, text, jsonb)'::regprocedure);

do $$
declare f record;
begin
  for f in select p.oid::regprocedure as sig from pg_proc p join pg_namespace n on n.oid = p.pronamespace
            where n.nspname = 'app' and p.proname in ('owner_draft_car', 'owner_lead_duplicate', 'owner_capture_lead', 'capture_contact_pre0344', 'owner_draft_to_lead',
                                                     'owner_unfinished_chase', 'job_capture_pre0344', 'owner_followup_text', 'owner_applications_lead_applied',
                                                     'owner_pipeline_advance', 'owner_pipeline_do_pre0344', 'phone_key') loop
    execute format('revoke all on function %s from public, anon, authenticated', f.sig);
    execute format('grant execute on function %s to service_role', f.sig);
  end loop;
end $$;
