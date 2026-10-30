-- 0194: the usage guard on our own server, UPDATE and DELETE with a WHERE clause everywhere. SCHEMA_MARKER 0194.
-- 1. The database and file storage run on our own server (self-hosted Supabase on a VPS), not a Supabase plan: Settings >
--    Usage, its alert emails and the import settings no longer speak of the Supabase Free or Pro plan. Over the
--    allowance means: clean up, or move to a larger server disk. "Data sent out (Supabase egress)" is not measured on
--    our server: it is retired (off and hidden). Allowances an Admin set are kept; only the old Supabase Free defaults
--    (500 MB database, 1 GB files) become the server's (8 GB, 20 GB). The database plan setting no longer rewrites the
--    database allowance.
-- 2. The server runs pg_safeupdate: an UPDATE or DELETE without a WHERE clause fails. The IndexNow sweep (claim and
--    report) and twelve other functions updated their one-row tables without one: each now says "where" explicitly.

create function pg_temp.patch_fn(p_sig regprocedure, p_old text, p_new text) returns void
language plpgsql as $$
declare
  d text := pg_get_functiondef(p_sig);
begin
  if position(p_old in d) = 0 then
    raise exception '0194: the text to change was not found in %: %', p_sig, left(p_old, 120);
  end if;
  execute replace(d, p_old, p_new);
end $$;

-- ================================================================ 1. the usage guard on our server
update usage_services set
    label = 'Database size (our server)', provider = 'Our server',
    price_text = 'Not billed by use: the server has a fixed monthly price.',
    upgrade_text = 'When it gets close: clean up (the audit log, old events) or move to a larger server disk.',
    measured_by = 'The database''s own size (pg_database_size), every hour.',
    when_used_up = 'Never blocked by us. A full server disk stops the database from saving anything: clean up (the audit log, old events) or move to a larger server disk before then.',
    updated_at = now()
 where service = 'supabase_db';
update usage_services set
    label = 'File storage (our server)', provider = 'Our server',
    price_text = 'Not billed by use: the server has a fixed monthly price.',
    upgrade_text = 'When it gets close: clean up the largest buckets (old deploy reports first) or move to a larger server disk.',
    measured_by = 'The size of every file stored on our server (storage.objects), every hour.',
    when_used_up = 'Never blocked by us. A full server disk stops uploads and the database: clean up the largest buckets (old deploy reports first) or move to a larger server disk.',
    updated_at = now()
 where service = 'supabase_storage';
-- the old Supabase Free defaults only: an allowance an Admin changed is kept
update usage_services set included = 8589934592 where service = 'supabase_db' and included = 524288000;
update usage_services set included = 21474836480 where service = 'supabase_storage' and included = 1073741824;
-- egress is not measured on our server: retired, its open alerts closed
update usage_services set enabled = false, label = 'Data sent out (retired)', provider = 'Our server',
    price_text = 'Not measured on our server.', upgrade_text = null,
    measured_by = 'Not measured: retired when the database moved to our own server.',
    when_used_up = 'Nothing: retired.', updated_at = now()
 where service = 'supabase_egress';
update usage_alerts set dismissed_at = coalesce(dismissed_at, now()) where service = 'supabase_egress' and dismissed_at is null;

-- Settings > Usage leaves out the retired service (Data sent out); the others show, on or off as before
select pg_temp.patch_fn('app.usage_page_pre0133(uuid, timestamptz)'::regprocedure,
  $o$order by s.sort) from usage_services s), '[]'::jsonb),$o$,
  $n$order by s.sort) from usage_services s where s.enabled or s.service <> 'supabase_egress'), '[]'::jsonb),$n$);

-- the database plan setting (0104) keeps the import caps only: the database allowance is the Admin's (our server's disk)
drop trigger if exists program_settings_db_allowance on program_settings;
drop function if exists app.program_settings_db_allowance();
comment on column program_settings.db_plan is 'Which import size cap applies (0104, 0194): pro is the standard cap (db_cap_pro_mb), free the small one (db_cap_free_mb). The catalog and places imports stop before the database passes it. The database allowance of Settings > Usage is set there.';
comment on column program_settings.db_cap_free_mb is 'The small import size cap (MB, 0104): the imports stop before the database passes it.';
comment on column program_settings.db_cap_pro_mb is 'The standard import size cap (MB, 0104).';

