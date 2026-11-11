-- 2220_r36b_social_scheduler.sql
-- Release 36b, item 3. The owner: "automating social media across Instagram and TikTok and reels and Facebook" and
-- "Facebook marketplace automation".
--   1. social_queue: posts Marketing staff (Admin, Fleet, customer service, Sales: app.marketing_may) schedule for a time:
--      a channel (the Facebook Page, Instagram or TikTok), a photo or a short video (2210), and the caption (typed, or taken
--      from a social draft of 0167 with its link). Every change is logged in social_post_log.
--   2. Publishing: a pg_cron job (carmacars-social-queue, every 5 minutes) marks the posts whose time has come as due. When
--      Meta publishing is connected (Admin > Settings > Meta publishing, 0167: the Page id, the Instagram business account
--      id and the Page token in Vault; empty by default) the ads job of the Worker (its flag in server_jobs_due) posts the
--      due Facebook and Instagram posts through the Graph API and records each result (three tries, then failed). Without
--      it the queue says "Connect Meta" and works as a list to copy, download and post by hand ("Posted by hand").
--   3. TikTok is never posted automatically: its Content Posting API needs Meta-like app review by TikTok first. A due TikTok
--      post shows the download and post checklist and is marked posted by hand.
--   4. Facebook Marketplace has no API: the Marketplace kit and the session flow (0410, 0510) stay as they are.
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

create table if not exists social_queue (
  id            uuid primary key default gen_random_uuid(),
  channel       text not null check (channel in ('facebook_page', 'instagram', 'tiktok')),
  media_kind    text not null check (media_kind in ('photo', 'video', 'none')),
  media_path    text check (media_path is null or media_path ~ '^(vehicles|site)/[A-Za-z0-9/_.-]{3,250}$'),
  video_id      uuid references social_videos (id) on delete set null,
  draft_id      uuid references social_drafts (id) on delete set null,
  vehicle_id    uuid references vehicles (id) on delete set null,
  caption       text not null check (length(caption) between 1 and 2200),
  link          text check (link is null or link ~ '^https://[^[:space:]]+$'),
  scheduled_at  timestamptz not null,
  status        text not null default 'queued' check (status in ('queued', 'due', 'posting', 'posted', 'failed', 'cancelled')),
  how           text check (how in ('api', 'hand')),
  attempts      integer not null default 0 check (attempts >= 0),
  post_id       text,
  post_url      text check (post_url is null or post_url ~ '^https://[^[:space:]]+$'),
  error         text check (error is null or length(error) <= 300),
  created_by    uuid references users (id) on delete set null,
  posted_by     uuid references users (id) on delete set null,
  posted_at     timestamptz,
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now(),
  check ((media_kind = 'none') = (media_path is null)),
  check (channel = 'facebook_page' or media_kind <> 'none'),
  check (channel <> 'instagram' or media_kind <> 'video' or media_path like '%.mp4'),
  check (status <> 'posted' or (posted_at is not null and how is not null)),
  check (channel <> 'tiktok' or how is distinct from 'api')
);
comment on table social_queue is 'Social posts scheduled for a time (2220): the Facebook Page and Instagram are posted through the Graph API when Meta publishing is connected (else by hand); TikTok always by hand (its posting API needs app review). Logged in social_post_log.';
create index if not exists social_queue_due on social_queue (scheduled_at) where status in ('queued', 'due', 'posting');
create index if not exists social_queue_recent on social_queue (created_at desc);
create trigger social_queue_updated before update on social_queue for each row execute function app.set_updated_at();
create trigger audit_social_queue after insert or update or delete on social_queue for each row execute function app.audit_row();
alter table social_queue enable row level security;
create policy admin_all on social_queue for all to authenticated using (app.is_admin()) with check (app.is_admin());
revoke all on social_queue from public, anon, authenticated;
grant select on social_queue to authenticated;
grant all on social_queue to service_role;

