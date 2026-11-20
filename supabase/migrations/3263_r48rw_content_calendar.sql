-- 3263_r48rw_content_calendar.sql
-- Release 48, part RW: the content calendar (docs/changes/2026-11-20-r48-rewards-calendar-notify.md). The owner, Nov 20
-- 11:35: "social content = an auto-generated CONTENT CALENDAR per business, approved by staff before anything goes live
-- (not just posting)." Built on social_drafts (0167) and social_queue (2220); nothing applied is edited.
--   1. A month's calendar is written by itself (the ads job, from the fleet's facts: src/features/social/calendar.ts):
--      content pillars, a mix of reels, carousels, photos and stories, a caption, hashtags, the best time on each
--      channel and a music suggestion per post. Rows of social_drafts with source 'calendar'.
--   2. Marketing staff (Admin, Fleet, customer service, Sales: app.marketing_may) approve, edit, reject or regenerate
--      each post. Nothing is published unapproved: only Approve writes to social_queue.
--   3. Approved posts go to social_queue at the day's best time per channel. The Facebook Page and Instagram are posted
--      through Meta when it is connected (photos and reels); a story, a carousel and every TikTok post are posted by
--      hand from a download and a checklist (Meta's API posts neither for us yet; TikTok's posting API needs its review).
--      Music is a suggestion picked at approval: the APIs cannot attach licensed trending audio.
--   4. Comments and direct messages are answered under the existing AI auto-reply rules (2380: Messenger and Instagram
--      switches, few, marked as AI, basic questions only); the calendar shows whether they are on.
--   5. Each post's results (views, reach, likes, comments, shares, saves) come back from Meta for posts it published, or
--      are typed in for posts made by hand; the next month's calendar leans on what did best (pillar, format, hour).
--   6. Admin > Marketing > Content calendar shows the month; the same screen is in the staff portal.
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

-- ================================================================ settings
alter table program_settings
  add column if not exists social_cal_enabled boolean not null default true,
  add column if not exists social_cal_mix jsonb not null default '{"reel": 2, "carousel": 1, "photo": 1, "story": 1}'::jsonb,
  add column if not exists social_cal_pillars jsonb not null default '[
    {"code": "fleet", "name": "Fleet spotlight", "weight": 3},
    {"code": "trust", "name": "How renting works", "weight": 2},
    {"code": "local", "name": "Toronto and the GTA", "weight": 2},
    {"code": "offers", "name": "Deals and seasons", "weight": 2},
    {"code": "owners", "name": "Earn with your car", "weight": 1},
    {"code": "proof", "name": "Renter stories", "weight": 1}]'::jsonb,
  add column if not exists social_cal_times jsonb not null default '{"instagram": ["12:00", "18:30"], "facebook_page": ["09:30", "19:00"], "tiktok": ["19:00", "21:00"]}'::jsonb,
  add column if not exists social_cal_hashtags text[] not null default '{#CarmaCars,#TorontoCarRental,#GTA,#CarRentalToronto,#RentACar}',
  add column if not exists social_cal_music jsonb not null default '{"fleet": "Upbeat, confident: a trending driving or city-night sound", "trust": "Calm and clear: a soft lo-fi or light acoustic bed", "local": "Warm and local: a feel-good indie or city sound", "offers": "Bright and quick: an energetic pop or dance cut", "owners": "Steady and optimistic: a motivational or corporate-light track", "proof": "Happy and human: a light, heartfelt sound"}'::jsonb,
  add column if not exists social_cal_generate_day smallint not null default 24 check (social_cal_generate_day between 1 and 28),
  add column if not exists social_cal_remind_days smallint not null default 2 check (social_cal_remind_days between 0 and 14);
comment on column program_settings.social_cal_enabled is 'Content calendar (3263): a month''s social posts are written by themselves and wait for approval. Off: the weekly drafts of 0167 as before.';
comment on column program_settings.social_cal_mix is 'Content calendar (3263): posts a week by format: reel, carousel, photo, story.';
comment on column program_settings.social_cal_pillars is 'Content calendar (3263): the content pillars and their weight (how often each comes up).';
comment on column program_settings.social_cal_times is 'Content calendar (3263): the best times to post on each channel, Toronto time; a month''s results move them.';
comment on column program_settings.social_cal_hashtags is 'Content calendar (3263): the hashtags every post carries; the car and the place add theirs.';
comment on column program_settings.social_cal_music is 'Content calendar (3263): the music suggestion per pillar (a mood; the sound itself is picked when posting).';
comment on column program_settings.social_cal_generate_day is 'Content calendar (3263): the day of the month the next month''s calendar is written.';
comment on column program_settings.social_cal_remind_days is 'Content calendar (3263): a post still waiting for approval this many days before its day is reminded.';

