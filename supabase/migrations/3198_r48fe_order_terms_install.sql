-- 3198 (release 48, part FE; docs/changes/2026-11-20-r48-fees-evidence-hiring.md): the owner's onboarding order, the updated
-- documents to accept, and the tracker install fee.
--
-- 1. Onboarding order: the staff agreement is signed BEFORE the academy: agreement, academy, WhatsApp, approval.
--    app.agreement_locked no longer waits for the academy; app.staff_onboarding_state puts the agreement step first;
--    app.staff_waiting_on lists the signature first; app.staff_welcome shows the agreement step before the academy (the
--    academy step says it opens once the agreement is signed). Staff who passed the academy and have not signed are only
--    asked to sign. The portal side (web/src/server/door.ts requireStaff) holds an unsigned person on Welcome, the sign
--    pages, Documents and the profile.
-- 2. The updated documents are published to accept (0721's "We've updated our terms"): the rental agreement (10.6 to 10.8,
--    11.6), the owner program agreement (9.3 owner use for someone else, the $150 Install Fee) and the staff agreements
--    (confidentiality, non-solicitation, return or deletion of data, a non-compete for contractors only: FOR LAWYER
--    REVIEW). Accepting records the version, the time, the IP address and the device (terms_acceptances, audit_log); a
--    decline is recorded too (terms_declines) and the portal stays closed with a way to contact us. Admin > Settings >
--    Terms shows each version's acceptances and declines.
-- 3. The tracker install fee is $150 (was $100): Program settings install_fee_cents and tracker_product_install_cents, the
--    defaults of new owner terms and Vehicle Schedules. Signed Vehicle Schedules keep theirs.
-- No applied migration is edited: app.agreement_locked and app.staff_waiting_on are replaced (one body each);
-- app.staff_onboarding_state, app.staff_welcome and app.terms_versions_admin are wrapped (_pre3198).
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

-- ================================================================ 1. agreement, academy, WhatsApp, approval
create or replace function app.agreement_locked(p_user uuid) returns boolean
language sql stable security definer set search_path = public, app as $$
  select coalesce((app.settings()).staff_agreement_gate, false) and app.staff_is_member(p_user)
     and not app.staff_agreement_signed(p_user)
     and exists (select 1 from staff_profiles sp where sp.user_id = p_user and sp.agreement_waived_at is null
                  and coalesce(sp.agreement_lock_from, '-infinity'::timestamptz) <= now())
$$;

alter function app.staff_onboarding_state(uuid) rename to staff_onboarding_state_pre3198;
create function app.staff_onboarding_state(p_user uuid) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare v jsonb := app.staff_onboarding_state_pre3198(p_user);
begin
  if not coalesce((v ->> 'member')::boolean, false) then return v; end if;
  if v ->> 'step' in ('academy', 'agreement') then
    v := v || jsonb_build_object('step', case when not coalesce((v ->> 'agreement')::boolean, true) then 'agreement' else 'academy' end);
  end if;
  return v || jsonb_build_object('order', '["agreement", "academy", "whatsapp", "approval"]'::jsonb);
end $$;
select pg_temp.copy_grants('app.staff_onboarding_state(uuid)'::regprocedure, 'app.staff_onboarding_state_pre3198(uuid)'::regprocedure);

create or replace function app.staff_waiting_on(p_user uuid, p_state jsonb) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare
  w text[] := '{}';
  c jsonb;
  g text;
  v_req text[] := coalesce((select array_agg(x) from jsonb_array_elements_text(p_state -> 'required') x), '{}');
  v_joined text[] := coalesce((select array_agg(x) from jsonb_array_elements_text(p_state -> 'joined') x), '{}');
begin
  if not coalesce((p_state ->> 'member')::boolean, false) or coalesce((p_state ->> 'exempt')::boolean, false) or coalesce((p_state ->> 'done')::boolean, false) then
    return '[]'::jsonb;
  end if;
  -- 3198: the agreement first, then the academy
  if not coalesce((p_state ->> 'agreement')::boolean, false) then w := w || 'Staff agreement signature'::text; end if;
  if not coalesce((p_state ->> 'academy')::boolean, false) then
    c := app.staff_academy_count(p_user);
    w := w || case when (c ->> 'total')::int > 0 then format('Academy (%s of %s sections)', c ->> 'passed', c ->> 'total') else 'Academy' end;
  end if;
  foreach g in array v_req loop
    if not (g = any (v_joined)) then
      w := w || format('WhatsApp %s group confirmation', case g when 'sales' then 'CARMA Closers' else 'CarmaCars Team' end);
    end if;
  end loop;
  if coalesce(p_state ->> 'step', '') = 'approval' then
    w := w || case when p_state ->> 'reject_reason' is not null then format('Asking again after the rejection (%s)', p_state ->> 'reject_reason')
                   else 'Approval by an Admin or a Fleet VA' end;
  end if;
  return to_jsonb(w);
end $$;