create table if not exists social_post_log (
  id        bigserial primary key,
  queue_id  uuid not null references social_queue (id) on delete cascade,
  at        timestamptz not null default now(),
  event     text not null check (event in ('queued', 'due', 'posting', 'posted', 'failed', 'retry', 'cancelled', 'by_hand', 'edited')),
  detail    text check (detail is null or length(detail) <= 400),
  by_user   uuid references users (id) on delete set null
);
comment on table social_post_log is 'What happened to each scheduled social post (2220): queued, due, posted through Meta or by hand, failed with Meta''s answer.';
create index if not exists social_post_log_queue on social_post_log (queue_id, at);
alter table social_post_log enable row level security;
create policy admin_all on social_post_log for all to authenticated using (app.is_admin()) with check (app.is_admin());
revoke all on social_post_log, social_post_log_id_seq from public, anon, authenticated;
grant select on social_post_log to authenticated;
grant all on social_post_log to service_role;
grant usage on sequence social_post_log_id_seq to service_role;

create or replace function app.social_log(p_queue uuid, p_event text, p_detail text default null, p_by uuid default null) returns void
language sql security definer set search_path = public, app as $$
  insert into social_post_log (queue_id, event, detail, by_user) values (p_queue, p_event, left(p_detail, 400), p_by)
$$;

create or replace function app.social_queue_row(x social_queue) returns jsonb
language sql stable security definer set search_path = public, app as $$
  select jsonb_build_object('id', x.id, 'channel', x.channel, 'media_kind', x.media_kind, 'media_path', x.media_path, 'video_id', x.video_id, 'draft_id', x.draft_id,
    'vehicle_id', x.vehicle_id, 'car', case when x.vehicle_id is not null then app.vehicle_name(x.vehicle_id) end, 'caption', x.caption, 'link', x.link,
    'scheduled_at', x.scheduled_at, 'status', x.status, 'how', x.how, 'attempts', x.attempts, 'post_url', x.post_url, 'error', x.error, 'posted_at', x.posted_at,
    'by', (select u.full_name from users u where u.id = x.created_by),
    'log', coalesce((select jsonb_agg(jsonb_build_object('at', l.at, 'event', l.event, 'detail', l.detail) order by l.at, l.id) from social_post_log l where l.queue_id = x.id), '[]'::jsonb))
$$;

-- the queue for the screen: what is coming and the last two weeks, whether Meta is connected, the drafts and videos to use
create or replace function app.social_queue_read(p_by uuid, p jsonb) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare m meta_publishing;
begin
  if not app.marketing_may(p_by) then raise exception 'Not permitted' using errcode = '42501'; end if;
  select * into m from meta_publishing;
  return jsonb_build_object('now', now(), 'meta', jsonb_build_object('connected', app.meta_usable(m), 'instagram', app.meta_usable(m) and m.ig_user_id is not null, 'last_error', m.last_error),
    'posts', coalesce((select jsonb_agg(app.social_queue_row(x) order by x.scheduled_at desc) from (
        select * from social_queue where status in ('queued', 'due', 'posting') or scheduled_at > now() - interval '14 days' order by scheduled_at desc limit 200) x), '[]'::jsonb),
    'drafts', coalesce((select jsonb_agg(jsonb_build_object('id', d.id, 'day', d.slot_date, 'kind', d.kind, 'car', case when d.vehicle_id is not null then app.vehicle_name(d.vehicle_id) end,
                          'vehicle_id', d.vehicle_id, 'caption', d.caption, 'link', d.link, 'photo', d.photos ->> 0) order by d.slot_date, d.created_at)
                         from social_drafts d where d.status in ('draft', 'approved') and d.slot_date >= app.today() - 7), '[]'::jsonb),
    'videos', coalesce((select jsonb_agg(jsonb_build_object('id', v.id, 'vehicle_id', v.vehicle_id, 'car', app.vehicle_name(v.vehicle_id), 'path', v.path, 'mime', v.mime, 'seconds', v.seconds, 'at', v.created_at) order by v.created_at desc)
                         from (select * from social_videos where removed_at is null order by created_at desc limit 30) v), '[]'::jsonb));
end $$;

