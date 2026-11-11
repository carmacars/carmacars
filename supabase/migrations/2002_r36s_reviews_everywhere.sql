-- 2002_r36s_reviews_everywhere.sql
-- Release 36, SEO (docs/changes/2026-11-11-r36-seo-growth.md), part 12: real reviews on every car page and search page.
--   1. Reviews that arrived outside the site (Turo and other platforms, text messages, phone calls, email, in person,
--      Google) are entered by an Admin or a customer service or sales staff member with "Add a customer review": the
--      reviewer's first name and last initial, the source, the date received, the rating, the customer's own words as
--      received, an optional proof (a screenshot) and who entered it. Only real customer feedback: the words are kept
--      as given (never edited after), a name must be "First L.", a date cannot be in the future, the same review cannot
--      be entered twice, and nothing is generated. An Admin can hide one for cause; it is never deleted.
--   2. public.review_summary(vehicle): the site's published reviews and these together, each with its source label
--      ("via Turo"), the count and average for AggregateRating (only at seo_rating_min_reviews or more, as before), and
--      the car's completed rentals only when there are seo_rental_count_min (3) or more. With no car, or a car with no
--      review, the fleet's reviews (the pages show those instead of an empty block).
-- No applied migration is edited.

alter table program_settings add column if not exists seo_rental_count_min integer not null default 3 check (seo_rental_count_min between 1 and 100);
comment on column program_settings.seo_rental_count_min is 'Reviews on the search pages (2002): a car''s completed-rental count is shown only from this many (3).';

create table if not exists outside_reviews (
  id            uuid primary key default gen_random_uuid(),
  vehicle_id    uuid references vehicles (id),
  reviewer_name text not null check (reviewer_name ~ '^[A-Z][A-Za-z''’-]{0,39}( [A-Z][A-Za-z''’-]{0,39})? [A-Z]\.$'),
  source        text not null check (source in ('turo', 'previous_platform', 'text_message', 'phone_call', 'email', 'in_person', 'google')),
  received_on   date not null check (received_on >= date '2015-01-01'),
  rating        smallint not null check (rating between 1 and 5),
  body          text not null check (length(btrim(body)) between 3 and 3000),
  proof_path    text check (proof_path is null or proof_path ~ '^outside-reviews/[0-9a-f-]{36}\.(jpg|png|pdf)$'),
  proof_mime    text check (proof_mime is null or proof_mime in ('image/jpeg', 'image/png', 'application/pdf')),
  status        text not null default 'published' check (status in ('published', 'hidden')),
  hidden_reason text check (hidden_reason is null or hidden_reason in ('personal_information', 'abusive', 'not_about_the_rental', 'entered_by_mistake')),
  hidden_by     uuid references users (id),
  entered_by    uuid not null references users (id),
  created_at    timestamptz not null default now(),
  check ((status = 'hidden') = (hidden_reason is not null))
);
create unique index if not exists outside_reviews_once on outside_reviews (lower(reviewer_name), received_on, md5(btrim(body)));
create index if not exists outside_reviews_vehicle on outside_reviews (vehicle_id, received_on desc) where status = 'published';
comment on table outside_reviews is 'Customer reviews received outside the site (2002), entered by staff exactly as received, with the source and an optional proof. Shown with "via <source>" beside the site''s reviews and counted in AggregateRating.';
alter table outside_reviews enable row level security;
revoke all on outside_reviews from public, anon, authenticated;
grant select, insert, update on outside_reviews to service_role;
drop policy if exists admin_all on outside_reviews;
create policy admin_all on outside_reviews for all to authenticated using (app.is_admin()) with check (app.is_admin());
drop trigger if exists audit_outside_reviews on outside_reviews;
create trigger audit_outside_reviews after insert or update or delete on outside_reviews for each row execute function app.audit_row();

-- the words, name, rating, source and date are what the customer gave: never changed after entry (hide is the only change)
create or replace function app.outside_review_guard() returns trigger
language plpgsql security definer set search_path = public, app as $$
begin
  if tg_op = 'DELETE' then raise exception 'A customer review is never deleted: hide it with a reason' using errcode = '42501'; end if;
  if tg_op = 'INSERT' and new.received_on > app.local_date(now()) then raise exception 'The date received cannot be in the future' using errcode = '22023'; end if;
  if tg_op = 'UPDATE' and (new.reviewer_name, new.source, new.received_on, new.rating, new.body, new.entered_by, new.created_at, new.proof_path)
                          is distinct from (old.reviewer_name, old.source, old.received_on, old.rating, old.body, old.entered_by, old.created_at, old.proof_path) then
    raise exception 'A customer review is kept as received: only hiding or showing it can change' using errcode = '42501';
  end if;
  return case when tg_op = 'DELETE' then old else new end;
