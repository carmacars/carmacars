-- 4300 (release 50; docs/changes/2026-11-24-r50-investor-library.md): the investor Documents library.
--
-- The owner (Nov 24): the investor portal shows CarmaCars's own documents: the business plan, the financial forecast, the
-- pitch deck, the feature decks and any other kind an Admin adds. Built on what exists:
--   kinds              investor_library_kinds: the four sections, plus any an Admin adds (a label becomes a key)
--   items              investor_library_items: a title, its kind, its place in the section, the version shown
--   versions           investor_library_versions: every upload or link, never overwritten; a replacement is a new version
--                      and the history stays. A file is a PDF in the private documents bucket (investor-library/...);
--                      a deck may instead be a link (https only)
--   reading            investor_read library (investors and prospects let in by app.investor_of: the latest version of
--                      each item with its date, never the history or the file's path) and library_file (the bucket and path
--                      of an item's latest version, for a 5-minute signed link made by the server for the signed-in
--                      investor only); admin_read investor_library (every item with its history) and investor_library_file
--   writing            admin_do investor_library_save (a new item, or a new version of one) and investor_library_archive
--   the notice         investor_document_updated (4301) to every active investor, once per version: email and the
--                      portal's notice (the bell). CarmaCars only: nothing here names another business.
-- New tables: row-level security with admin_all, the audit trigger. The door is wrapped (_pre4300). SCHEMA_MARKER 4301.
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

-- ================================================================ 1. tables
create table if not exists investor_library_kinds (
  key         text primary key check (key ~ '^[a-z][a-z0-9_]{1,39}$'),
  label       text not null check (char_length(label) between 2 and 60),
  sort_order  integer not null default 100,
  created_by  uuid references users (id) on delete set null,
  created_at  timestamptz not null default now()
);
create index if not exists investor_library_kinds_created_by_idx on investor_library_kinds (created_by) where created_by is not null;
comment on table investor_library_kinds is 'r50 (4300): the sections of the investor Documents library: business plan, financial forecast, pitch deck, feature decks, and any an Admin adds.';
insert into investor_library_kinds (key, label, sort_order) values
  ('business_plan', 'Business plan', 10), ('financial_forecast', 'Financial forecast', 20),
  ('pitch_deck', 'Pitch deck', 30), ('feature_decks', 'Feature decks', 40)
on conflict (key) do nothing;

create table if not exists investor_library_items (
  id               uuid primary key default gen_random_uuid(),
  kind             text not null references investor_library_kinds (key) on update cascade,
  title            text not null check (char_length(btrim(title)) between 3 and 120),
  sort_order       integer not null default 100,
  current_version  integer not null default 0 check (current_version >= 0),
  archived_at      timestamptz,
  created_by       uuid references users (id) on delete set null,
  created_at       timestamptz not null default now(),
  updated_at       timestamptz not null default now()
);
create index if not exists investor_library_items_kind_idx on investor_library_items (kind, sort_order) where archived_at is null;
create index if not exists investor_library_items_created_by_idx on investor_library_items (created_by) where created_by is not null;
comment on table investor_library_items is 'r50 (4300): one document of the investor Documents library; the version shown is current_version. Read and written through the door only.';

create table if not exists investor_library_versions (
  id           uuid primary key default gen_random_uuid(),
  item_id      uuid not null references investor_library_items (id) on delete cascade,
  version      integer not null check (version >= 1),
  file_kind    text not null check (file_kind in ('pdf', 'link')),
  bucket       text check (bucket = 'documents'),
  path         text check (path ~ '^investor-library/[0-9a-f-]{36}/[0-9a-f-]{36}\.pdf$'),
  link_url     text check (link_url ~ '^https://[^\s<>"]{3,}$' and char_length(link_url) <= 500),
  size_bytes   integer check (size_bytes between 1 and 52428800),
  sha256       text check (sha256 ~ '^[0-9a-f]{64}$'),
  note         text check (char_length(note) <= 500),
  uploaded_by  uuid references users (id) on delete set null,
  created_at   timestamptz not null default now(),
  unique (item_id, version),
  check ((file_kind = 'pdf' and bucket is not null and path is not null and link_url is null)
      or (file_kind = 'link' and link_url is not null and path is null and bucket is null))
);
create index if not exists investor_library_versions_uploaded_by_idx on investor_library_versions (uploaded_by) where uploaded_by is not null;
comment on table investor_library_versions is 'r50 (4300): every version of an investor library document, never overwritten: a PDF in the private documents bucket or an https link to a deck.';