insert into staff_alert_rules (rule, label, grp, who, tier, topic, wired, fixed, hint, sort, pref_type) values
  ('social_calendar_ready', 'A month''s content calendar is ready to approve', 'Marketing', '{admin,fn:cs,fn:sales,fn:fleet}', 'normal', 'alerts', true, false, 'Content calendar (3263): nothing is published until someone approves it.', 190, 'staff_marketing'),
  ('social_post_by_hand', 'A social post is due to be posted by hand', 'Marketing', '{admin,fn:cs,fn:sales,fn:fleet}', 'normal', 'alerts', true, false, 'Content calendar (3263): TikTok, a story, a carousel, or Meta not connected. Download it and follow the checklist.', 191, 'staff_marketing'),
  ('social_post_failed', 'A social post failed', 'Marketing', '{admin}', 'normal', 'alerts', true, false, 'Content calendar (3263): Meta refused it three times.', 192, 'staff_marketing'),
  ('social_post_unapproved', 'A social post is waiting for approval and its day is close', 'Marketing', '{admin,fn:cs,fn:sales,fn:fleet}', 'digest', 'alerts', true, false, 'Content calendar (3263).', 193, 'staff_marketing')
on conflict (rule) do nothing;

-- ================================================================ the calendar's columns
alter table social_drafts
  add column if not exists month date,
  add column if not exists slot_no integer,
  add column if not exists format text check (format is null or format in ('reel', 'carousel', 'photo', 'story')),
  add column if not exists pillar text check (pillar is null or pillar ~ '^[a-z_]{2,30}$'),
  add column if not exists hook text check (hook is null or length(hook) <= 200),
  add column if not exists hashtags text[] not null default '{}',
  add column if not exists music text check (music is null or length(music) <= 240),
  add column if not exists best_times jsonb not null default '{}'::jsonb,
  add column if not exists shot_list text check (shot_list is null or length(shot_list) <= 800),
  add column if not exists reject_reason text check (reject_reason is null or length(reject_reason) <= 300),
  add column if not exists rejected_by uuid references users (id) on delete set null,
  add column if not exists regenerated integer not null default 0,
  add column if not exists auto_reply boolean not null default true;
create index if not exists social_drafts_rejected_by_fk on social_drafts (rejected_by) where rejected_by is not null;
alter table social_drafts drop constraint social_drafts_source_check;
alter table social_drafts add constraint social_drafts_source_check check (source = any (array['auto', 'staff', 'calendar']));
alter table social_drafts drop constraint social_drafts_status_check;
alter table social_drafts add constraint social_drafts_status_check check (status = any (array['draft', 'approved', 'posted', 'skipped', 'rejected']));
alter table social_drafts drop constraint social_drafts_channels_check;
alter table social_drafts add constraint social_drafts_channels_check check (cardinality(channels) > 0 and channels <@ array['instagram', 'facebook_page', 'tiktok']);
alter table social_drafts add constraint social_drafts_calendar_check check (source <> 'calendar' or (month is not null and slot_no is not null and format is not null and pillar is not null));
create unique index if not exists social_drafts_calendar_slot_idx on social_drafts (month, slot_no) where source = 'calendar';
create index if not exists social_drafts_month_idx on social_drafts (month, slot_date) where source = 'calendar';
comment on column social_drafts.month is 'Content calendar (3263): the month this post belongs to (source calendar).';
comment on column social_drafts.best_times is 'Content calendar (3263): the time to post on each channel, {channel: "HH:MM"}, Toronto time.';

create table social_calendars (
  month        date primary key check (extract(day from month) = 1),
  generated_at timestamptz not null default now(),
  generated_by uuid references users (id) on delete set null,
  plan         jsonb not null default '{}'::jsonb,
  learned      jsonb not null default '{}'::jsonb,
  notified_at  timestamptz
);
comment on table social_calendars is 'Content calendar (3263): one row per month written: the plan it used (mix, pillars, times) and what the earlier posts'' results taught it.';

alter table social_queue
  add column if not exists format text check (format is null or format in ('reel', 'carousel', 'photo', 'story')),
  add column if not exists by_hand boolean not null default false,
  add column if not exists music text check (music is null or length(music) <= 240);
comment on column social_queue.by_hand is 'Content calendar (3263): never posted through Meta (a story, a carousel): it waits as due with its download and checklist until staff mark it posted.';

create table social_post_stats (
  queue_id   uuid primary key references social_queue (id) on delete cascade,
  views      integer check (views is null or views >= 0),
  reach      integer check (reach is null or reach >= 0),
  likes      integer check (likes is null or likes >= 0),
  comments   integer check (comments is null or comments >= 0),
  shares     integer check (shares is null or shares >= 0),
  saves      integer check (saves is null or saves >= 0),
  source     text not null check (source in ('api', 'hand')),
  fetched_at timestamptz not null default now(),
  updated_by uuid references users (id) on delete set null
);
comment on table social_post_stats is 'Content calendar (3263): a post''s results, from Meta for a post it published or typed in for a post made by hand. The next month''s calendar reads them.';