-- the alert email's description (emails/src/emails/staff_usage_alert.mjs)
update notification_catalogue
   set trigger_text = 'Usage guard (every hour, from the database): a metered service (Workers AI, Worker requests and CPU, image transformations, Resend emails, the database and file storage on our server, R2 storage, the Claude assistant) reached 80% of its included allowance for the period, or used all of it. Sent to the alert address in Program settings (uptime_alert_email), once per service, level and period, never from uptime_quiet_from_hour to uptime_quiet_until_hour (it waits for the morning). The same alert shows on Admin > To do.',
       updated_at = now()
 where code = 'staff_usage_alert';

-- ================================================================ 2. pg_safeupdate: every UPDATE and DELETE says WHERE
-- One-row tables (indexnow_sweep, site_settings, deck_settings, review_google_link, coverage_affiliate,
-- meta_publishing, ads_job_state, the sitemap cache state) and a temporary table: "where true" or "where id" (the
-- boolean key of indexnow_sweep) changes nothing but satisfies the server.
select pg_temp.patch_fn('app.business_listing_tick(uuid, jsonb)'::regprocedure,
  $o$updated_by = p_admin;
  return (select business_listings$o$,
  $n$updated_by = p_admin
   where true;
  return (select business_listings$n$);
select pg_temp.patch_fn('app.coverage_affiliate_save(uuid, jsonb)'::regprocedure,
  $o$enabled = v_enabled, updated_by = p_by, updated_at = now()
   returning * into a;$o$,
  $n$enabled = v_enabled, updated_by = p_by, updated_at = now()
   where true
   returning * into a;$n$);
select pg_temp.patch_fn('app.deck_settings_save(uuid, jsonb)'::regprocedure,
  $o$updated_by = p_user, updated_at = now();$o$,
  $n$updated_by = p_user, updated_at = now()
   where true;$n$);
select pg_temp.patch_fn('app.meta_publishing_save(uuid, jsonb)'::regprocedure,
  $o$updated_by = p_by, updated_at = now()
   returning * into m;$o$,
  $n$updated_by = p_by, updated_at = now()
   where true
   returning * into m;$n$);
select pg_temp.patch_fn('app.review_google_connect(uuid, jsonb)'::regprocedure,
  $o$location_name = null, location_title = null;
  return jsonb_build_object('connected', true);$o$,
  $n$location_name = null, location_title = null
   where true;
  return jsonb_build_object('connected', true);$n$);
select pg_temp.patch_fn('app.review_google_disconnect(uuid)'::regprocedure,
  $o$connected_at = null, connected_by = null, last_error = null;$o$,
  $n$connected_at = null, connected_by = null, last_error = null
   where true;$n$);
select pg_temp.patch_fn('app.review_google_sync_begin(timestamptz)'::regprocedure,
  $o$connect again', last_sync_at = p_now;$o$,
  $n$connect again', last_sync_at = p_now
     where true;$n$);
select pg_temp.patch_fn('app.review_google_sync_finish(jsonb, timestamptz)'::regprocedure,
  $o$location_title = coalesce(nullif(p ->> 'location_title', ''), location_title);$o$,
  $n$location_title = coalesce(nullif(p ->> 'location_title', ''), location_title)
   where true;$n$);
select pg_temp.patch_fn('app.review_google_sync_finish(jsonb, timestamptz)'::regprocedure,
  $o$set reviews_seen = (select count(*) from google_reviews);$o$,
  $n$set reviews_seen = (select count(*) from google_reviews) where true;$n$);
select pg_temp.patch_fn('app.sales_availability_save(uuid, jsonb)'::regprocedure,
  $o$delete from swm_new;$o$,
  $n$delete from swm_new where true;$n$);
select pg_temp.patch_fn('public.server_ads_job()'::regprocedure,
  $o$last_result = jsonb_build_object('ads_to_update', n);$o$,
  $n$last_result = jsonb_build_object('ads_to_update', n) where true;$n$);
select pg_temp.patch_fn('app.server_indexnow_claim(integer)'::regprocedure,
  $o$set day = v_today, sent_today = 0 returning * into w;$o$,
  $n$set day = v_today, sent_today = 0 where id returning * into w;$n$);
select pg_temp.patch_fn('app.server_indexnow_claim(integer)'::regprocedure,
  $o$file_i = v_file_i, pos = v_vpos, updated_at = now();$o$,
  $n$file_i = v_file_i, pos = v_vpos, updated_at = now() where id;$n$);
select pg_temp.patch_fn('app.server_indexnow_report(jsonb)'::regprocedure,
  $o$pos = case when c ? 'pos' then (c ->> 'pos')::bigint else pos end
     returning * into w;$o$,
  $n$pos = case when c ? 'pos' then (c ->> 'pos')::bigint else pos end
     where id
     returning * into w;$n$);
select pg_temp.patch_fn('app.server_indexnow_report(jsonb)'::regprocedure,
  $o$phase = 'priority', p_i = 0, p_pos = 0 returning * into w;$o$,
  $n$phase = 'priority', p_i = 0, p_pos = 0 where id returning * into w;$n$);
select pg_temp.patch_fn('app.server_indexnow_report(jsonb)'::regprocedure,
  $o$last_at = now(), updated_at = now() returning * into w;$o$,
  $n$last_at = now(), updated_at = now() where id returning * into w;$n$);
select pg_temp.patch_fn('public.server_social_published(jsonb)'::regprocedure,
  $o$update meta_publishing set last_ok_at = now(), last_error = null;$o$,
  $n$update meta_publishing set last_ok_at = now(), last_error = null where true;$n$);
select pg_temp.patch_fn('public.server_social_published(jsonb)'::regprocedure,
  $o$'Meta refused the post'), 500);
  end if;$o$,
  $n$'Meta refused the post'), 500) where true;
  end if;$n$);
