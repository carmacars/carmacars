-- 5134 (R50 hotfix 2, Sales; docs/changes/2026-11-27-r50-sales-fixes.md). The owner, Nov 27: "Eric, a lead generator: a
-- sales portal role for owner-lead generators. He enters interested car owners with contact details (replacing a
-- spreadsheet), the leads go to closers to call through the site (not personal phones), and he earns a flat $100 per lead
-- he generated that closes (owner signed). Track status per lead for him."
--
-- 1. The role: staff_profiles.lead_generator, set by an Admin (admin_do lead_gen_set {staff, on}) on a staff member with the
--    Sales function (the Sales portal is theirs). A lead generator finds owners; closers call them: a lead generator cannot
--    claim leads (lead_claim, lead_next refuse with the reason).
-- 2. Entering a lead: va_do owner_lead_add {name, phone, email, city, car, note}: an owner lead (kind owner_program, the
--    owner pipeline at New, source lead_gen) with leads.generated_by. A name and a phone are needed (the closers call
--    it); an email is optional. A person already an open lead or an owner is refused, with what was found (no credit for a
--    lead someone else already has). The lead goes to the Sales lead list (Owners > Leads) for the closers, who call and text
--    it through the site's business line as every lead (their numbers are masked, 0970/2870). No automatic follow-up email
--    goes to the owner (they did not write to us): the follow-ups are stopped on it.
-- 3. The credit: when a lead a generator entered closes (the owner signs: the lead's pipeline reaches Signed or Car
--    onboarded, or an enrollment agreement of the lead's owner, or of an owner with the lead's email or phone, is signed),
--    lead_gen_credits gets one row for that lead: Program settings lead_gen_flat_cents ($100 by default), waiting for an
--    Admin. The generator and the Admins are told (lead_gen_closed, lead_gen_credit_due). An Admin approves, voids (with a
--    reason) or marks it paid (with the reference) (admin_do lead_gen_credit). One credit a lead, ever.
-- 4. Reads: va_read my_owner_leads (the generator's own leads: name, contact as they typed it, car, city, when, the stage in
--    words, the closer, the outcome, the credit), admin_read lead_generators (everyone with the role or who entered leads,
--    their counts and credits, and the credits to decide).
-- SCHEMA_MARKER is not changed. New table: row-level security, admin_all, the audit trigger. No applied migration is
-- edited: app.door, app.lead_claim and app.lead_next are wrapped (_pre5134).
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

-- ================================================================ 1. the role, the lead, the setting
alter table staff_profiles
  add column if not exists lead_generator boolean not null default false,
  add column if not exists lead_generator_at timestamptz;
comment on column staff_profiles.lead_generator is 'Owner-lead generator (5134): enters interested car owners for the closers to call; earns lead_gen_flat_cents per lead that signs; claims no leads. Set by an Admin.';

alter table leads add column if not exists generated_by uuid references users (id);
create index if not exists leads_generated_by_idx on leads (generated_by, created_at) where generated_by is not null;
comment on column leads.generated_by is 'The lead generator who entered this owner lead (5134): credited lead_gen_flat_cents once the owner signs.';
drop trigger if exists leads_guard_generated_by on leads;
create trigger leads_guard_generated_by before update on leads for each row execute function app.guard_admin_columns('generated_by');

alter table program_settings add column if not exists lead_gen_flat_cents bigint not null default 10000 check (lead_gen_flat_cents between 0 and 100000);
comment on column program_settings.lead_gen_flat_cents is 'Owner-lead generators (5134): the flat amount earned for each lead they entered whose owner signs, $100 by default.';