do $$
declare t text;
begin
  foreach t in array array['social_calendars', 'social_post_stats'] loop
    execute format('alter table %I enable row level security', t);
    execute format('revoke all on %I from public, anon, authenticated', t);
    execute format('grant all on %I to service_role', t);
    execute format('create policy admin_all on %I for all to authenticated using (app.is_admin()) with check (app.is_admin())', t);
    execute format('create trigger audit_%s after insert or update or delete on %I for each row execute function app.audit_row()', t, t);
  end loop;
end $$;

-- ================================================================ the plan and what the results taught
create function app.social_cal_plan() returns jsonb
language sql stable security definer set search_path = public, app as $$
  select jsonb_build_object('mix', s.social_cal_mix, 'pillars', s.social_cal_pillars, 'times', s.social_cal_times, 'hashtags', to_jsonb(s.social_cal_hashtags), 'music', s.social_cal_music)
    from app.settings() s
$$;
-- a post's score: what people did with it
create function app.social_score(x social_post_stats) returns numeric
language sql immutable as $$
  select coalesce(x.likes, 0) + 2 * coalesce(x.comments, 0) + 3 * coalesce(x.shares, 0) + 2 * coalesce(x.saves, 0) + coalesce(x.views, 0) / 100.0
$$;
-- the 90 days before p_before: the average score by pillar, by format and by channel and hour (Toronto)
create function app.social_cal_learned(p_before date default null) returns jsonb
language sql stable security definer set search_path = public, app as $$
  with x as (
    select d.pillar, coalesce(q.format, d.format) as format, q.channel, extract(hour from (q.posted_at at time zone 'America/Toronto'))::integer as hour, app.social_score(st) as score
      from social_post_stats st join social_queue q on q.id = st.queue_id left join social_drafts d on d.id = q.draft_id
     where q.status = 'posted' and q.posted_at < coalesce(p_before, app.today() + 1)::timestamp at time zone 'America/Toronto'
       and q.posted_at >= (coalesce(p_before, app.today() + 1) - 90)::timestamp at time zone 'America/Toronto')
  select jsonb_build_object(
    'posts', (select count(*) from x),
    'pillars', coalesce((select jsonb_object_agg(pillar, a) from (select pillar, round(avg(score), 1) a from x where pillar is not null group by pillar) p), '{}'::jsonb),
    'formats', coalesce((select jsonb_object_agg(format, a) from (select format, round(avg(score), 1) a from x where format is not null group by format) f), '{}'::jsonb),
    'times', coalesce((select jsonb_object_agg(channel, hh) from (
               select channel, to_char(make_time(hour, 0, 0), 'HH24:MI') hh, row_number() over (partition by channel order by avg(score) desc, count(*) desc) rn
                 from x group by channel, hour having count(*) >= 2) t where rn = 1), '{}'::jsonb),
    'top_pillar', (select pillar from x where pillar is not null group by pillar having count(*) >= 2 order by avg(score) desc limit 1),
    'top_format', (select format from x where format is not null group by format having count(*) >= 2 order by avg(score) desc limit 1))
$$;

-- ================================================================ storing a written calendar
-- p: {month, posts: [{slot_no, slot_date, format, pillar, kind, channels, vehicle_id, hook, caption, hashtags, music, best_times, link, photos, shot_list}], plan, learned}
-- A slot already written is left alone (a post staff edited or approved is never overwritten).
create function app.social_cal_store(p jsonb, p_by uuid default null) returns integer
language plpgsql security definer set search_path = public, app as $$
declare
  v_month date := date_trunc('month', (p ->> 'month')::date)::date;
  d jsonb;
  n integer := 0;
  v_problem text;
begin
  if v_month is null then raise exception 'No month' using errcode = '22023'; end if;
  insert into social_calendars (month, generated_by, plan, learned) values (v_month, p_by, coalesce(p -> 'plan', '{}'::jsonb), coalesce(p -> 'learned', '{}'::jsonb))
  on conflict (month) do nothing;
  for d in select * from jsonb_array_elements(coalesce(p -> 'posts', '[]'::jsonb)) loop
    v_problem := app.ads_text_problem(d ->> 'caption');
    if v_problem is not null then raise exception 'Post for %: %', d ->> 'slot_date', v_problem using errcode = '22023'; end if;
    insert into social_drafts (slot_date, kind, channels, vehicle_id, caption, link, photos, source, created_by, month, slot_no, format, pillar, hook, hashtags, music, best_times, shot_list)
    values ((d ->> 'slot_date')::date, coalesce(nullif(d ->> 'kind', ''), 'custom'),
            coalesce((select array_agg(c) from jsonb_array_elements_text(d -> 'channels') c), array['instagram', 'facebook_page']),
            nullif(d ->> 'vehicle_id', '')::uuid, left(d ->> 'caption', 2200), nullif(d ->> 'link', ''), coalesce(d -> 'photos', '[]'::jsonb), 'calendar', p_by,
            v_month, (d ->> 'slot_no')::integer, d ->> 'format', d ->> 'pillar', left(nullif(d ->> 'hook', ''), 200),
            coalesce((select array_agg(h) from jsonb_array_elements_text(d -> 'hashtags') h), '{}'), left(nullif(d ->> 'music', ''), 240), coalesce(d -> 'best_times', '{}'::jsonb), left(nullif(d ->> 'shot_list', ''), 800))
    on conflict (month, slot_no) where source = 'calendar' do nothing;
    if found then n := n + 1; end if;
  end loop;
  if n > 0 and not exists (select 1 from social_calendars where month = v_month and notified_at is not null) then
    update social_calendars set notified_at = now() where month = v_month;
    perform app.staff_alert('social_calendar_ready', 'site_alert', null, to_char(v_month, 'YYYYMM'),
      left(format('%s''s content calendar is ready: %s posts to approve', to_char(v_month, 'FMMonth'), n), 140),
      'Approve, edit, reject or regenerate each post. Nothing is published until it is approved.',
      jsonb_build_object('path_admin', '/admin/marketing/calendar?month=' || to_char(v_month, 'YYYY-MM'), 'path_staff', '/staff/marketing/calendar?month=' || to_char(v_month, 'YYYY-MM')));
  end if;
  return n;
