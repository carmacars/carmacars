-- 0721: forced acceptance of updated terms (Release 33, part F). Record: docs/changes/2026-11-07-r33-signatures-terms.md.
--
-- The owner, November 7, 2026: when the site's terms of use or privacy policy, or an agreement template a person is
-- bound by, gets a new version, that person accepts it before using their portal: a full-screen "We've updated our
-- terms" step on their next sign-in with a short summary of what changed and the new text, and an Accept button
-- recorded with who, when, the IP address, the device and the version (the SHA-256 of the text shown). Renters,
-- owners, investors, staff and field. It does not void a signed agreement and no renter re-signs the rental agreement
-- of a past booking: it is a click-through acceptance of the new version. An Admin publishes a version with a
-- "Requires acceptance" switch and sees who accepted.
--
-- Who is asked (app.terms_audience_of): the terms of use and the privacy policy, every account with a portal other
-- than Admin; the owner program agreements, the owners of the standard routes; the fleet lease, the fleet suppliers;
-- the partner agreement, the partners; the investment agreement, the investors; the staff agreement, staff and field;
-- the rental agreement, the renters. Only people whose account was opened before the version was published are asked
-- (a newer account took that version when it signed up or signed). An Admin account is never asked (the Admins publish).
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

create table terms_versions (
  id                  uuid primary key default gen_random_uuid(),
  doc_key             text not null check (doc_key in ('terms', 'privacy', 'owner_agreement', 'fleet_lease', 'partner_agreement',
                                                       'investment_agreement', 'staff_agreement', 'rental_agreement')),
  version             text not null check (length(btrim(version)) between 1 and 40),
  title               text not null check (length(btrim(title)) between 3 and 160),
  summary             text not null check (length(btrim(summary)) between 10 and 2000),
  body                text not null check (length(btrim(body)) between 20 and 200000),
  body_sha256         text not null check (body_sha256 ~ '^[0-9a-f]{64}$'),
  requires_acceptance boolean not null default true,
  published_at        timestamptz not null default now(),
  published_by        uuid references users (id),
  unique (doc_key, version)
);
create index terms_versions_doc_idx on terms_versions (doc_key, published_at desc);
comment on table terms_versions is 'Published versions of the site terms, the privacy policy and the agreement templates (0721). With requires_acceptance, everyone bound by it accepts it before using their portal.';

create table terms_acceptances (
  id          uuid primary key default gen_random_uuid(),
  version_id  uuid not null references terms_versions (id),
  user_id     uuid not null references users (id),
  accepted_at timestamptz not null default now(),
  ip_address  inet,
  user_agent  text,
  body_sha256 text not null check (body_sha256 ~ '^[0-9a-f]{64}$'),
  portal      text check (portal in ('renter', 'owner', 'investor', 'staff', 'field')),
  unique (version_id, user_id)
);
create index terms_acceptances_user_idx on terms_acceptances (user_id);
comment on table terms_acceptances is 'Who accepted which published version (0721): the time, the IP address, the device and the SHA-256 of the text shown. Never edited or deleted.';

alter table terms_versions enable row level security;
alter table terms_acceptances enable row level security;
create policy admin_all on terms_versions for select to authenticated using (app.is_admin());
create policy admin_all on terms_acceptances for select to authenticated using (app.is_admin());
create trigger audit_terms_versions after insert or update or delete on terms_versions for each row execute function app.audit_row();
create trigger audit_terms_acceptances after insert or update or delete on terms_acceptances for each row execute function app.audit_row();
revoke all on terms_versions, terms_acceptances from public, anon, authenticated;
grant select, insert on terms_versions, terms_acceptances to service_role;

create function app.terms_acceptances_frozen() returns trigger
language plpgsql as $$
begin
  raise exception 'An acceptance is a record: it is never changed or deleted' using errcode = '42501';
end $$;
create trigger terms_acceptances_frozen before update or delete on terms_acceptances for each row execute function app.terms_acceptances_frozen();

-- Does this published document bind this person?
create function app.terms_binds(p_user uuid, p_doc text) returns boolean
language plpgsql stable security definer set search_path = public, app as $$
declare
  r jsonb := app.my_roles(p_user);
  v_owner owners;
  v_any boolean := coalesce((r ->> 'renter')::boolean, false) or coalesce((r ->> 'owner')::boolean, false) or coalesce((r ->> 'investor')::boolean, false)
                   or coalesce((r ->> 'field')::boolean, false) or nullif(r ->> 'va', '') is not null;
begin
  if coalesce((r ->> 'admin')::boolean, false) then return false; end if;
  if p_doc in ('terms', 'privacy') then return v_any; end if;
  if p_doc = 'rental_agreement' then return coalesce((r ->> 'renter')::boolean, false); end if;
  if p_doc = 'investment_agreement' then return coalesce((r ->> 'investor')::boolean, false); end if;
  if p_doc = 'staff_agreement' then return coalesce((r ->> 'field')::boolean, false) or nullif(r ->> 'va', '') is not null; end if;
  if not coalesce((r ->> 'owner')::boolean, false) then return false; end if;
  select * into v_owner from owners where id = app.portal_owner_id(p_user);
  if v_owner.id is null then return false; end if;
  if p_doc = 'fleet_lease' then return app.fleet_supplier(v_owner.id); end if;
  if p_doc = 'partner_agreement' then return v_owner.kind = 'partner'; end if;
  return p_doc = 'owner_agreement' and v_owner.kind is distinct from 'partner' and not app.fleet_supplier(v_owner.id);