alter function app.staff_welcome(uuid) rename to staff_welcome_pre3198;
create function app.staff_welcome(p_user uuid) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare
  v jsonb := app.staff_welcome_pre3198(p_user);
  v_signed boolean;
  v_steps jsonb;
begin
  if jsonb_typeof(v -> 'steps') <> 'array' then return v; end if;
  v_signed := coalesce((select (x ->> 'done')::boolean from jsonb_array_elements(v -> 'steps') x where x ->> 'key' = 'agreement'), true);
  -- the agreement step moves before the academy; the academy opens once it is signed
  select jsonb_agg(x order by case x ->> 'key' when 'welcome' then 0 when 'profile' then 1 when 'agreement' then 2 when 'academy' then 3 else 4 end, n)
    into v_steps
    from (select case when y ->> 'key' = 'agreement' then y || '{"waiting_for_academy": false}'::jsonb
                      when y ->> 'key' = 'academy' then y || jsonb_build_object('waiting_for_agreement', not v_signed)
                      else y end x, n
            from jsonb_array_elements(v -> 'steps') with ordinality t(y, n)) z;
  return v || jsonb_build_object('steps', v_steps, 'order', '["agreement", "academy", "whatsapp", "approval"]'::jsonb);
end $$;
select pg_temp.copy_grants('app.staff_welcome(uuid)'::regprocedure, 'app.staff_welcome_pre3198(uuid)'::regprocedure);

-- ================================================================ 2. the updated documents to accept
create table if not exists terms_declines (
  id          uuid primary key default gen_random_uuid(),
  version_id  uuid not null references terms_versions (id),
  user_id     uuid not null references users (id),
  declined_at timestamptz not null default now(),
  ip_address  inet,
  user_agent  text,
  reason      text check (char_length(reason) <= 1000)
);
create index if not exists terms_declines_user on terms_declines (user_id, declined_at desc);
comment on table terms_declines is 'A person who declined an updated document (3198): the portal stays closed (the terms step offers to contact us) until they accept.';
alter table terms_declines enable row level security;
revoke all on terms_declines from anon, authenticated;
grant select, insert on terms_declines to service_role;
create policy admin_all on terms_declines for select to authenticated using (app.is_admin());
create trigger audit_terms_declines after insert or update or delete on terms_declines for each row execute function app.audit_row();