end $$;

create function app.social_cal_row(x social_drafts) returns jsonb
language sql stable security definer set search_path = public, app as $$
  select jsonb_build_object('id', x.id, 'slot_no', x.slot_no, 'slot_date', x.slot_date, 'weekday', to_char(x.slot_date, 'FMDy'), 'format', x.format, 'pillar', x.pillar, 'kind', x.kind,
    'channels', to_jsonb(x.channels), 'vehicle_id', x.vehicle_id, 'car', case when x.vehicle_id is not null then app.vehicle_name(x.vehicle_id) end,
    'hook', x.hook, 'caption', x.caption, 'hashtags', to_jsonb(x.hashtags), 'music', x.music, 'best_times', x.best_times, 'link', x.link, 'photos', x.photos, 'shot_list', x.shot_list,
    'status', x.status, 'edited', x.edited, 'regenerated', x.regenerated, 'reject_reason', x.reject_reason, 'auto_reply', x.auto_reply,
    'approved_by', (select full_name from users where id = x.approved_by), 'approved_at', x.approved_at,
    'has_video', x.vehicle_id is not null and exists (select 1 from social_videos v where v.vehicle_id = x.vehicle_id and v.removed_at is null),
    'queue', coalesce((select jsonb_agg(jsonb_build_object('id', q.id, 'channel', q.channel, 'status', q.status, 'scheduled_at', q.scheduled_at, 'how', q.how, 'by_hand', q.by_hand or q.channel = 'tiktok',
                 'post_url', q.post_url, 'error', q.error, 'media_path', q.media_path, 'media_kind', q.media_kind,
                 'stats', (select jsonb_build_object('views', st.views, 'reach', st.reach, 'likes', st.likes, 'comments', st.comments, 'shares', st.shares, 'saves', st.saves, 'source', st.source,
                             'score', round(app.social_score(st), 1)) from social_post_stats st where st.queue_id = q.id)) order by q.scheduled_at, q.channel)
                from social_queue q where q.draft_id = x.id and q.status <> 'cancelled'), '[]'::jsonb))
$$;

-- p: {month: 'YYYY-MM'}
create function app.social_cal_read(p_by uuid, p jsonb) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare
  s program_settings := app.settings();
  v_month date := coalesce(to_date(nullif(p ->> 'month', '') || '-01', 'YYYY-MM-DD'), date_trunc('month', app.today())::date);
  m meta_publishing;
  c social_calendars;
begin
  if not app.marketing_may(p_by) then raise exception 'Not permitted' using errcode = '42501'; end if;
  select * into m from meta_publishing;
  select * into c from social_calendars where month = v_month;
  return jsonb_build_object(
    'month', to_char(v_month, 'YYYY-MM'), 'label', to_char(v_month, 'FMMonth YYYY'), 'today', app.today(), 'enabled', s.social_cal_enabled,
    'first_weekday', extract(isodow from v_month)::integer, 'days', extract(day from (v_month + interval '1 month - 1 day'))::integer,
    'prev', to_char(v_month - interval '1 month', 'YYYY-MM'), 'next', to_char(v_month + interval '1 month', 'YYYY-MM'),
    'generated_at', c.generated_at, 'plan', coalesce(c.plan, app.social_cal_plan()), 'learned', coalesce(c.learned, '{}'::jsonb), 'learned_now', app.social_cal_learned(),
    'pillars', s.social_cal_pillars,
    'meta', jsonb_build_object('connected', app.meta_usable(m), 'instagram', app.meta_usable(m) and m.ig_user_id is not null, 'last_error', m.last_error),
    'auto_reply', jsonb_build_object('instagram', s.auto_reply_instagram, 'messenger', s.auto_reply_messenger, 'per_sender_day', s.auto_reply_per_sender_day,
                                     'rule', 'Comments and direct messages get the same AI replies as texts and chat: few, marked as AI, basic questions only; anything else goes to a person.'),
    'counts', (select jsonb_build_object('all', count(*), 'draft', count(*) filter (where status = 'draft'), 'approved', count(*) filter (where status = 'approved'),
                 'posted', count(*) filter (where status = 'posted'), 'rejected', count(*) filter (where status = 'rejected')) from social_drafts where source = 'calendar' and month = v_month),
    'posts', (select coalesce(jsonb_agg(app.social_cal_row(x) order by x.slot_date, x.slot_no), '[]'::jsonb) from social_drafts x where x.source = 'calendar' and x.month = v_month),
    'videos', coalesce((select jsonb_agg(jsonb_build_object('id', v.id, 'vehicle_id', v.vehicle_id, 'car', app.vehicle_name(v.vehicle_id), 'path', v.path, 'mime', v.mime, 'seconds', v.seconds) order by v.created_at desc)
                         from (select * from social_videos where removed_at is null order by created_at desc limit 60) v), '[]'::jsonb));