-- p: channel, scheduled_at, caption (or draft: the draft's caption and link), media: photo path | video id | none, link
create or replace function app.social_queue_add(p_by uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  d social_drafts;
  v social_videos;
  v_channel text := p ->> 'channel';
  v_at timestamptz := nullif(p ->> 'scheduled_at', '')::timestamptz;
  v_caption text := nullif(btrim(coalesce(p ->> 'caption', '')), '');
  v_link text := nullif(btrim(coalesce(p ->> 'link', '')), '');
  v_kind text := 'none';
  v_path text;
  v_vehicle uuid := nullif(p ->> 'vehicle', '')::uuid;
  x social_queue;
begin
  if not app.marketing_may(p_by) then raise exception 'An Admin, Fleet, customer service or Sales schedules social posts' using errcode = '42501'; end if;
  if v_channel is null or v_channel not in ('facebook_page', 'instagram', 'tiktok') then raise exception 'Choose the Facebook Page, Instagram or TikTok' using errcode = '22023'; end if;
  if v_at is null then raise exception 'Choose when to post it' using errcode = '22023'; end if;
  if v_at < now() - interval '10 minutes' then raise exception 'The time has passed: choose a time from now on' using errcode = '22023'; end if;
  if nullif(p ->> 'draft', '') is not null then
    select * into d from social_drafts where id = (p ->> 'draft')::uuid;
    if d.id is null then raise exception 'Unknown draft' using errcode = 'P0002'; end if;
    v_caption := coalesce(v_caption, d.caption);
    v_link := coalesce(v_link, d.link);
    v_vehicle := coalesce(v_vehicle, d.vehicle_id);
  end if;
  if v_caption is null then raise exception 'Write the caption or choose a draft' using errcode = '22023'; end if;
  if nullif(p ->> 'video', '') is not null then
    select * into v from social_videos where id = (p ->> 'video')::uuid and removed_at is null;
    if v.id is null then raise exception 'Unknown video' using errcode = 'P0002'; end if;
    if v_channel = 'instagram' and v.mime <> 'video/mp4' then raise exception 'Instagram takes MP4 videos only: make the video in Chrome, Edge or Safari, or post it on Facebook or TikTok' using errcode = '23514'; end if;
    v_kind := 'video'; v_path := v.path; v_vehicle := coalesce(v_vehicle, v.vehicle_id);
  elsif nullif(p ->> 'photo', '') is not null then
    v_path := p ->> 'photo';
    -- a photo already on the site (a car's public photo, a made cover or a draft's photo): never a private file
    if v_path !~ '^(vehicles|site)/[A-Za-z0-9/_.-]{3,250}\.(jpg|jpeg|png|webp)$' or v_path like '%/original/%' then raise exception 'Choose a photo on the site' using errcode = '22023'; end if;
    v_kind := 'photo';
  end if;
  if v_channel <> 'facebook_page' and v_kind = 'none' then raise exception '% needs a photo or a video', case v_channel when 'instagram' then 'Instagram' else 'TikTok' end using errcode = '23514'; end if;
  if v_channel = 'tiktok' and v_kind <> 'video' then raise exception 'TikTok posts are videos: make a short video first' using errcode = '23514'; end if;
  insert into social_queue (channel, media_kind, media_path, video_id, draft_id, vehicle_id, caption, link, scheduled_at, created_by)
  values (v_channel, v_kind, v_path, v.id, d.id, v_vehicle, left(v_caption, 2200), v_link, v_at, p_by) returning * into x;
  perform app.social_log(x.id, 'queued', format('%s at %s', v_channel, to_char(v_at at time zone 'America/Toronto', 'YYYY-MM-DD HH24:MI')), p_by);
  return app.social_queue_row(x);
end $$;

-- p: id, action: cancel | posted (url: the post's address, by hand) | retry | requeue (scheduled_at)
create or replace function app.social_queue_act(p_by uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare x social_queue; v_action text := p ->> 'action'; v_url text := nullif(btrim(coalesce(p ->> 'url', '')), '');
begin
  if not app.marketing_may(p_by) then raise exception 'An Admin, Fleet, customer service or Sales schedules social posts' using errcode = '42501'; end if;
  select * into x from social_queue where id = nullif(p ->> 'id', '')::uuid for update;
  if x.id is null then raise exception 'Unknown post' using errcode = 'P0002'; end if;
  if v_action = 'cancel' then
    if x.status not in ('queued', 'due', 'failed') then raise exception 'Only a post not yet posted can be cancelled' using errcode = '23514'; end if;
    update social_queue set status = 'cancelled' where id = x.id returning * into x;
    perform app.social_log(x.id, 'cancelled', null, p_by);
  elsif v_action = 'posted' then
    if x.status not in ('queued', 'due', 'failed') then raise exception 'This post is already posted, being posted or cancelled' using errcode = '23514'; end if;
    if v_url is not null and v_url !~ '^https://[^[:space:]]+$' then raise exception 'Paste the post''s full address (https://...)' using errcode = '22023'; end if;
    update social_queue set status = 'posted', how = 'hand', post_url = v_url, posted_by = p_by, posted_at = now(), error = null where id = x.id returning * into x;
    perform app.social_log(x.id, 'by_hand', v_url, p_by);
  elsif v_action in ('retry', 'requeue') then
    if x.status not in ('failed', 'cancelled', 'queued', 'due') then raise exception 'This post is already posted or being posted' using errcode = '23514'; end if;
    update social_queue set status = 'queued', attempts = 0, error = null,
           scheduled_at = coalesce(nullif(p ->> 'scheduled_at', '')::timestamptz, greatest(scheduled_at, now())) where id = x.id returning * into x;
    perform app.social_log(x.id, 'retry', to_char(x.scheduled_at at time zone 'America/Toronto', 'YYYY-MM-DD HH24:MI'), p_by);
  else raise exception 'Unknown action' using errcode = '22023';
  end if;
  return app.social_queue_row(x);
end $$;

-- ================================================================ the job: pg_cron marks due; the Worker posts to Meta
create or replace function app.job_social_queue() returns integer
language plpgsql security definer set search_path = public, app as $$
declare r record; n integer := 0;
begin
  for r in update social_queue set status = 'due' where status = 'queued' and scheduled_at <= now() returning id, channel loop
    perform app.social_log(r.id, 'due', case when r.channel = 'tiktok' then 'Post it on TikTok by hand (checklist on the queue)'
                                             when not (select app.meta_usable(m) from meta_publishing m) then 'Meta is not connected: post it by hand' end);
    n := n + 1;
  end loop;
  -- a post stuck while being posted (the Worker stopped) is tried again
  for r in update social_queue set status = 'due' where status = 'posting' and updated_at < now() - interval '15 minutes' returning id loop
    perform app.social_log(r.id, 'retry', 'Not answered in 15 minutes');
  end loop;
  return n;
end $$;
do $$
begin
  if exists (select 1 from pg_extension where extname = 'pg_cron') then
    perform cron.schedule('carmacars-social-queue', '*/5 * * * *', $q$select app.job_social_queue()$q$);
  end if;
end $$;

-- the Worker's ads job runs when a Facebook or Instagram post is due and Meta is connected
alter function app.ads_job_due() rename to ads_job_due_pre2220;
create function app.ads_job_due() returns boolean
language sql stable security definer set search_path = public, app as $$
  select app.ads_job_due_pre2220()
      or ((select app.meta_usable(m) from meta_publishing m)
          and exists (select 1 from social_queue q where q.channel in ('facebook_page', 'instagram') and q.status = 'due' and q.attempts < 3))
$$;
select pg_temp.copy_grants('app.ads_job_due()'::regprocedure, 'app.ads_job_due_pre2220()'::regprocedure);

-- the due Meta posts for the Worker, marked as being posted (one Worker at a time); the token comes with server_ads_job
create or replace function public.server_social_queue_claim() returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare out jsonb;
begin
  perform app.job_social_queue();
  if not (select app.meta_usable(m) from meta_publishing m) then return '[]'::jsonb; end if;
  with c as (
    update social_queue q set status = 'posting', attempts = attempts + 1
     where q.id in (select id from social_queue where channel in ('facebook_page', 'instagram') and status = 'due' and attempts < 3 order by scheduled_at limit 10 for update skip locked)
    returning q.*)
  select coalesce(jsonb_agg(jsonb_build_object('id', c.id, 'channel', c.channel, 'media_kind', c.media_kind, 'media_path', c.media_path, 'caption', c.caption, 'link', c.link,
           'draft_id', c.draft_id, 'kind', (select d.kind from social_drafts d where d.id = c.draft_id), 'slot_date', (select d.slot_date from social_drafts d where d.id = c.draft_id))), '[]'::jsonb)
    into out from c;
  return out;
end $$;

-- what Meta answered for one post. p: {id, ok, post_id, url, error}
create or replace function public.server_social_queue_result(p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare x social_queue;
begin
  select * into x from social_queue where id = nullif(p ->> 'id', '')::uuid and status = 'posting' for update;
  if x.id is null then return jsonb_build_object('ok', false); end if;
  if coalesce((p ->> 'ok')::boolean, false) then
    update social_queue set status = 'posted', how = 'api', post_id = left(p ->> 'post_id', 120),
           post_url = case when (p ->> 'url') ~ '^https://[^[:space:]]+$' then p ->> 'url' end, posted_at = now(), error = null where id = x.id;
    perform app.social_log(x.id, 'posted', coalesce(p ->> 'url', p ->> 'post_id'));
    update meta_publishing set last_ok_at = now(), last_error = null;
  else
    update social_queue set status = case when x.attempts >= 3 then 'failed' else 'due' end, error = left(coalesce(p ->> 'error', 'Meta refused the post'), 300) where id = x.id;
    perform app.social_log(x.id, case when x.attempts >= 3 then 'failed' else 'retry' end, p ->> 'error');
    update meta_publishing set last_error = left(coalesce(p ->> 'error', 'Meta refused the post'), 300);
  end if;
  return jsonb_build_object('ok', true);
end $$;
revoke all on function public.server_social_queue_claim(), public.server_social_queue_result(jsonb) from public, anon, authenticated;
grant execute on function public.server_social_queue_claim(), public.server_social_queue_result(jsonb) to service_role;

-- ================================================================ the door
alter function app.door(uuid, text, text, text, jsonb) rename to door_pre2220;
create function app.door(p_user uuid, p_aal text, p_call text, p_name text, p jsonb default '{}'::jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
begin
  if (p_call in ('ops_read', 'va_read', 'admin_read') and p_name = 'social_queue') or (p_call in ('ops_do', 'va_do', 'admin_do') and p_name in ('social_queue_add', 'social_queue_act')) then
    if coalesce(p, '{}'::jsonb) ? '_va' then perform set_config('app.va_active', coalesce(p ->> '_va', ''), true); end if;
    perform app.door_begin(p_user, p_aal);
    p := coalesce(p, '{}'::jsonb) - '_va';
    return case p_name when 'social_queue' then app.social_queue_read(p_user, p) when 'social_queue_add' then app.social_queue_add(p_user, p)
                       else app.social_queue_act(p_user, p) end;
  end if;
  return app.door_pre2220(p_user, p_aal, p_call, p_name, p);
end $$;
select pg_temp.copy_grants('app.door(uuid, text, text, text, jsonb)'::regprocedure, 'app.door_pre2220(uuid, text, text, text, jsonb)'::regprocedure);

do $$
declare f record;
begin
  for f in
    select p.oid::regprocedure as sig from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'app' and p.proname = any (array['social_log', 'social_queue_row', 'social_queue_read', 'social_queue_add', 'social_queue_act', 'job_social_queue',
              'ads_job_due_pre2220', 'door_pre2220'])
  loop
    execute format('revoke all on function %s from public, anon, authenticated', f.sig);
    execute format('grant execute on function %s to service_role', f.sig);
  end loop;
end $$;