create trigger investor_library_items_updated before update on investor_library_items for each row execute function app.set_updated_at();
create trigger audit_investor_library_kinds after insert or update or delete on investor_library_kinds for each row execute function app.audit_row();
create trigger audit_investor_library_items after insert or update or delete on investor_library_items for each row execute function app.audit_row();
create trigger audit_investor_library_versions after insert or update or delete on investor_library_versions for each row execute function app.audit_row();

alter table investor_library_kinds enable row level security;
alter table investor_library_items enable row level security;
alter table investor_library_versions enable row level security;
create policy admin_all on investor_library_kinds for all to authenticated using (app.is_admin()) with check (app.is_admin());
create policy admin_all on investor_library_items for all to authenticated using (app.is_admin()) with check (app.is_admin());
create policy admin_all on investor_library_versions for all to authenticated using (app.is_admin()) with check (app.is_admin());
revoke all on investor_library_kinds, investor_library_items, investor_library_versions from public, anon, authenticated;
grant select on investor_library_kinds, investor_library_items, investor_library_versions to authenticated;
grant all on investor_library_kinds, investor_library_items, investor_library_versions to service_role;

-- ================================================================ 2. reading
create function app.investor_library_json(p_admin boolean) returns jsonb
language sql stable security definer set search_path = public, app, pg_temp as $$
  select jsonb_build_object('kinds', coalesce(jsonb_agg(jsonb_build_object('key', k.key, 'label', k.label, 'items', k.items) order by k.sort_order, k.label), '[]'::jsonb))
    from (
      select kk.key, kk.label, kk.sort_order, coalesce((
        select jsonb_agg(jsonb_build_object(
                 'id', i.id, 'title', i.title, 'kind', i.kind, 'version', v.version, 'file_kind', v.file_kind,
                 'updated_at', v.created_at, 'updated_on', app.local_date(v.created_at),
                 'link_url', case when v.file_kind = 'link' then v.link_url end)
               || case when p_admin then jsonb_build_object('archived', i.archived_at is not null, 'sort_order', i.sort_order,
                    'history', (select coalesce(jsonb_agg(jsonb_build_object('id', h.id, 'version', h.version, 'file_kind', h.file_kind, 'link_url', h.link_url,
                                  'size_bytes', h.size_bytes, 'note', h.note, 'created_at', h.created_at,
                                  'uploaded_by', (select u.full_name from users u where u.id = h.uploaded_by)) order by h.version desc), '[]'::jsonb)
                                  from investor_library_versions h where h.item_id = i.id)) else '{}'::jsonb end
               order by i.sort_order, i.title)
          from investor_library_items i
          join investor_library_versions v on v.item_id = i.id and v.version = i.current_version
         where i.kind = kk.key and (p_admin or i.archived_at is null)), '[]'::jsonb) as items
        from investor_library_kinds kk
    ) k
   where p_admin or jsonb_array_length(k.items) > 0
$$;

-- the bucket and path of an item's latest version (investors), or of one version (Admins, with p_version)
create function app.investor_library_file(p_user uuid, p_item uuid, p_version uuid default null) returns jsonb
language plpgsql stable security definer set search_path = public, app, pg_temp as $$
declare
  v investor_library_versions;
  t text;