end $$;

-- the day and time of a post on one channel (Toronto), never in the past
create function app.social_cal_when(p_day date, p_time text) returns timestamptz
language sql stable security definer set search_path = public, app as $$
  select greatest((p_day::timestamp + coalesce(nullif(p_time, ''), '12:00')::time) at time zone 'America/Toronto', now() + interval '5 minutes')
$$;

-- p: {id, action: approve | unapprove | reject | restore, reason, video (a short video's id), music}
create function app.social_cal_decide(p_by uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  x social_drafts;
  v social_videos;
  v_action text := p ->> 'action';
  v_ch text;
  v_photo text;
  v_caption text;
  v_reason text := nullif(btrim(coalesce(p ->> 'reason', '')), '');
  q social_queue;
begin
  if not app.marketing_may(p_by) then raise exception 'An Admin, Fleet, customer service or Sales approves social posts' using errcode = '42501'; end if;
  select * into x from social_drafts where id = nullif(p ->> 'id', '')::uuid and source = 'calendar' for update;
  if x.id is null then raise exception 'Post not found' using errcode = 'P0002'; end if;
  perform app.rw_act_as(p_by);
  if v_action = 'approve' then
    if x.status not in ('draft', 'rejected') then raise exception 'This post is already approved or posted' using errcode = '23514'; end if;
    v_photo := x.photos ->> 0;
    if x.format = 'reel' then
      select * into v from social_videos sv where sv.removed_at is null and (sv.id = nullif(p ->> 'video', '')::uuid or (nullif(p ->> 'video', '') is null and sv.vehicle_id = x.vehicle_id)) order by sv.created_at desc limit 1;
      if v.id is null then raise exception 'A reel needs a short video: make one for this car under Short videos, then approve' using errcode = '23514'; end if;
    elsif v_photo is null or v_photo !~ '^(vehicles|site)/[A-Za-z0-9/_.-]{3,250}$' then
      raise exception 'This post has no photo on the site: edit it and choose a car with photos' using errcode = '23514';
    end if;
    v_caption := left(x.caption || case when cardinality(x.hashtags) > 0 then E'\n\n' || array_to_string(x.hashtags, ' ') else '' end, 2200);
    foreach v_ch in array x.channels loop
      -- TikTok takes videos only; Instagram reels are MP4
      continue when v_ch = 'tiktok' and x.format <> 'reel';
      continue when v_ch = 'instagram' and x.format = 'reel' and v.mime <> 'video/mp4';
      insert into social_queue (channel, media_kind, media_path, video_id, draft_id, vehicle_id, caption, link, scheduled_at, created_by, format, by_hand, music)
      values (v_ch, case when x.format = 'reel' then 'video' else 'photo' end, case when x.format = 'reel' then v.path else v_photo end, case when x.format = 'reel' then v.id end,
              x.id, x.vehicle_id, v_caption, x.link, app.social_cal_when(x.slot_date, x.best_times ->> v_ch), p_by, x.format, x.format in ('story', 'carousel'),
              coalesce(nullif(btrim(coalesce(p ->> 'music', '')), ''), x.music))
      returning * into q;
      perform app.social_log(q.id, 'queued', format('%s, approved from the content calendar', v_ch), p_by);
    end loop;
    if q.id is null then raise exception 'None of this post''s channels can take it: an Instagram reel needs an MP4 video' using errcode = '23514'; end if;
    update social_drafts set status = 'approved', approved_by = p_by, approved_at = now(), reject_reason = null, rejected_by = null,
           music = coalesce(nullif(btrim(coalesce(p ->> 'music', '')), ''), music) where id = x.id returning * into x;
  elsif v_action = 'unapprove' then
    if x.status <> 'approved' then raise exception 'Only an approved post can go back to a draft' using errcode = '23514'; end if;
    if exists (select 1 from social_queue k where k.draft_id = x.id and k.status in ('posting', 'posted')) then raise exception 'Part of this post is already published' using errcode = '23514'; end if;
    for q in update social_queue set status = 'cancelled' where draft_id = x.id and status in ('queued', 'due', 'failed') returning * loop
      perform app.social_log(q.id, 'cancelled', 'Back to a draft', p_by);
    end loop;
    update social_drafts set status = 'draft', approved_by = null, approved_at = null where id = x.id returning * into x;
  elsif v_action = 'reject' then
    if x.status not in ('draft') then raise exception 'Only a post waiting for approval can be rejected' using errcode = '23514'; end if;
    if v_reason is null then raise exception 'Say why, so the next calendar learns from it' using errcode = '22023'; end if;
    update social_drafts set status = 'rejected', reject_reason = left(v_reason, 300), rejected_by = p_by where id = x.id returning * into x;
  elsif v_action = 'restore' then
    if x.status <> 'rejected' then raise exception 'Only a rejected post can be restored' using errcode = '23514'; end if;
    update social_drafts set status = 'draft', reject_reason = null, rejected_by = null where id = x.id returning * into x;
  else raise exception 'Unknown action' using errcode = '22023';
  end if;
  return app.social_cal_row(x);
end $$;

-- an edit, or a regenerated post put in the slot. p: {id, caption, hook, hashtags, music, slot_date, best_times, channels, regenerated: true + the new post's fields}
create function app.social_cal_save(p_by uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  x social_drafts;
  v_caption text := nullif(btrim(coalesce(p ->> 'caption', '')), '');
  v_problem text;
  v_regen boolean := coalesce((p ->> 'regenerated')::boolean, false);
  v_tags text[];
  v_channels text[];
  v_day date := nullif(p ->> 'slot_date', '')::date;
begin
  if not app.marketing_may(p_by) then raise exception 'An Admin, Fleet, customer service or Sales edits social posts' using errcode = '42501'; end if;
  select * into x from social_drafts where id = nullif(p ->> 'id', '')::uuid and source = 'calendar' for update;
  if x.id is null then raise exception 'Post not found' using errcode = 'P0002'; end if;
  if x.status not in ('draft', 'rejected') then raise exception 'Take the approval back first: an approved post is already scheduled' using errcode = '23514'; end if;
  if v_caption is null then raise exception 'Write the caption' using errcode = '22023'; end if;
  v_problem := app.ads_text_problem(v_caption);
  if v_problem is not null then raise exception '%', v_problem using errcode = '22023'; end if;
  if v_day is not null and date_trunc('month', v_day)::date <> x.month then raise exception 'Keep the post in %', to_char(x.month, 'FMMonth') using errcode = '22023'; end if;
  if p ? 'hashtags' then
    select coalesce(array_agg(distinct t), '{}') into v_tags from (
      select case when h like '#%' then h else '#' || h end t
        from (select regexp_replace(btrim(e), '[^#A-Za-z0-9_]', '', 'g') h
                from jsonb_array_elements_text(case when jsonb_typeof(p -> 'hashtags') = 'array' then p -> 'hashtags' else to_jsonb(regexp_split_to_array(coalesce(p ->> 'hashtags', ''), '[\s,]+')) end) e) y
       where length(h) > 1) z;
  end if;
  if jsonb_typeof(p -> 'channels') = 'array' then
    select array_agg(c) into v_channels from jsonb_array_elements_text(p -> 'channels') c where c in ('instagram', 'facebook_page', 'tiktok');
  end if;
  perform app.rw_act_as(p_by);
  update social_drafts set
         caption = left(v_caption, 2200), hook = case when p ? 'hook' then left(nullif(btrim(p ->> 'hook'), ''), 200) else hook end,
         hashtags = coalesce(v_tags, hashtags), music = case when p ? 'music' then left(nullif(btrim(p ->> 'music'), ''), 240) else music end,
         slot_date = coalesce(v_day, slot_date), channels = coalesce(v_channels, channels),
         best_times = case when jsonb_typeof(p -> 'best_times') = 'object' then p -> 'best_times' else best_times end,
         vehicle_id = case when v_regen and p ? 'vehicle_id' then nullif(p ->> 'vehicle_id', '')::uuid else vehicle_id end,
         photos = case when v_regen and jsonb_typeof(p -> 'photos') = 'array' then p -> 'photos' else photos end,
         link = case when v_regen and p ? 'link' then nullif(p ->> 'link', '') else link end,
         shot_list = case when v_regen and p ? 'shot_list' then left(nullif(p ->> 'shot_list', ''), 800) else shot_list end,
         status = 'draft', reject_reason = null, rejected_by = null,
         edited = case when v_regen then false else true end, regenerated = regenerated + case when v_regen then 1 else 0 end
   where id = x.id returning * into x;
  return app.social_cal_row(x);
end $$;

-- a post's results typed in (a post made by hand). p: {id (the queue row), views, reach, likes, comments, shares, saves}
create function app.social_stats_save(p_by uuid, p jsonb, p_source text default 'hand') returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  q social_queue;
  n integer[] := array[(p ->> 'views')::integer, (p ->> 'reach')::integer, (p ->> 'likes')::integer, (p ->> 'comments')::integer, (p ->> 'shares')::integer, (p ->> 'saves')::integer];
begin
  if p_source = 'hand' and not app.marketing_may(p_by) then raise exception 'Not permitted' using errcode = '42501'; end if;
  select * into q from social_queue where id = nullif(p ->> 'id', '')::uuid;
  if q.id is null or q.status <> 'posted' then raise exception 'Results go on a post that is published' using errcode = '23514'; end if;
  if exists (select 1 from unnest(n) v where v < 0) then raise exception 'Enter numbers from 0 up' using errcode = '22023'; end if;
  insert into social_post_stats (queue_id, views, reach, likes, comments, shares, saves, source, updated_by)
  values (q.id, n[1], n[2], n[3], n[4], n[5], n[6], p_source, p_by)
  on conflict (queue_id) do update set views = coalesce(excluded.views, social_post_stats.views), reach = coalesce(excluded.reach, social_post_stats.reach),
     likes = coalesce(excluded.likes, social_post_stats.likes), comments = coalesce(excluded.comments, social_post_stats.comments), shares = coalesce(excluded.shares, social_post_stats.shares),
     saves = coalesce(excluded.saves, social_post_stats.saves), source = excluded.source, fetched_at = now(), updated_by = excluded.updated_by;
  return jsonb_build_object('ok', true);
end $$;

-- ================================================================ the Worker's side
-- what the ads job needs for the calendar: the months to write (this month until it exists; the next from the
-- generate day), the plan, what the results taught, and the posts whose results to fetch from Meta
create function app.social_cal_job() returns jsonb
language sql stable security definer set search_path = public, app as $$
  select jsonb_build_object('enabled', s.social_cal_enabled,
    'months', (select coalesce(jsonb_agg(to_char(m, 'YYYY-MM') order by m), '[]'::jsonb) from (
                 select date_trunc('month', app.today())::date m
                 union select (date_trunc('month', app.today()) + interval '1 month')::date where extract(day from app.today()) >= s.social_cal_generate_day) x
                where s.social_cal_enabled and not exists (select 1 from social_calendars c where c.month = x.m)),
    'plan', app.social_cal_plan(), 'learned', app.social_cal_learned(),
    'recent', (select coalesce(jsonb_agg(d.vehicle_id), '[]'::jsonb) from social_drafts d where d.source = 'calendar' and d.vehicle_id is not null and d.slot_date > app.today() - 45),
    'stats_due', (select coalesce(jsonb_agg(jsonb_build_object('id', q.id, 'channel', q.channel, 'post_id', q.post_id, 'media_kind', q.media_kind)), '[]'::jsonb) from (
                    select q.* from social_queue q left join social_post_stats st on st.queue_id = q.id
                     where q.status = 'posted' and q.how = 'api' and q.post_id is not null and q.posted_at > now() - interval '35 days' and q.posted_at < now() - interval '2 hours'
                       and (st.queue_id is null or st.fetched_at < now() - interval '20 hours')
                     order by q.posted_at desc limit 25) q))
    from app.settings() s
$$;
alter function public.server_ads_job() rename to server_ads_job_pre3263;
create function public.server_ads_job() returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare v jsonb := public.server_ads_job_pre3263();
begin
  -- the monthly calendar takes the place of the week's drafts while it is on
  -- and a calendar post is published only from the queue its approval filled, never as a week's draft
  return v || jsonb_build_object('calendar', app.social_cal_job(), 'drafts_enabled', coalesce((v ->> 'drafts_enabled')::boolean, false) and not (app.settings()).social_cal_enabled,
    'due', coalesce((select jsonb_agg(d order by n) from jsonb_array_elements(case when jsonb_typeof(v -> 'due') = 'array' then v -> 'due' else '[]'::jsonb end) with ordinality x(d, n)
                      where not exists (select 1 from social_drafts sd where sd.id = (d ->> 'id')::uuid and sd.source = 'calendar')), '[]'::jsonb));
end $$;
select pg_temp.copy_grants('public.server_ads_job()'::regprocedure, 'public.server_ads_job_pre3263()'::regprocedure);
create function public.server_social_calendar_put(p jsonb) returns integer
language sql security definer set search_path = public, app as $$ select app.social_cal_store(p, null) $$;
create function public.server_social_stats_put(p jsonb) returns jsonb
language sql security definer set search_path = public, app as $$ select app.social_stats_save(null, p, 'api') $$;

-- the week's drafts screen (0167) keeps to its own drafts: a calendar post is handled on the calendar
alter function app.social_drafts_read(uuid, jsonb) rename to social_drafts_read_pre3263;
create function app.social_drafts_read(p_by uuid, p jsonb) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare v jsonb := app.social_drafts_read_pre3263(p_by, p);
begin
  return v || jsonb_build_object('drafts', coalesce((select jsonb_agg(d order by n) from jsonb_array_elements(coalesce(v -> 'drafts', '[]'::jsonb)) with ordinality x(d, n) where d ->> 'source' <> 'calendar'), '[]'::jsonb));
end $$;
select pg_temp.copy_grants('app.social_drafts_read(uuid, jsonb)'::regprocedure, 'app.social_drafts_read_pre3263(uuid, jsonb)'::regprocedure);

-- Meta posts photos and reels; a story and a carousel wait for a person
alter function public.server_social_queue_claim() rename to server_social_queue_claim_pre3263;
create function public.server_social_queue_claim() returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare out jsonb;
begin
  perform app.job_social_queue();
  if not (select app.meta_usable(m) from meta_publishing m) then return '[]'::jsonb; end if;
  with c as (
    update social_queue q set status = 'posting', attempts = attempts + 1
     where q.id in (select id from social_queue where channel in ('facebook_page', 'instagram') and status = 'due' and attempts < 3 and not by_hand order by scheduled_at limit 10 for update skip locked)
    returning q.*)
  select coalesce(jsonb_agg(jsonb_build_object('id', c.id, 'channel', c.channel, 'media_kind', c.media_kind, 'media_path', c.media_path, 'caption', c.caption, 'link', c.link,
           'draft_id', c.draft_id, 'kind', (select d.kind from social_drafts d where d.id = c.draft_id), 'slot_date', (select d.slot_date from social_drafts d where d.id = c.draft_id))), '[]'::jsonb)
    into out from c;
  return out;
end $$;
select pg_temp.copy_grants('public.server_social_queue_claim()'::regprocedure, 'public.server_social_queue_claim_pre3263()'::regprocedure);

-- a post due by hand, a post that failed: Marketing is told; a calendar post all of whose queue rows are posted is posted
create function app.social_cal_queue_after() returns trigger
language plpgsql security definer set search_path = public, app as $$
declare v_meta boolean;
begin
  if new.status = 'due' and old.status is distinct from 'due' then
    select app.meta_usable(m) into v_meta from meta_publishing m;
    if new.by_hand or new.channel = 'tiktok' or not coalesce(v_meta, false) then
      perform app.staff_alert('social_post_by_hand', 'site_alert', null, 'q:' || new.id,
        left(format('Post it now: %s on %s', coalesce(new.format, 'a post'), case new.channel when 'tiktok' then 'TikTok' when 'instagram' then 'Instagram' else 'the Facebook Page' end), 140),
        'Download it, post it with the caption and the music, then paste the link under Posted by hand.',
        jsonb_build_object('path_admin', '/admin/marketing/social', 'path_staff', '/staff/marketing'));
    end if;
  elsif new.status = 'failed' and old.status is distinct from 'failed' then
    perform app.staff_alert('social_post_failed', 'site_alert', null, 'q:' || new.id, 'A social post failed', left(coalesce(new.error, 'Meta refused the post'), 240),
      jsonb_build_object('path_admin', '/admin/marketing/social'));
  elsif new.status = 'posted' and old.status is distinct from 'posted' and new.draft_id is not null then
    update social_drafts d set status = 'posted'
     where d.id = new.draft_id and d.source = 'calendar' and d.status = 'approved'
       and not exists (select 1 from social_queue k where k.draft_id = d.id and k.status in ('queued', 'due', 'posting', 'failed'));
  end if;
  return null;
exception when others then
  raise warning 'content calendar: queue change % not followed: %', new.id, sqlerrm;
  return null;
end $$;
create trigger social_queue_calendar_after after update of status on social_queue for each row execute function app.social_cal_queue_after();

-- a post still waiting for approval close to its day: one reminder
create function app.job_social_calendar(p_now timestamptz default now()) returns integer
language plpgsql security definer set search_path = public, app as $$
declare s program_settings := app.settings(); n integer;
begin
  if not s.social_cal_enabled then return 0; end if;
  select count(*) into n from social_drafts d where d.source = 'calendar' and d.status = 'draft' and d.slot_date between app.local_date(p_now) and app.local_date(p_now) + s.social_cal_remind_days;
  if n > 0 then
    perform app.staff_alert('social_post_unapproved', 'site_alert', null, to_char(app.local_date(p_now), 'YYYYMMDD'),
      left(format('%s social post%s waiting for approval', n, case when n = 1 then ' is' else 's are' end), 140),
      format('Their day is within %s days. Unapproved posts are not published.', s.social_cal_remind_days),
      jsonb_build_object('path_admin', '/admin/marketing/calendar', 'path_staff', '/staff/marketing/calendar'));
  end if;
  return n;
end $$;

do $$
begin
  if exists (select 1 from pg_extension where extname = 'pg_cron') then
    perform cron.schedule('carmacars-social-calendar', '10 13 * * *', $q$select app.job_social_calendar()$q$);
  end if;
end $$;

do $$
declare f record;
begin
  for f in select p.oid::regprocedure as sig from pg_proc p join pg_namespace n on n.oid = p.pronamespace
            where n.nspname in ('app', 'public') and (p.proname ~ '^(social_cal_|social_score|social_stats_save|job_social_calendar|server_social_calendar_put|server_social_stats_put)' or p.proname ~ '_pre3263$')
  loop
    execute format('revoke all on function %s from public, anon, authenticated', f.sig);
    execute format('grant execute on function %s to service_role', f.sig);
  end loop;
end $$;
