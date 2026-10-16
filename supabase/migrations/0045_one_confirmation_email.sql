-- 0045_one_confirmation_email.sql
-- One confirmation email per sign-up, with a link that confirms.
--
-- What happened (October 16, 2026): an owner who applied from List your car got four emails: Supabase Auth's
-- "Confirm your CarmaCars account" (the only real link), and two emails of the app, "Confirm your email to finish
-- your CarmaCars account" (renter_account_created) and "Confirm your email to open your CarmaCars owner account"
-- (owner_account_created), whose "Confirm my email" button opened the sign-in page, plus "We have your application".
-- 0023's trigger on user_roles emitted an account email for every renter or owner role granted (sign-up, the owner
-- application, a guest's booking request, an Admin's invitation), and no one ever supplied the confirmation link the
-- templates expected: the sender filled it with the sign-in page. Signing in then failed, because the address was
-- not confirmed.
--
-- Now:
--   1. Supabase Auth's confirmation email is the only email that asks to confirm (its link: /auth/callback with the
--      token hash; the callback sends the person to their portal by role).
--   2. renter_account_created and owner_account_created are welcome emails ("Your CarmaCars account is ready"), with no
--      confirm button, emitted once when the address is first confirmed (users.email_verified_at set by
--      app.account_email_verified, 0040: the confirmation link, an invitation or a password link, a sign-in). An owner
--      gets the owner welcome; a renter with no other portal gets the renter welcome; staff, Admins and investors none.
--   3. Granting a role emits nothing (0023's user_roles trigger is dropped). Account emails of the old kind still
--      waiting to be sent are skipped.
--   4. Accounts Supabase Auth has already confirmed get users.email_verified_at now (where auth.users is present), so
--      no one who already has a working account gets a welcome late.
--   5. The live verification's sign-up checks: throwaway accounts at verify-signup-<path>-<n>@carmacars.ca, made as each
--      sign-up path makes them, on the email suppression list (nothing is sent), and removed again.
-- No earlier migration is edited.
set local check_function_bodies = off;

-- ================================================================ 1. no account email when a role is granted
drop trigger if exists user_roles_notify on user_roles;

-- Old-style account emails not sent yet (their button did not confirm anything): skipped, and their events closed.
update notification_outbox
   set status = 'skipped', status_reason = '0045: the confirmation comes from the sign-in service; the welcome follows it'
 where code in ('renter_account_created', 'owner_account_created') and status in ('queued', 'delayed')
   and dedupe_key like '%:created';
update app_events
   set processed_at = now(), process_note = '0045: replaced by the welcome sent after the email is confirmed'
 where processed_at is null and code in ('renter_account_created', 'owner_account_created') and dedupe_key like '%:created';

-- ================================================================ 2. accounts already confirmed
do $$
begin
  if to_regclass('auth.users') is not null
     and exists (select 1 from information_schema.columns where table_schema = 'auth' and table_name = 'users' and column_name = 'email_confirmed_at') then
    execute $q$
      update public.users u set email_verified_at = a.email_confirmed_at
        from auth.users a
       where a.id = u.id and a.email_confirmed_at is not null and u.email_verified_at is null
         and lower(btrim(a.email)) = lower(btrim(u.email))
    $q$;
  end if;
end $$;

-- ================================================================ 3. the welcome, once the address is confirmed
create or replace function app.ntf_users_confirmed_after() returns trigger
language plpgsql security definer set search_path = public, app as $$
declare
  v_owner uuid;
begin
  if old.email_verified_at is not null or new.email_verified_at is null then return null; end if;
  if exists (select 1 from user_roles r where r.user_id = new.id and r.role = 'owner') then
    v_owner := (select o.id from owners o where o.user_id = new.id order by o.created_at limit 1);
    perform app.ntf_emit('owner_account_created', 'user', new.id, 'confirmed',
                         jsonb_build_object('owner_id', v_owner, 'email', new.email, 'first_name', split_part(btrim(coalesce(new.full_name, '')), ' ', 1)));
  elsif exists (select 1 from user_roles r where r.user_id = new.id and r.role = 'renter')
        and not exists (select 1 from user_roles r where r.user_id = new.id and r.role <> 'renter')
        and not exists (select 1 from investors i where i.user_id = new.id) then
    perform app.ntf_emit('renter_account_created', 'user', new.id, 'confirmed',
                         jsonb_build_object('renter_id', (select r.id from renters r where r.user_id = new.id order by r.created_at limit 1)));
  end if;
  return null;
end $$;
create trigger users_confirmed_notify after update of email_verified_at on users
  for each row execute function app.ntf_users_confirmed_after();

-- ================================================================ 4. the catalogue
-- CATALOGUE 0045 START (generated by supabase/seed/0045_gen_catalogue.mjs; do not edit by hand)
insert into notification_catalogue (code, audience, also_sent_to, category, is_digest, digest_slot, from_address, reply_to,
    subject, preheader, timing, trigger_text, replaces_template, link_path, variables, template_html, template_text) values
  ('renter_account_created', 'renter', '{}'::text[], 'transactional', false, null, 'CarmaCars <hello@carmacars.ca>', 'contact@carmacars.ca', 'Your CarmaCars account is ready', 'Your email is confirmed. Request a car whenever you are ready.', 'Immediate', 'The person confirms their email address for the first time (the confirmation link from the sign-in service, or a password link for an address already on file from a booking request) and has the renter role only. Sent once per account. Accounts already confirmed before October 16, 2026 do not get it.', null, '/cars', '[{"name":"company_address","type":"string","global":true},{"name":"contact_email","type":"string","global":true},{"name":"first_name","type":"string"},{"name":"instagram_url","type":"url","global":true},{"name":"opening_hours","type":"string","global":true},{"name":"reply_time","type":"string","global":true},{"name":"support_phone","type":"string","global":true},{"name":"tiktok_url","type":"url","global":true}]'::jsonb, 'templates/renter_account_created.html', 'templates/renter_account_created.txt'),
  ('owner_account_created', 'owner', '{}'::text[], 'transactional', false, null, 'CarmaCars <owners@carmacars.ca>', 'owners@carmacars.ca', 'Your CarmaCars owner account is ready', 'Your email is confirmed. Your owner portal is open.', 'Immediate', 'The person confirms their email address for the first time (the confirmation link from the sign-in service, an invitation or a password link) and has the owner role. Sent once per account. Accounts already confirmed before October 16, 2026 do not get it.', null, '/owner', '[{"name":"company_address","type":"string","global":true},{"name":"contact_email","type":"string","global":true},{"name":"first_name","type":"string"},{"name":"instagram_url","type":"url","global":true},{"name":"opening_hours","type":"string","global":true},{"name":"reply_time","type":"string","global":true},{"name":"support_phone","type":"string","global":true},{"name":"tiktok_url","type":"url","global":true}]'::jsonb, 'templates/owner_account_created.html', 'templates/owner_account_created.txt')
on conflict (code) do update set
  audience = excluded.audience, also_sent_to = excluded.also_sent_to, category = excluded.category,
  is_digest = excluded.is_digest, digest_slot = excluded.digest_slot, from_address = excluded.from_address,
  reply_to = excluded.reply_to, subject = excluded.subject, preheader = excluded.preheader, timing = excluded.timing,
  trigger_text = excluded.trigger_text, replaces_template = excluded.replaces_template, link_path = excluded.link_path,
  variables = excluded.variables, template_html = excluded.template_html, template_text = excluded.template_text,
  in_catalogue = true, updated_at = now();
select app.notification_catalogue_refresh();
-- CATALOGUE 0045 END
update notification_catalogue set emitted_by = 'users_confirmed_notify (0045)' where code in ('renter_account_created', 'owner_account_created');

-- ================================================================ 5. the live verification's sign-up checks
-- Throwaway addresses only: verify-signup-<renter|owner|guest>-<digits>@carmacars.ca. Each is put on the email
-- suppression list before anything is made, so no email is ever sent to it.
create or replace function app.verify_signup_address(p_email text) returns text
language plpgsql immutable as $$
declare
  v text := lower(btrim(coalesce(p_email, '')));
begin
  if v !~ '^verify-signup-(renter|owner|guest)-[0-9]{6,20}@carmacars\.ca$' then
    raise exception 'Not a sign-up verification address: %', p_email using errcode = '22023';
  end if;
  return v;
end $$;

-- Makes the records a sign-up path makes, as the site's server does after Supabase Auth has made the sign-in:
--   renter  the create-account form: register_account (the users row and the renter role)
--   owner   the owner application: register_account, then the owner record and the owner role, as
--           app.submit_owner_application does (no vehicle, so no application email and no staff notice)
--   guest   a booking request from someone with no account: a users row, the renter role and the renter record, with no
--           sign-in (p user_id is ignored; the id is returned), as app.submit_booking_request does
create or replace function app.verify_signup(p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  v_email text := app.verify_signup_address(p ->> 'email');
  v_path text := split_part(v_email, '-', 3);
  v_name text := coalesce(nullif(btrim(p ->> 'name'), ''), 'Verify Signup');
  v_user uuid := (p ->> 'user_id')::uuid;
  v_reg jsonb;
begin
  insert into email_suppressions (email, scope, reason, detail)
  select v_email, 'all', 'manual', 'Deploy verification sign-up: no email is sent'
   where not exists (select 1 from email_suppressions s where s.email = v_email and s.scope = 'all' and s.lifted_at is null);
  if v_path = 'guest' then
    v_user := gen_random_uuid();
    insert into users (id, email, full_name) values (v_user, v_email, v_name);
    insert into user_roles (user_id, role) values (v_user, 'renter') on conflict do nothing;
    insert into renters (user_id, legal_name, email) values (v_user, v_name, v_email);
    return jsonb_build_object('ok', true, 'user_id', v_user, 'path', v_path);
  end if;
  if v_user is null then raise exception 'The sign-in account id is needed' using errcode = '22023'; end if;
  v_reg := app.register_account(v_user, v_email, v_name, null);
  if not coalesce((v_reg ->> 'ok')::boolean, false) then return v_reg; end if;
  if v_path = 'owner' then
    insert into owners (user_id, owner_type, legal_name, email, status) values (v_user, 'individual', v_name, v_email, 'lead');
    insert into user_roles (user_id, role) values (v_user, 'owner') on conflict do nothing;
  end if;
  return jsonb_build_object('ok', true, 'user_id', v_user, 'path', v_path);
end $$;

-- The emails the platform has decided to send to a verification account (events: every email starts as one; the
-- outbox row's status where the sender has picked it up, suppressed for these addresses).
create or replace function app.verify_signup_emails(p_user uuid) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare
  u users;
begin
  select * into u from users where id = p_user;
  if u.id is null then return '[]'::jsonb; end if;
  perform app.verify_signup_address(u.email);
  return coalesce((select jsonb_agg(jsonb_build_object('code', e.code, 'key', split_part(e.dedupe_key, ':', 3),
                                                       'outbox', (select o.status from notification_outbox o where o.event_id = e.id limit 1)) order by e.id)
                     from app_events e
                    where e.entity_id = p_user or e.payload ->> 'renter_id' = (select r.id::text from renters r where r.user_id = p_user limit 1)),
                  '[]'::jsonb);
end $$;

-- Removes what a sign-up check made (the sign-in itself is removed by the check through the Auth admin API).
create or replace function app.verify_signup_cleanup(p_user uuid) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  u users;
  v_events bigint[];
begin
  select * into u from users where id = p_user;
  if u.id is null then return jsonb_build_object('ok', true, 'removed', false); end if;
  perform app.verify_signup_address(u.email);
  v_events := array(select e.id from app_events e where e.entity_id = p_user);
  delete from notification_outbox where recipient_user_id = p_user or event_id = any (v_events) or lower(to_address) = u.email;
  delete from notifications where user_id = p_user;
  delete from account_links where user_id = p_user;
  delete from app_events where id = any (v_events);
  delete from owners where user_id = p_user;
  delete from renters where user_id = p_user;
  delete from user_roles where user_id = p_user;
  begin
    delete from users where id = p_user;
    return jsonb_build_object('ok', true, 'removed', true);
  exception when foreign_key_violation then
    update users set status = 'closed' where id = p_user;
    return jsonb_build_object('ok', true, 'removed', false, 'note', sqlerrm);
  end;
end $$;

create or replace function public.server_verify_signup(p jsonb) returns jsonb
language sql volatile security invoker set search_path = public, app as $$ select app.verify_signup(p) $$;
create or replace function public.server_verify_signup_emails(p_user uuid) returns jsonb
language sql stable security invoker set search_path = public, app as $$ select app.verify_signup_emails(p_user) $$;
create or replace function public.server_verify_signup_cleanup(p_user uuid) returns jsonb
language sql volatile security invoker set search_path = public, app as $$ select app.verify_signup_cleanup(p_user) $$;

-- ================================================================ privileges
do $$
declare
  f record;
begin
  for f in
    select p.oid::regprocedure as sig from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where (n.nspname = 'app' and p.proname = any (array['ntf_users_confirmed_after', 'verify_signup_address', 'verify_signup', 'verify_signup_emails', 'verify_signup_cleanup']))
        or (n.nspname = 'public' and p.proname = any (array['server_verify_signup', 'server_verify_signup_emails', 'server_verify_signup_cleanup']))
  loop
    execute format('revoke all on function %s from public, anon, authenticated', f.sig);
    execute format('grant execute on function %s to service_role', f.sig);
  end loop;
end $$;
