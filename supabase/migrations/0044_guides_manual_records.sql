-- 0044_guides_manual_records.sql
-- Guides inside every portal, payments received outside the processor, signatures on paper, and signing in the
-- portals for every signable document.
--
--   1. Guides. One guide per portal (renter, owner, admin, va, field, investor), stored as ordered sections in
--      Markdown, edited in Admin > Settings > Guides without code: a draft per section, version history, publish
--      (the published copy and its HTML, rendered once by the server at publish time, are what the portals read).
--      Images live in the static assets (/guides/img/...) or the public bucket. The PDF: the latest stored PDF per
--      portal (the committed PDFs uploaded at deploy, a PDF printed from the published content by the guides-pdf
--      workflow, or one an Admin uploads) with its date. Per user: the first-visit banner dismissed, the version last
--      opened.
--   2. Manual payments. An Admin (or Finance within their single limit) records a payment received by e-Transfer,
--      cheque, cash, bank transfer or another way on any owner invoice: partial or full, with its date, reference,
--      an optional proof and a note. The invoice is marked paid or partly paid, the automatic debit stops or shrinks
--      to the balance, the owner is emailed a receipt (owner_payment_recorded) and it is audited. A payment recorded
--      by mistake (a cheque that bounced) is voided with a reason: the invoice goes back to what it owes and the
--      owner is told (owner_payment_reversed). 0029's record_owner_offline_payment now goes through the same path.
--      A renter charge paid another way is recorded on its booking the same way (and stops the retries of the
--      failed card charge it settles).
--   3. Paper signatures. Every signable document can be recorded as signed on paper: the scan (stored privately in
--      the person's documents), the signer, the date signed, witnesses where the form needs them, a note. The
--      document then counts as signed wherever its status is used (onboarding checklist, the onboarding steps,
--      booking confirmation, the owner portal) with its method. Audited; voidable with a reason.
--   4. Signing in the portals for what had no signing yet: Forms A and B on screen in the owner portal, and
--      documents sent by CarmaCars to sign (investment agreements in the investor portal, staff agreements in the
--      staff and field portals) with the built-in signature (typed or drawn).
--   5. What is signed and paid, per person (app.signables) and per owner (Admin > Owners).
-- No earlier migration is edited. Functions it changes are wrapped (renamed _00NN and called from a new function of
-- the same name) or replaced with the same signature.
set local check_function_bodies = off;

-- ================================================================ 1. guides
create table guides (
  portal        text primary key check (portal in ('renter', 'owner', 'admin', 'va', 'field', 'investor')),
  title         text not null,
  promise       text,
  signin_url    text not null,
  lands_on      text,
  sort_order    integer not null default 0,
  version       integer not null default 0 check (version >= 0),  -- the published version; each publish adds one
  published_at  timestamptz,
  published_by  uuid references users (id),
  updated_at    timestamptz not null default now(),
  updated_by    uuid references users (id)
);
comment on table guides is 'One user guide per portal (0044). The sections are in guide_sections; the PDF in guide_pdfs.';
create trigger guides_updated before update on guides for each row execute function app.set_updated_at();

insert into guides (portal, title, promise, signin_url, lands_on, sort_order) values
  ('renter', 'Renter Guide', 'Book a car, sign, pay and manage your trips, from your phone or your computer.', 'carmacars.ca/sign-in', 'Your trips', 1),
  ('owner', 'Owner Portal Guide', 'Your cars, your money and your paperwork, in one place.', 'carmacars.ca/sign-in?next=/owner', 'Home in your owner portal', 2),
  ('admin', 'Admin Guide', 'Every booking, car, owner and dollar, run from one place.', 'carmacars.ca/sign-in?next=/admin', 'Today, the Admin home page', 3),
  ('va', 'VA Guide', 'Your queue, your screens and how to work each task.', 'carmacars.ca/sign-in?next=/va', 'Your queue', 4),
  ('field', 'Field Guide', 'Your jobs, handovers, returns and photos, on your phone.', 'carmacars.ca/sign-in?next=/field', 'My jobs', 5),
  ('investor', 'Investor Guide', 'Your investments, statements and requests.', 'carmacars.ca/sign-in?next=/investor', 'Your investments', 6);

create table guide_sections (
  id               uuid primary key default gen_random_uuid(),
  portal           text not null references guides (portal),
  kind             text not null default 'chapter' check (kind in ('start', 'chapter', 'reference')),
  sort_order       integer not null,
  slug             text not null check (slug ~ '^[a-z0-9][a-z0-9-]{0,60}$'),
  -- the draft an Admin edits
  title            text not null check (length(btrim(title)) between 1 and 120),
  blurb            text check (length(blurb) <= 300),
  body_md          text not null default '' check (length(body_md) <= 200000),
  is_hidden        boolean not null default false,
  draft_version    integer not null default 1 check (draft_version >= 1),
  -- the copy the portals read (set by publishing)
  published_title  text,
  published_blurb  text,
  published_md     text,
  published_html   text,
  published_hidden boolean,
  published_version integer,          -- the draft_version that was published
  published_at     timestamptz,
  published_by     uuid references users (id),
  created_by       uuid references users (id),
  created_at       timestamptz not null default now(),
  updated_by       uuid references users (id),
  updated_at       timestamptz not null default now(),
  unique (portal, slug)
);
create index guide_sections_portal_idx on guide_sections (portal, sort_order);
create trigger guide_sections_updated before update on guide_sections for each row execute function app.set_updated_at();
comment on table guide_sections is 'A guide''s chapters in order (0044): the draft (title, blurb, body_md) and the published copy with its HTML.';

-- Every saved draft and every publish, so an earlier text can be read and restored.
create table guide_section_versions (
  id           bigint generated always as identity primary key,
  section_id   uuid not null references guide_sections (id) on delete cascade,
  version      integer not null,
  title        text not null,
  blurb        text,
  body_md      text not null,
  is_hidden    boolean not null default false,
  published    boolean not null default false,
  saved_by     uuid references users (id),
  saved_at     timestamptz not null default now(),
  unique (section_id, version, published)
);
create index guide_section_versions_section_idx on guide_section_versions (section_id, saved_at desc);

-- Images uploaded for the guides (the public bucket). The committed screenshots are static assets.
create table guide_images (
  id           uuid primary key default gen_random_uuid(),
  portal       text references guides (portal),
  url          text not null check (url ~ '^(/|https://)'),
  storage_key  text,
  alt          text,
  width        integer,
  height       integer,
  bytes        integer,
  replaces_url text,
  uploaded_by  uuid references users (id),
  created_at   timestamptz not null default now()
);
create index guide_images_portal_idx on guide_images (portal, created_at desc);

-- The stored PDF of each guide. The newest current row is the one the portal offers.
create table guide_pdfs (
  id             uuid primary key default gen_random_uuid(),
  portal         text not null references guides (portal),
  storage_bucket text not null default 'documents',
  storage_path   text not null,
  sha256         text not null check (sha256 ~ '^[0-9a-f]{64}$'),
  bytes          integer not null check (bytes > 0),
  pages          integer,
  source         text not null check (source in ('committed', 'generated', 'uploaded')),
  guide_version  integer,              -- the published version it was printed from (null: the committed PDF)
  generated_at   timestamptz not null default now(),
  uploaded_by    uuid references users (id),
  is_current     boolean not null default true,
  created_at     timestamptz not null default now()
);
create unique index guide_pdfs_one_current on guide_pdfs (portal) where is_current;

-- Per person and guide: the banner dismissed, the version last opened.
create table guide_reads (
  user_id             uuid not null references users (id) on delete cascade,
  portal              text not null references guides (portal),
  first_opened_at     timestamptz,
  last_opened_at      timestamptz,
  last_version        integer,
  opens               integer not null default 0,
  banner_dismissed_at timestamptz,
  primary key (user_id, portal)
);
create index guide_reads_portal_idx on guide_reads (portal, last_opened_at desc);

-- Who may read a guide: the people of that portal; an Admin reads every guide.
create or replace function app.guide_access(p_user uuid, p_portal text) returns boolean
language sql stable security definer set search_path = public, app as $$
  select p_user is not null and exists (select 1 from users u where u.id = p_user and u.status = 'active') and (
    app.user_is_admin(p_user)
    or case p_portal
         when 'renter' then true                                        -- anyone signed in may rent
         when 'owner' then exists (select 1 from owners o where o.user_id = p_user)
         when 'va' then exists (select 1 from staff_profiles sp where sp.user_id = p_user and sp.staff_type = 'va' and sp.is_active)
         when 'field' then app.user_is_field(p_user)
         when 'investor' then exists (select 1 from investors i where i.user_id = p_user and i.status <> 'refused')
         else false end)
$$;

-- The published guide as a portal shows it: the guide, its visible sections (HTML), the stored PDF and whether the web
-- guide has edits newer than it, and the reader's own state.
create or replace function app.guide_read(p_user uuid, p_portal text) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare
  g guides;
  pdf guide_pdfs;
begin
  select * into g from guides where portal = p_portal;
  if g.portal is null then raise exception 'Unknown guide' using errcode = 'P0002'; end if;
  if not app.guide_access(p_user, p_portal) then raise exception 'This guide is for the people of that portal' using errcode = '42501'; end if;
  select * into pdf from guide_pdfs where portal = p_portal and is_current;
  return jsonb_build_object(
    'portal', g.portal, 'title', g.title, 'promise', g.promise, 'signin_url', g.signin_url, 'lands_on', g.lands_on,
    'version', g.version, 'published_at', g.published_at,
    'sections', coalesce((select jsonb_agg(jsonb_build_object('id', s.id, 'slug', s.slug, 'kind', s.kind, 'title', s.published_title,
                            'blurb', s.published_blurb, 'html', s.published_html) order by s.sort_order, s.created_at)
                          from guide_sections s where s.portal = p_portal and s.published_html is not null and not coalesce(s.published_hidden, false)), '[]'::jsonb),
    'pdf', case when pdf.id is null then null else jsonb_build_object('id', pdf.id, 'generated_at', pdf.generated_at, 'source', pdf.source,
                 'bytes', pdf.bytes, 'pages', pdf.pages, 'guide_version', pdf.guide_version,
                 'stale', g.published_at is not null and g.published_at > pdf.generated_at) end,
    'reader', (select jsonb_build_object('last_version', r.last_version, 'last_opened_at', r.last_opened_at, 'banner_dismissed_at', r.banner_dismissed_at)
                 from guide_reads r where r.user_id = p_user and r.portal = p_portal));
end $$;

-- The stored PDF of a guide, for the download route (after app.guide_access).
create or replace function app.guide_pdf_file(p_user uuid, p_portal text) returns jsonb
language sql stable security definer set search_path = public, app as $$
  select case when app.guide_access(p_user, p_portal) then
           (select jsonb_build_object('bucket', p.storage_bucket, 'path', p.storage_path, 'generated_at', p.generated_at, 'title', g.title)
              from guide_pdfs p join guides g on g.portal = p.portal where p.portal = p_portal and p.is_current) end
$$;

-- The person opened the guide: the version they read. Opening it also ends the first-visit banner.
create or replace function app.guide_opened(p_user uuid, p_portal text) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  v integer;
begin
  if not app.guide_access(p_user, p_portal) then raise exception 'This guide is for the people of that portal' using errcode = '42501'; end if;
  select version into v from guides where portal = p_portal;
  insert into guide_reads (user_id, portal, first_opened_at, last_opened_at, last_version, opens)
  values (p_user, p_portal, now(), now(), v, 1)
  on conflict (user_id, portal) do update
     set last_opened_at = now(), last_version = v, opens = guide_reads.opens + 1,
         first_opened_at = coalesce(guide_reads.first_opened_at, now());
  return jsonb_build_object('portal', p_portal, 'version', v);
end $$;

-- Whether the first-visit banner shows: never opened and never dismissed.
create or replace function app.guide_banner(p_user uuid, p_portal text) returns boolean
language sql stable security definer set search_path = public, app as $$
  select app.guide_access(p_user, p_portal)
     and exists (select 1 from guides g where g.portal = p_portal and g.version > 0)
     and not exists (select 1 from guide_reads r where r.user_id = p_user and r.portal = p_portal
                        and (r.banner_dismissed_at is not null or r.last_opened_at is not null))
$$;

create or replace function app.guide_dismiss(p_user uuid, p_portal text) returns boolean
language plpgsql security definer set search_path = public, app as $$
begin
  if not app.guide_access(p_user, p_portal) then raise exception 'This guide is for the people of that portal' using errcode = '42501'; end if;
  insert into guide_reads (user_id, portal, banner_dismissed_at) values (p_user, p_portal, now())
  on conflict (user_id, portal) do update set banner_dismissed_at = coalesce(guide_reads.banner_dismissed_at, now());
  return true;
end $$;

-- ---------------------------------------------------------------- editing (Admin)
-- Every guide with its counts, for Admin > Settings > Guides.
create or replace function app.guides_admin(p_by uuid) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
begin
  perform app.assert_admin(p_by);
  return (select coalesce(jsonb_agg(jsonb_build_object(
      'portal', g.portal, 'title', g.title, 'version', g.version, 'published_at', g.published_at,
      'published_by_name', (select u.full_name from users u where u.id = g.published_by),
      'sections', (select count(*) from guide_sections s where s.portal = g.portal),
      'unpublished', (select count(*) from guide_sections s where s.portal = g.portal
                        and (s.published_version is distinct from s.draft_version or s.published_hidden is distinct from s.is_hidden)),
      'readers', (select count(*) from guide_reads r where r.portal = g.portal and r.last_opened_at is not null),
      'readers_current', (select count(*) from guide_reads r where r.portal = g.portal and r.last_version = g.version and g.version > 0),
      'pdf', (select jsonb_build_object('generated_at', p.generated_at, 'source', p.source, 'bytes', p.bytes, 'guide_version', p.guide_version,
                                        'stale', g.published_at is not null and g.published_at > p.generated_at)
                from guide_pdfs p where p.portal = g.portal and p.is_current))
      order by g.sort_order), '[]'::jsonb) from guides g);
end $$;

-- One guide with every section's draft and published state, and the recent history of each.
create or replace function app.guide_admin(p_by uuid, p_portal text) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare
  g guides;
begin
  perform app.assert_admin(p_by);
  select * into g from guides where portal = p_portal;
  if g.portal is null then raise exception 'Unknown guide' using errcode = 'P0002'; end if;
  return to_jsonb(g) || jsonb_build_object(
    'published_by_name', (select u.full_name from users u where u.id = g.published_by),
    'sections', coalesce((select jsonb_agg(jsonb_build_object('id', s.id, 'kind', s.kind, 'slug', s.slug, 'sort_order', s.sort_order,
                   'title', s.title, 'blurb', s.blurb, 'body_md', s.body_md, 'is_hidden', s.is_hidden, 'draft_version', s.draft_version,
                   'published_version', s.published_version, 'published_at', s.published_at, 'published_title', s.published_title,
                   'changed', s.published_version is distinct from s.draft_version or s.published_hidden is distinct from s.is_hidden,
                   'updated_at', s.updated_at, 'updated_by_name', (select u.full_name from users u where u.id = s.updated_by),
                   'history', (select coalesce(jsonb_agg(jsonb_build_object('version', h.version, 'published', h.published, 'title', h.title,
                                 'saved_at', h.saved_at, 'saved_by_name', (select u.full_name from users u where u.id = h.saved_by),
                                 'chars', length(h.body_md)) order by h.saved_at desc, h.id desc), '[]'::jsonb)
                                 from (select * from guide_section_versions x where x.section_id = s.id order by x.saved_at desc, x.id desc limit 15) h))
                   order by s.sort_order, s.created_at) from guide_sections s where s.portal = p_portal), '[]'::jsonb),
    'pdf', (select to_jsonb(p) - 'storage_bucket' - 'storage_path' from guide_pdfs p where p.portal = p_portal and p.is_current),
    'images', coalesce((select jsonb_agg(jsonb_build_object('id', i.id, 'url', i.url, 'alt', i.alt, 'created_at', i.created_at) order by i.created_at desc)
                        from (select * from guide_images x where x.portal = p_portal order by x.created_at desc limit 40) i), '[]'::jsonb));
end $$;

-- The text of one earlier version, to read or restore.
create or replace function app.guide_section_version(p_by uuid, p_section uuid, p_version integer, p_published boolean default false) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
begin
  perform app.assert_admin(p_by);
  return (select to_jsonb(h) from guide_section_versions h where h.section_id = p_section and h.version = p_version and h.published = coalesce(p_published, false));
end $$;

-- Save a section's draft (a new one when p has no id). A new draft version and a history row each time the text
-- changes. p: {id | portal, kind, title, blurb, body_md, is_hidden, slug, after (the id it goes after)}
create or replace function app.guide_section_save(p_by uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  s guide_sections;
  v_portal text := p ->> 'portal';
  v_title text := nullif(btrim(coalesce(p ->> 'title', '')), '');
  v_body text := coalesce(p ->> 'body_md', '');
  v_slug text;
  v_order integer;
begin
  perform app.assert_admin(p_by);
  if nullif(p ->> 'id', '') is not null then
    select * into s from guide_sections where id = (p ->> 'id')::uuid for update;
    if s.id is null then raise exception 'Section not found' using errcode = 'P0002'; end if;
    if v_title is null then v_title := s.title; end if;
    if s.title = v_title and s.blurb is not distinct from nullif(btrim(coalesce(p ->> 'blurb', s.blurb, '')), '') and s.body_md = coalesce(p ->> 'body_md', s.body_md)
       and s.is_hidden = coalesce((p ->> 'is_hidden')::boolean, s.is_hidden) then
      return to_jsonb(s);                       -- nothing changed: no new version
    end if;
    update guide_sections
       set title = v_title, blurb = nullif(btrim(coalesce(p ->> 'blurb', blurb, '')), ''), body_md = coalesce(p ->> 'body_md', body_md),
           is_hidden = coalesce((p ->> 'is_hidden')::boolean, is_hidden), draft_version = draft_version + 1, updated_by = p_by
     where id = s.id returning * into s;
  else
    if not exists (select 1 from guides where portal = v_portal) then raise exception 'Unknown guide' using errcode = 'P0002'; end if;
    if v_title is null then raise exception 'Give the section a title' using errcode = '22023'; end if;
    v_slug := coalesce(nullif(p ->> 'slug', ''), left(trim(both '-' from regexp_replace(lower(v_title), '[^a-z0-9]+', '-', 'g')), 50));
    if v_slug = '' then v_slug := 'section'; end if;
    while exists (select 1 from guide_sections where portal = v_portal and slug = v_slug) loop
      v_slug := left(v_slug, 45) || '-' || substr(md5(random()::text), 1, 4);
    end loop;
    if nullif(p ->> 'after', '') is not null then
      select sort_order + 1 into v_order from guide_sections where id = (p ->> 'after')::uuid and portal = v_portal;
    end if;
    if v_order is null then
      select coalesce(max(sort_order), 0) + 1 into v_order from guide_sections where portal = v_portal and kind <> 'reference';
    end if;
    update guide_sections set sort_order = sort_order + 1 where portal = v_portal and sort_order >= v_order;
    insert into guide_sections (portal, kind, sort_order, slug, title, blurb, body_md, is_hidden, created_by, updated_by)
    values (v_portal, coalesce(nullif(p ->> 'kind', ''), 'chapter'), v_order, v_slug, v_title, nullif(btrim(coalesce(p ->> 'blurb', '')), ''),
            v_body, coalesce((p ->> 'is_hidden')::boolean, false), p_by, p_by)
    returning * into s;
  end if;
  insert into guide_section_versions (section_id, version, title, blurb, body_md, is_hidden, published, saved_by)
  values (s.id, s.draft_version, s.title, s.blurb, s.body_md, s.is_hidden, false, p_by)
  on conflict (section_id, version, published) do nothing;
  update guides set updated_by = p_by where portal = s.portal;
  return to_jsonb(s);
end $$;

-- Move a section up or down (the start page stays first and the quick reference last).
create or replace function app.guide_section_move(p_by uuid, p_section uuid, p_dir text) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  s guide_sections;
  o guide_sections;
begin
  perform app.assert_admin(p_by);
  select * into s from guide_sections where id = p_section for update;
  if s.id is null then raise exception 'Section not found' using errcode = 'P0002'; end if;
  if s.kind <> 'chapter' then raise exception 'The start page and the quick reference keep their places' using errcode = '23514'; end if;
  if p_dir = 'up' then
    select * into o from guide_sections where portal = s.portal and kind = 'chapter' and (sort_order, created_at) < (s.sort_order, s.created_at)
     order by sort_order desc, created_at desc limit 1 for update;
  elsif p_dir = 'down' then
    select * into o from guide_sections where portal = s.portal and kind = 'chapter' and (sort_order, created_at) > (s.sort_order, s.created_at)
     order by sort_order, created_at limit 1 for update;
  else
    raise exception 'Move up or down' using errcode = '22023';
  end if;
  if o.id is null then return to_jsonb(s); end if;
  update guide_sections set sort_order = o.sort_order, updated_by = p_by where id = s.id;
  update guide_sections set sort_order = s.sort_order, updated_by = p_by where id = o.id;
  -- the order is part of what the portals read: it takes effect at once
  update guides set updated_by = p_by, published_at = case when version > 0 then now() else published_at end where portal = s.portal;
  return (select to_jsonb(x) from guide_sections x where x.id = s.id);
end $$;

-- Delete a section that was never published (a published one is hidden instead, so its history stays).
create or replace function app.guide_section_delete(p_by uuid, p_section uuid) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  s guide_sections;
begin
  perform app.assert_admin(p_by);
  select * into s from guide_sections where id = p_section for update;
  if s.id is null then raise exception 'Section not found' using errcode = 'P0002'; end if;
  if s.published_at is not null then
    raise exception 'This section was published: hide it instead (its history is kept)' using errcode = '23514';
  end if;
  if s.kind <> 'chapter' then raise exception 'The start page and the quick reference cannot be deleted' using errcode = '23514'; end if;
  delete from guide_sections where id = s.id;
  return jsonb_build_object('deleted', s.id);
end $$;

-- Publish: every section's draft becomes the published copy with the HTML the server rendered from it (p_html:
-- {section_id: html} for every section of the guide that is not hidden). The guide's version goes up by one.
create or replace function app.guide_publish(p_by uuid, p_portal text, p_html jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  g guides;
  s guide_sections;
  v_n integer := 0;
begin
  perform app.assert_admin(p_by);
  select * into g from guides where portal = p_portal for update;
  if g.portal is null then raise exception 'Unknown guide' using errcode = 'P0002'; end if;
  if jsonb_typeof(p_html) <> 'object' then raise exception 'The rendered sections are missing' using errcode = '22023'; end if;
  for s in select * from guide_sections where portal = p_portal order by sort_order for update loop
    if not s.is_hidden and nullif(p_html ->> s.id::text, '') is null then
      raise exception 'Section "%" was not rendered: publish again', s.title using errcode = '22023';
    end if;
    if length(coalesce(p_html ->> s.id::text, '')) > 600000 then raise exception 'Section "%" is too long', s.title using errcode = '22023'; end if;
    update guide_sections
       set published_title = title, published_blurb = blurb, published_md = body_md,
           published_html = coalesce(p_html ->> s.id::text, published_html), published_hidden = is_hidden,
           published_version = draft_version, published_at = now(), published_by = p_by
     where id = s.id;
    if s.published_version is distinct from s.draft_version or s.published_hidden is distinct from s.is_hidden then
      insert into guide_section_versions (section_id, version, title, blurb, body_md, is_hidden, published, saved_by)
      values (s.id, s.draft_version, s.title, s.blurb, s.body_md, s.is_hidden, true, p_by)
      on conflict (section_id, version, published) do nothing;
      v_n := v_n + 1;
    end if;
  end loop;
  update guides set version = version + 1, published_at = now(), published_by = p_by, updated_by = p_by where portal = p_portal returning * into g;
  insert into audit_log (actor_user_id, action, entity_table, entity_id, after)
  values (p_by, 'guide_publish', 'guides', p_portal, jsonb_build_object('version', g.version, 'sections_changed', v_n));
  return jsonb_build_object('portal', p_portal, 'version', g.version, 'sections_changed', v_n, 'published_at', g.published_at);
end $$;

-- A stored PDF: the committed one (deploy), one printed from the published content (the guides-pdf workflow), or one
-- an Admin uploads. It becomes the current PDF of the guide. p: {portal, bucket, path, sha256, bytes, pages, source,
-- guide_version, generated_at}. p_by: an Admin, or null for the server's own jobs (the service role only).
create or replace function app.guide_pdf_record(p_by uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  v_portal text := p ->> 'portal';
  v_id uuid;
begin
  if p_by is not null then perform app.assert_admin(p_by); end if;
  if not exists (select 1 from guides where portal = v_portal) then raise exception 'Unknown guide' using errcode = 'P0002'; end if;
  if coalesce(p ->> 'source', '') not in ('committed', 'generated', 'uploaded') then raise exception 'Unknown source' using errcode = '22023'; end if;
  if coalesce(p ->> 'path', '') !~ ('^guides/' || v_portal || '/') then raise exception 'Unknown file' using errcode = '22023'; end if;
  if (p ->> 'source') = 'committed' and exists (select 1 from guide_pdfs where portal = v_portal) and not coalesce((p ->> 'replace')::boolean, false) then
    return jsonb_build_object('skipped', true, 'reason', 'a PDF is already stored');
  end if;
  -- asked before the file is stored: would it be kept?
  if coalesce((p ->> 'dry_run')::boolean, false) then return jsonb_build_object('skipped', false); end if;
  update guide_pdfs set is_current = false where portal = v_portal and is_current;
  insert into guide_pdfs (portal, storage_bucket, storage_path, sha256, bytes, pages, source, guide_version, generated_at, uploaded_by)
  values (v_portal, coalesce(nullif(p ->> 'bucket', ''), 'documents'), p ->> 'path', lower(p ->> 'sha256'), (p ->> 'bytes')::integer,
          nullif(p ->> 'pages', '')::integer, p ->> 'source', nullif(p ->> 'guide_version', '')::integer,
          coalesce(nullif(p ->> 'generated_at', '')::timestamptz, now()), p_by)
  returning id into v_id;
  return jsonb_build_object('id', v_id, 'portal', v_portal);
end $$;

-- An uploaded guide image (already stored in the public bucket by the server). With replaces_url, every draft of the
-- guide that shows the old image is changed to the new one (each as a new draft version).
create or replace function app.guide_image_record(p_by uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  v_id uuid;
  v_old text := nullif(p ->> 'replaces_url', '');
  v_new text := p ->> 'url';
  s guide_sections;
  v_n integer := 0;
begin
  perform app.assert_admin(p_by);
  if coalesce(v_new, '') !~ '^(/|https://)' then raise exception 'Unknown image address' using errcode = '22023'; end if;
  insert into guide_images (portal, url, storage_key, alt, width, height, bytes, replaces_url, uploaded_by)
  values (nullif(p ->> 'portal', ''), v_new, nullif(p ->> 'storage_key', ''), nullif(btrim(coalesce(p ->> 'alt', '')), ''),
          nullif(p ->> 'width', '')::integer, nullif(p ->> 'height', '')::integer, nullif(p ->> 'bytes', '')::integer, v_old, p_by)
  returning id into v_id;
  if v_old is not null then
    for s in select * from guide_sections where (portal = p ->> 'portal' or nullif(p ->> 'portal', '') is null) and position(v_old in body_md) > 0 loop
      perform app.guide_section_save(p_by, jsonb_build_object('id', s.id, 'body_md', replace(s.body_md, v_old, v_new)));
      v_n := v_n + 1;
    end loop;
  end if;
  return jsonb_build_object('id', v_id, 'url', v_new, 'sections_changed', v_n);
end $$;

-- Who opened a guide, and which version they read last (Admin).
create or replace function app.guide_readers(p_by uuid, p_portal text) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
begin
  perform app.assert_admin(p_by);
  return jsonb_build_object(
    'version', (select version from guides where portal = p_portal),
    'readers', coalesce((select jsonb_agg(jsonb_build_object('user_id', r.user_id, 'name', u.full_name, 'email', u.email, 'last_version', r.last_version,
                     'last_opened_at', r.last_opened_at, 'opens', r.opens, 'banner_dismissed_at', r.banner_dismissed_at)
                     order by r.last_opened_at desc nulls last)
                   from (select * from guide_reads x where x.portal = p_portal order by x.last_opened_at desc nulls last limit 300) r
                   join users u on u.id = r.user_id), '[]'::jsonb));
end $$;

-- The published content for the PDF printer (the guides-pdf workflow, through the site with the worker token).
create or replace function app.guide_print_content(p_portal text) returns jsonb
language sql stable security definer set search_path = public, app as $$
  select jsonb_build_object('portal', g.portal, 'title', g.title, 'promise', g.promise, 'signin_url', g.signin_url, 'lands_on', g.lands_on,
           'version', g.version, 'published_at', g.published_at,
           'sections', coalesce((select jsonb_agg(jsonb_build_object('slug', s.slug, 'kind', s.kind, 'title', s.published_title, 'blurb', s.published_blurb,
                                   'html', s.published_html) order by s.sort_order, s.created_at)
                                 from guide_sections s where s.portal = g.portal and s.published_html is not null and not coalesce(s.published_hidden, false)), '[]'::jsonb))
    from guides g where g.portal = p_portal
$$;

-- ================================================================ 2. payments received outside the processor
alter table payments drop constraint if exists payments_method_check;
alter table payments add constraint payments_method_check
  check (method in ('card', 'pre_authorized_debit', 'e_transfer', 'bank_transfer', 'cheque', 'cash', 'other'));
alter table owner_invoices drop constraint if exists owner_invoices_payment_method_check;
alter table owner_invoices add constraint owner_invoices_payment_method_check
  check (payment_method in ('pre_authorized_debit', 'card', 'e_transfer', 'bank_transfer', 'cheque', 'cash', 'other'));

-- A voided payment can take a paid invoice back to what it owed before.
insert into status_transitions (entity, from_status, to_status, note) values
  ('owner_invoice', 'paid', 'issued', 'a payment recorded by hand is voided (0044)'),
  ('owner_invoice', 'paid', 'failed', 'a payment recorded by hand is voided (0044)'),
  ('owner_invoice', 'paid', 'in_arrears', 'a payment recorded by hand is voided (0044)'),
  ('owner_invoice', 'paid', 'partially_deducted', 'a payment recorded by hand is voided (0044)'),
  ('vehicle_onboarding', 'upfront_paid', 'documents_signed', 'the upfront payment recorded by hand is voided (0044)'),
  ('vehicle_onboarding', 'documents_signed', 'documents_sent', 'a paper signature is voided (0044)')
on conflict do nothing;

create table manual_payments (
  id                    uuid primary key default gen_random_uuid(),
  payment_id            uuid not null unique references payments (id),
  target                text not null check (target in ('owner_invoice', 'booking')),
  owner_invoice_id      uuid references owner_invoices (id),
  booking_id            uuid references bookings (id),
  owner_id              uuid references owners (id),
  renter_id             uuid references renters (id),
  settles_payment_id    uuid references payments (id),   -- a renter's failed card charge this payment settles
  method                text not null check (method in ('e_transfer', 'cheque', 'cash', 'bank_transfer', 'other')),
  amount_cents          bigint not null check (amount_cents > 0),
  received_on           date not null,
  reference             text,
  proof_document_id     uuid references documents (id),
  note                  text,
  recorded_by           uuid not null references users (id),
  recorded_at           timestamptz not null default now(),
  invoice_status_before text,
  invoice_status_after  text,
  voided_at             timestamptz,
  voided_by             uuid references users (id),
  void_reason           text,
  check ((target = 'owner_invoice') = (owner_invoice_id is not null)),
  check ((target = 'booking') = (booking_id is not null)),
  check ((voided_at is null) = (voided_by is null)),
  check (voided_at is null or nullif(btrim(void_reason), '') is not null),
  check (method <> 'other' or nullif(btrim(note), '') is not null)
);
create index manual_payments_invoice_idx on manual_payments (owner_invoice_id);
create index manual_payments_booking_idx on manual_payments (booking_id);
create index manual_payments_received_idx on manual_payments (received_on);
comment on table manual_payments is 'Payments received outside the card processor (e-Transfer, cheque, cash, bank transfer, other), recorded by an Admin or Finance (0044).';

-- 0029's offline payments become manual payments (the same rows, so they show and can be voided the same way).
insert into manual_payments (payment_id, target, owner_invoice_id, owner_id, method, amount_cents, received_on, reference, note, recorded_by, recorded_at,
                             invoice_status_after)
select p.id, 'owner_invoice', p.owner_invoice_id, p.owner_id, p.method, p.amount_cents,
       coalesce(nullif(d.raw ->> 'received_on', '')::date, app.local_date(coalesce(p.processed_at, p.created_at))),
       d.raw ->> 'reference', nullif(d.raw ->> 'note', ''), coalesce((d.raw ->> 'recorded_by')::uuid, p.created_by), p.created_at,
       (select i.status from owner_invoices i where i.id = p.owner_invoice_id)
  from payments p join payment_processor_details d on d.payment_id = p.id
 where d.processor = 'offline' and p.owner_invoice_id is not null and coalesce((d.raw ->> 'recorded_by')::uuid, p.created_by) is not null
   and p.method in ('e_transfer', 'cheque', 'cash', 'bank_transfer', 'other')
on conflict (payment_id) do nothing;

create or replace function app.payment_method_label(p_method text) returns text
language sql immutable as $$
  select case p_method when 'e_transfer' then 'e-Transfer' when 'cheque' then 'cheque' when 'cash' then 'cash' when 'bank_transfer' then 'bank transfer'
                       when 'card' then 'card' when 'pre_authorized_debit' then 'pre-authorized debit' when 'other' then 'another way' else p_method end
$$;

-- Who may record a payment of this amount: an Admin; Finance up to their single limit (the VA Agreement's Schedule A).
create or replace function app.manual_payment_allowed(p_by uuid, p_amount bigint) returns text
language sql stable security definer set search_path = public, app as $$
  select case
    when app.user_is_admin(p_by) then null
    when not app.user_va_has(p_by, 'finance') then 'Only an Admin or Finance records a payment received outside the card processor'
    when p_amount > coalesce((select sp.single_limit_cents from staff_profiles sp where sp.user_id = p_by), 0)
      then format('%s is above your single limit of %s: an Admin records it', app.fmt_money(p_amount),
                  app.fmt_money(coalesce((select sp.single_limit_cents from staff_profiles sp where sp.user_id = p_by), 0)))
  end
$$;

-- Record a payment received outside the processor.
-- p: {invoice | booking, method, amount_cents (default: the balance of the invoice), received_on, reference, note,
--     proof: {path, sha256, mime}, purpose (renter: what it paid), settles_payment (renter: the failed charge it settles)}
create or replace function app.record_manual_payment(p_by uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  i owner_invoices;
  b bookings;
  v_method text := coalesce(nullif(p ->> 'method', ''), 'e_transfer');
  v_ref text := nullif(btrim(coalesce(p ->> 'reference', '')), '');
  v_note text := nullif(btrim(coalesce(p ->> 'note', '')), '');
  v_on date := coalesce(nullif(p ->> 'received_on', '')::date, app.today());
  v_amount bigint := nullif(p ->> 'amount_cents', '')::bigint;
  v_refuse text;
  v_pay uuid;
  v_doc uuid;
  v_id uuid;
  v_before text;
  v_after text;
  v_settles payments;
  v_key text;
  v_purpose text;
begin
  if p_by is null then raise exception 'Sign in first' using errcode = '42501'; end if;
  if v_method not in ('e_transfer', 'cheque', 'cash', 'bank_transfer', 'other') then
    raise exception 'Choose how it was paid: e-Transfer, cheque, cash, bank transfer or another way' using errcode = '22023';
  end if;
  if v_method in ('e_transfer', 'cheque', 'bank_transfer') and (v_ref is null or length(v_ref) < 3) then
    raise exception '%', case v_method when 'cheque' then 'Enter the reference (the cheque number)' when 'e_transfer' then 'Enter the reference (the e-Transfer reference number)'
                                       else 'Enter the reference of the bank transfer' end using errcode = '22023';
  end if;
  if v_method = 'other' and v_note is null then raise exception 'Say how it was paid in the note' using errcode = '22023'; end if;
  if v_on > app.today() then raise exception 'The date received cannot be in the future' using errcode = '22023'; end if;
  if v_on < app.today() - 400 then raise exception 'The date received is more than a year ago: check it' using errcode = '22023'; end if;

  if nullif(p ->> 'invoice', '') is not null then
    select * into i from owner_invoices where id::text = p ->> 'invoice' or invoice_number = upper(btrim(p ->> 'invoice')) for update;
    if i.id is null then raise exception 'Invoice not found' using errcode = 'P0002'; end if;
    -- the same reference twice on one invoice is the same payment
    if v_ref is not null then
      select m.id into v_id from manual_payments m where m.owner_invoice_id = i.id and m.method = v_method and lower(m.reference) = lower(v_ref) and m.voided_at is null;
      if v_id is not null then
        if app.manual_payment_allowed(p_by, 1) is not null then raise exception '%', app.manual_payment_allowed(p_by, 1) using errcode = '42501'; end if;
        return jsonb_build_object('ok', true, 'repeat', true, 'id', v_id, 'invoice_status', i.status, 'balance_cents', i.balance_cents);
      end if;
    end if;
    v_amount := coalesce(v_amount, i.balance_cents);
    if v_amount is null or v_amount <= 0 then raise exception 'Enter the amount received' using errcode = '22023'; end if;
    v_refuse := app.manual_payment_allowed(p_by, v_amount);
    if v_refuse is not null then raise exception '%', v_refuse using errcode = '42501'; end if;
    if i.status in ('processing', 'retry_processing') then
      raise exception 'A debit of invoice % is processing: wait for its result before recording another payment', i.invoice_number using errcode = '23514';
    end if;
    if i.status not in ('issued', 'failed', 'in_arrears', 'partially_deducted') or i.balance_cents <= 0 then
      raise exception 'Invoice % is % and owes nothing', i.invoice_number, i.status using errcode = '23514';
    end if;
    v_before := i.status;
  elsif nullif(p ->> 'booking', '') is not null then
    select * into b from bookings where id::text = p ->> 'booking' or booking_number = upper(btrim(p ->> 'booking')) for update;
    if b.id is null then raise exception 'Booking not found' using errcode = 'P0002'; end if;
    if nullif(p ->> 'settles_payment', '') is not null then
      select * into v_settles from payments where id = (p ->> 'settles_payment')::uuid and booking_id = b.id for update;
      if v_settles.id is null then raise exception 'That charge is not on this booking' using errcode = 'P0002'; end if;
      if v_settles.status <> 'failed' then raise exception 'That charge is % and is not waiting for payment', v_settles.status using errcode = '23514'; end if;
      v_amount := coalesce(v_amount, v_settles.amount_cents);
    end if;
    if v_amount is null or v_amount <= 0 then raise exception 'Enter the amount received' using errcode = '22023'; end if;
    v_refuse := app.manual_payment_allowed(p_by, v_amount);
    if v_refuse is not null then raise exception '%', v_refuse using errcode = '42501'; end if;
    v_purpose := coalesce(nullif(p ->> 'purpose', ''), v_settles.purpose, 'post_rental');
    if v_purpose not in ('booking_total', 'extension', 'post_rental', 'toll_ticket', 'damage', 'deductible', 'other') then
      raise exception 'Unknown purpose %', v_purpose using errcode = '22023';
    end if;
    if v_ref is not null then
      select m.id into v_id from manual_payments m where m.booking_id = b.id and m.method = v_method and lower(m.reference) = lower(v_ref) and m.voided_at is null;
      if v_id is not null then return jsonb_build_object('ok', true, 'repeat', true, 'id', v_id); end if;
    end if;
  else
    raise exception 'Choose the invoice or the booking the payment is for' using errcode = '22023';
  end if;

  if p ? 'proof' and jsonb_typeof(p -> 'proof') = 'object' then
    if lower(coalesce(p #>> '{proof,sha256}', '')) !~ '^[0-9a-f]{64}$' or coalesce(p #>> '{proof,path}', '') !~ '^payments/' then
      raise exception 'The proof file is missing' using errcode = '22023';
    end if;
    insert into documents (kind, title, storage_bucket, storage_path, mime_type, sha256, uploaded_by)
    values ('receipt', format('Proof of payment, %s %s', app.payment_method_label(v_method), coalesce(i.invoice_number, b.booking_number)),
            'documents', p #>> '{proof,path}', p #>> '{proof,mime}', lower(p #>> '{proof,sha256}'), p_by)
    returning id into v_doc;
  end if;

  v_key := v_method || ':' || coalesce(v_ref, gen_random_uuid()::text);
  insert into payments (owner_id, owner_invoice_id, booking_id, renter_id, purpose, kind, method, amount_cents, status, processed_at, created_by)
  values (i.owner_id, i.id, b.id, b.renter_id,
          case when i.id is not null then case when i.kind = 'upfront' then 'owner_upfront' else 'owner_fees' end else v_purpose end,
          'charge', v_method, v_amount, 'succeeded', app.local_midnight(v_on) + interval '12 hours', p_by)
  returning id into v_pay;
  insert into payment_processor_details (payment_id, processor, processor_payment_id, raw)
  values (v_pay, 'offline', v_key, jsonb_strip_nulls(jsonb_build_object('reference', v_ref, 'received_on', v_on, 'note', v_note, 'recorded_by', p_by)));

  insert into manual_payments (payment_id, target, owner_invoice_id, booking_id, owner_id, renter_id, settles_payment_id, method, amount_cents, received_on,
                               reference, proof_document_id, note, recorded_by, invoice_status_before)
  values (v_pay, case when i.id is not null then 'owner_invoice' else 'booking' end, i.id, b.id, i.owner_id, b.renter_id, v_settles.id, v_method, v_amount, v_on,
          v_ref, v_doc, v_note, p_by, v_before)
  returning id into v_id;

  if i.id is not null then
    -- the receipt is this payment's own email (owner_payment_recorded), not the processor's "payment received"
    perform set_config('app.manual_payment', v_id::text, true);
    v_after := app.owner_invoice_apply_payment(i.id, v_amount, v_method, v_pay);
    perform set_config('app.manual_payment', '', true);
    select * into i from owner_invoices where id = i.id;
    update manual_payments set invoice_status_after = v_after where id = v_id;
    -- the automatic debit: nothing left, nothing debited; a smaller balance, a smaller debit (never more than the notice said)
    if i.status = 'paid' or i.balance_cents <= 0 then
      update owner_debit_attempts set status = 'canceled', skip_reason = format('paid by %s on %s', app.payment_method_label(v_method), app.fmt_day(v_on))
       where owner_invoice_id = i.id and status = 'scheduled';
      update owner_invoices set debit_on = null where id = i.id and debit_on is not null;
    else
      update owner_debit_attempts set amount_cents = i.balance_cents where owner_invoice_id = i.id and status = 'scheduled' and amount_cents > i.balance_cents;
    end if;
    perform app.ntf_emit('owner_payment_recorded', 'manual_payment', v_id, 'recorded',
      jsonb_build_object('owner_id', i.owner_id, 'vehicle_id', i.vehicle_id, 'owner_invoice_id', i.id));
  else
    if v_settles.id is not null then
      update payments set next_retry_at = null where id = v_settles.id;
      update tasks set status = 'done', completed_at = now(), completed_by = p_by, completion_note = 'Paid by ' || app.payment_method_label(v_method)
       where related_table = 'payments' and related_id = v_settles.id and status in ('open', 'in_progress', 'waiting');
    end if;
  end if;

  insert into audit_log (actor_user_id, action, entity_table, entity_id, before, after)
  values (p_by, 'record_manual_payment', case when i.id is not null then 'owner_invoices' else 'bookings' end, coalesce(i.id, b.id)::text,
          jsonb_build_object('status', coalesce(v_before, b.status::text)),
          jsonb_build_object('manual_payment_id', v_id, 'payment_id', v_pay, 'method', v_method, 'amount_cents', v_amount, 'received_on', v_on,
                             'reference', v_ref, 'status', coalesce(v_after, b.status::text), 'proof_document_id', v_doc, 'note', v_note));
  return jsonb_build_object('ok', true, 'id', v_id, 'payment_id', v_pay, 'invoice_status', v_after, 'balance_cents', i.balance_cents);
end $$;

-- Void a manual payment recorded by mistake (a bounced cheque, the wrong invoice). An Admin, with the reason. The
-- invoice goes back to what it owes; the owner is told. A paid upfront invoice gives back its prepaid months unless
-- they were used.
create or replace function app.void_manual_payment(p_by uuid, p_id uuid, p_reason text) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  m manual_payments;
  i owner_invoices;
  v_remaining bigint;
  v_due bigint;
  v_back text;
begin
  perform app.assert_admin(p_by);
  if nullif(btrim(coalesce(p_reason, '')), '') is null then raise exception 'Give the reason for voiding the payment' using errcode = '22023'; end if;
  select * into m from manual_payments where id = p_id for update;
  if m.id is null then raise exception 'Payment not found' using errcode = 'P0002'; end if;
  if m.voided_at is not null then raise exception 'This payment was already voided' using errcode = '23514'; end if;
  update payments set status = 'cancelled', last_decline_code = left('voided: ' || btrim(p_reason), 200) where id = m.payment_id;
  update manual_payments set voided_at = now(), voided_by = p_by, void_reason = left(btrim(p_reason), 500) where id = m.id;

  if m.owner_invoice_id is not null then
    select * into i from owner_invoices where id = m.owner_invoice_id for update;
    v_remaining := coalesce((select sum(p.amount_cents) from payments p where p.owner_invoice_id = i.id and p.status = 'succeeded' and p.kind = 'charge'), 0);
    v_due := i.fees_cents + i.hst_cents + i.late_fee_cents - i.deducted_cents;
    if i.status = 'paid' and v_remaining < v_due then
      if i.kind = 'upfront' then
        if exists (select 1 from vehicle_prepaids x where x.source_invoice_id = i.id and (x.applied_cents > 0 or x.refunded_cents > 0)) then
          raise exception 'The prepaid months of invoice % were already used: correct it with an adjustment instead', i.invoice_number using errcode = '23514';
        end if;
        delete from vehicle_prepaids where source_invoice_id = i.id;
        update vehicle_onboardings set status = 'documents_signed', upfront_paid_at = null where upfront_invoice_id = i.id and status = 'upfront_paid';
        update vehicle_onboardings set upfront_paid_at = null where upfront_invoice_id = i.id;
      end if;
      v_back := case when m.invoice_status_before in ('issued', 'failed', 'in_arrears', 'partially_deducted') then m.invoice_status_before else 'issued' end;
      update owner_invoices set status = v_back, paid_at = null, payment_method = default where id = i.id;
      update owner_invoices set paid_cents = least(v_remaining, greatest(v_due - 1, 0)) where id = i.id;
    elsif i.status <> 'paid' then
      update owner_invoices set paid_cents = greatest(paid_cents - m.amount_cents, 0) where id = i.id;
    end if;
    select * into i from owner_invoices where id = i.id;
    perform app.ntf_emit('owner_payment_reversed', 'manual_payment', m.id, 'voided',
      jsonb_build_object('owner_id', i.owner_id, 'vehicle_id', i.vehicle_id, 'owner_invoice_id', i.id));
  elsif m.settles_payment_id is not null then
    -- the failed charge it settled is owed again: Finance decides whether to retry the card
    perform app.raise_task(p_type => 'manual_payment_voided', p_title => 'A payment recorded by hand was voided: the charge is owed again',
      p_detail => format('%s by %s on %s, voided: %s', app.fmt_money(m.amount_cents), app.payment_method_label(m.method), app.fmt_day(m.received_on), btrim(p_reason)),
      p_booking => m.booking_id, p_related_table => 'payments', p_related_id => m.settles_payment_id, p_queue => 'finance',
      p_dedupe => 'manual_payment_voided:' || m.id);
  end if;
  insert into audit_log (actor_user_id, action, entity_table, entity_id, before, after)
  values (p_by, 'void_manual_payment', 'manual_payments', m.id::text, jsonb_build_object('payment_id', m.payment_id, 'amount_cents', m.amount_cents, 'method', m.method),
          jsonb_build_object('reason', btrim(p_reason), 'invoice_status', i.status, 'balance_cents', i.balance_cents));
  return jsonb_build_object('ok', true, 'id', m.id, 'invoice_status', i.status, 'balance_cents', i.balance_cents);
end $$;

-- 0029's Admin path for an offline payment now records a manual payment (same signature).
create or replace function app.record_owner_offline_payment(p_invoice uuid, p_admin uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  r jsonb;
begin
  if not app.user_is_admin(p_admin) then
    raise exception 'Only an Admin records a payment received outside the card processor' using errcode = '42501';
  end if;
  r := app.record_manual_payment(p_admin, coalesce(p, '{}'::jsonb) || jsonb_build_object('invoice', p_invoice));
  return jsonb_build_object('ok', true, 'repeat', coalesce((r ->> 'repeat')::boolean, false), 'payment_id',
                            coalesce(r ->> 'payment_id', (select m.payment_id::text from manual_payments m where m.id = (r ->> 'id')::uuid)),
                            'invoice_status', coalesce(r ->> 'invoice_status', (select i.status from owner_invoices i where i.id = p_invoice)),
                            'manual_payment_id', r ->> 'id');
end $$;

-- The manual payments of one invoice or booking, as the portals and Admin show them.
create or replace function app.manual_payments_json(p_invoice uuid, p_booking uuid default null, p_staff boolean default false) returns jsonb
language sql stable security definer set search_path = public, app as $$
  select coalesce(jsonb_agg(jsonb_build_object('id', m.id, 'payment_id', m.payment_id, 'method', m.method, 'method_label', app.payment_method_label(m.method),
           'amount_cents', m.amount_cents, 'received_on', m.received_on, 'reference', m.reference, 'voided_at', m.voided_at,
           'void_reason', case when p_staff then m.void_reason end, 'note', case when p_staff then m.note end,
           'proof_document_id', case when p_staff then m.proof_document_id end, 'recorded_at', m.recorded_at,
           'recorded_by_name', case when p_staff then (select u.full_name from users u where u.id = m.recorded_by) end)
           order by m.received_on desc, m.recorded_at desc), '[]'::jsonb)
    from manual_payments m where (p_invoice is not null and m.owner_invoice_id = p_invoice) or (p_booking is not null and m.booking_id = p_booking)
$$;

-- The owner's invoice shows each payment recorded by hand and, when paid, how: "Paid by e-Transfer on <date>".
alter function app.owner_invoice_view(uuid) rename to owner_invoice_view_0037;
create or replace function app.owner_invoice_view(p_invoice uuid) returns jsonb
language sql stable security definer set search_path = public, app as $$
  select app.owner_invoice_view_0037(p_invoice) || jsonb_build_object(
    'manual', app.manual_payments_json(p_invoice),
    'paid_by', (select case when i.status = 'paid' then
                  (select format('Paid by %s on %s', app.payment_method_label(p.method),
                                 app.fmt_day(coalesce(m.received_on, app.local_date(coalesce(p.processed_at, i.paid_at)))))
                     from payments p left join manual_payments m on m.payment_id = p.id
                    where p.owner_invoice_id = i.id and p.status = 'succeeded' and p.kind = 'charge'
                    order by coalesce(m.received_on, app.local_date(coalesce(p.processed_at, p.created_at))) desc, p.created_at desc limit 1) end
                  from owner_invoices i where i.id = p_invoice),
    'partly_paid', (select i.status <> 'paid' and i.paid_cents > 0 from owner_invoices i where i.id = p_invoice))
$$;

-- The owner invoice emails of 0023 and 0037: a payment recorded by hand sends its own receipt (owner_payment_recorded),
-- so "payment received" is not sent for it as well. Same trigger function, same behaviour otherwise.
create or replace function app.ntf_owner_invoices_after() returns trigger
language plpgsql security definer set search_path = public, app as $$
declare
  pl jsonb := jsonb_build_object('owner_id', new.owner_id, 'vehicle_id', new.vehicle_id);
  v_att text := nullif(current_setting('app.debit_attempt_no', true), '');
begin
  if tg_op = 'UPDATE' and new.status is not distinct from old.status then return null; end if;
  if new.status = 'issued' and new.kind = 'upfront' and (tg_op = 'INSERT' or old.status = 'draft') then
    perform app.ntf_emit('owner_upfront_invoice', 'owner_invoice', new.id, 'issued', pl);
  elsif new.status = 'issued' and new.kind = 'monthly' and (tg_op = 'INSERT' or old.status = 'draft') then
    perform app.ntf_emit('owner_fee_invoice', 'owner_invoice', new.id, 'issued', pl);
  elsif new.status = 'paid' then
    if nullif(current_setting('app.manual_payment', true), '') is null then
      perform app.ntf_emit('owner_payment_received', 'owner_invoice', new.id, 'paid', pl);
    end if;
  elsif new.status = 'failed' then
    if tg_op = 'UPDATE' and old.status = 'paid' then return null; end if;   -- a voided manual payment (its own email)
    if coalesce(current_setting('app.debit_no_retry', true), '') = new.id::text then return null; end if;
    perform app.ntf_emit('owner_payment_failed', 'owner_invoice', new.id, 'failed' || case when coalesce(v_att, '1') <> '1' then ':' || v_att else '' end, pl);
    perform app.ntf_emit('staff_owner_invoice_failed', 'owner_invoice', new.id, 'failed' || case when coalesce(v_att, '1') <> '1' then ':' || v_att else '' end, pl);
  elsif new.status = 'in_arrears' then
    if tg_op = 'UPDATE' and old.status = 'paid' then return null; end if;
    perform app.ntf_emit('owner_in_arrears', 'owner_invoice', new.id, 'in_arrears', pl);
    perform app.ntf_emit('staff_owner_invoice_failed', 'owner_invoice', new.id, 'in_arrears',
                         pl || jsonb_build_object('_immediate_roles', jsonb_build_array('staff_admin')));
  end if;
  return null;
end $$;

-- Payments recorded by hand in a month, for reconciliation against the bank (Admin > Reconciliation, Finance).
create or replace function app.manual_payments_month(p_by uuid, p_month date) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare
  m0 date := date_trunc('month', coalesce(p_month, app.today()))::date;
begin
  if not app.user_runs_finance(p_by) then raise exception 'Not permitted' using errcode = '42501'; end if;
  return jsonb_build_object('month', m0,
    'rows', coalesce((select jsonb_agg(jsonb_build_object('id', m.id, 'received_on', m.received_on, 'method', m.method, 'method_label', app.payment_method_label(m.method),
                 'amount_cents', m.amount_cents, 'reference', m.reference, 'target', m.target,
                 'invoice_number', (select i.invoice_number from owner_invoices i where i.id = m.owner_invoice_id),
                 'booking_number', (select x.booking_number from bookings x where x.id = m.booking_id),
                 'payer', coalesce((select o.legal_name from owners o where o.id = m.owner_id), (select r.legal_name from renters r where r.id = m.renter_id)),
                 'voided_at', m.voided_at, 'void_reason', m.void_reason, 'recorded_by_name', (select u.full_name from users u where u.id = m.recorded_by))
                 order by m.received_on, m.recorded_at)
               from manual_payments m where m.received_on >= m0 and m.received_on < (m0 + interval '1 month')::date), '[]'::jsonb),
    'totals', coalesce((select jsonb_object_agg(x.method, x.total) from (select method, sum(amount_cents) total from manual_payments
                         where voided_at is null and received_on >= m0 and received_on < (m0 + interval '1 month')::date group by method) x), '{}'::jsonb));
end $$;

-- ================================================================ 3. signatures: on paper, and in the portals
alter table documents add column if not exists staff_user_id uuid references users (id);
create index if not exists documents_staff_user_idx on documents (staff_user_id);
comment on column documents.staff_user_id is 'A staff member''s own document (their agreement), readable by them and the Admins (0044).';

-- How a form was signed: uploaded by the owner after signing with witnesses, signed on screen, or recorded on paper.
alter table owner_agreement_forms add column if not exists signed_method text check (signed_method in ('upload', 'screen', 'paper'));
update owner_agreement_forms set signed_method = 'upload' where signed_method is null and status in ('uploaded', 'approved', 'rejected', 'replaced');
create unique index if not exists owner_agreement_forms_one_live_ab on owner_agreement_forms (owner_id, form_code)
  where status in ('uploaded', 'approved') and form_code in ('A', 'B');
alter table government_form_fills add column if not exists signed_method text check (signed_method in ('portal', 'paper'));
update government_form_fills set signed_method = 'portal' where signed_method is null and status in ('signed', 'filed') and document_id is not null;

-- ---------------------------------------------------------------- documents sent to one person to sign in their portal
-- Forms A and B (the owner opens them; the server renders the PDF), investment agreements (the investor portal) and
-- staff agreements (the staff and field portals), which an Admin sends as a PDF. A new version voids the one before.
create sequence if not exists investment_agreement_number_seq start 1001;

create table sign_requests (
  id                      uuid primary key default gen_random_uuid(),
  doc_type                text not null check (doc_type in ('form_a', 'form_b', 'investment_agreement', 'staff_agreement')),
  owner_id                uuid references owners (id),
  investor_id             uuid references investors (id),
  investment_agreement_id uuid references investment_agreements (id),
  staff_user_id           uuid references users (id),
  signer_user_id          uuid references users (id),
  signer_name             text not null,
  signer_email            text,
  signer_role             text not null check (signer_role in ('owner_individual', 'owner_corporation', 'investor', 'staff')),
  title                   text not null,
  document_id             uuid not null references documents (id),
  document_sha256         text not null check (document_sha256 ~ '^[0-9a-f]{64}$'),
  template_version        text,
  signature_request_id    uuid not null unique references signature_requests (id),
  status                  text not null default 'sent' check (status in ('sent', 'signed', 'voided')),
  method                  text check (method in ('typed', 'drawn', 'paper')),
  signature_record_id     uuid references signature_records (id),
  signed_at               timestamptz,
  signed_document_id      uuid references documents (id),     -- the signature record page (or the scan)
  extra                   jsonb not null default '{}'::jsonb, -- investment: exemption category, legal advice choice
  sent_by                 uuid references users (id),
  sent_at                 timestamptz not null default now(),
  voided_at               timestamptz,
  voided_by               uuid references users (id),
  void_reason             text,
  check (status <> 'signed' or (signed_at is not null and method is not null)),
  check (status <> 'voided' or (voided_at is not null and nullif(btrim(void_reason), '') is not null)),
  check (doc_type not in ('form_a', 'form_b') or owner_id is not null),
  check (doc_type <> 'investment_agreement' or investor_id is not null),
  check (doc_type <> 'staff_agreement' or staff_user_id is not null)
);
create unique index sign_requests_one_open on sign_requests (doc_type, coalesce(owner_id, investor_id, staff_user_id)) where status = 'sent';
create index sign_requests_signer_idx on sign_requests (signer_user_id, status);
comment on table sign_requests is 'A document one person signs in their portal with the built-in signature (0044): Forms A and B, investment agreements, staff agreements.';

-- ---------------------------------------------------------------- what was signed on paper
create table paper_signatures (
  id               uuid primary key default gen_random_uuid(),
  doc_type         text not null check (doc_type in ('owner_agreement', 'debit_agreement', 'form_a', 'form_b', 'form_c', 'form_d', 'registry_form',
                                                     'rental_agreement', 'rental_amendment', 'investment_agreement', 'staff_agreement')),
  target_id        uuid not null,     -- owner (owner_agreement, debit_agreement, form_a, form_b, form_d), vehicle (form_c), form fill (registry_form),
                                      -- booking (rental_agreement), change request (rental_amendment), investor, staff user
  owner_id         uuid references owners (id),
  vehicle_id       uuid references vehicles (id),
  booking_id       uuid references bookings (id),
  renter_id        uuid references renters (id),
  investor_id      uuid references investors (id),
  staff_user_id    uuid references users (id),
  document_id      uuid not null references documents (id),   -- the scan, stored privately in the person's documents
  signer_name      text not null check (length(btrim(signer_name)) between 2 and 200),
  signed_on        date not null,
  witness_1_name   text,
  witness_2_name   text,
  note             text,
  effect           jsonb not null default '{}'::jsonb,        -- what was changed, so a void can put it back
  recorded_by      uuid not null references users (id),
  recorded_at      timestamptz not null default now(),
  voided_at        timestamptz,
  voided_by        uuid references users (id),
  void_reason      text,
  check ((voided_at is null) = (voided_by is null)),
  check (voided_at is null or nullif(btrim(void_reason), '') is not null)
);
create index paper_signatures_target_idx on paper_signatures (doc_type, target_id) where voided_at is null;
create index paper_signatures_owner_idx on paper_signatures (owner_id);
comment on table paper_signatures is 'Documents signed on paper, with the scan, the signer, the date and the witnesses (0044). Voidable with a reason.';

create or replace function app.paper_doc_kind(p_type text) returns text
language sql immutable as $$
  select case p_type when 'owner_agreement' then 'enrollment_agreement' when 'form_a' then 'form_a_trust_declaration' when 'form_b' then 'form_b_lease_summary'
                     when 'form_c' then 'form_c_finance_permission_ack' when 'form_d' then 'form_d_power_of_attorney' when 'registry_form' then 'registry_form'
                     when 'rental_agreement' then 'rental_agreement' when 'rental_amendment' then 'rental_amendment'
                     when 'investment_agreement' then 'investment_agreement' when 'staff_agreement' then 'staff_agreement' else 'other' end
$$;

create or replace function app.paper_doc_title(p_type text) returns text
language sql immutable as $$
  select case p_type when 'owner_agreement' then 'Owner agreements and schedules' when 'debit_agreement' then 'Pre-authorized debit agreement'
                     when 'form_a' then 'Form A, trust declaration' when 'form_b' then 'Form B, lease summary'
                     when 'form_c' then 'Form C, lender or lessor permission acknowledgment' when 'form_d' then 'Form D, limited power of attorney'
                     when 'registry_form' then 'Registry form' when 'rental_agreement' then 'Rental agreement' when 'rental_amendment' then 'Booking amendment'
                     when 'investment_agreement' then 'Investment agreement' when 'staff_agreement' then 'Staff agreement' else 'Document' end
$$;

-- How a signature request was signed: 'paper' or 'portal' (typed or drawn on screen), from its first signer that is not CarmaCars.
create or replace function app.request_method(p_request uuid) returns text
language sql stable security definer set search_path = public, app as $$
  select case r.method when 'paper' then 'paper' when 'typed' then 'portal' when 'drawn' then 'portal' else r.method end
    from signature_records r where r.signature_request_id = p_request and r.signer_role not in ('carmacars', 'witness') and r.status = 'signed'
   order by r.signed_at limit 1
$$;

-- A paper signature record: the signer (and witnesses), method paper, on the date signed (noon, Toronto).
create or replace function app.paper_records(p_request uuid, p_role text, p_user uuid, p_name text, p_email text, p_on date, p_doc uuid, p_sha text,
                                             p_w1 text default null, p_w2 text default null) returns uuid
language plpgsql security definer set search_path = public, app as $$
declare
  v_rec uuid;
  v_at timestamptz := app.local_midnight(p_on) + interval '12 hours';
begin
  insert into signature_records (signature_request_id, signer_role, signer_user_id, signer_name, signer_email, status, signed_at, method,
                                 provider_signature, typed_name, consent_text, document_sha256)
  values (p_request, p_role, p_user, p_name, p_email, 'signed', v_at, 'paper', p_doc::text, p_name,
          'Signed on paper. The signed copy was scanned and is kept with this record.', p_sha)
  returning id into v_rec;
  if nullif(btrim(coalesce(p_w1, '')), '') is not null then
    insert into signature_records (signature_request_id, signer_role, signer_name, status, signed_at, method, typed_name, consent_text, document_sha256)
    values (p_request, 'witness', btrim(p_w1), 'signed', v_at, 'paper', btrim(p_w1), 'Witnessed the signature on paper.', p_sha);
  end if;
  if nullif(btrim(coalesce(p_w2, '')), '') is not null then
    insert into signature_records (signature_request_id, signer_role, signer_name, status, signed_at, method, typed_name, consent_text, document_sha256)
    values (p_request, 'witness', btrim(p_w2), 'signed', v_at, 'paper', btrim(p_w2), 'Witnessed the signature on paper.', p_sha);
  end if;
  return v_rec;
end $$;

-- Move an owner's vehicles whose agreements and schedules are now all signed (0029's rule, shared by paper and portal).
create or replace function app.owner_vehicles_signed(p_owner uuid) returns uuid[]
language plpgsql security definer set search_path = public, app as $$
declare
  r record;
  v_moved uuid[] := '{}';
begin
  for r in
    select ob.id, ob.status, v.billing_case, ob.upfront_invoice_id, ob.upfront_paid_at
      from vehicles v join vehicle_onboardings ob on ob.vehicle_id = v.id
      join vehicle_schedules s on s.vehicle_id = v.id and s.superseded_by is null
     where v.owner_id = p_owner and s.signed_at is not null and ob.status in ('terms_set', 'documents_sent')
       and exists (select 1 from owner_agreements e where e.owner_id = p_owner and e.kind = 'enrollment' and e.status = 'signed')
       and (v.management_mode = 'turo_only'
            or exists (select 1 from owner_agreements t where t.owner_id = p_owner and t.kind = 'title_holding' and t.status = 'signed'))
  loop
    if r.status = 'terms_set' then
      update vehicle_onboardings set status = 'documents_sent', documents_sent_at = coalesce(documents_sent_at, now()) where id = r.id;
    end if;
    update vehicle_onboardings set status = 'documents_signed', documents_signed_at = coalesce(documents_signed_at, now()) where id = r.id;
    if r.billing_case in ('managed', 'self_managed')
       and (r.upfront_paid_at is not null or exists (select 1 from owner_invoices i where i.id = r.upfront_invoice_id and i.status = 'paid')) then
      update vehicle_onboardings set status = 'upfront_paid', upfront_paid_at = coalesce(upfront_paid_at, now()) where id = r.id;
    end if;
    v_moved := v_moved || r.id;
  end loop;
  return v_moved;
end $$;

-- Which of Forms A and B an owner needs: A for any car under the Co-Registrant or Transfer method, B for any car under a
-- Lease method (the Title-Holding Agreement, 4.8 and 5.1). Each is signed once and covers every such car.
create or replace function app.owner_screen_forms(p_owner uuid) returns jsonb
language sql stable security definer set search_path = public, app as $$
  with need as (
    select 'A'::text as code where exists (select 1 from vehicles v join vehicle_schedules s on s.vehicle_id = v.id and s.superseded_by is null
                                            where v.owner_id = p_owner and s.onboarding_method in ('co_registrant', 'transfer')
                                              and v.status not in ('exited', 'declined', 'total_loss'))
    union all
    select 'B' where exists (select 1 from vehicles v join vehicle_schedules s on s.vehicle_id = v.id and s.superseded_by is null
                              where v.owner_id = p_owner and s.onboarding_method in ('lease_existing_corporation', 'lease_new_owner_corporation')
                                and v.status not in ('exited', 'declined', 'total_loss'))
  )
  select coalesce(jsonb_agg(jsonb_build_object(
      'code', n.code, 'title', case n.code when 'A' then 'Form A, trust declaration' else 'Form B, lease summary' end,
      'status', case when f.id is not null then 'signed' else 'needed' end, 'form_id', f.id, 'document_id', f.document_id,
      'signed_at', f.signed_at, 'method', f.signed_method,
      'open_request', (select r.id from sign_requests r where r.owner_id = p_owner and r.doc_type = 'form_' || lower(n.code) and r.status = 'sent'))
      order by n.code), '[]'::jsonb)
    from need n
    left join lateral (select * from owner_agreement_forms x where x.owner_id = p_owner and x.form_code = n.code and x.status = 'approved'
                        order by x.reviewed_at desc limit 1) f on true
$$;

-- What the Form A or B PDF prints (the server renders it): the owner, the cars it covers, the agreement it belongs to.
create or replace function app.owner_form_ab_facts(p_owner uuid, p_code text) returns jsonb
language sql stable security definer set search_path = public, app as $$
  select jsonb_build_object(
    'code', p_code, 'owner_id', o.id,
    'owner', jsonb_build_object('legal_name', o.legal_name, 'owner_type', o.owner_type, 'corporation_name', o.corporation_name,
               'signer_name', case when o.owner_type = 'corporation' then coalesce(o.signing_officer_name, o.legal_name) else o.legal_name end,
               'address', concat_ws(', ', nullif(o.address_line1, ''), nullif(o.city, ''), nullif(o.province, ''), nullif(o.postal_code, ''))),
    'vehicles', coalesce((select jsonb_agg(jsonb_build_object('name', app.vehicle_name(v.id), 'vin', upper(v.vin), 'plate', v.plate,
                                   'method', s.onboarding_method, 'title_status', s.title_status) order by v.created_at)
                            from vehicles v join vehicle_schedules s on s.vehicle_id = v.id and s.superseded_by is null
                           where v.owner_id = o.id and v.status not in ('exited', 'declined', 'total_loss')
                             and ((p_code = 'A' and s.onboarding_method in ('co_registrant', 'transfer'))
                               or (p_code = 'B' and s.onboarding_method in ('lease_existing_corporation', 'lease_new_owner_corporation')))), '[]'::jsonb),
    'title_agreement', (select a.agreement_number from owner_agreements a where a.owner_id = o.id and a.kind = 'title_holding' and a.status <> 'void'
                         order by a.created_at desc limit 1),
    'company', app.doc_company_brand())
    from owners o where o.id = p_owner
$$;

-- The owner opens Form A or B for signature: the server rendered and stored it. The same document returns the open request.
create or replace function app.owner_form_ab_open(p_by uuid, p_code text, p_sha256 text, p_path text, p_template_version text) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  o owners;
  v_owner uuid := app.portal_owner_id(p_by);
  r sign_requests;
  v_doc uuid;
  v_req uuid;
begin
  select * into o from owners where id = v_owner;
  if p_code not in ('A', 'B') then raise exception 'Choose Form A or Form B' using errcode = '22023'; end if;
  if not exists (select 1 from jsonb_array_elements(app.owner_screen_forms(o.id)) x where x ->> 'code' = p_code and x ->> 'status' = 'needed') then
    raise exception 'That form is not waiting for your signature' using errcode = '23514';
  end if;
  if lower(coalesce(p_sha256, '')) !~ '^[0-9a-f]{64}$' or coalesce(p_path, '') !~ ('^owners/' || o.id || '/') then
    raise exception 'The form document is missing' using errcode = '22023';
  end if;
  select * into r from sign_requests where owner_id = o.id and doc_type = 'form_' || lower(p_code) and status = 'sent' for update;
  if r.id is not null and r.document_sha256 = lower(p_sha256) then return to_jsonb(r); end if;
  if r.id is not null then
    update sign_requests set status = 'voided', voided_at = now(), voided_by = p_by, void_reason = 'The form was made again' where id = r.id;
    update signature_requests set status = 'voided' where id = r.signature_request_id;
  end if;
  insert into documents (kind, title, storage_bucket, storage_path, mime_type, sha256, template_version, owner_id, uploaded_by)
  values (case p_code when 'A' then 'form_a_trust_declaration' else 'form_b_lease_summary' end::document_kind,
          case p_code when 'A' then 'Form A, trust declaration' else 'Form B, lease summary' end, 'agreements', p_path, 'application/pdf',
          lower(p_sha256), p_template_version, o.id, p_by)
  returning id into v_doc;
  insert into signature_requests (document_id, provider, status, sent_at, created_by) values (v_doc, 'builtin', 'sent', now(), p_by) returning id into v_req;
  insert into sign_requests (doc_type, owner_id, signer_user_id, signer_name, signer_email, signer_role, title, document_id, document_sha256, template_version,
                             signature_request_id, sent_by)
  values ('form_' || lower(p_code), o.id, p_by, case when o.owner_type = 'corporation' then coalesce(o.signing_officer_name, o.legal_name) else o.legal_name end,
          o.email, case when o.owner_type = 'corporation' then 'owner_corporation' else 'owner_individual' end,
          case p_code when 'A' then 'Form A, trust declaration' else 'Form B, lease summary' end, v_doc, lower(p_sha256), p_template_version, v_req, p_by)
  returning * into r;
  return to_jsonb(r);
end $$;

-- What follows a signed investment agreement (portal or paper): the agreement is signed by the investor, with its
-- schedules (the signed document carries them) and the choices; CarmaCars is bound once it has cleared funds and signs.
create or replace function app.investment_signed(p_agreement uuid, p_doc uuid, p_request uuid, p_extra jsonb) returns void
language plpgsql security definer set search_path = public, app as $$
declare
  a investment_agreements;
begin
  select * into a from investment_agreements where id = p_agreement for update;
  if coalesce(p_extra ->> 'legal_advice_choice', a.legal_advice_choice, '') not in ('obtained', 'declined') then
    raise exception 'Say whether independent legal advice was obtained or declined' using errcode = '22023';
  end if;
  if coalesce(p_extra ->> 'exemption_category', a.exemption_category, '') not in ('accredited_investor', 'offering_memorandum_eligible') then
    raise exception 'Choose the prospectus exemption (accredited investor or offering memorandum)' using errcode = '22023';
  end if;
  update investment_agreements
     set status = 'signed', document_id = coalesce(p_doc, document_id), signature_request_id = coalesce(p_request, signature_request_id),
         schedule_c_document_id = coalesce(schedule_c_document_id, p_doc, document_id), schedule_d_document_id = coalesce(schedule_d_document_id, p_doc, document_id),
         legal_advice_choice = coalesce(p_extra ->> 'legal_advice_choice', legal_advice_choice),
         legal_adviser = coalesce(nullif(btrim(p_extra ->> 'legal_adviser'), ''), legal_adviser),
         exemption_category = coalesce(p_extra ->> 'exemption_category', exemption_category),
         exemption_paragraph = coalesce(nullif(btrim(p_extra ->> 'exemption_paragraph'), ''), exemption_paragraph)
   where id = a.id;
end $$;

-- An Admin sends a document to sign: an investment agreement to an investor, or a staff agreement to a staff member.
-- The PDF is already stored privately by the server. A new version voids the one before.
-- p: {doc_type, investor_id | staff_user_id, title, document: {path, sha256}, exemption_category, exemption_paragraph}
create or replace function app.sign_request_create(p_by uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  v_type text := p ->> 'doc_type';
  inv investors;
  u users;
  a investment_agreements;
  r sign_requests;
  v_doc uuid;
  v_req uuid;
  v_title text := nullif(btrim(coalesce(p ->> 'title', '')), '');
begin
  perform app.assert_admin(p_by);
  if v_type not in ('investment_agreement', 'staff_agreement') then raise exception 'Choose the kind of document' using errcode = '22023'; end if;
  if lower(coalesce(p #>> '{document,sha256}', '')) !~ '^[0-9a-f]{64}$' or coalesce(p #>> '{document,path}', '') !~ '^(investors|staff)/' then
    raise exception 'The PDF is missing' using errcode = '22023';
  end if;
  if v_type = 'investment_agreement' then
    select * into inv from investors where id = (p ->> 'investor_id')::uuid;
    if inv.id is null then raise exception 'Investor not found' using errcode = 'P0002'; end if;
    if inv.user_id is null then raise exception 'Invite % to the investor portal first: they sign there', inv.legal_name using errcode = '23514'; end if;
    if coalesce(p ->> 'exemption_category', '') not in ('accredited_investor', 'offering_memorandum_eligible') then
      raise exception 'Choose the prospectus exemption (accredited investor or offering memorandum)' using errcode = '22023';
    end if;
    select * into a from investment_agreements where investor_id = inv.id and status in ('draft', 'sent', 'signed') for update;
    if a.status = 'signed' then raise exception 'The agreement of % is already signed', inv.legal_name using errcode = '23514'; end if;
    if a.id is null then
      insert into investment_agreements (investor_id, agreement_number, status)
      values (inv.id, 'IA-' || nextval('investment_agreement_number_seq'), 'draft') returning * into a;
    end if;
    select * into u from users where id = inv.user_id;
    v_title := coalesce(v_title, 'Investment agreement ' || a.agreement_number);
  else
    select * into u from users where id = (p ->> 'staff_user_id')::uuid;
    if u.id is null or not exists (select 1 from staff_profiles sp where sp.user_id = u.id) then raise exception 'Staff member not found' using errcode = 'P0002'; end if;
    v_title := coalesce(v_title, 'Staff agreement');
  end if;
  for r in select * from sign_requests where status = 'sent' and doc_type = v_type
             and ((v_type = 'investment_agreement' and investor_id = inv.id) or (v_type = 'staff_agreement' and staff_user_id = u.id)) for update loop
    update sign_requests set status = 'voided', voided_at = now(), voided_by = p_by, void_reason = 'A new version was sent' where id = r.id;
    update signature_requests set status = 'voided' where id = r.signature_request_id;
  end loop;
  insert into documents (kind, title, storage_bucket, storage_path, mime_type, sha256, investor_id, staff_user_id, uploaded_by)
  values (v_type::document_kind, v_title, 'agreements', p #>> '{document,path}', 'application/pdf', lower(p #>> '{document,sha256}'),
          inv.id, case when v_type = 'staff_agreement' then u.id end, p_by)
  returning id into v_doc;
  insert into signature_requests (document_id, provider, status, sent_at, created_by) values (v_doc, 'builtin', 'sent', now(), p_by) returning id into v_req;
  insert into sign_requests (doc_type, investor_id, investment_agreement_id, staff_user_id, signer_user_id, signer_name, signer_email, signer_role, title,
                             document_id, document_sha256, signature_request_id, extra, sent_by)
  values (v_type, inv.id, a.id, case when v_type = 'staff_agreement' then u.id end, u.id, coalesce(inv.legal_name, u.full_name, u.email), u.email,
          case when v_type = 'investment_agreement' then 'investor' else 'staff' end, v_title, v_doc, lower(p #>> '{document,sha256}'), v_req,
          jsonb_strip_nulls(jsonb_build_object('exemption_category', p ->> 'exemption_category', 'exemption_paragraph', nullif(btrim(p ->> 'exemption_paragraph'), ''))),
          p_by)
  returning * into r;
  if a.id is not null then
    update investment_agreements set status = 'sent', document_id = v_doc, signature_request_id = v_req,
           exemption_category = p ->> 'exemption_category', exemption_paragraph = coalesce(nullif(btrim(p ->> 'exemption_paragraph'), ''), exemption_paragraph)
     where id = a.id;
  end if;
  insert into notifications (user_id, code, title, body, url, dedupe_key)
  values (u.id, 'person_document_to_sign', 'A document is ready for you to sign', v_title || '. Read it and sign it in your portal.',
          (app.settings()).notify_base_url || case when v_type = 'investment_agreement' then '/investor/sign' when app.user_is_field(u.id) and not app.user_is_staff(u.id) then '/field/sign' else '/va/sign' end,
          'person_document_to_sign:' || r.id)
  on conflict (dedupe_key) do nothing;
  insert into audit_log (actor_user_id, action, entity_table, entity_id, after)
  values (p_by, 'sign_request_create', 'sign_requests', r.id::text, jsonb_build_object('doc_type', v_type, 'signer', r.signer_name, 'title', v_title));
  return to_jsonb(r);
end $$;

-- An Admin withdraws a document sent to sign (sent by mistake, or replaced another way).
create or replace function app.sign_request_void(p_by uuid, p_id uuid, p_reason text) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  r sign_requests;
begin
  perform app.assert_admin(p_by);
  if nullif(btrim(coalesce(p_reason, '')), '') is null then raise exception 'Give the reason' using errcode = '22023'; end if;
  select * into r from sign_requests where id = p_id for update;
  if r.id is null then raise exception 'Not found' using errcode = 'P0002'; end if;
  if r.status <> 'sent' then raise exception 'This document is % and cannot be withdrawn', r.status using errcode = '23514'; end if;
  update sign_requests set status = 'voided', voided_at = now(), voided_by = p_by, void_reason = btrim(p_reason) where id = r.id;
  update signature_requests set status = 'voided' where id = r.signature_request_id;
  update investment_agreements set status = 'draft' where id = r.investment_agreement_id and status = 'sent';
  return jsonb_build_object('id', r.id, 'status', 'voided');
end $$;

-- The person's documents to sign and those they signed (their portal: investor, staff, field; Forms A and B for owners).
create or replace function app.my_sign_requests(p_user uuid) returns jsonb
language sql stable security definer set search_path = public, app as $$
  select jsonb_build_object(
    'open', coalesce((select jsonb_agg(jsonb_build_object('id', r.id, 'doc_type', r.doc_type, 'title', r.title, 'document_id', r.document_id, 'sent_at', r.sent_at,
                        'signer_name', r.signer_name, 'extra', r.extra) order by r.sent_at)
                      from sign_requests r where r.signer_user_id = p_user and r.status = 'sent' and r.doc_type in ('investment_agreement', 'staff_agreement')), '[]'::jsonb),
    'signed', coalesce((select jsonb_agg(x order by x ->> 'signed_on' desc) from (
        select jsonb_build_object('id', r.id, 'doc_type', r.doc_type, 'title', r.title, 'document_id', r.document_id, 'signed_document_id', r.signed_document_id,
                                  'method', r.method, 'signed_on', app.local_date(r.signed_at)) x
          from sign_requests r where r.signer_user_id = p_user and r.status = 'signed' and r.doc_type in ('investment_agreement', 'staff_agreement')
        union all
        select jsonb_build_object('id', ps.id, 'doc_type', ps.doc_type, 'title', app.paper_doc_title(ps.doc_type) || ', signed on paper', 'document_id', ps.document_id,
                                  'method', 'paper', 'signed_on', ps.signed_on)
          from paper_signatures ps
         where ps.voided_at is null and ps.doc_type in ('investment_agreement', 'staff_agreement')
           and (ps.staff_user_id = p_user or ps.investor_id in (select i.id from investors i where i.user_id = p_user))
           and not exists (select 1 from sign_requests r2 where r2.signature_record_id is not null and r2.status = 'signed' and r2.method = 'paper'
                              and (ps.effect ->> 'sign_request_id') = r2.id::text)) q), '[]'::jsonb))
$$;

-- One document to sign, for its page: only its signer reads it.
create or replace function app.sign_request_facts(p_user uuid, p_id uuid) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare
  r sign_requests;
begin
  select * into r from sign_requests where id = p_id;
  if r.id is null or r.signer_user_id is distinct from p_user then raise exception 'Not found' using errcode = 'P0002'; end if;
  return to_jsonb(r) || jsonb_build_object(
    'document', (select jsonb_build_object('bucket', d.storage_bucket, 'path', d.storage_path) from documents d where d.id = r.document_id),
    'agreement_number', (select a.agreement_number from investment_agreements a where a.id = r.investment_agreement_id));
end $$;

-- The person signs (typed name or drawn signature) the document they read, in their portal.
-- p: {typed_name, drawn_signature (stored path), ip, user_agent, consent_text, document_sha256, legal_advice_choice, legal_adviser, initials}
create or replace function app.sign_request_sign(p_user uuid, p_id uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  r sign_requests;
  v_typed text := nullif(btrim(coalesce(p ->> 'typed_name', '')), '');
  v_drawn text := nullif(btrim(coalesce(p ->> 'drawn_signature', '')), '');
  v_rec uuid;
  v_form uuid;
  v_agreement uuid;
begin
  select * into r from sign_requests where id = p_id for update;
  if r.id is null or r.signer_user_id is distinct from p_user then raise exception 'Not found' using errcode = 'P0002'; end if;
  if r.status <> 'sent' then raise exception 'This document is % and is not waiting for your signature', r.status using errcode = '23514'; end if;
  if lower(coalesce(p ->> 'document_sha256', '')) <> r.document_sha256 then
    raise exception 'The document changed after it was opened: reload and sign the current version' using errcode = '23514';
  end if;
  if v_typed is null and v_drawn is null then raise exception 'Sign by drawing a signature or by typing your full legal name' using errcode = '22023'; end if;
  if v_drawn is null and lower(regexp_replace(v_typed, '\s+', '', 'g')) <> lower(regexp_replace(r.signer_name, '\s+', '', 'g')) then
    raise exception 'The typed name must be your full legal name (%)', r.signer_name using errcode = '23514';
  end if;
  if nullif(btrim(coalesce(p ->> 'consent_text', '')), '') is null then
    raise exception 'The statement you agree to is recorded with the signature' using errcode = '22023';
  end if;
  if r.doc_type = 'investment_agreement' then
    if coalesce(p ->> 'legal_advice_choice', '') not in ('obtained', 'declined') then
      raise exception 'Say whether you obtained independent legal advice or chose not to' using errcode = '22023';
    end if;
    if nullif(btrim(coalesce(p ->> 'initials', '')), '') is null then
      raise exception 'Initial the risk acknowledgment (Schedule C)' using errcode = '22023';
    end if;
  end if;
  insert into signature_records (signature_request_id, signer_role, signer_user_id, signer_name, signer_email, status, signed_at, method,
                                 ip_address, user_agent, provider_signature, typed_name, consent_text, document_sha256, initials)
  values (r.signature_request_id, r.signer_role, p_user, r.signer_name, r.signer_email, 'signed', now(), case when v_drawn is not null then 'drawn' else 'typed' end,
          nullif(p ->> 'ip', '')::inet, nullif(p ->> 'user_agent', ''), v_drawn, v_typed, p ->> 'consent_text', r.document_sha256,
          case when nullif(btrim(coalesce(p ->> 'initials', '')), '') is not null then jsonb_build_object('schedule_c', upper(btrim(p ->> 'initials'))) end)
  returning id into v_rec;
  update sign_requests set status = 'signed', method = case when v_drawn is not null then 'drawn' else 'typed' end, signed_at = now(), signature_record_id = v_rec,
         extra = extra || jsonb_strip_nulls(jsonb_build_object('legal_advice_choice', p ->> 'legal_advice_choice', 'legal_adviser', nullif(btrim(p ->> 'legal_adviser'), '')))
   where id = r.id returning * into r;
  update signature_requests set status = case when r.doc_type = 'investment_agreement' then 'partially_signed' else 'completed' end,
         completed_at = case when r.doc_type = 'investment_agreement' then null else now() end where id = r.signature_request_id;
  if r.doc_type in ('form_a', 'form_b') then
    -- CarmaCars countersigns the form automatically when the owner signs, as for the owner agreement
    insert into signature_records (signature_request_id, signer_role, signer_name, signer_title, signer_email, status, signed_at, method,
                                   typed_name, consent_text, document_sha256)
    select r.signature_request_id, 'carmacars', coalesce(ps.signing_officer_name, ps.company_trade_name), coalesce(ps.signing_officer_title, 'for ' || ps.company_trade_name),
           ps.company_email, 'signed', now(), 'automatic', coalesce(ps.signing_officer_name, ps.company_trade_name),
           format('Countersigned for %s automatically when the owner signed.', ps.company_trade_name), r.document_sha256
      from (select (app.settings()).*) ps;
    update owner_agreement_forms set status = 'replaced' where owner_id = r.owner_id and form_code = upper(right(r.doc_type, 1)) and status = 'uploaded';
    insert into owner_agreement_forms (owner_agreement_id, owner_id, form_code, document_id, signature_request_id, signed_at, status, signed_method,
                                       uploaded_by, reviewed_by, reviewed_at)
    values ((select id from owner_agreements where owner_id = r.owner_id and kind = 'title_holding' and status <> 'void' order by created_at desc limit 1),
            r.owner_id, upper(right(r.doc_type, 1)), r.document_id, r.signature_request_id, now(), 'approved', 'screen', p_user, p_user, now())
    returning id into v_form;
  elsif r.doc_type = 'investment_agreement' then
    v_agreement := r.investment_agreement_id;
    perform app.investment_signed(v_agreement, r.document_id, r.signature_request_id, r.extra);
  elsif r.doc_type = 'staff_agreement' then
    update staff_profiles set agreement_document_id = r.document_id, started_on = coalesce(started_on, app.today()) where user_id = r.staff_user_id;
  end if;
  insert into audit_log (actor_user_id, action, entity_table, entity_id, after)
  values (p_user, 'sign_request_signed', 'sign_requests', r.id::text, jsonb_build_object('doc_type', r.doc_type, 'method', r.method, 'form_id', v_form));
  return to_jsonb(r) || jsonb_build_object('form_id', v_form, 'signature_record_id', v_rec,
    'record', (select jsonb_build_object('signer_role', x.signer_role, 'signer_name', x.signer_name, 'method', x.method, 'signed_at', x.signed_at,
                                         'ip_address', host(x.ip_address), 'user_agent', x.user_agent, 'provider_signature', x.provider_signature,
                                         'typed_name', x.typed_name, 'initials', x.initials) from signature_records x where x.id = v_rec));
end $$;

-- After signing: the signed copy (the signature and its record, rendered by the server) is filed with the document.
create or replace function app.sign_request_attach(p_id uuid, p_path text, p_sha256 text) returns uuid
language plpgsql security definer set search_path = public, app as $$
declare
  r sign_requests;
  d documents;
  v_doc uuid;
begin
  select * into r from sign_requests where id = p_id for update;
  if r.id is null or r.status <> 'signed' then raise exception 'Only a signed document gets its signed copy' using errcode = '23514'; end if;
  if r.signed_document_id is not null then return r.signed_document_id; end if;
  select * into d from documents where id = r.document_id;
  insert into documents (kind, title, storage_bucket, storage_path, mime_type, sha256, owner_id, investor_id, staff_user_id, template_version)
  values (d.kind, coalesce(d.title, r.title) || ', signed', 'agreements', p_path, 'application/pdf', lower(p_sha256), d.owner_id, d.investor_id, d.staff_user_id, d.template_version)
  returning id into v_doc;
  update sign_requests set signed_document_id = v_doc where id = r.id;
  update signature_requests set signed_document_id = v_doc where id = r.signature_request_id;
  if r.doc_type in ('form_a', 'form_b') then
    update owner_agreement_forms set document_id = v_doc where signature_request_id = r.signature_request_id and status = 'approved';
  elsif r.doc_type = 'staff_agreement' then
    update staff_profiles set agreement_document_id = v_doc where user_id = r.staff_user_id and agreement_document_id = r.document_id;
  end if;
  return v_doc;
end $$;

-- ---------------------------------------------------------------- recording a document signed on paper
-- An Admin records that a document was signed on paper (customer service may for rental agreements and amendments).
-- The scan is already stored privately by the server (agreements bucket, path paper/...). The document then counts as
-- signed everywhere its status is read.
-- p: {doc_type, target_id, signer_name, signed_on, witness_1_name, witness_2_name, note, scan: {path, sha256, mime},
--     investment: {exemption_category, legal_advice_choice, legal_adviser}}
create or replace function app.record_paper_signature(p_by uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  v_type text := p ->> 'doc_type';
  v_target uuid := nullif(p ->> 'target_id', '')::uuid;
  v_signer text := nullif(btrim(coalesce(p ->> 'signer_name', '')), '');
  v_on date := nullif(p ->> 'signed_on', '')::date;
  v_w1 text := nullif(btrim(coalesce(p ->> 'witness_1_name', '')), '');
  v_w2 text := nullif(btrim(coalesce(p ->> 'witness_2_name', '')), '');
  v_note text := nullif(btrim(coalesce(p ->> 'note', '')), '');
  v_sha text := lower(coalesce(p #>> '{scan,sha256}', ''));
  v_path text := p #>> '{scan,path}';
  v_doc uuid;
  v_req uuid;
  v_rec uuid;
  v_id uuid;
  v_effect jsonb := '{}'::jsonb;
  o owners;
  v vehicles;
  g government_form_fills;
  b bookings;
  ra rental_agreements;
  rs rental_agreement_signers;
  c booking_change_requests;
  am booking_amendments;
  inv investors;
  ia investment_agreements;
  sr sign_requests;
  a owner_agreements;
  u users;
  v_owner uuid; v_vehicle uuid; v_booking uuid; v_renter uuid; v_investor uuid; v_staff uuid;
  v_ids uuid[] := '{}'; v_reqs uuid[] := '{}'; v_recs uuid[] := '{}'; v_new_reqs uuid[] := '{}'; v_sched uuid[] := '{}';
  v_code text;
  v_form uuid;
  v_role text;
  v_renter_user uuid;
begin
  if p_by is null then raise exception 'Sign in first' using errcode = '42501'; end if;
  if v_type in ('rental_agreement', 'rental_amendment') then
    if not (app.user_is_admin(p_by) or app.user_va_has(p_by, 'cs')) then
      raise exception 'Only an Admin or customer service records a rental document signed on paper' using errcode = '42501';
    end if;
  else
    perform app.assert_admin(p_by);
  end if;
  if v_type is null or v_target is null then raise exception 'Choose the document and whose it is' using errcode = '22023'; end if;
  if v_signer is null then raise exception 'Enter the name of the person who signed' using errcode = '22023'; end if;
  if v_on is null then raise exception 'Enter the date it was signed' using errcode = '22023'; end if;
  if v_on > app.today() then raise exception 'The date signed cannot be in the future' using errcode = '22023'; end if;
  if v_sha !~ '^[0-9a-f]{64}$' or coalesce(v_path, '') !~ '^paper/' then raise exception 'Upload the scan of the signed document' using errcode = '22023'; end if;
  if v_type = 'form_c' and v_w1 is null then raise exception 'Form C is signed in front of a witness: enter the witness''s name' using errcode = '22023'; end if;
  if v_type = 'form_d' and (v_w1 is null or v_w2 is null) then raise exception 'Form D is signed in front of two witnesses: enter both names' using errcode = '22023'; end if;

  -- whose document it is
  case
  when v_type in ('owner_agreement', 'debit_agreement', 'form_a', 'form_b', 'form_d') then
    select * into o from owners where id = v_target for update;
    if o.id is null then raise exception 'Owner not found' using errcode = 'P0002'; end if;
    v_owner := o.id;
  when v_type = 'form_c' then
    select * into v from vehicles where id = v_target;
    if v.id is null then raise exception 'Vehicle not found' using errcode = 'P0002'; end if;
    v_owner := v.owner_id; v_vehicle := v.id;
    select * into o from owners where id = v_owner for update;
  when v_type = 'registry_form' then
    select * into g from government_form_fills where id = v_target for update;
    if g.id is null or g.superseded_at is not null then raise exception 'That form is not current' using errcode = 'P0002'; end if;
    v_owner := g.owner_id; v_vehicle := g.vehicle_id;
  when v_type = 'rental_agreement' then
    select * into b from bookings where id = v_target for update;
    if b.id is null then raise exception 'Booking not found' using errcode = 'P0002'; end if;
    v_booking := b.id; v_renter := b.renter_id;
  when v_type = 'rental_amendment' then
    select * into c from booking_change_requests where id = v_target for update;
    if c.id is null then raise exception 'Change not found' using errcode = 'P0002'; end if;
    select * into b from bookings where id = c.booking_id;
    v_booking := b.id; v_renter := b.renter_id;
  when v_type = 'investment_agreement' then
    select * into inv from investors where id = v_target;
    if inv.id is null then raise exception 'Investor not found' using errcode = 'P0002'; end if;
    v_investor := inv.id;
  when v_type = 'staff_agreement' then
    select * into u from users where id = v_target;
    if u.id is null or not exists (select 1 from staff_profiles sp where sp.user_id = u.id) then raise exception 'Staff member not found' using errcode = 'P0002'; end if;
    v_staff := u.id;
  else
    raise exception 'Unknown document %', v_type using errcode = '22023';
  end case;

  insert into documents (kind, title, storage_bucket, storage_path, mime_type, sha256, owner_id, vehicle_id, booking_id, renter_id, investor_id, staff_user_id, uploaded_by)
  values (app.paper_doc_kind(v_type)::document_kind, app.paper_doc_title(v_type) || ', signed on paper', 'agreements', v_path,
          coalesce(nullif(p #>> '{scan,mime}', ''), 'application/pdf'), v_sha, v_owner, v_vehicle, v_booking, v_renter, v_investor, v_staff, p_by)
  returning id into v_doc;

  -- what it changes
  case
  when v_type = 'owner_agreement' then
    v_role := case when o.owner_type = 'corporation' then 'owner_corporation' else 'owner_individual' end;
    for a in select * from owner_agreements where owner_id = o.id and status in ('draft', 'sent') order by kind for update loop
      v_req := null;
      if a.signature_request_id is not null and exists (select 1 from signature_requests x where x.id = a.signature_request_id and x.status = 'sent') then
        v_req := a.signature_request_id;
      else
        insert into signature_requests (document_id, provider, status, sent_at, created_by) values (v_doc, 'paper', 'sent', now(), p_by) returning id into v_req;
        v_new_reqs := v_new_reqs || v_req;
      end if;
      v_rec := app.paper_records(v_req, v_role, o.user_id, v_signer, o.email, v_on, v_doc, v_sha);
      v_recs := v_recs || v_rec;
      insert into signature_records (signature_request_id, signer_role, signer_name, signer_title, status, signed_at, method, typed_name, consent_text, document_sha256)
      select v_req, 'carmacars', coalesce(ps.signing_officer_name, ps.company_trade_name), coalesce(ps.signing_officer_title, 'for ' || ps.company_trade_name),
             'signed', app.local_midnight(v_on) + interval '12 hours', 'automatic', coalesce(ps.signing_officer_name, ps.company_trade_name),
             format('Countersigned for %s when the owner''s paper signature was recorded.', ps.company_trade_name), v_sha
        from (select (app.settings()).*) ps
      returning id into v_rec;
      v_recs := v_recs || v_rec;
      update signature_requests set status = 'completed', completed_at = now(), signed_document_id = v_doc where id = v_req;
      update owner_agreements set status = 'signed', agreement_date = coalesce(agreement_date, v_on), signature_request_id = v_req, document_id = v_doc,
             confirm_own_insurance_at = case when kind = 'enrollment' then coalesce(confirm_own_insurance_at, now()) else confirm_own_insurance_at end,
             confirm_fees_no_income_at = case when kind = 'enrollment' then coalesce(confirm_fees_no_income_at, now()) else confirm_fees_no_income_at end,
             confirm_tracker_downtime_at = case when kind = 'enrollment' then coalesce(confirm_tracker_downtime_at, now()) else confirm_tracker_downtime_at end
       where id = a.id;
      v_ids := v_ids || a.id; v_reqs := v_reqs || v_req;
    end loop;
    -- every current schedule not signed yet (the Additional Vehicle Schedules too)
    select coalesce(array_agg(s.id), '{}') into v_sched
      from vehicle_schedules s join vehicles vv on vv.id = s.vehicle_id join vehicle_onboardings ob on ob.vehicle_id = vv.id
     where vv.owner_id = o.id and s.superseded_by is null and s.signed_at is null and ob.status not in ('declined', 'withdrawn');
    if cardinality(v_ids) = 0 and cardinality(v_sched) = 0 then
      raise exception 'Nothing of % is waiting for a signature (set the terms first, or it is already signed)', o.legal_name using errcode = '23514';
    end if;
    if cardinality(v_sched) > 0 and cardinality(v_reqs) = 0 then
      insert into signature_requests (document_id, provider, status, sent_at, completed_at, signed_document_id, created_by)
      values (v_doc, 'paper', 'completed', now(), now(), v_doc, p_by) returning id into v_req;
      v_new_reqs := v_new_reqs || v_req; v_reqs := v_reqs || v_req;
      v_recs := v_recs || app.paper_records(v_req, v_role, o.user_id, v_signer, o.email, v_on, v_doc, v_sha);
    end if;
    update vehicle_schedules set signed_at = app.local_midnight(v_on) + interval '12 hours', document_id = coalesce(document_id, v_doc),
           signature_request_id = coalesce(signature_request_id, v_reqs[1])
     where id = any (v_sched);
    v_effect := jsonb_build_object('agreements', to_jsonb(v_ids), 'requests', to_jsonb(v_reqs), 'new_requests', to_jsonb(v_new_reqs),
                                   'records', to_jsonb(v_recs), 'schedules', to_jsonb(v_sched),
                                   'onboardings', to_jsonb(app.owner_vehicles_signed(o.id)));
  when v_type = 'debit_agreement' then
    if exists (select 1 from paper_signatures x where x.doc_type = 'debit_agreement' and x.target_id = o.id and x.voided_at is null) then
      raise exception 'A paper debit agreement of % is already on file' , o.legal_name using errcode = '23514';
    end if;
    v_effect := jsonb_build_object('note', 'The automatic debit still needs the bank account set up with the payment processor (Banking, Set up pre-authorized debit).');
  when v_type in ('form_a', 'form_b', 'form_c', 'form_d') then
    v_code := case v_type when 'form_a' then 'A' when 'form_b' then 'B' when 'form_c' then 'C' else 'D1' end;
    if v_type in ('form_a', 'form_b') and not exists (select 1 from jsonb_array_elements(app.owner_screen_forms(o.id)) x where x ->> 'code' = v_code) then
      raise exception '% does not need %', o.legal_name, app.paper_doc_title(v_type) using errcode = '23514';
    end if;
    if v_type in ('form_c', 'form_d') and not exists (select 1 from jsonb_array_elements(app.owner_witnessed_forms(o.id)) x
                                                       where x ->> 'code' = v_code and (x ->> 'vehicle_id')::uuid is not distinct from v_vehicle) then
      raise exception '% does not need %', o.legal_name, app.paper_doc_title(v_type) using errcode = '23514';
    end if;
    if exists (select 1 from owner_agreement_forms f where f.owner_id = o.id and f.form_code = v_code and f.vehicle_id is not distinct from v_vehicle and f.status = 'approved') then
      raise exception '% is already signed', app.paper_doc_title(v_type) using errcode = '23514';
    end if;
    update owner_agreement_forms set status = 'replaced'
     where owner_id = o.id and form_code = v_code and vehicle_id is not distinct from v_vehicle and status = 'uploaded';
    insert into signature_requests (document_id, provider, status, sent_at, completed_at, signed_document_id, created_by)
    values (v_doc, 'paper', 'completed', now(), now(), v_doc, p_by) returning id into v_req;
    v_rec := app.paper_records(v_req, case when o.owner_type = 'corporation' then 'owner_corporation' else 'owner_individual' end, o.user_id, v_signer, o.email,
                               v_on, v_doc, v_sha, v_w1, v_w2);
    insert into owner_agreement_forms (owner_agreement_id, owner_id, form_code, vehicle_id, document_id, signature_request_id, signed_at, witness_1_name, witness_2_name,
                                       finance_permission, ack_read_warning_at, ack_no_advice_at, ack_bears_consequences_at,
                                       status, signed_method, uploaded_by, reviewed_by, reviewed_at)
    values ((select id from owner_agreements where owner_id = o.id and kind = 'title_holding' and status <> 'void' order by created_at desc limit 1),
            o.id, v_code, v_vehicle, v_doc, v_req, app.local_midnight(v_on) + interval '12 hours', v_w1, v_w2,
            case when v_code = 'C' then (select s.finance_permission from vehicle_schedules s where s.vehicle_id = v_vehicle and s.superseded_by is null) end,
            case when v_code = 'C' then app.local_midnight(v_on) + interval '12 hours' end, case when v_code = 'C' then app.local_midnight(v_on) + interval '12 hours' end,
            case when v_code = 'C' then app.local_midnight(v_on) + interval '12 hours' end,
            'approved', 'paper', p_by, p_by, now())
    returning id into v_form;
    update tasks set status = 'done', completed_at = now(), completed_by = p_by, completion_note = 'Signed on paper'
     where task_type = 'owner_form_review' and owner_id = o.id and status in ('open', 'in_progress', 'waiting')
       and related_id in (select f.id from owner_agreement_forms f where f.owner_id = o.id and f.form_code = v_code and f.vehicle_id is not distinct from v_vehicle);
    -- an open on-screen request for the same form is no longer needed
    update sign_requests set status = 'voided', voided_at = now(), voided_by = p_by, void_reason = 'Signed on paper'
     where owner_id = o.id and doc_type = v_type and status = 'sent';
    v_effect := jsonb_build_object('form_id', v_form, 'request', v_req);
  when v_type = 'registry_form' then
    if g.status not in ('ready', 'printed') then
      raise exception '%', case when g.status = 'draft' then 'Some values of this form are still missing: ' || array_to_string(g.missing, ', ')
                                else 'This form is already ' || g.status end using errcode = '23514';
    end if;
    v_effect := jsonb_build_object('fill_id', g.id, 'status_before', g.status, 'document_before', g.document_id, 'file_key_before', g.file_key);
    perform app.set_government_form_status(g.id, 'signed', p_by, v_path, v_doc);
    update government_form_fills set signed_method = 'paper' where id = g.id;
  when v_type = 'rental_agreement' then
    select * into ra from rental_agreements where booking_id = b.id and status in ('open', 'signed', 'completed') for update;
    if ra.id is null then raise exception 'Open the rental agreement of % first (its sign page), then record the paper signature', b.booking_number using errcode = '23514'; end if;
    if ra.status <> 'open' then raise exception 'The rental agreement of % is already signed', b.booking_number using errcode = '23514'; end if;
    if b.status <> 'pending_payment' then raise exception 'Booking % is %: its agreement is not waiting for the renter''s signature', b.booking_number, b.status using errcode = '23514'; end if;
    select * into rs from rental_agreement_signers where agreement_id = ra.id and signer_role = 'renter' for update;
    v_rec := app.paper_records(ra.signature_request_id, 'renter', rs.user_id, v_signer, rs.signer_email, v_on, v_doc, ra.document_sha256);
    update rental_agreement_signers set signature_record_id = v_rec, signed_at = now() where id = rs.id;
    update rental_agreements set status = 'signed', renter_signed_at = now() where id = ra.id;
    update signature_requests set status = 'partially_signed' where id = ra.signature_request_id;
    perform app.log_booking_event(b.id, 'agreement_signed', b.status::text, b.status::text, ra.offer_version, 'Signed on paper', p_by, 'staff',
      jsonb_build_object('agreement_id', ra.id, 'signer_id', rs.id, 'signer_role', 'renter', 'signer_name', v_signer, 'signature_record_id', v_rec, 'method', 'paper'));
    v_effect := jsonb_build_object('agreement_id', ra.id, 'record', v_rec);
  when v_type = 'rental_amendment' then
    if c.status not in ('proposed', 'approved') or coalesce(c.accept_by, 'infinity') <= now() then
      raise exception 'This change is no longer waiting for the renter''s answer' using errcode = '23514';
    end if;
    select r.user_id into v_renter_user from renters r where r.id = b.renter_id;
    if v_renter_user is null then raise exception 'The renter of % has no account to record the agreement for' , b.booking_number using errcode = '23514'; end if;
    select * into am from booking_amendments where change_request_id = c.id and status = 'open' for update;
    if am.id is null then
      if exists (select 1 from booking_amendments x where x.change_request_id = c.id and x.status in ('signed', 'recorded')) then
        raise exception 'This change is already signed' using errcode = '23514';
      end if;
      insert into signature_requests (document_id, provider, status, sent_at, created_by) values (v_doc, 'paper', 'sent', now(), p_by) returning id into v_req;
      insert into booking_amendments (booking_id, change_request_id, amendment_number, agreement_id, document_id, document_sha256, template_version, signature_request_id, created_by)
      values (b.id, c.id,
              coalesce((select a2.agreement_number from rental_agreements a2 where a2.booking_id = b.id and a2.status <> 'voided' order by a2.opened_at desc limit 1), b.booking_number)
                || '-A' || (1 + (select count(*) from booking_amendments x where x.booking_id = b.id)),
              (select a2.id from rental_agreements a2 where a2.booking_id = b.id and a2.status <> 'voided' order by a2.opened_at desc limit 1),
              v_doc, v_sha, 'paper', v_req, p_by)
      returning * into am;
    end if;
    v_rec := app.paper_records(am.signature_request_id, 'renter', v_renter_user, v_signer, null, v_on, v_doc, am.document_sha256);
    update booking_amendments set status = 'signed', signed_at = now(), signer_user_id = v_renter_user, signature_record_id = v_rec,
           signed_document_id = case when document_id = v_doc then v_doc else signed_document_id end
     where id = am.id;
    update signature_requests set status = 'partially_signed' where id = am.signature_request_id;
    perform app.agree_booking_change(c.id, v_renter_user, null, null);
    v_effect := jsonb_build_object('amendment_id', am.id, 'record', v_rec, 'applied', false);
    select * into c from booking_change_requests where id = c.id;
    if coalesce(c.total_difference_cents, 0) <= 0 then
      perform app.accept_booking_change_apply(c.id, p_by, null, null);
      v_effect := v_effect || jsonb_build_object('applied', true);
    end if;
  when v_type = 'investment_agreement' then
    select * into ia from investment_agreements where investor_id = inv.id and status in ('draft', 'sent', 'signed') for update;
    if ia.status = 'signed' then raise exception 'The agreement of % is already signed', inv.legal_name using errcode = '23514'; end if;
    if ia.id is null then
      insert into investment_agreements (investor_id, agreement_number, status)
      values (inv.id, 'IA-' || nextval('investment_agreement_number_seq'), 'draft') returning * into ia;
      v_effect := jsonb_build_object('created', true);
    end if;
    select * into sr from sign_requests where investment_agreement_id = ia.id and status = 'sent' for update;
    insert into signature_requests (document_id, provider, status, sent_at, completed_at, signed_document_id, created_by)
    values (v_doc, 'paper', 'partially_signed', now(), null, v_doc, p_by) returning id into v_req;
    v_rec := app.paper_records(v_req, 'investor', inv.user_id, v_signer, inv.email, v_on, v_doc, v_sha);
    perform app.investment_signed(ia.id, v_doc, v_req, coalesce(sr.extra, '{}'::jsonb) || coalesce(p -> 'investment', '{}'::jsonb));
    if sr.id is not null then
      update sign_requests set status = 'signed', method = 'paper', signed_at = app.local_midnight(v_on) + interval '12 hours', signature_record_id = v_rec,
             signed_document_id = v_doc where id = sr.id;
      update signature_requests set status = 'voided' where id = sr.signature_request_id;
    end if;
    v_effect := v_effect || jsonb_build_object('agreement_id', ia.id, 'status_before', ia.status, 'document_before', ia.document_id, 'request', v_req,
                                               'sign_request_id', sr.id);
  when v_type = 'staff_agreement' then
    select * into sr from sign_requests where staff_user_id = u.id and doc_type = 'staff_agreement' and status = 'sent' for update;
    insert into signature_requests (document_id, provider, status, sent_at, completed_at, signed_document_id, created_by)
    values (v_doc, 'paper', 'completed', now(), now(), v_doc, p_by) returning id into v_req;
    v_rec := app.paper_records(v_req, 'staff', u.id, v_signer, u.email, v_on, v_doc, v_sha, v_w1, v_w2);
    v_effect := jsonb_build_object('document_before', (select agreement_document_id from staff_profiles where user_id = u.id), 'request', v_req, 'sign_request_id', sr.id);
    update staff_profiles set agreement_document_id = v_doc, started_on = coalesce(started_on, v_on) where user_id = u.id;
    if sr.id is not null then
      update sign_requests set status = 'signed', method = 'paper', signed_at = app.local_midnight(v_on) + interval '12 hours', signature_record_id = v_rec,
             signed_document_id = v_doc where id = sr.id;
      update signature_requests set status = 'voided' where id = sr.signature_request_id;
    end if;
  end case;

  insert into paper_signatures (doc_type, target_id, owner_id, vehicle_id, booking_id, renter_id, investor_id, staff_user_id, document_id, signer_name, signed_on,
                                witness_1_name, witness_2_name, note, effect, recorded_by)
  values (v_type, v_target, v_owner, v_vehicle, v_booking, v_renter, v_investor, v_staff, v_doc, v_signer, v_on, v_w1, v_w2, v_note, v_effect, p_by)
  returning id into v_id;
  insert into audit_log (actor_user_id, action, entity_table, entity_id, after)
  values (p_by, 'record_paper_signature', 'paper_signatures', v_id::text,
          jsonb_build_object('doc_type', v_type, 'target_id', v_target, 'signer_name', v_signer, 'signed_on', v_on, 'witnesses', jsonb_strip_nulls(jsonb_build_object('w1', v_w1, 'w2', v_w2)),
                             'document_id', v_doc, 'effect', v_effect, 'note', v_note));
  return jsonb_build_object('ok', true, 'id', v_id, 'document_id', v_doc, 'effect', v_effect);
end $$;

-- Void a paper signature recorded by mistake (the wrong scan, the wrong person). The document is waiting for a signature
-- again, except where something already rests on it (a confirmed booking, an applied change, investments): then the void
-- is refused and the record stays.
create or replace function app.void_paper_signature(p_by uuid, p_id uuid, p_reason text) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  ps paper_signatures;
  e jsonb;
  x uuid;
  v_moved uuid[];
begin
  perform app.assert_admin(p_by);
  if nullif(btrim(coalesce(p_reason, '')), '') is null then raise exception 'Give the reason for voiding the paper signature' using errcode = '22023'; end if;
  select * into ps from paper_signatures where id = p_id for update;
  if ps.id is null then raise exception 'Not found' using errcode = 'P0002'; end if;
  if ps.voided_at is not null then raise exception 'This paper signature was already voided' using errcode = '23514'; end if;
  e := ps.effect;
  case ps.doc_type
  when 'owner_agreement' then
    for x in select (jsonb_array_elements_text(e -> 'records'))::uuid loop delete from signature_records where id = x; end loop;
    update signature_requests set status = case when id in (select (jsonb_array_elements_text(e -> 'new_requests'))::uuid) then 'voided' else 'sent' end,
           completed_at = null, signed_document_id = null
     where id in (select (jsonb_array_elements_text(e -> 'requests'))::uuid);
    update owner_agreements set status = case when signature_request_id in (select (jsonb_array_elements_text(e -> 'new_requests'))::uuid) then 'draft' else 'sent' end,
           signature_request_id = case when signature_request_id in (select (jsonb_array_elements_text(e -> 'new_requests'))::uuid) then null else signature_request_id end,
           document_id = case when document_id = ps.document_id then null else document_id end
     where id in (select (jsonb_array_elements_text(e -> 'agreements'))::uuid);
    update vehicle_schedules set signed_at = null, document_id = case when document_id = ps.document_id then null else document_id end,
           signature_request_id = case when signature_request_id in (select (jsonb_array_elements_text(e -> 'new_requests'))::uuid) then null else signature_request_id end
     where id in (select (jsonb_array_elements_text(e -> 'schedules'))::uuid);
    select coalesce(array_agg(ob.id), '{}') into v_moved from vehicle_onboardings ob
     where ob.id in (select (jsonb_array_elements_text(e -> 'onboardings'))::uuid) and ob.status = 'documents_signed';
    update vehicle_onboardings set status = 'documents_sent', documents_signed_at = null where id = any (v_moved);
  when 'form_a', 'form_b', 'form_c', 'form_d' then
    update owner_agreement_forms set status = 'replaced' where id = (e ->> 'form_id')::uuid and status = 'approved';
    update signature_requests set status = 'voided' where id = (e ->> 'request')::uuid;
  when 'registry_form' then
    update government_form_fills set status = e ->> 'status_before', signed_at = null, signed_recorded_by = null, signed_method = null,
           document_id = nullif(e ->> 'document_before', '')::uuid, file_key = coalesce(nullif(e ->> 'file_key_before', ''), file_key)
     where id = (e ->> 'fill_id')::uuid and status = 'signed';
    if not found then raise exception 'The registry form has moved on (filed): the paper signature stays' using errcode = '23514'; end if;
  when 'rental_agreement' then
    if exists (select 1 from rental_agreements ra join bookings b on b.id = ra.booking_id
                where ra.id = (e ->> 'agreement_id')::uuid and (ra.status <> 'signed' or b.status <> 'pending_payment')) then
      raise exception 'The booking was confirmed on this signature: the paper signature stays' using errcode = '23514';
    end if;
    -- a signature record is never changed: the agreement is voided and the renter signs a new one
    update rental_agreements set status = 'voided', voided_at = now(), void_reason = left('Paper signature voided: ' || btrim(p_reason), 300)
     where id = (e ->> 'agreement_id')::uuid;
    update signature_requests set status = 'voided' where id = (select signature_request_id from rental_agreements where id = (e ->> 'agreement_id')::uuid);
  when 'rental_amendment' then
    if coalesce((e ->> 'applied')::boolean, false)
       or exists (select 1 from booking_amendments am join booking_change_requests c on c.id = am.change_request_id
                   where am.id = (e ->> 'amendment_id')::uuid and c.status = 'applied') then
      raise exception 'The change was applied on this signature: the paper signature stays' using errcode = '23514';
    end if;
    update booking_amendments set status = 'voided', voided_at = now(), void_reason = left('Paper signature voided: ' || btrim(p_reason), 300)
     where id = (e ->> 'amendment_id')::uuid;
    update signature_requests set status = 'voided' where id = (select signature_request_id from booking_amendments where id = (e ->> 'amendment_id')::uuid);
    update booking_change_requests set renter_agreed_at = null, agreed_by = null, agreed_ip = null, agreed_user_agent = null
     where id = ps.target_id and status in ('proposed', 'approved');
  when 'investment_agreement' then
    if exists (select 1 from investments i where i.agreement_id = (e ->> 'agreement_id')::uuid) then
      raise exception 'Investments rest on this agreement: the paper signature stays' using errcode = '23514';
    end if;
    update investment_agreements set status = case when nullif(e ->> 'sign_request_id', '') is not null then 'draft' else coalesce(nullif(e ->> 'status_before', ''), 'draft') end,
           document_id = nullif(e ->> 'document_before', '')::uuid
     where id = (e ->> 'agreement_id')::uuid;
    update signature_requests set status = 'voided' where id = (e ->> 'request')::uuid;
    update sign_requests set status = 'voided', voided_at = now(), voided_by = p_by, void_reason = 'Paper signature voided'
     where id = nullif(e ->> 'sign_request_id', '')::uuid and status = 'signed' and method = 'paper';
  when 'staff_agreement' then
    update staff_profiles set agreement_document_id = nullif(e ->> 'document_before', '')::uuid where user_id = ps.target_id and agreement_document_id = ps.document_id;
    update signature_requests set status = 'voided' where id = (e ->> 'request')::uuid;
    update sign_requests set status = 'voided', voided_at = now(), voided_by = p_by, void_reason = 'Paper signature voided'
     where id = nullif(e ->> 'sign_request_id', '')::uuid and status = 'signed' and method = 'paper';
  else
    null;   -- debit_agreement: the record itself is the signature
  end case;
  update paper_signatures set voided_at = now(), voided_by = p_by, void_reason = left(btrim(p_reason), 500) where id = ps.id;
  insert into audit_log (actor_user_id, action, entity_table, entity_id, before, after)
  values (p_by, 'void_paper_signature', 'paper_signatures', ps.id::text, jsonb_build_object('doc_type', ps.doc_type, 'target_id', ps.target_id, 'effect', e),
          jsonb_build_object('reason', btrim(p_reason)));
  return jsonb_build_object('ok', true, 'id', ps.id);
end $$;

-- The paper signatures of one person or record (Admin screens).
create or replace function app.paper_signatures_json(p_owner uuid default null, p_booking uuid default null, p_investor uuid default null, p_staff uuid default null)
returns jsonb language sql stable security definer set search_path = public, app as $$
  select coalesce(jsonb_agg(jsonb_build_object('id', ps.id, 'doc_type', ps.doc_type, 'title', app.paper_doc_title(ps.doc_type), 'target_id', ps.target_id,
           'vehicle_id', ps.vehicle_id, 'vehicle_name', case when ps.vehicle_id is not null then app.vehicle_name(ps.vehicle_id) end,
           'document_id', ps.document_id, 'signer_name', ps.signer_name, 'signed_on', ps.signed_on, 'witness_1_name', ps.witness_1_name,
           'witness_2_name', ps.witness_2_name, 'note', ps.note, 'recorded_at', ps.recorded_at,
           'recorded_by_name', (select u.full_name from users u where u.id = ps.recorded_by), 'voided_at', ps.voided_at, 'void_reason', ps.void_reason)
           order by ps.recorded_at desc), '[]'::jsonb)
    from paper_signatures ps
   where (p_owner is not null and ps.owner_id = p_owner) or (p_booking is not null and ps.booking_id = p_booking)
      or (p_investor is not null and ps.investor_id = p_investor) or (p_staff is not null and ps.staff_user_id = p_staff)
$$;

-- ---------------------------------------------------------------- what is signed and paid, per owner
-- One row per item an owner signs or pays to get their cars on the road, with its status and how it was done:
-- status: done | open | not_needed; method: portal | paper | upload | screen | debit | card | e_transfer | cheque | cash | bank_transfer | other.
-- target_id is what "Record payment" (an invoice) or "Record paper signature" (doc_type and target) acts on.
create or replace function app.owner_signables(p_owner uuid) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare
  o owners;
  v_out jsonb := '[]'::jsonb;
  v_non_turo boolean;
  v_billed boolean;
  a owner_agreements;
  r record;
  x jsonb;
  v_paper paper_signatures;
begin
  select * into o from owners where id = p_owner;
  if o.id is null then return v_out; end if;
  v_non_turo := exists (select 1 from vehicles v where v.owner_id = o.id and v.management_mode <> 'turo_only' and v.status not in ('exited', 'declined', 'total_loss'));
  v_billed := exists (select 1 from vehicles v where v.owner_id = o.id and v.billing_case in ('managed', 'self_managed') and v.status not in ('exited', 'declined', 'total_loss'));
  -- the agreements
  for r in select k.kind, k.label from (values ('enrollment', 'Enrollment Agreement', 1), ('title_holding', 'Title-Holding and Lease Agreement', 2)) k(kind, label, ord) order by k.ord loop
    select * into a from owner_agreements where owner_id = o.id and kind = r.kind and status in ('draft', 'sent', 'signed') order by created_at desc limit 1;
    v_out := v_out || jsonb_build_array(jsonb_build_object('code', r.kind, 'group', 'sign', 'label', r.label, 'doc_type', 'owner_agreement', 'target_id', o.id,
      'needed', a.id is not null or (r.kind = 'enrollment' and exists (select 1 from vehicles v where v.owner_id = o.id)) or (r.kind = 'title_holding' and v_non_turo),
      'status', case when a.status = 'signed' then 'done' when r.kind = 'title_holding' and not v_non_turo and a.id is null then 'not_needed' else 'open' end,
      'detail', case when a.id is null then 'Not prepared yet (terms not set)' when a.status = 'draft' then 'Ready, not opened by the owner' when a.status = 'sent' then 'Waiting for the owner''s signature' end,
      'method', case when a.status = 'signed' then app.request_method(a.signature_request_id) end, 'date', a.agreement_date,
      'number', a.agreement_number, 'document_id', a.document_id));
  end loop;
  -- each current schedule
  for r in select s.id, s.vehicle_id, s.schedule_number, s.signed_at, s.signature_request_id, s.document_id, s.is_additional, app.vehicle_name(s.vehicle_id) vname
             from vehicle_schedules s join vehicles v on v.id = s.vehicle_id join vehicle_onboardings ob on ob.vehicle_id = v.id
            where v.owner_id = o.id and s.superseded_by is null and ob.status not in ('declined', 'withdrawn') order by s.vehicle_number loop
    v_out := v_out || jsonb_build_array(jsonb_build_object('code', 'schedule', 'group', 'sign', 'label', case when r.is_additional then 'Additional Vehicle Schedule' else 'Vehicle Schedule' end,
      'vehicle_id', r.vehicle_id, 'vehicle_name', r.vname, 'doc_type', 'owner_agreement', 'target_id', o.id, 'needed', true,
      'status', case when r.signed_at is not null then 'done' else 'open' end, 'method', case when r.signed_at is not null then app.request_method(r.signature_request_id) end,
      'date', app.local_date(r.signed_at), 'number', r.schedule_number, 'document_id', r.document_id));
  end loop;
  -- the pre-authorized debit agreement (a mandate given online, or one signed on paper)
  select * into v_paper from paper_signatures where doc_type = 'debit_agreement' and target_id = o.id and voided_at is null order by recorded_at desc limit 1;
  select jsonb_build_object('at', m.created_at, 'bank', m.brand_or_bank, 'last4', m.last4) into x
    from owner_payment_methods m where m.owner_id = o.id and m.kind = 'pre_authorized_debit' and m.status = 'active' order by m.created_at desc limit 1;
  v_out := v_out || jsonb_build_array(jsonb_build_object('code', 'debit_agreement', 'group', 'sign', 'label', 'Pre-authorized debit agreement', 'doc_type', 'debit_agreement',
    'target_id', o.id, 'needed', v_billed, 'status', case when x is not null or v_paper.id is not null then 'done' when v_billed then 'open' else 'not_needed' end,
    'method', case when x is not null then 'portal' when v_paper.id is not null then 'paper' end,
    'date', coalesce(app.local_date((x ->> 'at')::timestamptz), v_paper.signed_on),
    'detail', case when x is not null then format('%s account ending %s', coalesce(x ->> 'bank', 'Bank'), coalesce(x ->> 'last4', '----'))
                   when v_paper.id is not null then 'On paper; the automatic debit still needs the bank account set up' end,
    'document_id', v_paper.document_id, 'paper_id', v_paper.id));
  -- Forms A and B (on screen), C and D (with witnesses)
  for x in select value from jsonb_array_elements(app.owner_screen_forms(o.id)) loop
    v_out := v_out || jsonb_build_array(jsonb_build_object('code', 'form_' || lower(x ->> 'code'), 'group', 'sign', 'label', x ->> 'title', 'doc_type', 'form_' || lower(x ->> 'code'),
      'target_id', o.id, 'needed', true, 'status', case when x ->> 'status' = 'signed' then 'done' else 'open' end, 'method', x ->> 'method',
      'date', app.local_date((x ->> 'signed_at')::timestamptz), 'document_id', x ->> 'document_id'));
  end loop;
  for x in select value from jsonb_array_elements(app.owner_witnessed_forms(o.id)) loop
    v_out := v_out || jsonb_build_array(jsonb_build_object('code', case x ->> 'code' when 'C' then 'form_c' else 'form_d' end, 'group', 'sign', 'label', x ->> 'title',
      'vehicle_id', x ->> 'vehicle_id', 'vehicle_name', x ->> 'vehicle_name', 'doc_type', case x ->> 'code' when 'C' then 'form_c' else 'form_d' end,
      'target_id', coalesce(x ->> 'vehicle_id', o.id::text), 'needed', true,
      'status', case when x ->> 'status' = 'approved' then 'done' else 'open' end,
      'detail', case x ->> 'status' when 'uploaded' then 'Uploaded, waiting for review' when 'rejected' then 'Sent back: ' || coalesce(x ->> 'reject_reason', '') end,
      'method', (select f.signed_method from owner_agreement_forms f where f.id = (x ->> 'form_id')::uuid), 'date', app.local_date((x ->> 'uploaded_at')::timestamptz),
      'document_id', x ->> 'document_id'));
  end loop;
  -- the registry forms of each car
  for r in select g.id, g.form_code, g.vehicle_id, g.status, g.missing, g.signed_at, g.signed_method, g.document_id, t.title
             from government_form_fills g join pdf_templates t on t.id = g.pdf_template_id
            where g.owner_id = o.id and g.superseded_at is null order by g.vehicle_id, g.form_code loop
    v_out := v_out || jsonb_build_array(jsonb_build_object('code', 'registry_form', 'group', 'sign', 'label', coalesce(r.title, r.form_code) || ' (' || r.form_code || ')',
      'vehicle_id', r.vehicle_id, 'vehicle_name', app.vehicle_name(r.vehicle_id), 'doc_type', 'registry_form', 'target_id', r.id, 'needed', true,
      'status', case when r.status in ('signed', 'filed') then 'done' else 'open' end,
      'detail', case when r.status = 'draft' then 'Missing: ' || array_to_string(r.missing, ', ') when r.status = 'filed' then 'Filed at the registry' end,
      'method', r.signed_method, 'date', app.local_date(r.signed_at), 'document_id', r.document_id));
  end loop;
  -- the invoices to pay before a car starts (first and last month, tracker install), and any other invoice still owing
  for r in select i.id, i.invoice_number, i.kind, i.vehicle_id, i.status, i.total_cents, i.balance_cents, i.paid_cents, i.paid_at, i.payment_method
             from owner_invoices i where i.owner_id = o.id and i.status <> 'draft' and i.status <> 'void'
              and (i.kind in ('upfront', 'tracker_install') or i.status in ('issued', 'failed', 'in_arrears', 'partially_deducted', 'processing', 'retry_processing'))
            order by i.billing_date, i.invoice_number loop
    v_out := v_out || jsonb_build_array(jsonb_build_object('code', case r.kind when 'upfront' then 'upfront_payment' when 'tracker_install' then 'tracker_payment' else 'invoice' end,
      'group', 'pay', 'label', case r.kind when 'upfront' then 'First and last month''s insurance' when 'tracker_install' then 'Tracker install' else 'Invoice' end || ' ' || r.invoice_number,
      'vehicle_id', r.vehicle_id, 'vehicle_name', app.vehicle_name(r.vehicle_id), 'invoice_id', r.id, 'invoice_number', r.invoice_number, 'target_id', r.id,
      'needed', true, 'status', case when r.status in ('paid', 'deducted') then 'done' else 'open' end,
      'detail', case when r.status in ('processing', 'retry_processing') then 'Debit processing'
                     when r.status not in ('paid', 'deducted') and r.paid_cents > 0 then format('Partly paid: %s of %s, %s owing', app.fmt_money(r.paid_cents), app.fmt_money(r.total_cents), app.fmt_money(r.balance_cents))
                     when r.status not in ('paid', 'deducted') then app.fmt_money(r.balance_cents) || ' owing' end,
      'amount_cents', r.total_cents, 'balance_cents', r.balance_cents,
      'method', case when r.status = 'paid' then case coalesce(r.payment_method, '') when 'pre_authorized_debit' then 'debit' when '' then null else r.payment_method end
                     when r.status = 'deducted' then 'deducted' end,
      'date', app.local_date(r.paid_at),
      'payable', r.status in ('issued', 'failed', 'in_arrears', 'partially_deducted') and r.balance_cents > 0));
  end loop;
  return v_out;
end $$;

-- Admin > Owners: every owner with their checklist (the signables) and the counts.
create or replace function app.owner_checklists(p_by uuid, p_owner uuid default null) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
begin
  if not (app.user_is_admin(p_by) or app.user_va_has(p_by, 'finance', 'cs')) then raise exception 'Not permitted' using errcode = '42501'; end if;
  return (select coalesce(jsonb_agg(jsonb_build_object('owner_id', o.id, 'legal_name', o.legal_name, 'items', s.items,
             'open', (select count(*) from jsonb_array_elements(s.items) i where i ->> 'status' = 'open'),
             'done', (select count(*) from jsonb_array_elements(s.items) i where i ->> 'status' = 'done'),
             'paper', (select count(*) from paper_signatures ps where ps.owner_id = o.id and ps.voided_at is null))
             order by o.legal_name), '[]'::jsonb)
            from owners o cross join lateral (select app.owner_signables(o.id) items) s
           where (p_owner is null or o.id = p_owner) and exists (select 1 from vehicles v where v.owner_id = o.id));
end $$;

-- ---------------------------------------------------------------- the investor portal opens for signing
-- An investor invited to sign (still a prospect) reaches the investor portal to sign their agreement.
alter function app.my_roles(uuid) rename to my_roles_0036;
create or replace function app.my_roles(p_user uuid) returns jsonb
language sql stable security definer set search_path = public, app as $$
  select app.my_roles_0036(p_user) || jsonb_build_object('investor',
    coalesce((app.my_roles_0036(p_user) ->> 'investor')::boolean, false)
    or exists (select 1 from investors i where i.user_id = p_user and i.status = 'prospect'
                  and (exists (select 1 from sign_requests r where r.investor_id = i.id and r.status in ('sent', 'signed'))
                       or exists (select 1 from investment_agreements a where a.investor_id = i.id and a.status = 'signed'))))
$$;

create or replace function app.investor_of(p_user uuid) returns investors
language plpgsql stable security definer set search_path = public, app as $$
declare
  i investors;
begin
  select * into i from investors where user_id = p_user and status in ('active', 'exited');
  if i.id is null then
    -- a prospect invited to sign their agreement
    select * into i from investors x where x.user_id = p_user and x.status = 'prospect'
       and (exists (select 1 from sign_requests r where r.investor_id = x.id and r.status in ('sent', 'signed'))
            or exists (select 1 from investment_agreements a where a.investor_id = x.id and a.status = 'signed'));
  end if;
  if i.id is null then raise exception 'This area is for investors who have signed in' using errcode = '42501'; end if;
  return i;
end $$;

-- ---------------------------------------------------------------- the screens' lists
-- Owner invoices still owing, for recording a payment received another way (Finance and Admins).
create or replace function app.owner_invoices_open(p_by uuid, p_q text default null) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
begin
  if not app.user_runs_finance(p_by) then raise exception 'Not permitted' using errcode = '42501'; end if;
  return coalesce((select jsonb_agg(jsonb_build_object('id', i.id, 'invoice_number', i.invoice_number, 'owner_id', i.owner_id, 'owner_name', o.legal_name,
             'vehicle_name', app.vehicle_name(i.vehicle_id), 'kind', i.kind, 'status', i.status, 'total_cents', i.total_cents, 'paid_cents', i.paid_cents,
             'balance_cents', i.balance_cents, 'billing_date', i.billing_date, 'debit_on', i.debit_on, 'manual', app.manual_payments_json(i.id, null, true))
             order by i.billing_date, i.invoice_number)
           from (select * from owner_invoices x where x.status in ('issued', 'failed', 'in_arrears', 'partially_deducted') and x.balance_cents > 0
                    and (nullif(btrim(coalesce(p_q, '')), '') is null or x.invoice_number ilike '%' || btrim(p_q) || '%'
                         or exists (select 1 from owners o2 where o2.id = x.owner_id and o2.legal_name ilike '%' || btrim(p_q) || '%'))
                  order by x.billing_date, x.invoice_number limit 100) i
           join owners o on o.id = i.owner_id), '[]'::jsonb);
end $$;

-- Staff agreements: each staff member with the agreement on file, how it was signed, and any document waiting (Admin).
create or replace function app.staff_agreements(p_by uuid) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
begin
  perform app.assert_admin(p_by);
  return coalesce((select jsonb_agg(jsonb_build_object('user_id', sp.user_id, 'name', u.full_name, 'email', u.email, 'staff_type', sp.staff_type,
             'function', coalesce(sp.va_function::text, sp.field_function::text), 'is_active', sp.is_active, 'agreement_document_id', sp.agreement_document_id,
             'signed', (select jsonb_build_object('method', case when ps.id is not null then 'paper' else r.method end, 'on', coalesce(ps.signed_on, app.local_date(r.signed_at)),
                                                  'paper_id', ps.id, 'document_id', coalesce(ps.document_id, r.signed_document_id, r.document_id))
                          from (select 1) one
                          left join lateral (select * from paper_signatures p where p.staff_user_id = sp.user_id and p.doc_type = 'staff_agreement' and p.voided_at is null
                                              and p.document_id = sp.agreement_document_id order by p.recorded_at desc limit 1) ps on true
                          left join lateral (select * from sign_requests x where x.staff_user_id = sp.user_id and x.status = 'signed'
                                              and sp.agreement_document_id in (x.document_id, x.signed_document_id) order by x.signed_at desc limit 1) r on true
                         where sp.agreement_document_id is not null),
             'open', (select jsonb_build_object('id', x.id, 'title', x.title, 'sent_at', x.sent_at) from sign_requests x
                       where x.staff_user_id = sp.user_id and x.status = 'sent' order by x.sent_at desc limit 1))
             order by sp.is_active desc, u.full_name)
           from staff_profiles sp join users u on u.id = sp.user_id), '[]'::jsonb);
end $$;

-- ================================================================ 4. emails and notices
-- CATALOGUE 0044 START (generated by supabase/seed/0044_gen_catalogue.mjs; do not edit by hand)
insert into notification_catalogue (code, audience, also_sent_to, category, is_digest, digest_slot, from_address, reply_to,
    subject, preheader, timing, trigger_text, replaces_template, link_path, variables, template_html, template_text) values
  ('owner_payment_recorded', 'owner', '{}'::text[], 'transactional', false, null, 'CarmaCars <billing@carmacars.ca>', 'billing@carmacars.ca', 'Receipt: {{amount}} received for invoice {{invoice_number}}', 'Paid by {{payment_method}} on {{payment_date}}. {{balance_line}}', 'Immediate', 'An Admin or Finance records a payment received outside the card processor (e-Transfer, cheque, cash, bank transfer or another way) on an owner invoice, in full or in part. The receipt for that payment; the automatic debit stops, or debits only what is still owing.', null, '/owner/invoices/{{invoice_number}}', '[{"name":"amount","type":"string"},{"name":"balance","type":"string"},{"name":"balance_line","type":"string"},{"name":"company_address","type":"string","global":true},{"name":"contact_email","type":"string","global":true},{"name":"debit_line","type":"string"},{"name":"first_name","type":"string"},{"name":"has_reference","type":"boolean"},{"name":"instagram_url","type":"url","global":true},{"name":"invoice_number","type":"string"},{"name":"is_paid_in_full","type":"boolean"},{"name":"opening_hours","type":"string","global":true},{"name":"payment_date","type":"string"},{"name":"payment_method","type":"string"},{"name":"reference","type":"string"},{"name":"reply_time","type":"string","global":true},{"name":"support_phone","type":"string","global":true},{"name":"tiktok_url","type":"url","global":true},{"name":"vehicle_name","type":"string"}]'::jsonb, 'templates/owner_payment_recorded.html', 'templates/owner_payment_recorded.txt'),
  ('owner_payment_reversed', 'owner', '{}'::text[], 'transactional', false, null, 'CarmaCars <billing@carmacars.ca>', 'billing@carmacars.ca', 'Payment for invoice {{invoice_number}} was not received', '{{amount}} by {{payment_method}} on {{payment_date}}. {{balance}} is owing.', 'Immediate', 'An Admin voids a payment that was recorded by hand on an owner invoice (for example a cheque that was returned, or a payment recorded on the wrong invoice), with the reason. The invoice owes that amount again.', null, '/owner/invoices/{{invoice_number}}', '[{"name":"amount","type":"string"},{"name":"balance","type":"string"},{"name":"company_address","type":"string","global":true},{"name":"contact_email","type":"string","global":true},{"name":"instagram_url","type":"url","global":true},{"name":"invoice_number","type":"string"},{"name":"opening_hours","type":"string","global":true},{"name":"payment_date","type":"string"},{"name":"payment_method","type":"string"},{"name":"reply_time","type":"string","global":true},{"name":"support_phone","type":"string","global":true},{"name":"tiktok_url","type":"url","global":true},{"name":"vehicle_name","type":"string"},{"name":"void_reason","type":"string"}]'::jsonb, 'templates/owner_payment_reversed.html', 'templates/owner_payment_reversed.txt')
on conflict (code) do update set
  audience = excluded.audience, also_sent_to = excluded.also_sent_to, category = excluded.category,
  is_digest = excluded.is_digest, digest_slot = excluded.digest_slot, from_address = excluded.from_address,
  reply_to = excluded.reply_to, subject = excluded.subject, preheader = excluded.preheader, timing = excluded.timing,
  trigger_text = excluded.trigger_text, replaces_template = excluded.replaces_template, link_path = excluded.link_path,
  variables = excluded.variables, template_html = excluded.template_html, template_text = excluded.template_text,
  in_catalogue = true, updated_at = now();
select app.notification_catalogue_refresh();
-- CATALOGUE 0044 END
update notification_catalogue set emitted_by = 'app.record_manual_payment (0044)' where code = 'owner_payment_recorded';
update notification_catalogue set emitted_by = 'app.void_manual_payment (0044)' where code = 'owner_payment_reversed';

-- in the portal only (no email): a document waiting for the person's signature
insert into notification_catalogue (code, audience, category, subject, preheader, has_email, priority, emitted_by, link_path)
values ('person_document_to_sign', 'investor', 'transactional', 'A document is ready for you to sign', '{{title}}. Read it and sign it in your portal.', false, 2,
        'app.sign_request_create (0044)', '/investor/sign')
on conflict (code) do nothing;

alter function app.notification_payload(text, app_events, jsonb) rename to ntf_payload_0040;
create or replace function app.notification_payload(p_code text, p_event app_events, p_to jsonb) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare
  x jsonb := app.ntf_payload_0040(p_code, p_event, p_to);
  m manual_payments;
  i owner_invoices;
begin
  if p_code in ('owner_payment_recorded', 'owner_payment_reversed') then
    select * into m from manual_payments where id = p_event.entity_id;
    select * into i from owner_invoices where id = m.owner_invoice_id;
    x := x || jsonb_build_object(
      'invoice_number', i.invoice_number,
      'amount', app.fmt_money(m.amount_cents),
      'payment_method', app.payment_method_label(m.method),
      'payment_date', app.fmt_day(m.received_on),
      'reference', coalesce(m.reference, ''), 'has_reference', m.reference is not null,
      'balance', app.fmt_money(case when i.status in ('paid', 'deducted') then 0 else greatest(i.balance_cents, 0) end),
      'is_paid_in_full', i.status in ('paid', 'deducted'),
      'balance_line', case when i.status in ('paid', 'deducted') then 'Paid in full.' else app.fmt_money(greatest(i.balance_cents, 0)) || ' still owing.' end,
      'debit_line', case when exists (select 1 from owner_debit_attempts a where a.owner_invoice_id = i.id and a.status = 'scheduled')
                         then 'Only what is still owing is debited, on ' || (select app.fmt_day(min(a.debit_on)) from owner_debit_attempts a where a.owner_invoice_id = i.id and a.status = 'scheduled') || '.'
                         else 'You can pay it from the invoice page.' end,
      'void_reason', coalesce(nullif(m.void_reason, ''), 'The payment was not received.'),
      '_url', app.ntf_link('owner_invoice', jsonb_build_object('invoice_number', i.invoice_number)));
    x := x || coalesce(app.ntf_vehicle(i.vehicle_id), '{}'::jsonb);
  end if;
  return x;
end $$;

-- ================================================================ 5. the doors
-- Staff screens through 0031's door: ops_read and ops_do names of this migration. Each function checks the role itself
-- (Admins for guides, paper signatures and documents to sign; Admins and Finance for manual payments).
create or replace function app.ops44(p_user uuid, p_call text, p_name text, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
begin
  case p_name
  -- guides
  when 'guides_admin' then return app.guides_admin(p_user);
  when 'guide_admin' then return app.guide_admin(p_user, p ->> 'portal');
  when 'guide_section_version' then return app.guide_section_version(p_user, (p ->> 'section')::uuid, (p ->> 'version')::integer, coalesce((p ->> 'published')::boolean, false));
  when 'guide_readers' then return app.guide_readers(p_user, p ->> 'portal');
  when 'guide_section_save' then return app.guide_section_save(p_user, p);
  when 'guide_section_move' then return app.guide_section_move(p_user, (p ->> 'id')::uuid, p ->> 'dir');
  when 'guide_section_delete' then return app.guide_section_delete(p_user, (p ->> 'id')::uuid);
  when 'guide_publish' then return app.guide_publish(p_user, p ->> 'portal', p -> 'html');
  when 'guide_pdf_record' then return app.guide_pdf_record(p_user, p);
  when 'guide_image_record' then return app.guide_image_record(p_user, p);
  -- manual payments
  when 'manual_payment_record' then return app.record_manual_payment(p_user, p);
  when 'manual_payment_void' then return app.void_manual_payment(p_user, (p ->> 'id')::uuid, p ->> 'reason');
  when 'manual_payments' then
    if not app.user_runs_finance(p_user) then raise exception 'Not permitted' using errcode = '42501'; end if;
    return app.manual_payments_json(nullif(p ->> 'invoice', '')::uuid, nullif(p ->> 'booking', '')::uuid, true);
  when 'manual_payments_month' then return app.manual_payments_month(p_user, nullif(p ->> 'month', '')::date);
  -- paper signatures and what is signed
  when 'paper_signature_record' then return app.record_paper_signature(p_user, p);
  when 'paper_signature_void' then return app.void_paper_signature(p_user, (p ->> 'id')::uuid, p ->> 'reason');
  when 'paper_signatures' then
    if not (app.user_is_admin(p_user) or app.user_va_has(p_user, 'cs')) then raise exception 'Not permitted' using errcode = '42501'; end if;
    return app.paper_signatures_json(nullif(p ->> 'owner', '')::uuid, nullif(p ->> 'booking', '')::uuid, nullif(p ->> 'investor', '')::uuid, nullif(p ->> 'staff', '')::uuid);
  when 'owner_checklists' then return app.owner_checklists(p_user, nullif(p ->> 'owner', '')::uuid);
  when 'owner_invoices_open' then return app.owner_invoices_open(p_user, p ->> 'q');
  -- a file staff open from these screens: a proof of payment (Finance), a rental document's paper scan (customer service)
  when 'staff_document' then
    return (select jsonb_build_object('bucket', d.storage_bucket, 'path', d.storage_path, 'mime_type', d.mime_type)
              from documents d
             where d.id = nullif(p ->> 'document', '')::uuid and d.storage_path is not null and d.purged_at is null
               and (app.user_is_admin(p_user)
                    or (app.user_runs_finance(p_user) and exists (select 1 from manual_payments m where m.proof_document_id = d.id))
                    or (app.user_va_has(p_user, 'cs') and exists (select 1 from paper_signatures ps where ps.document_id = d.id
                                                                     and ps.doc_type in ('rental_agreement', 'rental_amendment')))));
  when 'staff_agreements' then return app.staff_agreements(p_user);
  when 'owner_signables' then
    if not (app.user_is_admin(p_user) or app.user_va_has(p_user, 'finance', 'cs')) then raise exception 'Not permitted' using errcode = '42501'; end if;
    return app.owner_signables((p ->> 'owner')::uuid);
  -- documents sent to sign
  when 'sign_request_create' then return app.sign_request_create(p_user, p);
  when 'sign_request_void' then return app.sign_request_void(p_user, (p ->> 'id')::uuid, p ->> 'reason');
  when 'sign_requests' then
    perform app.assert_admin(p_user);
    return coalesce((select jsonb_agg(jsonb_build_object('id', r.id, 'doc_type', r.doc_type, 'title', r.title, 'status', r.status, 'signer_name', r.signer_name,
                       'sent_at', r.sent_at, 'signed_at', r.signed_at, 'method', r.method, 'document_id', r.document_id, 'signed_document_id', r.signed_document_id,
                       'void_reason', r.void_reason) order by r.sent_at desc)
                     from sign_requests r where (nullif(p ->> 'investor', '') is not null and r.investor_id = (p ->> 'investor')::uuid)
                        or (nullif(p ->> 'staff', '') is not null and r.staff_user_id = (p ->> 'staff')::uuid)
                        or (nullif(p ->> 'owner', '') is not null and r.owner_id = (p ->> 'owner')::uuid)), '[]'::jsonb);
  else
    raise exception 'Unknown action %', p_name using errcode = '22023';
  end case;
end $$;

alter function app.door(uuid, text, text, text, jsonb) rename to door_0042;
create or replace function app.door(p_user uuid, p_aal text, p_call text, p_name text, p jsonb default '{}'::jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
begin
  if p_call in ('ops_read', 'ops_do')
     and p_name in ('guides_admin', 'guide_admin', 'guide_section_version', 'guide_readers', 'guide_section_save', 'guide_section_move', 'guide_section_delete',
                    'guide_publish', 'guide_pdf_record', 'guide_image_record', 'manual_payment_record', 'manual_payment_void', 'manual_payments',
                    'manual_payments_month', 'paper_signature_record', 'paper_signature_void', 'paper_signatures', 'owner_checklists', 'owner_signables',
                    'sign_request_create', 'sign_request_void', 'sign_requests', 'owner_invoices_open', 'staff_agreements', 'staff_document') then
    perform app.door_begin(p_user, p_aal);
    if p_call = 'ops_read' and p_name not in ('guides_admin', 'guide_admin', 'guide_section_version', 'guide_readers', 'manual_payments', 'manual_payments_month',
                                              'paper_signatures', 'owner_checklists', 'owner_signables', 'sign_requests', 'owner_invoices_open', 'staff_agreements',
                                              'staff_document') then
      raise exception 'Unknown read %', p_name using errcode = '22023';
    end if;
    return app.ops44(p_user, p_call, p_name, coalesce(p, '{}'::jsonb) - '_va');
  end if;
  return app.door_0042(p_user, p_aal, p_call, p_name, p);
end $$;

-- The portals' own calls (the server, as the service role, with the signed-in person's id; each checks the person).
create or replace function public.guide_read(p_by uuid, p_portal text) returns jsonb
language sql stable security invoker set search_path = public, app as $$ select app.guide_read(p_by, p_portal) $$;
create or replace function public.guide_opened(p_by uuid, p_portal text) returns jsonb
language sql volatile security invoker set search_path = public, app as $$ select app.guide_opened(p_by, p_portal) $$;
create or replace function public.guide_banner(p_by uuid, p_portal text) returns boolean
language sql stable security invoker set search_path = public, app as $$ select app.guide_banner(p_by, p_portal) $$;
create or replace function public.guide_dismiss(p_by uuid, p_portal text) returns boolean
language sql volatile security invoker set search_path = public, app as $$ select app.guide_dismiss(p_by, p_portal) $$;
create or replace function public.guide_pdf_file(p_by uuid, p_portal text) returns jsonb
language sql stable security invoker set search_path = public, app as $$ select app.guide_pdf_file(p_by, p_portal) $$;
create or replace function public.server_guide_print_content(p_portal text) returns jsonb
language sql stable security invoker set search_path = public, app as $$ select app.guide_print_content(p_portal) $$;
create or replace function public.server_guide_pdf_record(p jsonb) returns jsonb
language sql volatile security invoker set search_path = public, app as $$ select app.guide_pdf_record(null, p) $$;
create or replace function public.owner_screen_forms(p_by uuid) returns jsonb
language sql stable security invoker set search_path = public, app as $$ select app.owner_screen_forms(app.portal_owner_id(p_by)) $$;
create or replace function public.server_owner_form_ab_facts(p_by uuid, p_code text) returns jsonb
language sql stable security invoker set search_path = public, app as $$ select app.owner_form_ab_facts(app.portal_owner_id(p_by), p_code) $$;
create or replace function public.owner_form_ab_open(p_by uuid, p_code text, p_sha256 text, p_path text, p_template_version text) returns jsonb
language sql volatile security invoker set search_path = public, app as $$ select app.owner_form_ab_open(p_by, p_code, p_sha256, p_path, p_template_version) $$;
create or replace function public.my_sign_requests(p_by uuid) returns jsonb
language sql stable security invoker set search_path = public, app as $$ select app.my_sign_requests(p_by) $$;
create or replace function public.sign_request_facts(p_by uuid, p_id uuid) returns jsonb
language sql stable security invoker set search_path = public, app as $$ select app.sign_request_facts(p_by, p_id) $$;
create or replace function public.sign_request_sign(p_by uuid, p_id uuid, p jsonb) returns jsonb
language sql volatile security invoker set search_path = public, app as $$ select app.sign_request_sign(p_by, p_id, p) $$;
create or replace function public.server_sign_request_attach(p_id uuid, p_path text, p_sha256 text) returns uuid
language sql volatile security invoker set search_path = public, app as $$ select app.sign_request_attach(p_id, p_path, p_sha256) $$;

-- A document the person may open from their signing page: one sent to them to sign, its signed copy, or a scan of
-- their own paper signature (investor and staff agreements).
create or replace function app.my_sign_document(p_user uuid, p_document uuid) returns jsonb
language sql stable security definer set search_path = public, app as $$
  select jsonb_build_object('bucket', d.storage_bucket, 'path', d.storage_path, 'title', d.title, 'mime_type', d.mime_type)
    from documents d
   where d.id = p_document and d.purged_at is null and d.storage_path is not null
     and (exists (select 1 from sign_requests r where r.signer_user_id = p_user and r.status <> 'voided' and d.id in (r.document_id, r.signed_document_id))
          or d.staff_user_id = p_user
          or (d.investor_id is not null and d.investor_id in (select i.id from investors i where i.user_id = p_user)
              and d.kind in ('investment_agreement', 'investment_schedule_a', 'investment_schedule_c', 'investment_schedule_d')))
$$;
create or replace function public.my_sign_document(p_by uuid, p_document uuid) returns jsonb
language sql stable security invoker set search_path = public, app as $$ select app.my_sign_document(p_by, p_document) $$;

-- ================================================================ 6. row-level security, privileges, audit
alter table guides enable row level security;
alter table guide_sections enable row level security;
alter table guide_section_versions enable row level security;
alter table guide_images enable row level security;
alter table guide_pdfs enable row level security;
alter table guide_reads enable row level security;
alter table manual_payments enable row level security;
alter table sign_requests enable row level security;
alter table paper_signatures enable row level security;
create policy admin_all on guides for all to authenticated using (app.is_admin()) with check (app.is_admin());
create policy admin_all on guide_sections for all to authenticated using (app.is_admin()) with check (app.is_admin());
create policy admin_all on guide_section_versions for all to authenticated using (app.is_admin()) with check (app.is_admin());
create policy admin_all on guide_images for all to authenticated using (app.is_admin()) with check (app.is_admin());
create policy admin_all on guide_pdfs for all to authenticated using (app.is_admin()) with check (app.is_admin());
create policy admin_all on guide_reads for all to authenticated using (app.is_admin()) with check (app.is_admin());
create policy own_read on guide_reads for select to authenticated using (user_id = app.uid());
create policy admin_all on manual_payments for all to authenticated using (app.is_admin()) with check (app.is_admin());
create policy finance_read on manual_payments for select to authenticated using (app.va_has('finance'));
create policy owner_read on manual_payments for select to authenticated using (owner_id is not null and app.is_my_owner(owner_id));
create policy admin_all on sign_requests for all to authenticated using (app.is_admin()) with check (app.is_admin());
create policy own_read on sign_requests for select to authenticated using (signer_user_id = app.uid());
create policy admin_all on paper_signatures for all to authenticated using (app.is_admin()) with check (app.is_admin());
create policy cs_read on paper_signatures for select to authenticated using (app.va_has('cs') and booking_id is not null);
revoke all on guides, guide_sections, guide_section_versions, guide_images, guide_pdfs, guide_reads, manual_payments, sign_requests, paper_signatures
  from anon, authenticated;
grant select on guides, guide_sections, guide_section_versions, guide_images, guide_pdfs, guide_reads, manual_payments, sign_requests, paper_signatures to authenticated;
grant all on guides, guide_sections, guide_section_versions, guide_images, guide_pdfs, guide_reads, manual_payments, sign_requests, paper_signatures to service_role;
grant usage on sequence guide_section_versions_id_seq, investment_agreement_number_seq to service_role;

do $$
declare
  f record;
begin
  for f in
    select p.oid::regprocedure as sig from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where (n.nspname = 'app' and p.proname = any (array[
              'guide_access', 'guide_read', 'guide_pdf_file', 'guide_opened', 'guide_banner', 'guide_dismiss', 'guides_admin', 'guide_admin', 'guide_section_version',
              'guide_section_save', 'guide_section_move', 'guide_section_delete', 'guide_publish', 'guide_pdf_record', 'guide_image_record', 'guide_readers',
              'guide_print_content', 'manual_payment_allowed', 'record_manual_payment', 'void_manual_payment', 'manual_payments_json', 'manual_payments_month',
              'request_method', 'paper_records', 'owner_vehicles_signed', 'owner_screen_forms', 'owner_form_ab_facts', 'owner_form_ab_open', 'investment_signed',
              'sign_request_create', 'sign_request_void', 'my_sign_requests', 'sign_request_facts', 'sign_request_sign', 'sign_request_attach',
              'record_paper_signature', 'void_paper_signature', 'paper_signatures_json', 'owner_signables', 'owner_checklists', 'my_sign_document', 'ops44',
              'owner_invoices_open', 'staff_agreements']))
        or (n.nspname = 'public' and p.proname = any (array['guide_read', 'guide_opened', 'guide_banner', 'guide_dismiss', 'guide_pdf_file', 'server_guide_print_content',
              'server_guide_pdf_record', 'owner_screen_forms', 'server_owner_form_ab_facts', 'owner_form_ab_open', 'my_sign_requests', 'sign_request_facts',
              'sign_request_sign', 'server_sign_request_attach', 'my_sign_document']))
  loop
    execute format('revoke all on function %s from public, anon, authenticated', f.sig);
    execute format('grant execute on function %s to service_role', f.sig);
  end loop;
end $$;
-- pure functions of their arguments
grant execute on function app.payment_method_label(text), app.paper_doc_kind(text), app.paper_doc_title(text) to service_role;
revoke execute on function app.payment_method_label(text), app.paper_doc_kind(text), app.paper_doc_title(text) from public, anon, authenticated;

-- Each wrapper keeps the privileges of the function it wraps (a new function would otherwise be open to everyone).
do $$
declare
  r record;
  v_new regprocedure;
  g text;
begin
  for r in select p.oid, m.new_name, oidvectortypes(p.proargtypes) as args
             from pg_proc p join pg_namespace n on n.oid = p.pronamespace
             join (values ('owner_invoice_view_0037', 'owner_invoice_view'), ('ntf_payload_0040', 'notification_payload'),
                          ('door_0042', 'door'), ('my_roles_0036', 'my_roles')) m(old_name, new_name) on m.old_name = p.proname
            where n.nspname = 'app' loop
    v_new := format('app.%I(%s)', r.new_name, r.args)::regprocedure;
    execute format('revoke execute on function %s from public, anon, authenticated', v_new);
    foreach g in array array['anon', 'authenticated', 'service_role'] loop
      if has_function_privilege(g, r.oid, 'execute') then execute format('grant execute on function %s to %I', v_new, g); end if;
    end loop;
  end loop;
end $$;

select app.attach_audit();