end $$;
drop trigger if exists outside_review_guard on outside_reviews;
create trigger outside_review_guard before insert or update or delete on outside_reviews for each row execute function app.outside_review_guard();

create or replace function app.outside_review_source_label(p text) returns text
language sql immutable as $$
  select case p when 'turo' then 'via Turo' when 'previous_platform' then 'via a previous rental platform' when 'text_message' then 'via text message'
                when 'phone_call' then 'via phone call' when 'email' then 'via email' when 'in_person' then 'in person' when 'google' then 'via Google' else 'on CarmaCars' end
$$;

-- Add a customer review: an Admin, or customer service or sales staff
create or replace function app.outside_review_add(p_by uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  v_name text := regexp_replace(btrim(coalesce(p ->> 'reviewer_name', '')), '\s+', ' ', 'g');
  v_vehicle uuid := nullif(p ->> 'vehicle_id', '')::uuid;
  r outside_reviews;
begin
  if not (app.user_is_admin(p_by) or app.user_va_has(p_by, variadic array['cs', 'sales'])) then
    raise exception 'Only an Admin, customer service or sales can add a customer review' using errcode = '42501';
  end if;
  if v_name !~ '^[A-Z][A-Za-z''’-]{0,39}( [A-Z][A-Za-z''’-]{0,39})? [A-Z]\.$' then
    raise exception 'Write the reviewer as first name and last initial, like "Sarah K."' using errcode = '22023';
  end if;
  if v_vehicle is not null and not exists (select 1 from vehicles where id = v_vehicle) then raise exception 'Car not found' using errcode = 'P0002'; end if;
  if (p ->> 'proof_path') is not null and (p ->> 'proof_path') !~ ('^outside-reviews/[0-9a-f-]{36}\.(jpg|png|pdf)$') then raise exception 'Unknown proof file' using errcode = '22023'; end if;
  begin
    insert into outside_reviews (vehicle_id, reviewer_name, source, received_on, rating, body, proof_path, proof_mime, entered_by)
    values (v_vehicle, v_name, p ->> 'source', (p ->> 'received_on')::date, (p ->> 'rating')::smallint, btrim(p ->> 'body'), nullif(p ->> 'proof_path', ''), nullif(p ->> 'proof_mime', ''), p_by)
    returning * into r;
  exception when unique_violation then
    raise exception 'This review is already entered' using errcode = '23505';
  end;
  return jsonb_build_object('id', r.id);
end $$;

-- hide or show again (an Admin, for cause; never because it is negative)
create or replace function app.outside_review_hide(p_by uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare v_reason text := nullif(p ->> 'reason', '');
begin
  perform app.assert_admin(p_by);
  update outside_reviews set status = case when v_reason is null then 'published' else 'hidden' end, hidden_reason = v_reason, hidden_by = case when v_reason is null then null else p_by end
   where id = (p ->> 'id')::uuid;
  if not found then raise exception 'Review not found' using errcode = 'P0002'; end if;
  return jsonb_build_object('ok', true);
end $$;

-- the list for the staff screens
create or replace function app.outside_review_list(p_by uuid) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
begin
  if not (app.user_is_admin(p_by) or app.user_va_has(p_by, variadic array['cs', 'sales'])) then raise exception 'Not allowed' using errcode = '42501'; end if;
  return (select coalesce(jsonb_agg(jsonb_build_object('id', o.id, 'reviewer_name', o.reviewer_name, 'source', o.source, 'source_label', app.outside_review_source_label(o.source),
      'received_on', o.received_on, 'rating', o.rating, 'body', o.body, 'status', o.status, 'hidden_reason', o.hidden_reason, 'proof', o.proof_path is not null,
      'vehicle', case when v.id is null then null else concat_ws(' ', v.year, v.make, v.model) end, 'entered_by', coalesce(u.full_name, u.email), 'created_at', o.created_at)
      order by o.received_on desc, o.created_at desc), '[]'::jsonb)
    from outside_reviews o left join vehicles v on v.id = o.vehicle_id left join users u on u.id = o.entered_by);
end $$;

-- the reviews a public page shows: the car's own (site and outside), else the fleet's
create or replace function public.review_summary(p_vehicle uuid default null) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare
  st program_settings := app.settings();
  v_scope text := 'car';
  v_rentals integer;
  v_out jsonb;
begin
  if p_vehicle is null or (not exists (select 1 from reviews where vehicle_id = p_vehicle and status = 'published')
                           and not exists (select 1 from outside_reviews where vehicle_id = p_vehicle and status = 'published')) then
    v_scope := 'fleet';
  end if;
  with items as (
    select x.rating::integer as rating, x.title, x.body, x.reviewer_first_name as name, x.review_month::date as month, x.staff_reply as reply, 'site' as source, 'on CarmaCars' as source_label, x.vehicle_label,
           coalesce((select rv.reward_points from reviews rv where rv.id = x.review_id), false) as rewarded
      from app.public_reviews(case when v_scope = 'car' then p_vehicle end, 100, 0) x
    union all
    select o.rating::integer, null::text, o.body, o.reviewer_name, app.month_start(o.received_on), null, o.source, app.outside_review_source_label(o.source), concat_ws(' ', v.year, v.make, v.model), false
      from outside_reviews o left join vehicles v on v.id = o.vehicle_id
     where o.status = 'published' and (v_scope = 'fleet' or o.vehicle_id = p_vehicle)
  )
  select jsonb_build_object('scope', v_scope, 'count', count(*), 'average', round(avg(rating)::numeric, 1), 'min_for_rating', st.seo_rating_min_reviews,
           'items', coalesce((select jsonb_agg(to_jsonb(i) order by i.month desc, i.name) from (select * from items order by month desc, name limit 12) i), '[]'::jsonb))
    into v_out from items;
  if p_vehicle is not null then
    select count(*) into v_rentals from bookings b where b.vehicle_id = p_vehicle and b.status::text in ('returned', 'completed');
    v_out := v_out || jsonb_build_object('rentals', case when v_rentals >= st.seo_rental_count_min then v_rentals end);
  end if;
  return v_out;
end $$;

-- the door: Add a customer review, hide, the list (ops_* for staff, admin_* for an Admin)
alter function app.door(uuid, text, text, text, jsonb) rename to door_pre2002;
create function app.door(p_user uuid, p_aal text, p_call text, p_name text, p jsonb default '{}'::jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare p_ jsonb := coalesce(p, '{}'::jsonb) - '_va';
begin
  if p_call in ('ops_do', 'admin_do', 'va_do') and p_name in ('outside_review_add', 'outside_review_hide') then
    perform app.door_begin(p_user, p_aal);
    return case p_name when 'outside_review_add' then app.outside_review_add(p_user, p_) else app.outside_review_hide(p_user, p_) end;
  end if;
  if p_call in ('ops_read', 'admin_read', 'va_read') and p_name = 'outside_reviews' then
    perform app.door_begin(p_user, p_aal);
    return app.outside_review_list(p_user);
  end if;
  return app.door_pre2002(p_user, p_aal, p_call, p_name, p);
end $$;
do $$
declare g text;
begin
  execute 'revoke all on function app.door(uuid, text, text, text, jsonb) from public, anon, authenticated';
  foreach g in array array['anon', 'authenticated', 'service_role'] loop
    if has_function_privilege(g, 'app.door_pre2002(uuid, text, text, text, jsonb)'::regprocedure, 'execute') then execute format('grant execute on function app.door(uuid, text, text, text, jsonb) to %I', g); end if;
  end loop;
end $$;

revoke all on function app.outside_review_guard(), app.outside_review_add(uuid, jsonb), app.outside_review_hide(uuid, jsonb), app.outside_review_list(uuid), app.door_pre2002(uuid, text, text, text, jsonb) from public, anon, authenticated;
grant execute on function app.outside_review_guard(), app.outside_review_add(uuid, jsonb), app.outside_review_hide(uuid, jsonb), app.outside_review_list(uuid), app.door_pre2002(uuid, text, text, text, jsonb) to service_role;
revoke all on function app.outside_review_source_label(text) from public, anon, authenticated;
grant execute on function app.outside_review_source_label(text) to service_role;
grant execute on function public.review_summary(uuid) to anon, authenticated, service_role;
