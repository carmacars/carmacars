-- 3601 (release 49): the gift cards academy section (3600) is optional. A section marked optional counts as passed for every
-- gate (portal unlock, onboarding, path progress), so no staff member is locked out by a lesson added after they were hired.
-- It is still taught, and the quiz can still be taken.
alter table academy_sections add column if not exists optional boolean not null default false;
comment on column academy_sections.optional is 'Release 49 (3601): an optional section counts as passed for every gate; the lesson and quiz stay available.';
update academy_sections set optional = true where slug = 'r49-gift-cards';

create or replace function app.academy_passed(p_user uuid, p_section uuid) returns boolean
language sql stable security definer set search_path = public, app as $$
  select exists (select 1 from academy_sections s where s.id = p_section and s.optional)
      or exists (select 1 from academy_attempts a where a.user_id = p_user and a.section_id = p_section and a.passed
                    and a.created_at > app.academy_since(p_user, p_section))
$$;