create table lead_gen_credits (
  id             uuid primary key default gen_random_uuid(),
  lead_id        uuid not null unique references leads (id),
  staff_id       uuid not null references users (id),
  owner_id       uuid references owners (id),
  amount_cents   bigint not null check (amount_cents between 0 and 100000),
  status         text not null default 'pending_approval' check (status in ('pending_approval', 'approved', 'paid', 'void')),
  earned_at      timestamptz not null default now(),
  decided_by     uuid references users (id),
  decided_at     timestamptz,
  paid_at        timestamptz,
  paid_reference text check (paid_reference is null or length(paid_reference) <= 120),
  note           text check (note is null or length(note) <= 500),
  created_at     timestamptz not null default now(),
  updated_at     timestamptz not null default now(),
  check (status <> 'paid' or paid_at is not null),
  check (status <> 'void' or note is not null)
);
comment on table lead_gen_credits is 'Owner-lead generators (5134): the flat amount earned for a lead they entered whose owner signed. One a lead; an Admin approves, voids or marks it paid.';
create index lead_gen_credits_staff_idx on lead_gen_credits (staff_id, earned_at);
create index lead_gen_credits_owner_idx on lead_gen_credits (owner_id);
create trigger lead_gen_credits_updated before update on lead_gen_credits for each row execute function app.set_updated_at();
create trigger audit_lead_gen_credits after insert or update or delete on lead_gen_credits for each row execute function app.audit_row();
alter table lead_gen_credits enable row level security;
create policy admin_all on lead_gen_credits for all to authenticated using (app.is_admin()) with check (app.is_admin());
revoke all on lead_gen_credits from public, anon, authenticated;
grant all on lead_gen_credits to service_role;

insert into staff_alert_rules (rule, label, grp, who, tier, topic, wired, fixed, hint, sort, pref_type) values
  ('lead_gen_closed', 'An owner you found signed: your lead credit', 'Sales', '{assigned}', 'normal', 'leads', true, false,
   '5134: a lead you entered signed with us; the credit waits for an Admin.', 52, 'staff_system'),
  ('lead_gen_credit_due', 'A lead credit to approve', 'Sales', '{admin}', 'normal', 'leads', true, false,
   '5134: an owner lead a lead generator entered signed; approve, void or pay the credit on Lead generators.', 53, 'staff_system')
on conflict (rule) do nothing;

create function app.is_lead_generator(p_user uuid) returns boolean
language sql stable security definer set search_path = public, app, pg_temp as $$
  select p_user is not null and exists (select 1 from staff_profiles sp join users u on u.id = sp.user_id
                                         where sp.user_id = p_user and sp.lead_generator and sp.is_active and u.status = 'active')
$$;

create function app.lead_gen_stage_words(l leads) returns text
language sql immutable set search_path = public, app, pg_temp as $$
  select case
    when l.merged_into is not null then 'Joined another lead of the same owner'
    when l.sales_outcome = 'lost' or l.pipeline_stage = 'lost' then 'Lost' || coalesce(': ' || nullif(l.sales_outcome_reason, ''), '')
    when l.pipeline_stage = 'car_onboarded' then 'Signed, car onboarded'
    when l.pipeline_stage = 'signed' or l.sales_outcome = 'won' then 'Signed'
    when l.pipeline_stage = 'agreement_sent' then 'Agreement sent'
    when l.pipeline_stage = 'applied' then 'Applied'
    when l.pipeline_stage = 'call_booked' then 'Call booked'
    when l.pipeline_stage = 'contacted' or l.first_contact_at is not null then 'Contacted'
    else 'New: waiting for a closer' end
$$;

-- the closer on a lead: an Admin's assignment, else the live claim, else the last person who claimed it
create function app.lead_closer(p_lead uuid) returns text
language sql stable security definer set search_path = public, app, pg_temp as $$
  select coalesce(u.full_name, u.email) from users u
   where u.id = coalesce((select l.assigned_to from leads l where l.id = p_lead),
                         (select c.claimed_by from lead_claims c where c.lead_id = p_lead and c.expires_at > now() limit 1),
                         (select g.user_id from lead_claim_log g where g.lead_id = p_lead and g.action = 'claim' order by g.at desc limit 1))
$$;