select pg_temp.patch_fn('app.vehicle_sitemap_shape_refresh()'::regprocedure,
  $o$shape_switches = app.vehicle_sitemap_switches();$o$,
  $n$shape_switches = app.vehicle_sitemap_switches() where true;$n$);

-- ================================================================ 3. the guide chapter (Settings > Usage)
-- GUIDES 0194 START (generated by supabase/seed/0194_gen_guides.mjs from docs/guides/content; do not edit by hand)
select app.guide_release_section('admin', 'usage-and-paid-usage', 'chapter', 'assistant', 'The plans CarmaCars runs on include a free allowance: AI, the website, image transformations, emails, the database and storage. When an allowance runs out, AI and photo features pause with a short message until it resets. Workers AI never runs into paid usage; for photos you are asked before anything is paid.

## The alerts

At 80% of an allowance you get one quiet card on **To do** and one email to the alert address. When it is used up, a second card and email.

1. Workers AI used up shows "Stopped for today, never paid": it starts again at midnight, Toronto time. There is nothing to allow.
2. A used-up image allowance shows "Included ... used up for this month: Allow paid usage". Press **Allow paid usage** to see what continuing costs at the current rates.
3. Choose until the end of today or this month, type the most it may cost (for example $1), and press the Allow button. Or press Keep paused.
4. Nobody answering keeps it paused: nothing is charged. Live chat goes to a person, AI copy waits with the template text, Turo emails are read by the rules, photos keep their original background, the assistant rests.
5. The website and the portals are never paused (that would stop bookings): their card shows the estimated cost, usually cents.

## Settings > Usage

Open **Settings**, then **Usage**: every service, used against included, when it resets, paid usage and the last 30 days.

1. Workers AI by feature, at the top: the neurons each feature used today and in the last 7 days (the staff assistant, visitor chat, the phone line, search copy, listing copy, guide upkeep, Turo emails, the readers), and what each share has left now. Use Cloudflare counted beyond the app''s own record shows as Unmetered.
2. The day is shared in three: 70% is kept for the staff assistant; visitor chat, the phone line and the readers share the rest; background writing (search copy, listing copy, guide rewrites, Turo emails) gets 10%, and from 9 pm what is left of the day, less a small cushion for the assistant.
3. Press **Change the shares** to change the assistant''s reserve, the background share, the release hour or the cushion.
4. Press **Change the allowance** after a plan change (for example a Supabase or Resend upgrade).
5. Supabase egress is not readable automatically: press **Enter a figure** with the number from the Supabase dashboard.
6. Emails cannot be paid on the free plan: when the daily or monthly count is used, booking, payment and sign-in emails still go first and the others wait. A banner on To do says so.
', 'Usage and paid usage', 'Included allowances, the 80% and used-up alerts, Workers AI by feature (never paid), allowing paid usage for photos, what pauses and what never does.',
  'The plans CarmaCars runs on include a free allowance: AI, the website, image transformations, emails, the database and storage. When an allowance runs out, AI and photo features pause with a short message until it resets. Workers AI never runs into paid usage; for photos you are asked before anything is paid.

## The alerts

At 80% of an allowance you get one quiet card on **To do** and one email to the alert address. When it is used up, a second card and email.

1. Workers AI used up shows "Stopped for today, never paid": it starts again at midnight, Toronto time. There is nothing to allow.
2. A used-up image allowance shows "Included ... used up for this month: Allow paid usage". Press **Allow paid usage** to see what continuing costs at the current rates.
3. Choose until the end of today or this month, type the most it may cost (for example $1), and press the Allow button. Or press Keep paused.
4. Nobody answering keeps it paused: nothing is charged. Live chat goes to a person, AI copy waits with the template text, Turo emails are read by the rules, photos keep their original background, the assistant rests.
5. The website and the portals are never paused (that would stop bookings): their card shows the estimated cost, usually cents.

## Settings > Usage

Open **Settings**, then **Usage**: every service, used against included, when it resets, paid usage and the last 30 days.

1. Workers AI by feature, at the top: the neurons each feature used today and in the last 7 days (the staff assistant, visitor chat, the phone line, search copy, listing copy, guide upkeep, Turo emails, the readers), and what each share has left now. Use Cloudflare counted beyond the app''s own record shows as Unmetered.
2. The day is shared in three: 70% is kept for the staff assistant; visitor chat, the phone line and the readers share the rest; background writing (search copy, listing copy, guide rewrites, Turo emails) gets 10%, and from 9 pm what is left of the day, less a small cushion for the assistant.
3. Press **Change the shares** to change the assistant''s reserve, the background share, the release hour or the cushion.
4. Press **Change the allowance** after a plan change (for example a Resend upgrade, or a larger disk on our server).
5. Database size and file storage are our own server''s: near the allowance, clean up or move to a larger server disk. Nothing is billed by use.
6. Emails cannot be paid on the free plan: when the daily or monthly count is used, booking, payment and sign-in emails still go first and the others wait. A banner on To do says so.
',
  '<p class="gd-p">The plans CarmaCars runs on include a free allowance: AI, the website, image transformations, emails, the database and storage. When an allowance runs out, AI and photo features pause with a short message until it resets. Workers AI never runs into paid usage; for photos you are asked before anything is paid.</p><section class="gd-task" id="usage-and-paid-usage-the-alerts" data-gd-task><h2 class="gd-h2">The alerts</h2><p class="gd-p">At 80% of an allowance you get one quiet card on <b class="gd-ui">To do</b> and one email to the alert address. When it is used up, a second card and email.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Workers AI used up shows &quot;Stopped for today, never paid&quot;: it starts again at midnight, Toronto time. There is nothing to allow.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">A used-up image allowance shows &quot;Included ... used up for this month: Allow paid usage&quot;. Press <b class="gd-ui">Allow paid usage</b> to see what continuing costs at the current rates.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Choose until the end of today or this month, type the most it may cost (for example $1), and press the Allow button. Or press Keep paused.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">Nobody answering keeps it paused: nothing is charged. Live chat goes to a person, AI copy waits with the template text, Turo emails are read by the rules, photos keep their original background, the assistant rests.</div></li><li><span class="gd-n" aria-hidden="true">5</span><div class="gd-t">The website and the portals are never paused (that would stop bookings): their card shows the estimated cost, usually cents.</div></li></ol></div></section><section class="gd-task" id="usage-and-paid-usage-settings-usage" data-gd-task><h2 class="gd-h2">Settings &gt; Usage</h2><p class="gd-p">Open <b class="gd-ui">Settings</b>, then <b class="gd-ui">Usage</b>: every service, used against included, when it resets, paid usage and the last 30 days.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Workers AI by feature, at the top: the neurons each feature used today and in the last 7 days (the staff assistant, visitor chat, the phone line, search copy, listing copy, guide upkeep, Turo emails, the readers), and what each share has left now. Use Cloudflare counted beyond the app&#39;s own record shows as Unmetered.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">The day is shared in three: 70% is kept for the staff assistant; visitor chat, the phone line and the readers share the rest; background writing (search copy, listing copy, guide rewrites, Turo emails) gets 10%, and from 9 pm what is left of the day, less a small cushion for the assistant.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Press <b class="gd-ui">Change the shares</b> to change the assistant&#39;s reserve, the background share, the release hour or the cushion.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">Press <b class="gd-ui">Change the allowance</b> after a plan change (for example a Resend upgrade, or a larger disk on our server).</div></li><li><span class="gd-n" aria-hidden="true">5</span><div class="gd-t">Database size and file storage are our own server&#39;s: near the allowance, clean up or move to a larger server disk. Nothing is billed by use.</div></li><li><span class="gd-n" aria-hidden="true">6</span><div class="gd-t">Emails cannot be paid on the free plan: when the daily or monthly count is used, booking, payment and sign-in emails still go first and the others wait. A banner on To do says so.</div></li></ol></div></section>');
-- GUIDES 0194 END