begin
  if p_version is not null then
    perform app.assert_admin(p_user);
    select * into v from investor_library_versions where id = p_version;
  else
    if not app.user_is_admin(p_user) then perform app.investor_of(p_user); end if;
    select x.* into v from investor_library_versions x join investor_library_items i on i.id = x.item_id and x.version = i.current_version
     where i.id = p_item and i.archived_at is null;
  end if;
  if v.id is null then raise exception 'No such document' using errcode = 'P0002'; end if;
  select title into t from investor_library_items where id = v.item_id;
  return jsonb_build_object('file_kind', v.file_kind, 'bucket', v.bucket, 'path', v.path, 'link_url', v.link_url, 'title', t, 'version', v.version);
end $$;

-- ================================================================ 3. writing (Admins)
-- p: item (to replace an existing document) or kind + title (a new one; kind_label makes a new section); file_kind pdf
-- (path, size_bytes, sha256 from the server's upload) or link (link_url); note, sort_order optional.
create function app.investor_library_save(p_user uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app, pg_temp as $$
declare
  p_ jsonb := coalesce(p, '{}'::jsonb);
  i investor_library_items;
  v_kind text := nullif(btrim(p_ ->> 'kind'), '');
  v_label text := nullif(btrim(p_ ->> 'kind_label'), '');
  v_title text := nullif(btrim(p_ ->> 'title'), '');
  v_fk text := p_ ->> 'file_kind';
  v_ver integer;
  v_new boolean := false;
  r record;
  n integer := 0;
begin
  perform app.assert_admin(p_user);
  if v_fk is null or v_fk not in ('pdf', 'link') then raise exception 'Upload a PDF or give a link to the deck' using errcode = '22023'; end if;
  if v_fk = 'link' and (coalesce(p_ ->> 'link_url', '') !~ '^https://[^\s<>"]{3,}$' or char_length(p_ ->> 'link_url') > 500) then raise exception 'The link must start with https://' using errcode = '22023'; end if;
  if v_fk = 'pdf' and coalesce(p_ ->> 'path', '') !~ '^investor-library/[0-9a-f-]{36}/[0-9a-f-]{36}\.pdf$' then raise exception 'Upload the PDF first' using errcode = '22023'; end if;
  if p_ ? 'item' then
    select * into i from investor_library_items where id = (p_ ->> 'item')::uuid for update;
    if i.id is null then raise exception 'No such document' using errcode = 'P0002'; end if;
    if v_title is not null and v_title <> i.title then update investor_library_items set title = v_title where id = i.id; end if;
  else
    if v_title is null then raise exception 'Give the document a title' using errcode = '22023'; end if;
    if v_kind is null and v_label is not null then
      v_kind := left(trim(both '_' from regexp_replace(lower(v_label), '[^a-z0-9]+', '_', 'g')), 40);
      if v_kind !~ '^[a-z]' then v_kind := 'k_' || v_kind; end if;
      if char_length(v_label) not between 2 and 60 then raise exception 'Name the new section in 2 to 60 characters' using errcode = '22023'; end if;
      insert into investor_library_kinds (key, label, sort_order, created_by)
      values (v_kind, v_label, (select coalesce(max(sort_order), 0) + 10 from investor_library_kinds), p_user)
      on conflict (key) do nothing;
    end if;
    if v_kind is null or not exists (select 1 from investor_library_kinds where key = v_kind) then raise exception 'Choose the section' using errcode = '22023'; end if;
    insert into investor_library_items (kind, title, sort_order, created_by)
    values (v_kind, v_title, coalesce((p_ ->> 'sort_order')::integer, 100), p_user) returning * into i;
    v_new := true;
  end if;
  v_ver := (select coalesce(max(version), 0) + 1 from investor_library_versions where item_id = i.id);
  insert into investor_library_versions (item_id, version, file_kind, bucket, path, link_url, size_bytes, sha256, note, uploaded_by)
  values (i.id, v_ver, v_fk, case when v_fk = 'pdf' then 'documents' end, case when v_fk = 'pdf' then p_ ->> 'path' end,
          case when v_fk = 'link' then p_ ->> 'link_url' end, (p_ ->> 'size_bytes')::integer, nullif(p_ ->> 'sha256', ''),
          nullif(left(btrim(coalesce(p_ ->> 'note', '')), 500), ''), p_user);
  update investor_library_items set current_version = v_ver, archived_at = null where id = i.id returning * into i;
  -- every active investor is told, once per version (email and the portal's notice)
  for r in select x.id from investors x where x.status = 'active' loop
    perform app.ntf_emit('investor_document_updated', 'investor_library_item', i.id, 'v' || v_ver || ':' || r.id,
      jsonb_build_object('investor_id', r.id,
        'document_change', case when v_ver = 1 then 'New document' else 'New version' end,
        'document_title', i.title, 'document_kind', (select label from investor_library_kinds where key = i.kind),
        'document_version', v_ver::text, 'document_date', app.fmt_day(app.today()),
        '_url', app.ntf_link('investor_library')));
    n := n + 1;
  end loop;
  return jsonb_build_object('item', i.id, 'version', v_ver, 'new', v_new, 'told', n);
end $$;

-- p: item, archived (true hides it from investors; false shows it again)
create function app.investor_library_archive(p_user uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app, pg_temp as $$
declare i investor_library_items;
begin
  perform app.assert_admin(p_user);
  update investor_library_items set archived_at = case when coalesce((p ->> 'archived')::boolean, true) then now() end
   where id = (p ->> 'item')::uuid returning * into i;
  if i.id is null then raise exception 'No such document' using errcode = 'P0002'; end if;
  return jsonb_build_object('item', i.id, 'archived', i.archived_at is not null);
end $$;

insert into notification_link_paths (key, path) values ('investor_library', '/investor/documents?tab=library') on conflict (key) do update set path = excluded.path;

-- ================================================================ 4. the door
alter function app.door(uuid, text, text, text, jsonb) rename to door_pre4300;
create function app.door(p_user uuid, p_aal text, p_call text, p_name text, p jsonb default '{}'::jsonb) returns jsonb
language plpgsql security definer set search_path = public, app, pg_temp as $$
begin
  if p_call = 'investor_read' and p_name in ('library', 'library_file') then
    perform app.door_begin(p_user, p_aal);
    if p_name = 'library_file' then return app.investor_library_file(p_user, (p ->> 'item')::uuid); end if;
    if not app.user_is_admin(p_user) then perform app.investor_of(p_user); end if;
    return app.investor_library_json(false);
  elsif p_call = 'admin_read' and p_name in ('investor_library', 'investor_library_file') then
    perform app.door_begin(p_user, p_aal);
    perform app.assert_admin(p_user);
    if p_name = 'investor_library_file' then return app.investor_library_file(p_user, null, (p ->> 'version')::uuid); end if;
    return app.investor_library_json(true);
  elsif p_call = 'admin_do' and p_name in ('investor_library_save', 'investor_library_archive') then
    perform app.door_begin(p_user, p_aal);
    if p_name = 'investor_library_save' then return app.investor_library_save(p_user, p); end if;
    return app.investor_library_archive(p_user, p);
  end if;
  return app.door_pre4300(p_user, p_aal, p_call, p_name, p);
end $$;
select pg_temp.copy_grants('app.door(uuid, text, text, text, jsonb)'::regprocedure, 'app.door_pre4300(uuid, text, text, text, jsonb)'::regprocedure);

-- ================================================================ 5. privileges: the server only
do $$
declare f record;
begin
  for f in select p.oid::regprocedure as sig from pg_proc p join pg_namespace n on n.oid = p.pronamespace
            where n.nspname = 'app' and p.proname in ('investor_library_json', 'investor_library_file', 'investor_library_save', 'investor_library_archive', 'door_pre4300') loop
    execute format('revoke all on function %s from public, anon, authenticated', f.sig);
    execute format('grant execute on function %s to service_role', f.sig);
  end loop;
end $$;