-- ================================================================ 2. entering a lead
-- p: {name, phone, email, city, car, note}
create function app.owner_lead_add(p_by uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app, pg_temp as $$
declare
  v_name text := nullif(left(btrim(coalesce(p ->> 'name', '')), 120), '');
  v_phone text := nullif(left(btrim(coalesce(p ->> 'phone', '')), 40), '');
  v_email text := lower(nullif(left(btrim(coalesce(p ->> 'email', '')), 200), ''));
  v_city text := nullif(left(btrim(coalesce(p ->> 'city', '')), 80), '');
  v_car text := nullif(left(btrim(coalesce(p ->> 'car', '')), 120), '');
  v_note text := nullif(left(btrim(coalesce(p ->> 'note', '')), 1000), '');
  v_dup leads;
  v_owner owners;
  l leads;
begin
  if not (app.is_lead_generator(p_by) or app.user_is_admin(p_by)) then
    raise exception 'Only lead generators add owner leads here' using errcode = '42501';
  end if;
  if v_name is null or length(v_name) < 2 then raise exception 'Enter the owner''s name' using errcode = '22023'; end if;
  if length(coalesce(app.phone_key(v_phone), '')) <> 10 then raise exception 'Enter the owner''s phone number (10 digits): the closers call it' using errcode = '22023'; end if;
  if v_email is not null and v_email !~ '^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$' then raise exception 'Check the email address' using errcode = '22023'; end if;
  select * into v_owner from owners o
   where (v_email is not null and lower(o.email) = v_email) or app.phone_key(o.phone) = app.phone_key(v_phone) limit 1;
  if v_owner.id is not null then raise exception 'Already an owner with us (%): no new lead', coalesce(v_owner.legal_name, 'same phone or email') using errcode = '23505'; end if;
  select * into v_dup from leads x
   where app.sl_type(x) = 'owner' and x.merged_into is null and x.status not in ('closed', 'spam', 'converted') and x.sales_outcome is null
     and ((v_email is not null and lower(x.email) = v_email) or app.phone_key(x.phone) = app.phone_key(v_phone))
   order by x.created_at limit 1;
  if v_dup.id is not null then
    raise exception 'Already an open owner lead (added %): a closer has it', to_char(v_dup.created_at at time zone 'America/Toronto', 'Mon DD, YYYY') using errcode = '23505';
  end if;
  insert into leads (kind, name, email, phone, message, vehicle_text, payload, source, pipeline_source, pipeline_stage, generated_by,
                     followup_stopped_at, followup_stop_reason)
  values ('owner_program', v_name, v_email, v_phone, v_note, v_car,
          jsonb_strip_nulls(jsonb_build_object('form', 'lead_gen', 'city', v_city, 'added_by', p_by)), 'lead_gen', 'manual', 'new', p_by,
          now(), 'lead_gen')
  returning * into l;
  insert into audit_log (actor_user_id, action, entity_table, entity_id, after)
  values (p_by, 'owner_lead_add', 'leads', l.id::text, jsonb_build_object('generated_by', p_by));
  return jsonb_build_object('ok', true, 'lead_id', l.id, 'name', l.name);
end $$;

-- ================================================================ 3. the credit
create function app.lead_gen_credit_check(p_lead uuid) returns uuid
language plpgsql security definer set search_path = public, app, pg_temp as $$
declare
  l leads;
  v_owner uuid;
  v_id uuid;
begin
  select * into l from leads where id = p_lead;
  -- a merged lead's credit goes with the lead it joined (5131 carries generated_by there)
  if l.id is null or l.merged_into is not null or l.generated_by is null or app.is_test_user(l.generated_by) then return null; end if;
  select o.id into v_owner from owners o
   where o.id = l.owner_id or (l.email is not null and lower(o.email) = lower(l.email)) or (app.phone_key(l.phone) is not null and app.phone_key(o.phone) = app.phone_key(l.phone))
   order by (o.id = l.owner_id) desc nulls last limit 1;
  if not (l.pipeline_stage in ('signed', 'car_onboarded')
          or (v_owner is not null and exists (select 1 from owner_agreements a where a.owner_id = v_owner and a.kind = 'enrollment' and a.status = 'signed'))) then
    return null;
  end if;
  -- one credit an owner, whichever of their leads signed
  if v_owner is not null and exists (select 1 from lead_gen_credits c where c.owner_id = v_owner and c.status <> 'void') then return null; end if;
  insert into lead_gen_credits (lead_id, staff_id, owner_id, amount_cents)
  values (l.id, l.generated_by, v_owner, (app.settings()).lead_gen_flat_cents)
  on conflict (lead_id) do nothing
  returning id into v_id;
  if v_id is null then return null; end if;
  begin
    perform app.staff_alert('lead_gen_closed', 'lead', l.id, 'credit:' || v_id,
      left(format('%s signed with us: you earned %s', coalesce(l.name, 'An owner you found'), app.money_text((app.settings()).lead_gen_flat_cents)), 140),
      'The credit waits for an Admin to approve it. My owner leads has every lead you entered.',
      jsonb_build_object('assigned_to', l.generated_by, 'path_staff', '/staff/my-owner-leads'));
    perform app.staff_alert('lead_gen_credit_due', 'lead', l.id, 'credit:' || v_id,
      left(format('Lead credit to approve: %s found %s', coalesce((select u.full_name from users u where u.id = l.generated_by), 'a lead generator'), coalesce(l.name, 'an owner')), 140),
      'The owner signed. Approve, void or mark it paid on Lead generators.', jsonb_build_object('path_admin', '/admin/lead-generators'));
  exception when others then raise warning 'lead credit alert not sent for %: %', l.id, sqlerrm;
  end;
  return v_id;
end $$;

create function app.lead_gen_lead_trg() returns trigger
language plpgsql security definer set search_path = public, app, pg_temp as $$
begin
  if new.generated_by is not null then perform app.lead_gen_credit_check(new.id); end if;
  return null;
end $$;
create trigger leads_zz_lead_gen_credit after update of pipeline_stage, owner_id, sales_outcome, generated_by on leads
  for each row when (new.generated_by is not null) execute function app.lead_gen_lead_trg();

create function app.lead_gen_agreement_trg() returns trigger
language plpgsql security definer set search_path = public, app, pg_temp as $$
declare r record;
begin
  if new.status <> 'signed' or new.kind <> 'enrollment' then return null; end if;
  for r in select l.id from leads l join owners o on o.id = new.owner_id
            where l.generated_by is not null and l.merged_into is null
              and (l.owner_id = o.id or (l.email is not null and lower(l.email) = lower(o.email)) or (app.phone_key(l.phone) is not null and app.phone_key(l.phone) = app.phone_key(o.phone))) loop
    perform app.lead_gen_credit_check(r.id);
  end loop;
  return null;
end $$;
create trigger owner_agreements_zz_lead_gen after insert or update of status on owner_agreements
  for each row execute function app.lead_gen_agreement_trg();

-- ================================================================ 4. reads and Admin actions
create function app.my_owner_leads(p_by uuid) returns jsonb
language plpgsql stable security definer set search_path = public, app, pg_temp as $$
begin
  if not (app.is_lead_generator(p_by) or app.user_va_has_sales(p_by) or app.user_is_admin(p_by)) then
    raise exception 'My owner leads is for Sales' using errcode = '42501';
  end if;
  return jsonb_build_object('flat_cents', (app.settings()).lead_gen_flat_cents, 'generator', app.is_lead_generator(p_by),
    'rows', coalesce((select jsonb_agg(jsonb_build_object('id', l.id, 'name', l.name, 'phone', l.phone, 'email', l.email, 'car', l.vehicle_text,
               'city', l.payload ->> 'city', 'note', l.message, 'created_at', l.created_at, 'stage', app.lead_gen_stage_words(l),
               'closer', app.lead_closer(l.id),
               'credit', (select jsonb_build_object('amount_cents', c.amount_cents, 'status', c.status, 'paid_at', c.paid_at) from lead_gen_credits c where c.lead_id = l.id))
             order by l.created_at desc) from leads l where l.generated_by = p_by), '[]'::jsonb),
    'totals', (select jsonb_build_object('leads', count(*), 'signed', count(*) filter (where exists (select 1 from lead_gen_credits c where c.lead_id = l.id and c.status <> 'void')),
                 'earned_cents', coalesce((select sum(c.amount_cents) from lead_gen_credits c where c.staff_id = p_by and c.status in ('approved', 'paid')), 0),
                 'waiting_cents', coalesce((select sum(c.amount_cents) from lead_gen_credits c where c.staff_id = p_by and c.status = 'pending_approval'), 0),
                 'paid_cents', coalesce((select sum(c.amount_cents) from lead_gen_credits c where c.staff_id = p_by and c.status = 'paid'), 0))
                 from leads l where l.generated_by = p_by));
end $$;

create function app.lead_generators_admin(p_by uuid) returns jsonb
language plpgsql stable security definer set search_path = public, app, pg_temp as $$
begin
  perform app.assert_admin(p_by);
  return jsonb_build_object('flat_cents', (app.settings()).lead_gen_flat_cents,
    'people', coalesce((select jsonb_agg(jsonb_build_object('id', u.id, 'name', coalesce(u.full_name, u.email), 'lead_generator', coalesce(sp.lead_generator, false),
                 'leads', (select count(*) from leads l where l.generated_by = u.id),
                 'open', (select count(*) from leads l where l.generated_by = u.id and l.merged_into is null and l.status in ('new', 'contacted', 'qualified') and l.sales_outcome is null),
                 'signed', (select count(*) from lead_gen_credits c where c.staff_id = u.id and c.status <> 'void'),
                 'owed_cents', (select coalesce(sum(c.amount_cents), 0) from lead_gen_credits c where c.staff_id = u.id and c.status = 'approved'),
                 'paid_cents', (select coalesce(sum(c.amount_cents), 0) from lead_gen_credits c where c.staff_id = u.id and c.status = 'paid'))
               order by coalesce(u.full_name, u.email))
             from users u left join staff_profiles sp on sp.user_id = u.id
            where not u.is_test and (coalesce(sp.lead_generator, false) or exists (select 1 from leads l where l.generated_by = u.id))), '[]'::jsonb),
    'candidates', coalesce((select jsonb_agg(jsonb_build_array(u.id, coalesce(u.full_name, u.email)) order by coalesce(u.full_name, u.email))
             from users u join staff_profiles sp on sp.user_id = u.id
            where not u.is_test and not sp.lead_generator and app.user_va_has_sales(u.id)), '[]'::jsonb),
    'credits', coalesce((select jsonb_agg(jsonb_build_object('id', c.id, 'lead_id', c.lead_id, 'lead', l.name, 'staff', coalesce(u.full_name, u.email), 'amount_cents', c.amount_cents,
                 'status', c.status, 'earned_at', c.earned_at, 'paid_at', c.paid_at, 'paid_reference', c.paid_reference, 'note', c.note) order by c.earned_at desc)
             from lead_gen_credits c join leads l on l.id = c.lead_id join users u on u.id = c.staff_id), '[]'::jsonb));
end $$;

-- p: {staff, on}
create function app.lead_gen_set(p_by uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app, pg_temp as $$
declare
  v_staff uuid := nullif(p ->> 'staff', '')::uuid;
  v_on boolean := coalesce((p ->> 'on')::boolean, true);
begin
  perform app.assert_admin(p_by);
  if v_on and not app.user_va_has_sales(v_staff) then raise exception 'A lead generator needs the Sales function first (Staff and roles)' using errcode = '23514'; end if;
  update staff_profiles set lead_generator = v_on, lead_generator_at = now() where user_id = v_staff;
  if not found then raise exception 'Staff member not found' using errcode = 'P0002'; end if;
  insert into audit_log (actor_user_id, action, entity_table, entity_id, after) values (p_by, 'lead_gen_set', 'staff_profiles', v_staff::text, jsonb_build_object('lead_generator', v_on));
  return jsonb_build_object('ok', true, 'staff', v_staff, 'lead_generator', v_on);
end $$;

-- p: {credit, action: approve | void | paid, reference, note}
create function app.lead_gen_credit_do(p_by uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app, pg_temp as $$
declare
  c lead_gen_credits;
  v_action text := p ->> 'action';
  v_ref text := nullif(left(btrim(coalesce(p ->> 'reference', '')), 120), '');
  v_note text := nullif(left(btrim(coalesce(p ->> 'note', '')), 500), '');
begin
  perform app.assert_admin(p_by);
  select * into c from lead_gen_credits where id = nullif(p ->> 'credit', '')::uuid for update;
  if c.id is null then raise exception 'Credit not found' using errcode = 'P0002'; end if;
  -- an Admin never decides a credit of their own lead
  if c.staff_id = p_by or exists (select 1 from leads l where l.id = c.lead_id and l.generated_by = p_by) then
    raise exception 'This credit is yours: another Admin decides it' using errcode = '42501';
  end if;
  if v_action = 'approve' then
    if c.status <> 'pending_approval' then raise exception 'This credit is %', replace(c.status, '_', ' ') using errcode = '23514'; end if;
    update lead_gen_credits set status = 'approved', decided_by = p_by, decided_at = now(), note = coalesce(v_note, note) where id = c.id;
  elsif v_action = 'void' then
    if c.status = 'paid' then raise exception 'A paid credit is not voided' using errcode = '23514'; end if;
    if v_note is null then raise exception 'Say why it is voided' using errcode = '22023'; end if;
    update lead_gen_credits set status = 'void', decided_by = p_by, decided_at = now(), note = v_note where id = c.id;
  elsif v_action = 'paid' then
    if c.status <> 'approved' then raise exception 'Approve the credit before marking it paid' using errcode = '23514'; end if;
    if v_ref is null then raise exception 'Give the payment reference' using errcode = '22023'; end if;
    update lead_gen_credits set status = 'paid', paid_at = now(), paid_reference = v_ref, note = coalesce(v_note, note) where id = c.id;
  else
    raise exception 'Choose approve, void or paid' using errcode = '22023';
  end if;
  insert into audit_log (actor_user_id, action, entity_table, entity_id, before, after)
  values (p_by, 'lead_gen_credit_' || v_action, 'lead_gen_credits', c.id::text, to_jsonb(c), (select to_jsonb(x) from lead_gen_credits x where x.id = c.id));
  return jsonb_build_object('ok', true, 'credit', c.id, 'status', (select status from lead_gen_credits where id = c.id));
end $$;

-- ================================================================ 5. lead generators find, closers call
alter function app.lead_claim(uuid, jsonb) rename to lead_claim_pre5134;
create function app.lead_claim(p_by uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app, pg_temp as $$
begin
  if app.is_lead_generator(p_by) and not app.user_is_admin(p_by) then
    raise exception 'Lead generators find owners; the closers call them. Add the owners you find on My owner leads.' using errcode = '42501';
  end if;
  return app.lead_claim_pre5134(p_by, p);
end $$;
select pg_temp.copy_grants('app.lead_claim(uuid, jsonb)'::regprocedure, 'app.lead_claim_pre5134(uuid, jsonb)'::regprocedure);

alter function app.lead_next(uuid, jsonb) rename to lead_next_pre5134;
create function app.lead_next(p_by uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app, pg_temp as $$
begin
  if app.is_lead_generator(p_by) and not app.user_is_admin(p_by) then
    raise exception 'Lead generators find owners; the closers call them. Add the owners you find on My owner leads.' using errcode = '42501';
  end if;
  return app.lead_next_pre5134(p_by, p);
end $$;
select pg_temp.copy_grants('app.lead_next(uuid, jsonb)'::regprocedure, 'app.lead_next_pre5134(uuid, jsonb)'::regprocedure);

alter function app.door(uuid, text, text, text, jsonb) rename to door_pre5134;
create function app.door(p_user uuid, p_aal text, p_call text, p_name text, p jsonb default '{}'::jsonb) returns jsonb
language plpgsql security definer set search_path = public, app, pg_temp as $$
declare p_ jsonb := coalesce(p, '{}'::jsonb) - '_va';
begin
  if (p_call in ('va_read', 'ops_read') and p_name = 'my_owner_leads') or (p_call in ('va_do', 'ops_do') and p_name = 'owner_lead_add')
     or (p_call = 'admin_read' and p_name = 'lead_generators') or (p_call = 'admin_do' and p_name in ('lead_gen_set', 'lead_gen_credit', 'owner_lead_add')) then
    perform app.door_begin(p_user, p_aal);
    return case p_name
      when 'my_owner_leads' then app.my_owner_leads(p_user)
      when 'owner_lead_add' then app.owner_lead_add(p_user, p_)
      when 'lead_generators' then app.lead_generators_admin(p_user)
      when 'lead_gen_set' then app.lead_gen_set(p_user, p_)
      else app.lead_gen_credit_do(p_user, p_) end;
  end if;
  return app.door_pre5134(p_user, p_aal, p_call, p_name, p);
end $$;
select pg_temp.copy_grants('app.door(uuid, text, text, text, jsonb)'::regprocedure, 'app.door_pre5134(uuid, text, text, text, jsonb)'::regprocedure);

revoke all on function app.is_lead_generator(uuid), app.lead_gen_stage_words(leads), app.lead_closer(uuid), app.owner_lead_add(uuid, jsonb),
  app.lead_gen_credit_check(uuid), app.lead_gen_lead_trg(), app.lead_gen_agreement_trg(), app.my_owner_leads(uuid),
  app.lead_generators_admin(uuid), app.lead_gen_set(uuid, jsonb), app.lead_gen_credit_do(uuid, jsonb) from public, anon, authenticated;
grant execute on function app.is_lead_generator(uuid), app.lead_gen_stage_words(leads), app.lead_closer(uuid), app.owner_lead_add(uuid, jsonb),
  app.lead_gen_credit_check(uuid), app.lead_gen_lead_trg(), app.lead_gen_agreement_trg(), app.my_owner_leads(uuid),
  app.lead_generators_admin(uuid), app.lead_gen_set(uuid, jsonb), app.lead_gen_credit_do(uuid, jsonb) to service_role;
