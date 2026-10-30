-- 0210: Admin adds an investor record (Release 21b, extra item). SCHEMA_MARKER 0210. docs/changes/2026-11-01-add-an-investor.md.
--   Admin > Investors, Add an investor: the legal name, individual or corporation (with the person who signs for it), email,
--   phone, address, and optionally the amount committed and the yearly percentage offered (the investor offer's, 30% by
--   default: deck_settings.deck_return_bps). "Invite now" (on by default) then sends the invitation through the existing invite
--   path (inviteAccount, investor_id), which links the sign-in to this record.
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

alter table investors add column if not exists signatory_name text check (signatory_name is null or length(btrim(signatory_name)) between 2 and 120);
alter table investors add column if not exists committed_amount_cents bigint check (committed_amount_cents is null or committed_amount_cents > 0);
alter table investors add column if not exists offered_yearly_bps integer check (offered_yearly_bps is null or offered_yearly_bps between 1 and 10000);
comment on column investors.signatory_name is 'A corporation''s signing officer (0210): who signs its investment agreement.';
comment on column investors.committed_amount_cents is 'The amount the investor said they will invest (0210), before any agreement; optional.';
comment on column investors.offered_yearly_bps is 'The Yearly Percentage offered (0210), from the investor offer (deck_settings.deck_return_bps) unless typed; the agreement sets the one that applies.';

create function app.investor_create(p_admin uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  v_name text := btrim(coalesce(p ->> 'legal_name', ''));
  v_type text := coalesce(nullif(p ->> 'investor_type', ''), 'individual');
  v_email text := lower(btrim(coalesce(p ->> 'email', '')));
  v_sign text := nullif(btrim(coalesce(p ->> 'signatory_name', '')), '');
  v_bps int := coalesce(nullif(p ->> 'offered_yearly_bps', '')::int, (select deck_return_bps from deck_settings limit 1), 3000);
  v_id uuid;
begin
  if not app.user_is_admin(p_admin) then raise exception 'Admins only' using errcode = '42501'; end if;
  if length(v_name) < 2 then raise exception 'Enter the legal name' using errcode = '22023'; end if;
  if v_type not in ('individual', 'corporation') then raise exception 'Choose individual or corporation' using errcode = '22023'; end if;
  if v_type = 'corporation' and v_sign is null then raise exception 'Enter the name of the person who signs for the corporation' using errcode = '22023'; end if;
  if v_email !~ '^[^@\s]+@[^@\s]+\.[^@\s]+$' then raise exception 'Enter an email address' using errcode = '22023'; end if;
  if exists (select 1 from investors where lower(email) = v_email) then raise exception 'An investor with this email is already on file' using errcode = '23505'; end if;
  if v_bps < 1 or v_bps > 10000 then raise exception 'The yearly percentage is between 0.01%% and 100%%' using errcode = '22023'; end if;
  insert into investors (legal_name, investor_type, email, phone, address, signatory_name, committed_amount_cents, offered_yearly_bps)
    values (v_name, v_type, v_email, nullif(btrim(coalesce(p ->> 'phone', '')), ''), nullif(btrim(coalesce(p ->> 'address', '')), ''),
            case when v_type = 'corporation' then v_sign end, nullif(p ->> 'committed_amount_cents', '')::bigint, v_bps)
    returning id into v_id;
  return jsonb_build_object('id', v_id, 'email', v_email, 'legal_name', v_name, 'offered_yearly_bps', v_bps);
end $$;

alter function app.door(uuid, text, text, text, jsonb) rename to door_pre0210;
create function app.door(p_user uuid, p_aal text, p_call text, p_name text, p jsonb default '{}'::jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
begin
  if p_call = 'admin_do' and p_name = 'investor_create' then
    perform app.door_begin(p_user, p_aal);
    return app.investor_create(p_user, coalesce(p, '{}'::jsonb) - '_va');
  end if;
  return app.door_pre0210(p_user, p_aal, p_call, p_name, p);
end $$;
select pg_temp.copy_grants('app.door(uuid, text, text, text, jsonb)'::regprocedure, 'app.door_pre0210(uuid, text, text, text, jsonb)'::regprocedure);

do $$
declare f record;
begin
  for f in select p.oid::regprocedure as sig from pg_proc p join pg_namespace n on n.oid = p.pronamespace
            where n.nspname = 'app' and p.proname in ('investor_create', 'door_pre0210') loop
    execute format('revoke all on function %s from public, anon, authenticated', f.sig);
    execute format('grant execute on function %s to service_role', f.sig);
  end loop;
end $$;
