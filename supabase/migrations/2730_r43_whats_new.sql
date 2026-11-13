-- 2730_r43_whats_new.sql
-- Release 43: a "What's new" pop-up once per person and release, in every portal. The text comes from the release notes
-- (docs/releases/rNN.md, built into web/src/generated/whats-new.json); the database keeps only who has seen what, so the
-- pop-up shows once on the next visit and the "What's new" link in the menu opens it again.
--   1. user_release_seen: one row per person, release and portal (renter, owner, partner, investor, staff, admin).
--   2. public.release_seen_mark(release, portal, by): marks one pop-up as seen (server only; the server passes the person).
--   3. public.release_seen_list(by, portal): the releases this person has seen in that portal.
-- No data is written by this migration.

create table public.user_release_seen (
  user_id uuid not null references users (id) on delete cascade,
  release text not null check (release ~ '^[a-z0-9][a-z0-9_-]{0,31}$'),
  portal text not null check (portal in ('renter', 'owner', 'partner', 'investor', 'staff', 'admin')),
  seen_at timestamptz not null default now(),
  primary key (user_id, release, portal)
);
comment on table public.user_release_seen is 'Which release "What''s new" pop-up each person has seen, per portal (2730). Written by release_seen_mark only.';
-- the primary key starts with user_id, which is the foreign key's index
alter table public.user_release_seen enable row level security;
revoke all on table public.user_release_seen from public, anon, authenticated;
grant select, insert, update, delete on table public.user_release_seen to service_role;
create policy admin_all on public.user_release_seen for select to authenticated using (app.is_admin());
create policy own_read on public.user_release_seen for select to authenticated using (user_id = auth.uid());
grant select on table public.user_release_seen to authenticated;

-- Both are called by the server (service role) with the signed-in person's id, like the guides' functions; the browser roles
-- have no execute (the security suite's door lists what a signed-in session may call).
create function public.release_seen_mark(p_release text, p_portal text, p_by uuid) returns boolean
language plpgsql volatile security definer set search_path = public, app as $$
begin
  if p_by is null or not exists (select 1 from users where id = p_by) then raise exception 'Unknown person' using errcode = '42501'; end if;
  insert into user_release_seen (user_id, release, portal) values (p_by, p_release, p_portal)
  on conflict (user_id, release, portal) do nothing;
  return true;
end $$;
revoke all on function public.release_seen_mark(text, text, uuid) from public, anon, authenticated;
grant execute on function public.release_seen_mark(text, text, uuid) to service_role;

create function public.release_seen_list(p_by uuid, p_portal text) returns text[]
language sql stable security definer set search_path = public, app as $$
  select coalesce(array_agg(release order by release), '{}') from user_release_seen where user_id = p_by and portal = p_portal
$$;
revoke all on function public.release_seen_list(uuid, text) from public, anon, authenticated;
grant execute on function public.release_seen_list(uuid, text) to service_role;
-- SCHEMA_MARKER 2730.