end $$;

-- The versions this person still has to accept: the latest version of each document that requires acceptance, binds
-- them, was published after their account was opened, and is not accepted yet.
create function app.terms_pending(p_user uuid) returns jsonb
language sql stable security definer set search_path = public, app as $$
  with latest as (
    select distinct on (v.doc_key) v.* from terms_versions v order by v.doc_key, v.published_at desc, v.id
  )
  select coalesce(jsonb_agg(jsonb_build_object('id', l.id, 'doc_key', l.doc_key, 'version', l.version, 'title', l.title, 'summary', l.summary,
                                               'body', l.body, 'body_sha256', l.body_sha256, 'published_at', l.published_at)
                            order by case l.doc_key when 'terms' then 0 when 'privacy' then 1 else 2 end, l.published_at), '[]'::jsonb)
    from latest l join users u on u.id = p_user
   where l.requires_acceptance and l.published_at > u.created_at
     and not exists (select 1 from terms_acceptances a where a.version_id = l.id and a.user_id = p_user)
     and app.terms_binds(p_user, l.doc_key)
$$;

-- Accept: the version, the SHA-256 of the text shown (the same one), the IP address and the device.
create function app.terms_accept(p_user uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  v terms_versions;
  v_id uuid;
begin
  if p_user is null then raise exception 'Sign in first' using errcode = '42501'; end if;
  select * into v from terms_versions where id = nullif(p ->> 'version_id', '')::uuid;
  if v.id is null then raise exception 'Not found' using errcode = 'P0002'; end if;
  if not app.terms_binds(p_user, v.doc_key) then raise exception 'This version does not apply to your account' using errcode = '42501'; end if;
  if lower(coalesce(p ->> 'body_sha256', '')) <> v.body_sha256 then
    raise exception 'The text changed after the page was opened: reload and read the current version' using errcode = '23514';
  end if;
  insert into terms_acceptances (version_id, user_id, ip_address, user_agent, body_sha256, portal)
  values (v.id, p_user, nullif(p ->> 'ip', '')::inet, left(nullif(p ->> 'user_agent', ''), 500), v.body_sha256,
          case when p ->> 'portal' in ('renter', 'owner', 'investor', 'staff', 'field') then p ->> 'portal' end)
  on conflict (version_id, user_id) do nothing
  returning id into v_id;
  if v_id is not null then
    insert into audit_log (actor_user_id, action, entity_table, entity_id, after)
    values (p_user, 'terms_accepted', 'terms_versions', v.id::text, jsonb_build_object('doc_key', v.doc_key, 'version', v.version, 'sha256', v.body_sha256, 'ip', p ->> 'ip'));
  end if;
  return jsonb_build_object('accepted', true, 'pending', jsonb_array_length(app.terms_pending(p_user)));
end $$;

-- An Admin publishes a version. The terms of use and the privacy policy also replace the text the site shows
-- (site_content_blocks legal.terms / legal.privacy, and legal.meta's "last updated").
create function app.terms_publish(p_by uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  v_doc text := p ->> 'doc_key';
  v_body text := nullif(btrim(coalesce(p ->> 'body', '')), '');
  v_row terms_versions;
  v_block text;
begin
  perform app.assert_admin(p_by);
  if v_doc not in ('terms', 'privacy', 'owner_agreement', 'fleet_lease', 'partner_agreement', 'investment_agreement', 'staff_agreement', 'rental_agreement') then
    raise exception 'Choose the document' using errcode = '22023';
  end if;
  v_block := case v_doc when 'terms' then 'legal.terms' when 'privacy' then 'legal.privacy' end;
  -- the site's own text when none is given (the version records what the site shows now)
  if v_body is null and v_block is not null then select nullif(btrim(body), '') into v_body from site_content_blocks where block_key = v_block; end if;
  if v_body is null or length(v_body) < 20 then raise exception 'Paste the new text (at least a few sentences)' using errcode = '22023'; end if;
  if nullif(btrim(coalesce(p ->> 'summary', '')), '') is null or length(btrim(p ->> 'summary')) < 10 then
    raise exception 'Write a short summary of what changed (people read it first)' using errcode = '22023';
  end if;
  if nullif(btrim(coalesce(p ->> 'version', '')), '') is null then raise exception 'Give the version (for example 2026-11-07)' using errcode = '22023'; end if;
  if exists (select 1 from terms_versions where doc_key = v_doc and version = btrim(p ->> 'version')) then
    raise exception 'Version % of this document is published already: give the new version another name', btrim(p ->> 'version') using errcode = '23505';
  end if;
  insert into terms_versions (doc_key, version, title, summary, body, body_sha256, requires_acceptance, published_by)
  values (v_doc, btrim(p ->> 'version'), coalesce(nullif(btrim(coalesce(p ->> 'title', '')), ''), app.terms_doc_title(v_doc)), btrim(p ->> 'summary'), v_body,
          encode(sha256(convert_to(v_body, 'UTF8')), 'hex'), coalesce((p ->> 'requires_acceptance')::boolean, true), p_by)
  returning * into v_row;
  if v_block is not null then
    update site_content_blocks set body = v_body, updated_by = p_by, updated_at = now() where block_key = v_block and body is distinct from v_body;
    update site_content_blocks set data = data || jsonb_build_object('last_updated', to_char(app.today(), 'FMMonth FMDD, YYYY')), updated_by = p_by, updated_at = now()
     where block_key = 'legal.meta';
  end if;
  insert into audit_log (actor_user_id, action, entity_table, entity_id, after)
  values (p_by, 'terms_published', 'terms_versions', v_row.id::text, jsonb_build_object('doc_key', v_doc, 'version', v_row.version, 'requires_acceptance', v_row.requires_acceptance));
  return jsonb_build_object('id', v_row.id, 'version', v_row.version);
end $$;

create function app.terms_doc_title(p_doc text) returns text
language sql immutable as $$
  select case p_doc when 'terms' then 'Terms of use' when 'privacy' then 'Privacy policy' when 'owner_agreement' then 'Owner program agreements'
                    when 'fleet_lease' then 'Fleet Supplier Lease Agreement' when 'partner_agreement' then 'Partner agreement'
                    when 'investment_agreement' then 'Investment agreement' when 'staff_agreement' then 'Staff and contractor agreement'
                    when 'rental_agreement' then 'Rental agreement' else p_doc end
$$;

-- Admin > Updated terms: every version, how many accepted, and who (with when, the IP address and the portal).
create function app.terms_versions_admin(p_by uuid, p jsonb) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
begin
  perform app.assert_admin(p_by);
  return jsonb_build_object(
    'versions', coalesce((select jsonb_agg(jsonb_build_object('id', v.id, 'doc_key', v.doc_key, 'title', v.title, 'version', v.version, 'summary', v.summary,
        'requires_acceptance', v.requires_acceptance, 'published_at', v.published_at, 'published_by', (select u.full_name from users u where u.id = v.published_by),
        'accepted', (select count(*) from terms_acceptances a where a.version_id = v.id),
        'acceptances', case when v.id = nullif(p ->> 'version_id', '')::uuid then coalesce((
            select jsonb_agg(jsonb_build_object('name', coalesce(nullif(btrim(u.full_name), ''), u.email), 'email', u.email, 'accepted_at', a.accepted_at,
                                                'ip_address', host(a.ip_address), 'portal', a.portal) order by a.accepted_at desc)
              from terms_acceptances a join users u on u.id = a.user_id where a.version_id = v.id), '[]'::jsonb) end)
      order by v.published_at desc) from terms_versions v), '[]'::jsonb),
    'site', jsonb_build_object('terms', (select body from site_content_blocks where block_key = 'legal.terms'),
                               'privacy', (select body from site_content_blocks where block_key = 'legal.privacy')));
end $$;

create function public.server_terms_pending(p_by uuid) returns jsonb
language sql stable security invoker set search_path = public, app as $$ select app.terms_pending(p_by) $$;
create function public.server_terms_accept(p_by uuid, p jsonb) returns jsonb
language sql volatile security invoker set search_path = public, app as $$ select app.terms_accept(p_by, p) $$;

alter function app.door(uuid, text, text, text, jsonb) rename to door_pre0721;
create function app.door(p_user uuid, p_aal text, p_call text, p_name text, p jsonb default '{}'::jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
begin
  if (p_call = 'admin_do' and p_name = 'terms_publish') or (p_call = 'admin_read' and p_name = 'terms_versions') then
    perform app.door_begin(p_user, p_aal);
    if p_name = 'terms_publish' then return app.terms_publish(p_user, coalesce(p, '{}'::jsonb) - '_va'); end if;
    return app.terms_versions_admin(p_user, coalesce(p, '{}'::jsonb));
  end if;
  return app.door_pre0721(p_user, p_aal, p_call, p_name, p);
end $$;
select pg_temp.copy_grants('app.door(uuid, text, text, text, jsonb)'::regprocedure, 'app.door_pre0721(uuid, text, text, text, jsonb)'::regprocedure);

do $$
declare
  f record;
begin
  for f in
    select p.oid::regprocedure as sig from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where (n.nspname = 'app' and p.proname = any (array['terms_acceptances_frozen', 'terms_binds', 'terms_pending', 'terms_accept', 'terms_publish',
              'terms_doc_title', 'terms_versions_admin', 'door_pre0721']))
        or (n.nspname = 'public' and p.proname = any (array['server_terms_pending', 'server_terms_accept']))
  loop
    execute format('revoke all on function %s from public, anon, authenticated', f.sig);
    execute format('grant execute on function %s to service_role', f.sig);
  end loop;
end $$;