create function app.terms_decline(p_user uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare v terms_versions;
begin
  if p_user is null then raise exception 'Sign in first' using errcode = '42501'; end if;
  select * into v from terms_versions where id = nullif(p ->> 'version_id', '')::uuid;
  if v.id is null then raise exception 'Not found' using errcode = 'P0002'; end if;
  insert into terms_declines (version_id, user_id, ip_address, user_agent, reason)
  values (v.id, p_user, nullif(p ->> 'ip', '')::inet, left(nullif(p ->> 'user_agent', ''), 500), left(nullif(btrim(coalesce(p ->> 'reason', '')), ''), 1000));
  insert into audit_log (actor_user_id, action, entity_table, entity_id, after)
  values (p_user, 'terms_declined', 'terms_versions', v.id::text, jsonb_build_object('doc_key', v.doc_key, 'version', v.version, 'ip', p ->> 'ip'));
  return jsonb_build_object('declined', true, 'contact', (select jsonb_build_object('email', s.public_email, 'phone', s.phone_display) from site_settings s where s.singleton));
end $$;
create function public.server_terms_decline(p_by uuid, p jsonb) returns jsonb
language sql security definer set search_path = public, app as $$ select app.terms_decline(p_by, p) $$;

alter function app.terms_versions_admin(uuid, jsonb) rename to terms_versions_admin_pre3198;
create function app.terms_versions_admin(p_by uuid, p jsonb default '{}'::jsonb) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare v jsonb := app.terms_versions_admin_pre3198(p_by, p);
begin
  return v || jsonb_build_object('versions', coalesce((select jsonb_agg(x || jsonb_build_object(
      'declined', (select count(distinct d.user_id) from terms_declines d where d.version_id = (x ->> 'id')::uuid
                    and not exists (select 1 from terms_acceptances a where a.version_id = d.version_id and a.user_id = d.user_id)),
      'waiting', (select count(*) from users u where u.created_at < (x ->> 'published_at')::timestamptz and app.terms_binds(u.id, x ->> 'doc_key')
                    and not exists (select 1 from terms_acceptances a where a.version_id = (x ->> 'id')::uuid and a.user_id = u.id))) order by o)
    from jsonb_array_elements(v -> 'versions') with ordinality t(x, o)), '[]'::jsonb));
end $$;
select pg_temp.copy_grants('app.terms_versions_admin(uuid, jsonb)'::regprocedure, 'app.terms_versions_admin_pre3198(uuid, jsonb)'::regprocedure);

-- the versions of this release (the full texts are on the site's agreement pages; the summary is what the pop-up shows)
insert into terms_versions (doc_key, version, title, summary, body, body_sha256, requires_acceptance, published_by)
select x.doc_key, x.version, x.title, x.summary, x.body, encode(sha256(convert_to(x.body, 'UTF8')), 'hex'), true, app.system_admin()
  from (values
  ('rental_agreement', 'rental-v3-r48fe', 'Rental agreement',
   'New charges with their evidence: non-return (not back by the final late notice deadline), improper return, theft recovery, and flat tires, blowouts and roadside call-outs at cost plus $50 (not for a mechanical fault that is not yours). Roadside assistance stays included.',
   E'10.6 Non-return. If the Vehicle is not back by the deadline in our final late return notice, you owe the non-return charge in the Fee Schedule ($1,000) and the actual costs of recovering the Vehicle: towing, impound, storage, an investigator or a repossession agent. The rental charge at the booking''s daily rate, the per-day fees and the late return fee keep adding up until the Vehicle is recovered.\n\n10.7 Improper return. If the Vehicle is left somewhere else than agreed, the keys are not returned, it is left unlocked or unsecured, or it is dropped off in a way we did not agree to, you owe the improper return charge ($250) plus the actual costs.\n\n10.8 Theft recovery. If the Vehicle is stolen during the Rental Period, or is recovered by the police or a repossession, you owe the theft recovery charge ($1,500) plus the actual costs. The Damage and deductible rules still apply.\n\n11.6 Tires and roadside call-outs. Access to our 24-hour roadside line is included. The cost of a flat tire, a tire blowout or damage to a tire, and of a roadside call-out (a tow, a boost, a lockout or a fuel delivery), is yours: the actual cost plus the $50 tire and roadside administration fee. This does not apply to a mechanical fault that is not yours.\n\nEvery charge is billed with its evidence (Tracker readings, notices, photos, receipts), plus HST.'),
  ('owner_agreement', 'owner-v3-r48fe', 'Owner program agreement',
   'You can book your car for a family member or friend (they are the main driver and sign the rental agreement); you stay responsible for the deductible and any damage, tickets, tolls and fees during it. The tracker Install Fee is $150 for new cars (a car already enrolled keeps its signed amount).',
   E'9.3 An Owner Booking may be for the Owner or for a family member or friend the Owner names, who is then the main driver: they sign the Rental Agreement and must meet its driver rules (an Ontario licence for the main driver). The Owner stays responsible for every Owner Booking, whoever drives: the Deductible ($2,500 unless the Fleet Policy sets another amount) and any Damage, tickets, tolls and fees during it are billed to the Owner, each with its evidence.\n\nFee Schedule: Install Fee, $150 per Vehicle (from November 20, 2026; a Vehicle Schedule already signed keeps its amount).'),
  ('staff_agreement', 'staff-r48fe', 'Staff agreement',
   'Confidentiality now covers customer data, pricing, owners, suppliers, our systems and business methods; no soliciting customers, owners or staff for 12 months after you leave; data returned or deleted when you leave; and, for contractors only, no competing car rental or owner-program business in the GTA for 12 months. Employees (hourly field staff) have no non-compete.',
   E'Confidentiality. Everything not public that you learn through your work is confidential: customer and owner data and lists, pricing, Procedures, supplier and insurance terms, CarmaCars'' systems, software, data and accounts, and its business methods. You use it only for your work and disclose it to no one, during and after your work with us.\n\nNon-solicitation. While you work with us and for 12 months after, you do not solicit any customer or owner you dealt with to rent or list a vehicle elsewhere, or any staff member or contractor to leave CarmaCars.\n\nData on exit. Within 7 days of the end you return or permanently delete every copy of confidential information and personal data on any device or account you control, and confirm it in writing.\n\nNon-competition (contractors only). While a contractor agreement runs and for 12 months after it ends, the contractor does not work for, own or help a car rental or owner-program business in the Greater Toronto Area in competition with CarmaCars. It does not apply to employees: Ontario''s Employment Standards Act does not allow a non-compete for an employee.')
  ) x(doc_key, version, title, summary, body)
on conflict (doc_key, version) do nothing;

-- ================================================================ 3. the tracker install fee: $150
update program_settings set install_fee_cents = 15000 where id = (app.settings()).id and install_fee_cents = 10000;
update program_settings set tracker_product_install_cents = 15000 where id = (app.settings()).id;
alter table program_settings alter column install_fee_cents set default 15000;
alter table owner_terms alter column install_fee_cents set default 15000;
alter table vehicle_schedules alter column install_fee_cents set default 15000;
comment on column program_settings.tracker_product_install_cents is 'The tracker install fee shown on the owner pages and the Owner Program (3198: $150).';

revoke all on function app.staff_onboarding_state_pre3198(uuid), app.staff_welcome_pre3198(uuid), app.terms_decline(uuid, jsonb), public.server_terms_decline(uuid, jsonb),
  app.terms_versions_admin_pre3198(uuid, jsonb) from public, anon, authenticated;
grant execute on function app.staff_onboarding_state_pre3198(uuid), app.staff_welcome_pre3198(uuid), app.terms_decline(uuid, jsonb), public.server_terms_decline(uuid, jsonb),
  app.terms_versions_admin_pre3198(uuid, jsonb) to service_role;
