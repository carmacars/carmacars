-- 0059_guides_auto_sales_commission_only.sql
-- The owner's decisions of October 19, 2026 (docs/changes/2026-10-19-guides-auto-sales-commission-only.md):
--   1. the guides update themselves with nothing to review. Every automatic rewrite that passes the checks is published
--      at once, always, including a section an Admin edited before or has a draft waiting in (the newest automatic version
--      wins; the history keeps every version, and Revert brings the replaced text back). A rewrite that fails the checks
--      is never kept as a suggestion: the old text stays (the screenshots and button names are still updated by the
--      upkeep), and the section is logged for the next run (auto_retry_*), which tries again. A release's chapters are
--      published the same way. The "To review" queue is gone: its live suggestions are published (the ones newer than
--      the published text; older ones are dropped, logged in the audit log), and every flag is cleared.
--   2. Program settings: the owner confirmed the 20% discount limit, no price floor, and the commission rates and tiers as
--      set (recorded; no value changes).
--   3. staff enter their own home address (first sign-in to the VA or field portal, the staff agreement signing step, the
--      profile); it is required before they add a rental, mark a quote or an offer "I sourced this client", or earn a
--      commission (a commission waits as not earned yet until it is there). Admins can still edit it.
--   4. Sales is commission only: the Sales function's staff agreement defaults are commission only (no Rate, a flexible
--      schedule), and the generated VA agreement handles a commission-only engagement.
-- No applied migration is edited.

-- ================================================================ 1. the guides update themselves
alter table guide_sections add column if not exists auto_retry_at timestamptz;
alter table guide_sections add column if not exists auto_retry_note text;
alter table guide_sections add column if not exists auto_retry_count integer not null default 0;
comment on column guide_sections.auto_retry_at is 'The last guide upkeep run could not rewrite this section within the checks (0059): the old text was kept and the next run tries again. A log for the upkeep, never a task.';
comment on column guide_sections.needs_review is 'Internal to the guide upkeep since 0059: a screenshot in this section changed and the run has not checked its text yet. Never shown as a task.';

-- p: {section_id, body_md, html, reason, run, model, neurons, duration_ms, checks_ok, problems, retry_note}.
-- checks_ok with the HTML: published now, whatever an Admin edited or drafted (their draft is kept in the history), the
-- replaced text kept for Revert. retry_note: published, and still logged for the next run (only the button names were
-- fixed). Otherwise the old text stays and the section is logged for the next run. Nothing waits for anyone.
create or replace function app.guide_auto_update(p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  s guide_sections;
  v_body text := p ->> 'body_md';
  v_html text := p ->> 'html';
  v_run text := coalesce(nullif(p ->> 'run', ''), 'manual');
  v_reason text := left(coalesce(nullif(p ->> 'reason', ''), 'The screen changed'), 300);
  v_retry text := nullif(p ->> 'retry_note', '');
  v_new integer;
begin
  select * into s from guide_sections where id = (p ->> 'section_id')::uuid for update;
  if s.id is null then raise exception 'Section not found' using errcode = 'P0002'; end if;
  if coalesce(length(v_body), 0) < 10 then raise exception 'The text is missing' using errcode = '22023'; end if;
  insert into provider_calls (provider, purpose, ok, error, duration_ms, cost_microusd, units, unit)
  values (left(coalesce(nullif(p ->> 'model', ''), 'workers-ai'), 120), 'guide_rewrite', true, null, greatest(coalesce((p ->> 'duration_ms')::integer, 0), 0), 0,
          greatest(coalesce((p ->> 'neurons')::integer, 0), 0), 'neurons');
  if not coalesce((p ->> 'checks_ok')::boolean, false) or coalesce(v_html, '') = '' then
    update guide_sections set needs_review = false, review_note = null, review_images = '[]'::jsonb, suggestion_md = null, suggestion_at = null, suggestion_model = null,
           auto_retry_at = now(), auto_retry_count = auto_retry_count + 1,
           auto_retry_note = left(v_reason || '. Kept the old text: ' || coalesce(nullif(p ->> 'problems', ''), 'the rewrite did not pass the checks'), 600)
     where id = s.id;
    insert into audit_log (action, entity_table, entity_id, after)
    values ('guide_auto_kept', 'guide_sections', s.id::text, jsonb_build_object('portal', s.portal, 'section', s.slug, 'run', v_run, 'reason', v_reason, 'problems', p ->> 'problems'));
    return jsonb_build_object('result', 'kept', 'section_id', s.id);
  end if;
  if v_body = s.published_md and s.body_md = s.published_md then
    update guide_sections set needs_review = false, review_note = null, review_images = '[]'::jsonb, suggestion_md = null, suggestion_at = null, suggestion_model = null,
           auto_retry_at = case when v_retry is null then null else now() end, auto_retry_note = left(v_retry, 600)
     where id = s.id;
    return jsonb_build_object('result', 'same', 'section_id', s.id);
  end if;
  -- an Admin's draft waiting goes into the history before the newer automatic text replaces it
  if s.body_md is distinct from s.published_md or s.draft_version is distinct from s.published_version then
    insert into guide_section_versions (section_id, version, title, blurb, body_md, is_hidden, published)
    values (s.id, s.draft_version, s.title, s.blurb, s.body_md, s.is_hidden, false)
    on conflict (section_id, version, published) do nothing;
  end if;
  v_new := greatest(s.draft_version, coalesce(s.published_version, 0)) + 1;
  update guide_sections
     set auto_prev = jsonb_build_object('title', coalesce(s.published_title, s.title), 'blurb', coalesce(s.published_blurb, s.blurb), 'body_md', s.body_md,
                                        'published_md', s.published_md, 'published_html', s.published_html, 'version', s.published_version),
         title = coalesce(s.published_title, s.title), blurb = coalesce(s.published_blurb, s.blurb),
         body_md = v_body, draft_version = v_new, published_md = v_body, published_html = v_html, published_version = v_new, published_at = now(),
         needs_review = false, review_note = null, review_images = '[]'::jsonb, suggestion_md = null, suggestion_at = null, suggestion_model = null,
         auto_updated_at = now(), auto_update_reason = v_reason, auto_update_run = v_run,
         auto_retry_at = case when v_retry is null then null else now() end, auto_retry_note = left(v_retry, 600),
         auto_retry_count = case when v_retry is null then 0 else auto_retry_count + 1 end
   where id = s.id;
  insert into guide_section_versions (section_id, version, title, blurb, body_md, is_hidden, published)
  select s.id, v_new, coalesce(s.published_title, s.title), coalesce(s.published_blurb, s.blurb), v_body, s.is_hidden, b from (values (false), (true)) v(b)
  on conflict (section_id, version, published) do nothing;
  update guides g set version = version + 1, published_at = now()
   where g.portal = s.portal and g.version > 0
     and not exists (select 1 from audit_log l where l.action = 'guide_auto_update' and l.entity_id = v_run and l.at > now() - interval '1 day'
                       and l.after ->> 'portal' = s.portal);
  insert into audit_log (action, entity_table, entity_id, after)
  values ('guide_auto_update', 'guides', v_run, jsonb_build_object('portal', s.portal, 'section', s.slug, 'reason', v_reason, 'version', v_new,
                                                                    'replaced_admin_draft', s.body_md is distinct from s.published_md));
  return jsonb_build_object('result', 'updated', 'section_id', s.id, 'version', v_new);
end $$;

-- The sections a run reads (0055), with the ones the last run could not rewrite (retry) and the ones whose screenshot
-- changed in a run that did not check the text (pending), whatever run they come from.
create or replace function app.guide_upkeep_sections(p_run text) returns jsonb
language sql stable security definer set search_path = public, app as $$
  select coalesce(jsonb_agg(jsonb_build_object('id', s.id, 'portal', s.portal, 'slug', s.slug, 'kind', s.kind, 'title', s.title,
           'body_md', coalesce(s.published_md, s.body_md), 'draft_waiting', s.body_md is distinct from s.published_md or s.draft_version is distinct from s.published_version,
           'is_hidden', s.is_hidden, 'retry', s.auto_retry_at is not null, 'retry_note', s.auto_retry_note, 'retry_count', s.auto_retry_count, 'pending', s.needs_review,
           'images_changed', (select coalesce(jsonb_agg(e), '[]'::jsonb) from jsonb_array_elements(coalesce(s.review_images, '[]'::jsonb)) e
                               where s.needs_review and (coalesce(p_run, '') = '' or e ->> 'run' = p_run)))
           order by s.portal, s.sort_order), '[]'::jsonb)
    from guide_sections s join guides g on g.portal = s.portal
   where g.version > 0 and s.published_version is not null
$$;

-- A release's chapter (0055's rule, replaced): published whenever it differs from the live text, an Admin's edits
-- included (their text stays in the history and Revert brings it back); added when new.
create or replace function app.guide_release_section(p_portal text, p_slug text, p_kind text, p_after text, p_base_md text, p_title text, p_blurb text,
                                                     p_md text, p_html text) returns text
language plpgsql security definer set search_path = public, app as $$
declare
  s guide_sections;
  v_md text := app.guide_latest_images(p_md);
  v_html text := app.guide_latest_images(p_html);
  v_new integer;
  v_edited boolean;
begin
  if not exists (select 1 from guides where portal = p_portal) then return 'no guide'; end if;
  select * into s from guide_sections where portal = p_portal and slug = p_slug for update;
  if s.id is null then
    if not exists (select 1 from guide_sections where portal = p_portal) then return 'missing'; end if;
    return app.guide_add_published_section(p_portal, p_slug, p_kind, p_after, p_title, p_blurb, v_md, v_html);
  end if;
  if s.published_md = v_md and s.body_md = v_md and s.published_html is not distinct from v_html then
    update guide_sections set needs_review = false, review_note = null, suggestion_md = null, suggestion_at = null, suggestion_model = null where id = s.id and (needs_review or suggestion_md is not null);
    return 'same';
  end if;
  v_edited := p_base_md is null or s.published_md is distinct from app.guide_latest_images(p_base_md) or s.body_md is distinct from s.published_md
              or s.published_version is distinct from s.draft_version;
  if s.body_md is distinct from s.published_md or s.draft_version is distinct from s.published_version then
    insert into guide_section_versions (section_id, version, title, blurb, body_md, is_hidden, published)
    values (s.id, s.draft_version, s.title, s.blurb, s.body_md, s.is_hidden, false)
    on conflict (section_id, version, published) do nothing;
  end if;
  v_new := greatest(s.draft_version, coalesce(s.published_version, 0)) + 1;
  update guide_sections set title = p_title, blurb = p_blurb, body_md = v_md, draft_version = v_new,
         published_title = p_title, published_blurb = p_blurb, published_md = v_md, published_html = v_html, published_version = v_new, published_at = now(),
         needs_review = false, review_note = null, review_images = '[]'::jsonb, suggestion_md = null, suggestion_at = null, suggestion_model = null,
         auto_retry_at = null, auto_retry_note = null, auto_retry_count = 0,
         auto_prev = case when v_edited then jsonb_build_object('title', coalesce(s.published_title, s.title), 'blurb', coalesce(s.published_blurb, s.blurb), 'body_md', s.body_md,
                                                                'published_md', s.published_md, 'published_html', s.published_html, 'version', s.published_version) else auto_prev end,
         auto_updated_at = case when v_edited then now() else auto_updated_at end,
         auto_update_reason = case when v_edited then 'CarmaCars updated this chapter in a release' else auto_update_reason end
   where id = s.id;
  insert into guide_section_versions (section_id, version, title, blurb, body_md, is_hidden, published)
  select s.id, v_new, p_title, p_blurb, v_md, s.is_hidden, b from (values (false), (true)) v(b)
  on conflict (section_id, version, published) do nothing;
  update guides set version = version + 1, published_at = now() where portal = p_portal and version > 0 and published_at is distinct from now();
  return 'updated';
end $$;

-- 0049's update of a shipped chapter, with the same rule: published, never a suggestion.
create or replace function app.guide_update_published_section(p_portal text, p_slug text, p_old_md5 text, p_title text, p_blurb text,
                                                               p_md text, p_html text) returns text
language plpgsql security definer set search_path = public, app as $$
declare
  s guide_sections;
begin
  select * into s from guide_sections where portal = p_portal and slug = p_slug;
  if s.id is null then return 'missing'; end if;
  return app.guide_release_section(p_portal, p_slug, s.kind, null,
                                   case when md5(coalesce(s.published_md, '')) = p_old_md5 then s.published_md end, p_title, p_blurb, p_md, p_html);
end $$;

-- The admin reads without the review queue: no flag, no suggestion, no count to review.
alter function app.guide_admin(uuid, text) rename to guide_admin_0055;
create or replace function app.guide_admin(p_by uuid, p_portal text) returns jsonb
language sql stable security definer set search_path = public, app as $$
  select jsonb_set(r, '{sections}', coalesce((
      select jsonb_agg(x - 'needs_review' - 'review_note' - 'review_images' - 'review_flagged_at' - 'suggestion_md' - 'suggestion_at' - 'suggestion_model' order by o)
        from jsonb_array_elements(r -> 'sections') with ordinality t(x, o)), '[]'::jsonb))
    from app.guide_admin_0055(p_by, p_portal) r
$$;
alter function app.guides_admin(uuid) rename to guides_admin_0055;
create or replace function app.guides_admin(p_by uuid) returns jsonb
language sql stable security definer set search_path = public, app as $$
  select coalesce(jsonb_agg(g - 'needs_review' order by o), '[]'::jsonb) from jsonb_array_elements(app.guides_admin_0055(p_by)) with ordinality t(g, o)
$$;

-- ================================================================ 2. Program settings: the owner's confirmation
comment on column program_settings.custom_price_max_discount_bps is 'A rental charge typed by hand more than this far under the rate sheet is flagged for an Admin (0058), 20% by default; the owner confirmed 20% on October 19, 2026 (0059)';
comment on column program_settings.custom_price_floor_daily_cents is 'A rental charge typed by hand under this amount a day is flagged for an Admin (0058). Empty: no floor; the owner confirmed no floor on October 19, 2026 (0059)';
comment on column program_settings.staff_commission_bps is 'Staff commission outside the Sales function (customer service, finance, fleet, field staff; 0058): the share of the rental charge of a rental they sourced, 10% by default. It is also the field staff referral fee. Confirmed by the owner on October 19, 2026 (0059)';
comment on column program_settings.sales_tier_high_days is 'Rental days in a month for the top Sales tier, and the month''s target on My sales and the scorecard (0058), 100 by default. The tiers (10% under 50 days, 15% from 50, 20% from 100) were confirmed by the owner on October 19, 2026 (0059)';
insert into audit_log (action, entity_table, entity_id, after)
select 'owner_confirmed_settings', 'program_settings', s.id::text,
       jsonb_build_object('on', '2026-10-19', 'note', 'The owner confirmed the commission settings as set; no value changed',
                          'custom_price_max_discount_bps', s.custom_price_max_discount_bps, 'custom_price_floor_daily_cents', s.custom_price_floor_daily_cents,
                          'staff_commission_bps', s.staff_commission_bps, 'sales_tier_low_bps', s.sales_tier_low_bps, 'sales_tier_mid_bps', s.sales_tier_mid_bps,
                          'sales_tier_high_bps', s.sales_tier_high_bps, 'sales_tier_mid_days', s.sales_tier_mid_days, 'sales_tier_high_days', s.sales_tier_high_days)
  from program_settings s
 where s.id = (app.settings()).id;

-- ================================================================ 3. staff enter their own home address
alter table staff_profiles add column if not exists home_address_set_at timestamptz;
alter table staff_profiles add column if not exists home_address_set_by uuid references users(id);
comment on column staff_profiles.home_address is 'Home address (0058), entered by the staff member at their first sign-in, when signing their agreement or in their profile (0059); an Admin can edit it. Used only to recognize a household rental, which earns no commission. Required before they add a rental or earn a commission';

-- An active staff member (assistant or field staff) without a home address and postal code. Admins have no staff profile.
create or replace function app.staff_home_address_missing(p_user uuid) returns boolean
language sql stable security definer set search_path = public, app as $$
  select exists (select 1 from staff_profiles sp where sp.user_id = p_user and sp.is_active
                   and (nullif(btrim(coalesce(sp.home_address, '')), '') is null or nullif(btrim(coalesce(sp.home_postal_code, '')), '') is null))
$$;

create or replace function app.staff_home_address_read(p_user uuid) returns jsonb
language sql stable security definer set search_path = public, app as $$
  select jsonb_build_object('home_address', sp.home_address, 'home_postal_code', sp.home_postal_code, 'missing', app.staff_home_address_missing(p_user),
                            'set_at', sp.home_address_set_at)
    from staff_profiles sp where sp.user_id = p_user
$$;

-- The staff member saves their own home address. p: {home_address, home_postal_code}
create or replace function app.staff_home_address_save(p_user uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  v_addr text := regexp_replace(btrim(coalesce(p ->> 'home_address', '')), '\s+', ' ', 'g');
  v_postal text := upper(regexp_replace(btrim(coalesce(p ->> 'home_postal_code', '')), '\s+', ' ', 'g'));
begin
  if not exists (select 1 from staff_profiles where user_id = p_user and is_active) then raise exception 'Not permitted' using errcode = '42501'; end if;
  if length(v_addr) < 8 or v_addr !~ '[0-9]' or v_addr !~ '[A-Za-z]' then
    raise exception 'Write your full home address: number, street and city' using errcode = '22023';
  end if;
  if length(v_addr) > 300 then raise exception 'The address is too long' using errcode = '22023'; end if;
  if v_postal !~ '^[A-Z0-9][A-Z0-9 -]{2,9}$' then raise exception 'Write your postal code' using errcode = '22023'; end if;
  update staff_profiles set home_address = v_addr, home_postal_code = v_postal, home_address_set_at = now(), home_address_set_by = p_user where user_id = p_user;
  insert into audit_log (actor_user_id, action, entity_table, entity_id, after)
  values (p_user, 'staff_home_address_save', 'staff_profiles', p_user::text, jsonb_build_object('home_postal_code', v_postal));
  return app.staff_home_address_read(p_user);
end $$;

-- An Admin can still edit it (0058's call), now dated.
create or replace function app.staff_household_set(p_by uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  v_staff uuid := nullif(p ->> 'staff', '')::uuid;
begin
  perform app.assert_admin(p_by);
  if not app.user_is_sales_staff(v_staff) then raise exception 'Choose an active staff member' using errcode = '22023'; end if;
  update staff_profiles set home_address = nullif(btrim(coalesce(p ->> 'home_address', '')), ''),
         home_postal_code = upper(nullif(btrim(coalesce(p ->> 'home_postal_code', '')), '')), home_address_set_at = now(), home_address_set_by = p_by
   where user_id = v_staff;
  insert into audit_log (actor_user_id, action, entity_table, entity_id, after)
  values (p_by, 'staff_household_set', 'staff_profiles', v_staff::text, jsonb_build_object('home_postal_code', upper(nullif(btrim(coalesce(p ->> 'home_postal_code', '')), ''))));
  return jsonb_build_object('staff', v_staff);
end $$;

-- 0058's sync, with one more condition to earn: the staff member's home address is there (the household check needs it).
-- Until then the commission waits as not earned yet, with a note saying why.
create or replace function app.commission_sync(p_booking uuid) returns void
language plpgsql security definer set search_path = public, app as $$
declare
  b bookings;
  c staff_commissions;
  v_staff uuid;
  v_reason text;
  v_base bigint;
  v_earned boolean;
  v_month date;
  v_old_month date;
  v_no_addr boolean;
  v_note constant text := 'Earned once the home address is in the staff member''s profile';
begin
  select * into b from bookings where id = p_booking;
  if b.id is null then return; end if;
  v_staff := case when b.sales_sourced then b.sales_staff_id end;
  if v_staff is null and not exists (select 1 from staff_commissions x where x.booking_id = b.id) then return; end if;
  for c in select * from staff_commissions x where x.booking_id = b.id and x.kind = 'commission' and x.staff_id is distinct from v_staff
             and x.status not in ('void', 'reversed') and x.reversed_at is null loop
    perform app.commission_close(c.id, 'The booking is credited to someone else now');
  end loop;
  if v_staff is null then return; end if;

  v_reason := case when b.booking_type = 'owner' then 'Owner Booking'
                   when b.status in ('cancelled', 'no_show', 'expired', 'declined') then 'Cancelled booking'
                   when exists (select 1 from disputes d where d.booking_id = b.id and d.status = 'lost') then 'Charged back'
                   else app.commission_own_reason(b.id, v_staff) end;
  v_base := case when v_reason is null then app.commission_base_cents(b.id) else 0 end;
  if v_reason is null and b.status in ('returned', 'closed') and v_base <= 0 then v_reason := 'Refunded'; end if;
  v_no_addr := app.staff_home_address_missing(v_staff);
  v_earned := v_reason is null and b.status in ('returned', 'closed') and app.booking_paid_in_full(b.id) and not v_no_addr
              and not exists (select 1 from disputes d where d.booking_id = b.id and d.status in ('open', 'evidence_submitted'));
  v_month := app.month_start(app.local_date(coalesce(b.checked_in_at, b.return_at)));

  select * into c from staff_commissions where booking_id = b.id and staff_id = v_staff and kind = 'commission' for update;
  if c.id is null then
    if v_reason is not null then return; end if;
    insert into staff_commissions (booking_id, staff_id, kind, month, rental_days, base_cents, status, earned_at, note)
    values (b.id, v_staff, 'commission', v_month, coalesce(b.billable_days, 0), v_base,
            case when v_earned then 'pending_approval' else 'accruing' end, case when v_earned then now() end, case when v_no_addr then v_note end);
    perform app.commission_retier(v_staff, v_month);
    return;
  end if;
  if c.admin_reversed then return; end if;
  if v_reason is not null then
    perform app.commission_close(c.id, v_reason);
    return;
  end if;
  v_old_month := c.month;
  if c.status in ('void', 'reversed') or (c.status = 'paid' and c.reversed_at is not null) then
    update staff_commissions set status = case when c.status = 'paid' then 'paid' when v_earned then 'pending_approval' else 'accruing' end,
           reversed_at = null, reversed_by = null, reason = null, earned_at = case when v_earned then coalesce(earned_at, now()) end,
           month = v_month, rental_days = coalesce(b.billable_days, 0), base_cents = v_base, updated_at = now()
     where id = c.id;
  else
    update staff_commissions set month = case when status = 'paid' then month else v_month end, rental_days = coalesce(b.billable_days, 0), base_cents = v_base,
           status = case when status = 'accruing' and v_earned then 'pending_approval' when status = 'pending_approval' and not v_earned then 'accruing' else status end,
           earned_at = case when status = 'accruing' and v_earned then now() when status = 'pending_approval' and not v_earned then null else earned_at end,
           approved_at = case when status = 'approved' and base_cents <> v_base then null else approved_at end,
           approved_by = case when status = 'approved' and base_cents <> v_base then null else approved_by end,
           note = case when status = 'approved' and base_cents <> v_base then 'The rental charge changed after it was approved: approve it again' else note end,
           updated_at = now()
     where id = c.id;
    update staff_commissions set status = 'pending_approval' where id = c.id and status = 'approved' and approved_at is null;
  end if;
  update staff_commissions set note = case when v_no_addr and status = 'accruing' then v_note when note = v_note then null else note end
   where id = c.id and (note is not distinct from v_note) <> (v_no_addr and status = 'accruing');
  perform app.commission_retier(v_staff, v_month);
  if v_old_month is distinct from v_month then perform app.commission_retier(v_staff, v_old_month); end if;
end $$;

-- A home address added (by the staff member or an Admin): the commissions waiting for it are brought in step.
create or replace function app.staff_profiles_home_resync() returns trigger
language plpgsql security definer set search_path = public, app as $$
declare
  r record;
begin
  for r in select distinct booking_id from staff_commissions where staff_id = new.user_id and kind = 'commission' and status in ('accruing', 'pending_approval') loop
    perform app.commission_sync(r.booking_id);
  end loop;
  return new;
end $$;
drop trigger if exists staff_profiles_home_resync on staff_profiles;
create trigger staff_profiles_home_resync after update of home_address, home_postal_code on staff_profiles
  for each row when (old.home_address is distinct from new.home_address or old.home_postal_code is distinct from new.home_postal_code)
  execute function app.staff_profiles_home_resync();

-- The staff agreement, prepared (0057), with the staff member's own home address (the Field Staff Agreement prints it).
alter function app.staff_agreement_prepare(uuid, uuid) rename to staff_agreement_prepare_0057;
create or replace function app.staff_agreement_prepare(p_by uuid, p_user uuid) returns jsonb
language sql stable security definer set search_path = public, app as $$
  select jsonb_set(r, '{staff}', (r -> 'staff') || jsonb_build_object(
           'home_address', (select nullif(concat_ws(', ', nullif(btrim(sp.home_address), ''), nullif(btrim(sp.home_postal_code), '')), '') from staff_profiles sp where sp.user_id = p_user)))
    from app.staff_agreement_prepare_0057(p_by, p_user) r
$$;

-- ================================================================ 4. Sales: commission only
-- The Sales function's defaults: commission only (no Rate), a flexible schedule (no set days or hours). A value an
-- Admin already set for Sales is kept.
alter table program_settings alter column staff_agreement_defaults set default
  '{"va": {"country": "Philippines", "currency": "USD", "platform": "OnlineJobs.ph", "pay_timing": "every two weeks", "trial_days": "30",
           "coverage": "Days and times as set in the weekly roster",
           "by_function": {"cs": {"pay_basis": "monthly", "rate": "350.00", "schedule": "full_time", "days_per_week": "6", "hours_per_day": "10"},
                           "fleet": {"pay_basis": "monthly", "rate": "400.00", "schedule": "full_time", "days_per_week": "6", "hours_per_day": "10"},
                           "finance": {"pay_basis": "monthly", "rate": "200.00", "schedule": "part_time", "days_per_week": "3", "hours_per_day": "9"},
                           "sales": {"pay_basis": "commission", "rate": "", "schedule": "flexible", "days_per_week": "", "hours_per_day": ""}}},
    "field": {"wage": "18.00", "currency": "CAD", "vehicle_types": "Cars, SUVs and minivans in the CarmaCars fleet", "pay_dates": "every two weeks", "licence_years": "3"}}'::jsonb;
comment on column program_settings.staff_agreement_defaults is
  'What a staff agreement generated from the record starts with (0049, by function since 0057). va: {country, currency, platform, pay_timing, trial_days, coverage (days and times), by_function: {cs, fleet, finance, sales: {pay_basis monthly|hourly|commission, rate, schedule full_time|part_time|flexible, days_per_week, hours_per_day}}}. Commission only (Sales since 0059): no Rate, no set schedule or hours, paid the commission of VA agreement 3.4. field: {wage (CA$ an hour), currency, vehicle_types, pay_dates, licence_years}. The Admin sees and can change each value before sending.';
update program_settings s
   set staff_agreement_defaults = jsonb_set(s.staff_agreement_defaults, '{va,by_function,sales}',
         '{"pay_basis": "commission", "rate": "", "schedule": "flexible", "days_per_week": "", "hours_per_day": ""}'::jsonb, true)
 where s.staff_agreement_defaults #> '{va,by_function}' is not null
   and coalesce(s.staff_agreement_defaults #>> '{va,by_function,sales,pay_basis}', '') = ''
   and coalesce(s.staff_agreement_defaults #>> '{va,by_function,sales,rate}', '') = '';

-- ================================================================ 5. the doors
create or replace function app.ops59(p_user uuid, p_call text, p_name text, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
begin
  case p_name
  when 'home_address' then return coalesce(app.staff_home_address_read(p_user), '{}'::jsonb);
  when 'home_address_save' then return app.staff_home_address_save(p_user, p);
  else raise exception 'Unknown action %', p_name using errcode = '22023';
  end case;
end $$;

alter function app.door(uuid, text, text, text, jsonb) rename to door_0058;
create or replace function app.door(p_user uuid, p_aal text, p_call text, p_name text, p jsonb default '{}'::jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  p_ jsonb := coalesce(p, '{}'::jsonb);
  v_msg constant text := 'Add your home address first (Profile). It is needed before you add a rental or earn a commission.';
begin
  if p_call in ('va_read', 'field_read', 'va_do', 'field_do') and p_name in ('home_address', 'home_address_save') then
    perform app.door_begin(p_user, p_aal);
    if p_call like 'va_%' and not app.user_is_staff(p_user) then raise exception 'Not permitted' using errcode = '42501'; end if;
    if p_call like 'field_%' and not app.user_is_field(p_user) then raise exception 'Not permitted' using errcode = '42501'; end if;
    return app.ops59(p_user, p_call, p_name, p_ - '_va');
  end if;
  -- the review queue of the guides is gone (0059): the guides update themselves
  if p_call = 'ops_do' and p_name in ('guide_suggestion_record', 'guide_review_resolve') then
    raise exception 'The guides update themselves: there is nothing to review' using errcode = '22023';
  end if;
  -- the home address before a rental, or a quote or an offer marked "I sourced this client"
  if app.staff_home_address_missing(p_user) then
    if (p_call = 'ops_do' and p_name = 'manual_rental_create')
       or (p_call = 'va_do' and p_name = 'quote_create' and p_ ->> 'sales_choice' = 'sourced')
       or (p_call in ('va_do', 'admin_do') and p_name in ('send_offer', 'resend_offer') and p_ ->> 'sales_choice' = 'sourced') then
      raise exception '%', v_msg using errcode = '22023';
    end if;
  end if;
  return app.door_0058(p_user, p_aal, p_call, p_name, p);
end $$;

-- ================================================================ 6. privileges
do $$
declare
  f record;
begin
  for f in
    select p.oid::regprocedure as sig from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'app' and p.proname = any (array[
              'guide_auto_update', 'guide_upkeep_sections', 'guide_release_section', 'guide_update_published_section', 'guide_admin', 'guides_admin',
              'staff_home_address_missing', 'staff_home_address_read', 'staff_home_address_save', 'staff_household_set', 'commission_sync', 'staff_profiles_home_resync',
              'staff_agreement_prepare', 'ops59', 'door'])
  loop
    execute format('revoke all on function %s from public, anon, authenticated', f.sig);
    execute format('grant execute on function %s to service_role', f.sig);
  end loop;
end $$;

do $$
declare
  r record;
  v_new regprocedure;
  g text;
begin
  for r in select p.oid, m.new_name, oidvectortypes(p.proargtypes) as args
             from pg_proc p join pg_namespace n on n.oid = p.pronamespace
             join (values ('door_0058', 'door'), ('guide_admin_0055', 'guide_admin'), ('guides_admin_0055', 'guides_admin'),
                          ('staff_agreement_prepare_0057', 'staff_agreement_prepare')) m(old_name, new_name)
               on m.old_name = p.proname
            where n.nspname = 'app' loop
    v_new := format('app.%I(%s)', r.new_name, r.args)::regprocedure;
    execute format('revoke all on function %s from public, anon, authenticated', v_new);
    foreach g in array array['anon', 'authenticated', 'service_role'] loop
      if has_function_privilege(g, r.oid, 'execute') then execute format('grant execute on function %s to %I', v_new, g); end if;
    end loop;
  end loop;
end $$;

-- ================================================================ 7. the guides of this release, and the queue published
-- From docs/guides/content (docs/guides/src, exported): every chapter this release changed, and the three chapters whose
-- 0058 text was waiting as a suggestion (admin/owner-money, admin/settings, field/my-jobs), published.
create or replace function app.guide_release_0059(p_portal text, p_slug text, p_kind text, p_after text, p_base_md text, p_title text, p_blurb text,
                                                  p_md text, p_html text) returns text
language sql security definer set search_path = public, app as $$
  select app.guide_release_section(p_portal, p_slug, p_kind, p_after, p_base_md, p_title, p_blurb, p_md, p_html)
$$;
revoke all on function app.guide_release_0059(text, text, text, text, text, text, text, text, text) from public, anon, authenticated;
grant execute on function app.guide_release_0059(text, text, text, text, text, text, text, text, text) to service_role;

-- GUIDES 0059 START (generated by supabase/seed/0059_gen_guides.mjs from docs/guides/content; do not edit by hand)
select app.guide_release_0059('admin', 'people-and-access', 'chapter', 'getting-around-admin', 'Let people in, help them back in when they are locked out, and see exactly what they see. Every step is recorded in the audit log.

## Portals and sign-in

Open **People** > **Portals and view as**. Every portal has a card.

1. Each card links to **Its sign-in page**, the address to send that person.
2. Choose a person in the list on the card.
3. Press **Open as this person** to see that portal as they see it.

![](/guides/img/admin-27-portals-desktop-0361bf61.jpg "desktop; size: 1440 820; address: carmacars.ca/admin/portals; pins: 1 65.9 30.2, 2 58.1 39.4, 3 51.6 45.6")

## Invite a person

Invitations work for staff, field staff, owners and investors. The person gets our invitation email and chooses a password.

1. Under Invite a person, choose the Role: Staff (assistant), Field staff, Owner on file or Investor on file. Admin is not offered: only rent@carmacars.ca can be an Admin.
2. Fill in the Name and Email.
3. For staff, pick the Main function, and tick Also covers for any other function they help with. For field staff, pick the Field function.
4. Press **Invite**. The link in the email works for 24 hours.

![](/guides/img/admin-27-portals-desktop-c10725cb.jpg "desktop; size: 1230 360; address: carmacars.ca/admin/portals; pins: 1 18.8 40.8, 2 50.0 40.8, 3 18.8 66.7, 4 9.8 87.8")

> Tip: Someone who already signs in gets the new role at once, with no email. Owners and investors must be on file first: Owners and partners > Owners and People > Investors also have a one-click invite for a record without a sign-in.

## Send a password link

For anyone who forgot their password or let their invitation expire.

1. Under People who can sign in, search by name or email.
2. On their row, press **Send password link**. They get "Reset your CarmaCars password", valid for 24 hours.
3. **View as (...)** on the same row opens their portal, read only.

![](/guides/img/admin-27-portals-desktop-ee9b3e94.jpg "desktop; size: 1230 440; address: carmacars.ca/admin/portals; pins: 1 74.8 6.6, 2 68.2 28.6, 3 84.1 28.6")

## View as: see what someone sees

1. A red banner says "Viewing as Name (email), read only." on every page.
2. Click around their portal. Nothing can be changed: every save is refused.
3. Press **Exit** to come back. A view also ends by itself after 30 minutes.

![](/guides/img/admin-28-view-as-desktop-f858e38c.jpg "desktop; size: 1440 620; address: carmacars.ca/owner; pins: 1 48.6 4.5, 3 94.4 4.5")

> Watch out: Can''t change anything in Admin? You may still be viewing as someone. Look for the red banner and press Exit.

## The audit log

**Settings** > **Audit log** shows who changed what, and when.

1. Changes lists every change with the person, the action, the table and the record. Data access lists lookups of private data.
2. Every View as is recorded (view_as_start), with the person viewed.
3. Search by table, record id or value.

![](/guides/img/admin-29-audit-desktop-b7504100.jpg "desktop; size: 1440 560; address: carmacars.ca/admin/audit; pins: 1 22.6 31.1, 2 39.0 46.4, 3 89.6 20.7")

## Staff and roles

**People** > **Staff** opens Staff and roles.

1. Invite staff here too: Role, Name, Email, Main function and Also covers, then **Invite**.
2. Each row has **Send password link**, **View as (...)** and Limits (how much they may approve or refund).
3. Press **End access** to close their staff portal at once. **Restore** undoes it.

![](/guides/img/admin-26-staff-desktop-72287d0b.jpg "desktop; size: 1440 780; address: carmacars.ca/admin/settings/staff; pins: 1 20.8 59.0, 2 94.4 86.7, 3 83.3 92.6")

## Admin access

**Settings** > **All settings**, then Admin access. Who may hold the Admin role.

1. The list holds rent@carmacars.ca, and verify-admin@carmacars.ca, the automated test account the site''s nightly checks sign in with.
2. Below it: everyone who holds the Admin role now. Each must be on the list; the database refuses the Admin role to any other address.
3. Change the list only if the business''s Admin address changes.

## Staff scorecards

See how each assistant is doing against the targets.

1. On a staff member''s row in Staff and roles, press **Scorecard**.
2. By week shows each measure (for example quote sent within 5 minutes) and the result for each week.
3. A task meets its target when it is done by its due time. Daily checks count when done by 9:00 and 18:00.

![](/guides/img/va-sales-05-scorecard-desktop-956a5a9e.jpg "desktop; size: 1230 350; address: carmacars.ca/va/scorecard; pins: 2 21.1 42.9")

## Sales by staff member

See each person''s commissions, quotes, offers, rentals added, bookings confirmed and booked revenue.

1. On a staff member''s row in Staff and roles, press **Sales**. Press **By week** or **By month**.
2. The tiles show the current week or month. By week (or By month) lists each period: quotes created, offers sent, rentals added, bookings confirmed, conversion and booked revenue.
3. Follow-ups due lists their open deals with the next step. Deals lists each booking they created, added or sent an offer on, with what it counts.
4. A deal credited to the wrong person, or marked sourced when it was not? Press **Reassign** beside it, choose who, say whether they sourced the client, and write the reason.
5. **Commission rate** gives this person their own flat rate (empty: the Program settings). **Reverse** beside a commission stops it, for example for a household rental found later.
6. The whole team: **Today** > **Overview**, the Sales card at the bottom. Choose another month and press **Show**.

| Figure | How it is counted |
| --- | --- |
| Credited to | Whoever created the quote or added the rental; for a website request, whoever sent its first offer. An Admin can reassign it. |
| Conversion | Of the deals credited in the period, the share confirmed so far. |
| Booked revenue | The rental charge before tax, after discounts, for bookings confirmed in the period. A cancelled booking counts only what was kept; refunds come off. |
', 'People and access', 'Portals and sign-in, invitations, password links, View as, staff and scorecards.',
  'Let people in, help them back in when they are locked out, and see exactly what they see. Every step is recorded in the audit log.

## Portals and sign-in

Open **People** > **Portals and view as**. Every portal has a card.

1. Each card links to **Its sign-in page**, the address to send that person.
2. Choose a person in the list on the card.
3. Press **Open as this person** to see that portal as they see it.

![](/guides/img/admin-27-portals-desktop-0361bf61.jpg "desktop; size: 1440 820; address: carmacars.ca/admin/portals; pins: 1 65.9 30.2, 2 58.1 39.4, 3 51.6 45.6")

## Invite a person

Invitations work for staff, field staff, owners and investors. The person gets our invitation email and chooses a password.

1. Under Invite a person, choose the Role: Staff (assistant), Field staff, Owner on file or Investor on file. Admin is not offered: only rent@carmacars.ca can be an Admin.
2. Fill in the Name and Email.
3. For staff, pick the Main function, and tick Also covers for any other function they help with. For field staff, pick the Field function.
4. Press **Invite**. The link in the email works for 24 hours.

![](/guides/img/admin-27-portals-desktop-c10725cb.jpg "desktop; size: 1230 360; address: carmacars.ca/admin/portals; pins: 1 18.8 40.8, 2 50.0 40.8, 3 18.8 66.7, 4 9.8 87.8")

> Tip: Someone who already signs in gets the new role at once, with no email. Owners and investors must be on file first: Owners and partners > Owners and People > Investors also have a one-click invite for a record without a sign-in.

## Send a password link

For anyone who forgot their password or let their invitation expire.

1. Under People who can sign in, search by name or email.
2. On their row, press **Send password link**. They get "Reset your CarmaCars password", valid for 24 hours.
3. **View as (...)** on the same row opens their portal, read only.

![](/guides/img/admin-27-portals-desktop-ee9b3e94.jpg "desktop; size: 1230 440; address: carmacars.ca/admin/portals; pins: 1 74.8 6.6, 2 68.2 28.6, 3 84.1 28.6")

## View as: see what someone sees

1. A red banner says "Viewing as Name (email), read only." on every page.
2. Click around their portal. Nothing can be changed: every save is refused.
3. Press **Exit** to come back. A view also ends by itself after 30 minutes.

![](/guides/img/admin-28-view-as-desktop-f858e38c.jpg "desktop; size: 1440 620; address: carmacars.ca/owner; pins: 1 48.6 4.5, 3 94.4 4.5")

> Watch out: Can''t change anything in Admin? You may still be viewing as someone. Look for the red banner and press Exit.

## The audit log

**Settings** > **Audit log** shows who changed what, and when.

1. Changes lists every change with the person, the action, the table and the record. Data access lists lookups of private data.
2. Every View as is recorded (view_as_start), with the person viewed.
3. Search by table, record id or value.

![](/guides/img/admin-29-audit-desktop-b7504100.jpg "desktop; size: 1440 560; address: carmacars.ca/admin/audit; pins: 1 22.6 31.1, 2 39.0 46.4, 3 89.6 20.7")

## Staff and roles

**People** > **Staff** opens Staff and roles.

1. Invite staff here too: Role, Name, Email, Main function and Also covers, then **Invite**.
2. Each row has **Send password link**, **View as (...)** and Limits (how much they may approve or refund).
3. Press **End access** to close their staff portal at once. **Restore** undoes it.

![](/guides/img/admin-26-staff-desktop-72287d0b.jpg "desktop; size: 1440 780; address: carmacars.ca/admin/settings/staff; pins: 1 20.8 59.0, 2 94.4 86.7, 3 83.3 92.6")

## Admin access

**Settings** > **All settings**, then Admin access. Who may hold the Admin role.

1. The list holds rent@carmacars.ca, and verify-admin@carmacars.ca, the automated test account the site''s nightly checks sign in with.
2. Below it: everyone who holds the Admin role now. Each must be on the list; the database refuses the Admin role to any other address.
3. Change the list only if the business''s Admin address changes.

## Staff scorecards

See how each assistant is doing against the targets.

1. On a staff member''s row in Staff and roles, press **Scorecard**.
2. By week shows each measure (for example quote sent within 5 minutes) and the result for each week.
3. A task meets its target when it is done by its due time. Daily checks count when done by 9:00 and 18:00.

![](/guides/img/va-sales-05-scorecard-desktop-956a5a9e.jpg "desktop; size: 1230 350; address: carmacars.ca/va/scorecard; pins: 2 21.1 42.9")

## Sales by staff member

See each person''s commissions, quotes, offers, rentals added, bookings confirmed and booked revenue.

1. On a staff member''s row in Staff and roles, press **Sales**. Press **By week** or **By month**.
2. The tiles show the current week or month. By week (or By month) lists each period: quotes created, offers sent, rentals added, bookings confirmed, conversion and booked revenue.
3. Follow-ups due lists their open deals with the next step. Deals lists each booking they created, added or sent an offer on, with what it counts.
4. A deal credited to the wrong person, or marked sourced when it was not? Press **Reassign** beside it, choose who, say whether they sourced the client, and write the reason.
5. **Commission rate** gives this person their own flat rate (empty: the Program settings). **Reverse** beside a commission stops it, for example for a household rental found later.
6. Staff enter their own home address (at their first sign-in, before they sign their agreement, or in their profile). It is needed before they add a rental or earn a commission, and spots a household rental. **Home address** here changes it if it is wrong.
7. The whole team: **Today** > **Overview**, the Sales card at the bottom. Choose another month and press **Show**.

| Figure | How it is counted |
| --- | --- |
| Credited to | Whoever created the quote or added the rental; for a website request, whoever sent its first offer. An Admin can reassign it. |
| Conversion | Of the deals credited in the period, the share confirmed so far. |
| Booked revenue | The rental charge before tax, after discounts, for bookings confirmed in the period. A cancelled booking counts only what was kept; refunds come off. |
',
  '<p class="gd-p">Let people in, help them back in when they are locked out, and see exactly what they see. Every step is recorded in the audit log.</p><section class="gd-task" id="people-and-access-portals-and-sign-in" data-gd-task><h2 class="gd-h2">Portals and sign-in</h2><p class="gd-p">Open <b class="gd-ui">People</b> &gt; <b class="gd-ui">Portals and view as</b>. Every portal has a card.</p><div class="gd-stepblock gd-stepblock--below"><div class="gd-stepcol"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Each card links to <b class="gd-ui">Its sign-in page</b>, the address to send that person.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Choose a person in the list on the card.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Press <b class="gd-ui">Open as this person</b> to see that portal as they see it.</div></li></ol></div><figure class="gd-fig gd-fig--desk"><div class="gd-browser"><div class="gd-bar" aria-hidden="true"><i></i><i></i><i></i><span class="gd-addr">carmacars.ca/admin/portals</span></div><div class="gd-imgwrap" style="aspect-ratio:1440/820"><img src="/guides/img/admin-27-portals-desktop-0361bf61.jpg" alt="" loading="lazy" decoding="async" width="1440" height="820"><span class="gd-pin" style="left:65.9%;top:30.2%" aria-hidden="true">1</span><span class="gd-pin" style="left:58.1%;top:39.4%" aria-hidden="true">2</span><span class="gd-pin" style="left:51.6%;top:45.6%" aria-hidden="true">3</span></div></div></figure></div></section><section class="gd-task" id="people-and-access-invite-a-person" data-gd-task><h2 class="gd-h2">Invite a person</h2><p class="gd-p">Invitations work for staff, field staff, owners and investors. The person gets our invitation email and chooses a password.</p><div class="gd-stepblock gd-stepblock--below"><div class="gd-stepcol"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Under Invite a person, choose the Role: Staff (assistant), Field staff, Owner on file or Investor on file. Admin is not offered: only rent@carmacars.ca can be an Admin.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Fill in the Name and Email.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">For staff, pick the Main function, and tick Also covers for any other function they help with. For field staff, pick the Field function.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">Press <b class="gd-ui">Invite</b>. The link in the email works for 24 hours.</div></li></ol></div><figure class="gd-fig gd-fig--desk"><div class="gd-browser"><div class="gd-bar" aria-hidden="true"><i></i><i></i><i></i><span class="gd-addr">carmacars.ca/admin/portals</span></div><div class="gd-imgwrap" style="aspect-ratio:1230/360"><img src="/guides/img/admin-27-portals-desktop-c10725cb.jpg" alt="" loading="lazy" decoding="async" width="1230" height="360"><span class="gd-pin" style="left:18.8%;top:40.8%" aria-hidden="true">1</span><span class="gd-pin" style="left:50%;top:40.8%" aria-hidden="true">2</span><span class="gd-pin" style="left:18.8%;top:66.7%" aria-hidden="true">3</span><span class="gd-pin" style="left:9.8%;top:87.8%" aria-hidden="true">4</span></div></div></figure></div><aside class="gd-box"><span class="gd-lbl">Tip</span><div>Someone who already signs in gets the new role at once, with no email. Owners and investors must be on file first: Owners and partners &gt; Owners and People &gt; Investors also have a one-click invite for a record without a sign-in.</div></aside></section><section class="gd-task" id="people-and-access-send-a-password-link" data-gd-task><h2 class="gd-h2">Send a password link</h2><p class="gd-p">For anyone who forgot their password or let their invitation expire.</p><div class="gd-stepblock gd-stepblock--below"><div class="gd-stepcol"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Under People who can sign in, search by name or email.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">On their row, press <b class="gd-ui">Send password link</b>. They get &quot;Reset your CarmaCars password&quot;, valid for 24 hours.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t"><b class="gd-ui">View as (...)</b> on the same row opens their portal, read only.</div></li></ol></div><figure class="gd-fig gd-fig--desk"><div class="gd-browser"><div class="gd-bar" aria-hidden="true"><i></i><i></i><i></i><span class="gd-addr">carmacars.ca/admin/portals</span></div><div class="gd-imgwrap" style="aspect-ratio:1230/440"><img src="/guides/img/admin-27-portals-desktop-ee9b3e94.jpg" alt="" loading="lazy" decoding="async" width="1230" height="440"><span class="gd-pin" style="left:74.8%;top:6.6%" aria-hidden="true">1</span><span class="gd-pin" style="left:68.2%;top:28.6%" aria-hidden="true">2</span><span class="gd-pin" style="left:84.1%;top:28.6%" aria-hidden="true">3</span></div></div></figure></div></section><section class="gd-task" id="people-and-access-view-as-see-what-someone-sees" data-gd-task><h2 class="gd-h2">View as: see what someone sees</h2><div class="gd-stepblock gd-stepblock--below"><div class="gd-stepcol"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">A red banner says &quot;Viewing as Name (email), read only.&quot; on every page.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Click around their portal. Nothing can be changed: every save is refused.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Press <b class="gd-ui">Exit</b> to come back. A view also ends by itself after 30 minutes.</div></li></ol></div><figure class="gd-fig gd-fig--desk"><div class="gd-browser"><div class="gd-bar" aria-hidden="true"><i></i><i></i><i></i><span class="gd-addr">carmacars.ca/owner</span></div><div class="gd-imgwrap" style="aspect-ratio:1440/620"><img src="/guides/img/admin-28-view-as-desktop-f858e38c.jpg" alt="" loading="lazy" decoding="async" width="1440" height="620"><span class="gd-pin" style="left:48.6%;top:4.5%" aria-hidden="true">1</span><span class="gd-pin" style="left:94.4%;top:4.5%" aria-hidden="true">3</span></div></div></figure></div><aside class="gd-box gd-box--warn"><span class="gd-lbl">Watch out</span><div>Can&#39;t change anything in Admin? You may still be viewing as someone. Look for the red banner and press Exit.</div></aside></section><section class="gd-task" id="people-and-access-the-audit-log" data-gd-task><h2 class="gd-h2">The audit log</h2><p class="gd-p"><b class="gd-ui">Settings</b> &gt; <b class="gd-ui">Audit log</b> shows who changed what, and when.</p><div class="gd-stepblock gd-stepblock--below"><div class="gd-stepcol"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Changes lists every change with the person, the action, the table and the record. Data access lists lookups of private data.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Every View as is recorded (view_as_start), with the person viewed.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Search by table, record id or value.</div></li></ol></div><figure class="gd-fig gd-fig--desk"><div class="gd-browser"><div class="gd-bar" aria-hidden="true"><i></i><i></i><i></i><span class="gd-addr">carmacars.ca/admin/audit</span></div><div class="gd-imgwrap" style="aspect-ratio:1440/560"><img src="/guides/img/admin-29-audit-desktop-b7504100.jpg" alt="" loading="lazy" decoding="async" width="1440" height="560"><span class="gd-pin" style="left:22.6%;top:31.1%" aria-hidden="true">1</span><span class="gd-pin" style="left:39%;top:46.4%" aria-hidden="true">2</span><span class="gd-pin" style="left:89.6%;top:20.7%" aria-hidden="true">3</span></div></div></figure></div></section><section class="gd-task" id="people-and-access-staff-and-roles" data-gd-task><h2 class="gd-h2">Staff and roles</h2><p class="gd-p"><b class="gd-ui">People</b> &gt; <b class="gd-ui">Staff</b> opens Staff and roles.</p><div class="gd-stepblock gd-stepblock--below"><div class="gd-stepcol"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Invite staff here too: Role, Name, Email, Main function and Also covers, then <b class="gd-ui">Invite</b>.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Each row has <b class="gd-ui">Send password link</b>, <b class="gd-ui">View as (...)</b> and Limits (how much they may approve or refund).</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Press <b class="gd-ui">End access</b> to close their staff portal at once. <b class="gd-ui">Restore</b> undoes it.</div></li></ol></div><figure class="gd-fig gd-fig--desk"><div class="gd-browser"><div class="gd-bar" aria-hidden="true"><i></i><i></i><i></i><span class="gd-addr">carmacars.ca/admin/settings/staff</span></div><div class="gd-imgwrap" style="aspect-ratio:1440/780"><img src="/guides/img/admin-26-staff-desktop-72287d0b.jpg" alt="" loading="lazy" decoding="async" width="1440" height="780"><span class="gd-pin" style="left:20.8%;top:59%" aria-hidden="true">1</span><span class="gd-pin" style="left:94.4%;top:86.7%" aria-hidden="true">2</span><span class="gd-pin" style="left:83.3%;top:92.6%" aria-hidden="true">3</span></div></div></figure></div></section><section class="gd-task" id="people-and-access-admin-access" data-gd-task><h2 class="gd-h2">Admin access</h2><p class="gd-p"><b class="gd-ui">Settings</b> &gt; <b class="gd-ui">All settings</b>, then Admin access. Who may hold the Admin role.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">The list holds rent@carmacars.ca, and verify-admin@carmacars.ca, the automated test account the site&#39;s nightly checks sign in with.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Below it: everyone who holds the Admin role now. Each must be on the list; the database refuses the Admin role to any other address.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Change the list only if the business&#39;s Admin address changes.</div></li></ol></div></section><section class="gd-task" id="people-and-access-staff-scorecards" data-gd-task><h2 class="gd-h2">Staff scorecards</h2><p class="gd-p">See how each assistant is doing against the targets.</p><div class="gd-stepblock gd-stepblock--below"><div class="gd-stepcol"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">On a staff member&#39;s row in Staff and roles, press <b class="gd-ui">Scorecard</b>.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">By week shows each measure (for example quote sent within 5 minutes) and the result for each week.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">A task meets its target when it is done by its due time. Daily checks count when done by 9:00 and 18:00.</div></li></ol></div><figure class="gd-fig gd-fig--desk"><div class="gd-browser"><div class="gd-bar" aria-hidden="true"><i></i><i></i><i></i><span class="gd-addr">carmacars.ca/va/scorecard</span></div><div class="gd-imgwrap" style="aspect-ratio:1230/350"><img src="/guides/img/va-sales-05-scorecard-desktop-956a5a9e.jpg" alt="" loading="lazy" decoding="async" width="1230" height="350"><span class="gd-pin" style="left:21.1%;top:42.9%" aria-hidden="true">2</span></div></div></figure></div></section><section class="gd-task" id="people-and-access-sales-by-staff-member" data-gd-task><h2 class="gd-h2">Sales by staff member</h2><p class="gd-p">See each person&#39;s commissions, quotes, offers, rentals added, bookings confirmed and booked revenue.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">On a staff member&#39;s row in Staff and roles, press <b class="gd-ui">Sales</b>. Press <b class="gd-ui">By week</b> or <b class="gd-ui">By month</b>.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">The tiles show the current week or month. By week (or By month) lists each period: quotes created, offers sent, rentals added, bookings confirmed, conversion and booked revenue.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Follow-ups due lists their open deals with the next step. Deals lists each booking they created, added or sent an offer on, with what it counts.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">A deal credited to the wrong person, or marked sourced when it was not? Press <b class="gd-ui">Reassign</b> beside it, choose who, say whether they sourced the client, and write the reason.</div></li><li><span class="gd-n" aria-hidden="true">5</span><div class="gd-t"><b class="gd-ui">Commission rate</b> gives this person their own flat rate (empty: the Program settings). <b class="gd-ui">Reverse</b> beside a commission stops it, for example for a household rental found later.</div></li><li><span class="gd-n" aria-hidden="true">6</span><div class="gd-t">Staff enter their own home address (at their first sign-in, before they sign their agreement, or in their profile). It is needed before they add a rental or earn a commission, and spots a household rental. <b class="gd-ui">Home address</b> here changes it if it is wrong.</div></li><li><span class="gd-n" aria-hidden="true">7</span><div class="gd-t">The whole team: <b class="gd-ui">Today</b> &gt; <b class="gd-ui">Overview</b>, the Sales card at the bottom. Choose another month and press <b class="gd-ui">Show</b>.</div></li></ol></div><div class="gd-tablewrap"><table class="gd-table"><thead><tr><th scope="col">Figure</th><th scope="col">How it is counted</th></tr></thead><tbody><tr><td>Credited to</td><td>Whoever created the quote or added the rental; for a website request, whoever sent its first offer. An Admin can reassign it.</td></tr><tr><td>Conversion</td><td>Of the deals credited in the period, the share confirmed so far.</td></tr><tr><td>Booked revenue</td><td>The rental charge before tax, after discounts, for bookings confirmed in the period. A cancelled booking counts only what was kept; refunds come off.</td></tr></tbody></table></div></section>');
select app.guide_release_0059('admin', 'owner-money', 'chapter', 'owners-and-onboarding', 'Owner fee invoices are issued on the notice day and debited on the 15th. Statements are built, approved and issued each month, and payouts follow.

## Owner invoices

**Money** > **Owner invoices**

1. **Run the monthly invoices** issues the invoices for the 15th by hand, for a missed month. An invoice is never issued twice.
2. **Issue all tracker invoices** bills the Tracker Install for each car waiting for its tracker.
3. Filter by Open, Paid, Failed or In arrears. Failed invoices show the reason.
4. Paid by e-Transfer, cheque, cash or bank transfer? Press **Record payment** under the invoice. Leave Amount empty for the full balance.

![](/guides/img/admin-14-owner-invoices-desktop-dc4ed1f1.jpg "desktop; size: 1440 1060; address: carmacars.ca/admin/invoices; pins: 1 83.3 22.4, 2 41.7 35.7, 3 29.0 43.4, 4 51.6 84.3")

## The automatic debit

The debit runs by itself. Your job is to watch for returned debits and owners without a mandate.

:::flow
Notice day | Invoices issued, one notice per owner, 10 days before
Debit day | The 15th from 6:00: one debit per invoice
Cleared | The invoice is paid
Returned, insufficient funds | The $50.00 Late Fee is added once; the same amount is tried again within 30 days
Returned for another reason | No retry and no Late Fee: the debit pauses and you get a task
:::

1. The tiles show the next debit day and notice day, scheduled, processing, cleared and returned debits.
2. How it runs explains the policy in words, read from Program settings.
3. Scheduled and processing lists each debit. **Pause** holds one (a reason is needed).
4. Owners lists each mandate. Use **Pause**, **Resume** or **Send a notice now**.

![](/guides/img/admin-15-owner-debits-desktop-f65f061a.jpg "desktop; size: 1440 920; address: carmacars.ca/admin/debits; pins: 1 21.8 21.7, 2 21.5 35.5, 3 91.5 75.4, 4 84.7 94.7")

5. Results: each debit, cleared or returned, with the bank''s reason.
6. Run log: each notice and debit run, with its counts.
7. Notices sent: who was told what, for which debit day.

![](/guides/img/admin-15-owner-debits-desktop-8d4682bc.jpg "desktop; size: 1230 520; address: carmacars.ca/admin/debits; pins: 5 11.0 14.4, 6 10.2 52.3, 7 15.4 89.8")

Insufficient funds: the $50.00 Late Fee is added to that invoice once and collected with the owner''s next debit, and the original amount is tried again within 30 days, as section 4.4 of the Enrollment Agreement sets out. The retry is never more than the original amount. Returned again: the invoice is in arrears and you get a task.

> Watch out: Returned for any other reason (account closed, payment stopped, no authorization): there is no retry and no Late Fee. The owner''s debit pauses, the owner gets an email asking them to fix the account or pay another way, and you get a task. A debit is never more than its notice said. An owner with no mandate gets an email on the notice day and you get a task; nothing is debited for them.

## Owner statements

**Money** > **Owner statements**

1. Press **Build all for a month** (or **Build one**).
2. Open each draft. Check it, **Rebuild** after a correction, **Preview PDF**, then **Approve**.
3. Press **Issue to the owner**. **Reissue** sends a corrected copy; **CSV** exports it.

![](/guides/img/admin-16-statements-desktop-43a313ea.jpg "desktop; size: 1440 400; address: carmacars.ca/admin/statements; pins: 1 79.9 27.3")

![An approved statement: the owner gets it by email with the PDF on the 10th, and payouts follow under Payouts.](/guides/img/admin-17-statement-desktop-106ee57f.jpg "desktop; size: 1440 520; address: carmacars.ca/admin/statements/f27936a8-9bfb-4280-81ae-c67ec47febe1; pins: 3 86.0 22.7")

## Staff commissions

**Money** > **Staff commissions**. Nothing is paid automatically.

:::flow
Not earned yet | The rental is ahead, or not paid in full
Pending approval | Completed and paid in full; a Sales month once it has ended
Approved | You approved it; the staff member is told
Paid | You recorded the payment; the staff member is told
Reversed | Cancelled, refunded or charged back; after payment it comes off the next payment
:::

1. By person shows each staff member''s month (Sales: rental days of 100 and the tier), what is not earned yet, pending approval, approved and paid.
2. Press **Approve** on a person (everything that may be approved now) or on one commission.
3. Press **Record a payment**: choose how it was paid (e-Transfer, bank transfer, Wise, cash, the monthly pay statement or another way), the reference and the date.
4. **Prices to review** lists prices typed by hand; **Sourcing claims** lists staff who say they sourced a website request; **Payments made** lists each payment.

|  | Commission |
| --- | --- |
| Sales | By rental days of the month: under 50 days 10%, from 50 days 15%, from 100 days 20%, on all that month''s rentals |
| Customer service, finance, fleet, field staff | 10% (also the field referral fee) |
| Base | The rental charge before tax, after discounts, less refunds |
| On the owner statement | An owner''s car: deducted with the kickbacks before Owner Revenue, its own line on the statement. A partner''s car: from CarmaCars'' commission. A CarmaCars-owned car: a CarmaCars expense |

> Tip: A commission that changes after an owner statement was built (a refund, or the month''s Sales tier) goes on the owner''s next statement as an adjustment line.

## Company statements

CarmaCars'' own monthly statement, in twelve sections.

1. Choose the month. The tiles show revenue, fees, refunds, expenses and the company net.
2. Switch between Total, Per owner and Per vehicle.
3. Download **PDF**, **PDF by owner** or **PDF by vehicle**, or press **Email me the PDFs**.
4. **Finalize** freezes the month. **Rebuild** works until then.

![](/guides/img/admin-18-company-statements-desktop-8e2738ed.jpg "desktop; size: 1440 760; address: carmacars.ca/admin/reports; pins: 1 20.8 28.0, 2 19.4 59.3, 3 77.1 15.5, 4 46.9 15.5")
', 'Owner money', 'Owner invoices, the automatic debit, statements, payouts and the company statement.',
  'Owner fee invoices are issued on the notice day and debited on the 15th. Statements are built, approved and issued each month, and payouts follow.

## Owner invoices

**Money** > **Owner invoices**

1. **Run the monthly invoices** issues the invoices for the 15th by hand, for a missed month. An invoice is never issued twice.
2. **Issue all tracker invoices** bills the Tracker Install for each car waiting for its tracker.
3. Filter by Open, Paid, Failed or In arrears. Failed invoices show the reason.
4. Paid by e-Transfer, cheque, cash or bank transfer? Press **Record payment** under the invoice. Leave Amount empty for the full balance.

![](/guides/img/admin-14-owner-invoices-desktop-dc4ed1f1.jpg "desktop; size: 1440 1060; address: carmacars.ca/admin/invoices; pins: 1 83.3 22.4, 2 41.7 35.7, 3 29.0 43.4, 4 51.6 84.3")

## The automatic debit

The debit runs by itself. Your job is to watch for returned debits and owners without a mandate.

:::flow
Notice day | Invoices issued, one notice per owner, 10 days before
Debit day | The 15th from 6:00: one debit per invoice
Cleared | The invoice is paid
Returned, insufficient funds | The $50.00 Late Fee is added once; the same amount is tried again within 30 days
Returned for another reason | No retry and no Late Fee: the debit pauses and you get a task
:::

1. The tiles show the next debit day and notice day, scheduled, processing, cleared and returned debits.
2. How it runs explains the policy in words, read from Program settings.
3. Scheduled and processing lists each debit. **Pause** holds one (a reason is needed).
4. Owners lists each mandate. Use **Pause**, **Resume** or **Send a notice now**.

![](/guides/img/admin-15-owner-debits-desktop-f65f061a.jpg "desktop; size: 1440 920; address: carmacars.ca/admin/debits; pins: 1 21.8 21.7, 2 21.5 35.5, 3 91.5 75.4, 4 84.7 94.7")

5. Results: each debit, cleared or returned, with the bank''s reason.
6. Run log: each notice and debit run, with its counts.
7. Notices sent: who was told what, for which debit day.

![](/guides/img/admin-15-owner-debits-desktop-8d4682bc.jpg "desktop; size: 1230 520; address: carmacars.ca/admin/debits; pins: 5 11.0 14.4, 6 10.2 52.3, 7 15.4 89.8")

Insufficient funds: the $50.00 Late Fee is added to that invoice once and collected with the owner''s next debit, and the original amount is tried again within 30 days, as section 4.4 of the Enrollment Agreement sets out. The retry is never more than the original amount. Returned again: the invoice is in arrears and you get a task.

> Watch out: Returned for any other reason (account closed, payment stopped, no authorization): there is no retry and no Late Fee. The owner''s debit pauses, the owner gets an email asking them to fix the account or pay another way, and you get a task. A debit is never more than its notice said. An owner with no mandate gets an email on the notice day and you get a task; nothing is debited for them.

## Owner statements

**Money** > **Owner statements**

1. Press **Build all for a month** (or **Build one**).
2. Open each draft. Check it, **Rebuild** after a correction, **Preview PDF**, then **Approve**.
3. Press **Issue to the owner**. **Reissue** sends a corrected copy; **CSV** exports it.

![](/guides/img/admin-16-statements-desktop-43a313ea.jpg "desktop; size: 1440 400; address: carmacars.ca/admin/statements; pins: 1 79.9 27.3")

![An approved statement: the owner gets it by email with the PDF on the 10th, and payouts follow under Payouts.](/guides/img/admin-17-statement-desktop-106ee57f.jpg "desktop; size: 1440 520; address: carmacars.ca/admin/statements/f27936a8-9bfb-4280-81ae-c67ec47febe1; pins: 3 86.0 22.7")

## Staff commissions

**Money** > **Staff commissions**. Nothing is paid automatically.

:::flow
Not earned yet | The rental is ahead, or not paid in full
Pending approval | Completed and paid in full; a Sales month once it has ended
Approved | You approved it; the staff member is told
Paid | You recorded the payment; the staff member is told
Reversed | Cancelled, refunded or charged back; after payment it comes off the next payment
:::

1. By person shows each staff member''s month (Sales: rental days of 100 and the tier), what is not earned yet, pending approval, approved and paid.
2. Press **Approve** on a person (everything that may be approved now) or on one commission.
3. Press **Record a payment**: choose how it was paid (e-Transfer, bank transfer, Wise, cash, the monthly pay statement or another way), the reference and the date.
4. **Prices to review** lists prices typed by hand; **Sourcing claims** lists staff who say they sourced a website request; **Payments made** lists each payment.

|  | Commission |
| --- | --- |
| Sales | By rental days of the month: under 50 days 10%, from 50 days 15%, from 100 days 20%, on all that month''s rentals |
| Customer service, finance, fleet, field staff | 10% (also the field referral fee) |
| Base | The rental charge before tax, after discounts, less refunds |
| On the owner statement | An owner''s car: deducted with the kickbacks before Owner Revenue, its own line on the statement. A partner''s car: from CarmaCars'' commission. A CarmaCars-owned car: a CarmaCars expense |

> Tip: A commission that changes after an owner statement was built (a refund, or the month''s Sales tier) goes on the owner''s next statement as an adjustment line.

## Company statements

CarmaCars'' own monthly statement, in twelve sections.

1. Choose the month. The tiles show revenue, fees, refunds, expenses and the company net.
2. Switch between Total, Per owner and Per vehicle.
3. Download **PDF**, **PDF by owner** or **PDF by vehicle**, or press **Email me the PDFs**.
4. **Finalize** freezes the month. **Rebuild** works until then.

![](/guides/img/admin-18-company-statements-desktop-8e2738ed.jpg "desktop; size: 1440 760; address: carmacars.ca/admin/reports; pins: 1 20.8 28.0, 2 19.4 59.3, 3 77.1 15.5, 4 46.9 15.5")
',
  '<p class="gd-p">Owner fee invoices are issued on the notice day and debited on the 15th. Statements are built, approved and issued each month, and payouts follow.</p><section class="gd-task" id="owner-money-owner-invoices" data-gd-task><h2 class="gd-h2">Owner invoices</h2><p class="gd-p"><b class="gd-ui">Money</b> &gt; <b class="gd-ui">Owner invoices</b></p><div class="gd-stepblock gd-stepblock--below"><div class="gd-stepcol"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t"><b class="gd-ui">Run the monthly invoices</b> issues the invoices for the 15th by hand, for a missed month. An invoice is never issued twice.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t"><b class="gd-ui">Issue all tracker invoices</b> bills the Tracker Install for each car waiting for its tracker.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Filter by Open, Paid, Failed or In arrears. Failed invoices show the reason.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">Paid by e-Transfer, cheque, cash or bank transfer? Press <b class="gd-ui">Record payment</b> under the invoice. Leave Amount empty for the full balance.</div></li></ol></div><figure class="gd-fig gd-fig--desk"><div class="gd-browser"><div class="gd-bar" aria-hidden="true"><i></i><i></i><i></i><span class="gd-addr">carmacars.ca/admin/invoices</span></div><div class="gd-imgwrap" style="aspect-ratio:1440/1060"><img src="/guides/img/admin-14-owner-invoices-desktop-dc4ed1f1.jpg" alt="" loading="lazy" decoding="async" width="1440" height="1060"><span class="gd-pin" style="left:83.3%;top:22.4%" aria-hidden="true">1</span><span class="gd-pin" style="left:41.7%;top:35.7%" aria-hidden="true">2</span><span class="gd-pin" style="left:29%;top:43.4%" aria-hidden="true">3</span><span class="gd-pin" style="left:51.6%;top:84.3%" aria-hidden="true">4</span></div></div></figure></div></section><section class="gd-task" id="owner-money-the-automatic-debit" data-gd-task><h2 class="gd-h2">The automatic debit</h2><p class="gd-p">The debit runs by itself. Your job is to watch for returned debits and owners without a mandate.</p><ol class="gd-flow"><li><b>1</b><span>Notice day</span><em>Invoices issued, one notice per owner, 10 days before</em></li><li><b>2</b><span>Debit day</span><em>The 15th from 6:00: one debit per invoice</em></li><li><b>3</b><span>Cleared</span><em>The invoice is paid</em></li><li><b>4</b><span>Returned, insufficient funds</span><em>The $50.00 Late Fee is added once; the same amount is tried again within 30 days</em></li><li><b>5</b><span>Returned for another reason</span><em>No retry and no Late Fee: the debit pauses and you get a task</em></li></ol><div class="gd-stepblock gd-stepblock--below"><div class="gd-stepcol"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">The tiles show the next debit day and notice day, scheduled, processing, cleared and returned debits.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">How it runs explains the policy in words, read from Program settings.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Scheduled and processing lists each debit. <b class="gd-ui">Pause</b> holds one (a reason is needed).</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">Owners lists each mandate. Use <b class="gd-ui">Pause</b>, <b class="gd-ui">Resume</b> or <b class="gd-ui">Send a notice now</b>.</div></li></ol></div><figure class="gd-fig gd-fig--desk"><div class="gd-browser"><div class="gd-bar" aria-hidden="true"><i></i><i></i><i></i><span class="gd-addr">carmacars.ca/admin/debits</span></div><div class="gd-imgwrap" style="aspect-ratio:1440/920"><img src="/guides/img/admin-15-owner-debits-desktop-f65f061a.jpg" alt="" loading="lazy" decoding="async" width="1440" height="920"><span class="gd-pin" style="left:21.8%;top:21.7%" aria-hidden="true">1</span><span class="gd-pin" style="left:21.5%;top:35.5%" aria-hidden="true">2</span><span class="gd-pin" style="left:91.5%;top:75.4%" aria-hidden="true">3</span><span class="gd-pin" style="left:84.7%;top:94.7%" aria-hidden="true">4</span></div></div></figure></div><div class="gd-stepblock gd-stepblock--below"><div class="gd-stepcol"><ol class="gd-ol" start="5"><li><span class="gd-n" aria-hidden="true">5</span><div class="gd-t">Results: each debit, cleared or returned, with the bank&#39;s reason.</div></li><li><span class="gd-n" aria-hidden="true">6</span><div class="gd-t">Run log: each notice and debit run, with its counts.</div></li><li><span class="gd-n" aria-hidden="true">7</span><div class="gd-t">Notices sent: who was told what, for which debit day.</div></li></ol></div><figure class="gd-fig gd-fig--desk"><div class="gd-browser"><div class="gd-bar" aria-hidden="true"><i></i><i></i><i></i><span class="gd-addr">carmacars.ca/admin/debits</span></div><div class="gd-imgwrap" style="aspect-ratio:1230/520"><img src="/guides/img/admin-15-owner-debits-desktop-8d4682bc.jpg" alt="" loading="lazy" decoding="async" width="1230" height="520"><span class="gd-pin" style="left:11%;top:14.4%" aria-hidden="true">5</span><span class="gd-pin" style="left:10.2%;top:52.3%" aria-hidden="true">6</span><span class="gd-pin" style="left:15.4%;top:89.8%" aria-hidden="true">7</span></div></div></figure></div><p class="gd-p">Insufficient funds: the $50.00 Late Fee is added to that invoice once and collected with the owner&#39;s next debit, and the original amount is tried again within 30 days, as section 4.4 of the Enrollment Agreement sets out. The retry is never more than the original amount. Returned again: the invoice is in arrears and you get a task.</p><aside class="gd-box gd-box--warn"><span class="gd-lbl">Watch out</span><div>Returned for any other reason (account closed, payment stopped, no authorization): there is no retry and no Late Fee. The owner&#39;s debit pauses, the owner gets an email asking them to fix the account or pay another way, and you get a task. A debit is never more than its notice said. An owner with no mandate gets an email on the notice day and you get a task; nothing is debited for them.</div></aside></section><section class="gd-task" id="owner-money-owner-statements" data-gd-task><h2 class="gd-h2">Owner statements</h2><p class="gd-p"><b class="gd-ui">Money</b> &gt; <b class="gd-ui">Owner statements</b></p><div class="gd-stepblock gd-stepblock--below"><div class="gd-stepcol"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Press <b class="gd-ui">Build all for a month</b> (or <b class="gd-ui">Build one</b>).</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Open each draft. Check it, <b class="gd-ui">Rebuild</b> after a correction, <b class="gd-ui">Preview PDF</b>, then <b class="gd-ui">Approve</b>.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Press <b class="gd-ui">Issue to the owner</b>. <b class="gd-ui">Reissue</b> sends a corrected copy; <b class="gd-ui">CSV</b> exports it.</div></li></ol></div><figure class="gd-fig gd-fig--desk"><div class="gd-browser"><div class="gd-bar" aria-hidden="true"><i></i><i></i><i></i><span class="gd-addr">carmacars.ca/admin/statements</span></div><div class="gd-imgwrap" style="aspect-ratio:1440/400"><img src="/guides/img/admin-16-statements-desktop-43a313ea.jpg" alt="" loading="lazy" decoding="async" width="1440" height="400"><span class="gd-pin" style="left:79.9%;top:27.3%" aria-hidden="true">1</span></div></div></figure></div><div class="gd-figblock"><figure class="gd-fig gd-fig--desk"><div class="gd-browser"><div class="gd-bar" aria-hidden="true"><i></i><i></i><i></i><span class="gd-addr">carmacars.ca/admin/statements/f27936a8-9bfb-4280-81ae-c67ec47febe1</span></div><div class="gd-imgwrap" style="aspect-ratio:1440/520"><img src="/guides/img/admin-17-statement-desktop-106ee57f.jpg" alt="An approved statement: the owner gets it by email with the PDF on the 10th, and payouts follow under Payouts." loading="lazy" decoding="async" width="1440" height="520"><span class="gd-pin" style="left:86%;top:22.7%" aria-hidden="true">3</span></div></div><figcaption>An approved statement: the owner gets it by email with the PDF on the 10th, and payouts follow under Payouts.</figcaption></figure></div></section><section class="gd-task" id="owner-money-staff-commissions" data-gd-task><h2 class="gd-h2">Staff commissions</h2><p class="gd-p"><b class="gd-ui">Money</b> &gt; <b class="gd-ui">Staff commissions</b>. Nothing is paid automatically.</p><ol class="gd-flow"><li><b>1</b><span>Not earned yet</span><em>The rental is ahead, or not paid in full</em></li><li><b>2</b><span>Pending approval</span><em>Completed and paid in full; a Sales month once it has ended</em></li><li><b>3</b><span>Approved</span><em>You approved it; the staff member is told</em></li><li><b>4</b><span>Paid</span><em>You recorded the payment; the staff member is told</em></li><li><b>5</b><span>Reversed</span><em>Cancelled, refunded or charged back; after payment it comes off the next payment</em></li></ol><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">By person shows each staff member&#39;s month (Sales: rental days of 100 and the tier), what is not earned yet, pending approval, approved and paid.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Press <b class="gd-ui">Approve</b> on a person (everything that may be approved now) or on one commission.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Press <b class="gd-ui">Record a payment</b>: choose how it was paid (e-Transfer, bank transfer, Wise, cash, the monthly pay statement or another way), the reference and the date.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t"><b class="gd-ui">Prices to review</b> lists prices typed by hand; <b class="gd-ui">Sourcing claims</b> lists staff who say they sourced a website request; <b class="gd-ui">Payments made</b> lists each payment.</div></li></ol></div><div class="gd-tablewrap"><table class="gd-table"><thead><tr><th scope="col"></th><th scope="col">Commission</th></tr></thead><tbody><tr><td>Sales</td><td>By rental days of the month: under 50 days 10%, from 50 days 15%, from 100 days 20%, on all that month&#39;s rentals</td></tr><tr><td>Customer service, finance, fleet, field staff</td><td>10% (also the field referral fee)</td></tr><tr><td>Base</td><td>The rental charge before tax, after discounts, less refunds</td></tr><tr><td>On the owner statement</td><td>An owner&#39;s car: deducted with the kickbacks before Owner Revenue, its own line on the statement. A partner&#39;s car: from CarmaCars&#39; commission. A CarmaCars-owned car: a CarmaCars expense</td></tr></tbody></table></div><aside class="gd-box"><span class="gd-lbl">Tip</span><div>A commission that changes after an owner statement was built (a refund, or the month&#39;s Sales tier) goes on the owner&#39;s next statement as an adjustment line.</div></aside></section><section class="gd-task" id="owner-money-company-statements" data-gd-task><h2 class="gd-h2">Company statements</h2><p class="gd-p">CarmaCars&#39; own monthly statement, in twelve sections.</p><div class="gd-stepblock gd-stepblock--below"><div class="gd-stepcol"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Choose the month. The tiles show revenue, fees, refunds, expenses and the company net.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Switch between Total, Per owner and Per vehicle.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Download <b class="gd-ui">PDF</b>, <b class="gd-ui">PDF by owner</b> or <b class="gd-ui">PDF by vehicle</b>, or press <b class="gd-ui">Email me the PDFs</b>.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t"><b class="gd-ui">Finalize</b> freezes the month. <b class="gd-ui">Rebuild</b> works until then.</div></li></ol></div><figure class="gd-fig gd-fig--desk"><div class="gd-browser"><div class="gd-bar" aria-hidden="true"><i></i><i></i><i></i><span class="gd-addr">carmacars.ca/admin/reports</span></div><div class="gd-imgwrap" style="aspect-ratio:1440/760"><img src="/guides/img/admin-18-company-statements-desktop-8e2738ed.jpg" alt="" loading="lazy" decoding="async" width="1440" height="760"><span class="gd-pin" style="left:20.8%;top:28%" aria-hidden="true">1</span><span class="gd-pin" style="left:19.4%;top:59.3%" aria-hidden="true">2</span><span class="gd-pin" style="left:77.1%;top:15.5%" aria-hidden="true">3</span><span class="gd-pin" style="left:46.9%;top:15.5%" aria-hidden="true">4</span></div></div></figure></div></section>');
select app.guide_release_0059('admin', 'settings', 'chapter', 'tolls-and-tickets', 'Settings change the public site and the rules of the program at once. Program settings are kept as dated rows, so earlier values stay on record.

## The Settings page

1. Site setup lists what is still missing on the public site, with **Open site settings**.
2. Site settings: contact details, hours, tagline, logo, socials, Google place id and featured cars.
3. Program settings: every timing and policy value.
4. Forms: the official ServiceOntario PDFs and what goes in each field.
5. Insurers: insurance companies billed for bookings.

![](/guides/img/admin-24-settings-desktop-89b31691.jpg "desktop; size: 1440 900; address: carmacars.ca/admin/settings; pins: 1 32.6 33.0, 2 25.8 40.2, 3 77.4 40.2, 4 25.8 73.2, 5 25.8 84.9")

The other tiles: Site content (headings, FAQs, legal text), Fee defaults, Deposit tiers, Kilometre choices, Vehicle classes, Airports and delivery, Coverage prices, Email aliases and reply-to, Staff and roles, Promo codes and Quick replies.

## Program settings

1. Turnaround between trips: the time held between two trips. The cleaning block after a trip is this time.
2. Settings come in groups such as Company, Booking requests and offers, Owner debits and statement emails, Deposits, Delivery, Owners and fleet, and Tolls and damage. Open one to see its fields.
3. First reply target for customer service and sales (minutes), under Booking requests and offers: 5 by default. New booking requests, enquiries, changes renters ask for and renter messages are due that many minutes after they come in; the scorecard and the staff screens use it. What renters are told (Reply wording, in Site settings) is separate.
4. Staff commissions and prices typed by hand: the commission outside Sales (10%), the three Sales tiers and their days (10%, 15% from 50 days, 20% from 100 days, the month''s target), the price floor a day (empty: none) and the discount from the rate sheet that flags a price (20%).
5. Staff agreement defaults by function, at the bottom: pay (a month or an hour), the rate, full or part time, days a week and hours a day for Customer service, Fleet, Finance and Sales, the values every assistant shares, and the field staff wage. Press **Save the defaults**.
6. Change a value and press **Save**. It is saved as a new row from today; the rows before stay as they were.

![](/guides/img/admin-25-program-settings-desktop-d16b066c.jpg "desktop; size: 1440 1000; address: carmacars.ca/admin/settings/program; pins: 1 25.8 22.0, 2 27.8 49.0")

## Official ServiceOntario forms

The five official forms are loaded with a draft mapping to the owner, car, company and lender details. Until you check a form, owners get a data sheet with the values.

1. Open **Settings** > **Forms**. Each form shows "Mapping to check" (a draft is ready) or "Official PDF in use". Its notes say what the form is for and which boxes are left blank on purpose.
2. Press **Download a filled preview** for one car and check each value against the form.
3. Change a field if needed: What goes in it (or "The owner signs here"), a Format (for example YYYY/MM/DD) and Only when. Press Save the mapping.
4. Press **Checked: use for owners**. Every owner''s form of that kind is filled again, except ones already signed or filed, and owners sign it with their other documents.
5. A new version from ServiceOntario? Press **Upload the official fillable PDF**: the fields of the same name keep their mapping.

> Good to know: SR-LV-006 (registration), SR-LV-012 (two registrants), ON00453 (a company''s RIN), 013-1155 and 013-0169 (the tax-exempt transfer into an owner''s corporation). 013-1155 is sworn before a commissioner, so it is printed and signed in person.

## Agreements to sign: investors and staff

Investment agreements and staff agreements are made from the person''s record and signed in their own portal, or on paper.

1. Investor: open **People** > **Investors** and the investor. Under Investment agreement, press **Send the agreement to sign**. Check the values it is filled with (amount, yearly percentage, dates, exemption) and press **Send to sign**.
2. Once the investor signs, the agreement shows **Awaiting countersignature** on the investor''s page and on To do. It is not countersigned automatically: check it and press **Countersign**. CarmaCars is bound once it has countersigned and the funds clear.
3. Staff: open **People** > **Staff**. Under Staff agreements, press **Send the agreement to sign** beside the person. Pay, schedule, hours and the other values start from the staff profile and the defaults of their function in Program settings; change any before sending.
4. They get a notice, check the key values and sign in their portal in a few taps (their name is the signature, or they draw it). The signed copy is filed with their documents.
5. Your own PDF instead? **Send a PDF to sign** still works.
6. Signed on paper instead? Press **Record paper signature** in the same place and upload the scan.
7. Sent by mistake? Press **Withdraw** and give the reason.

## The user guides

**Settings** > **Guides**. The guide of each portal, as people read it under Guide.

1. Each guide shows its version, when it was published and whether there are unpublished changes.
2. Open a guide and press a section. Change its text and press **Show the preview** to see it as people will. Press **Save the draft**; each save is kept in the section''s history.
3. Move a section with the arrows, hide it, or press **Add a chapter**. Upload a screenshot under Screenshots and paste the line it gives you.
4. Press **Publish version** (the next number). The portals show the new version at once.
5. The stored PDF is printed again by the guides-pdf workflow. Until then the guide says the web guide has newer edits.

## The guides keep up by themselves

After every update of the site that changes the portals, the guides are checked without anyone asking.

1. Every screenshot is taken again on the new version of the site. One whose screen changed replaces the old one in the guide.
2. The text of each section whose screen changed, or that names a button the portals no longer show, is rewritten from the portal''s own labels and menu, checked, and published. The PDFs of those guides are printed again.
3. Such a section says **Changed automatically on** and the date, in the list of guides and in the guide''s editor. Not right? Open the section and press **Revert**: the text it replaced comes back, published at once.
4. A rewrite that did not pass the checks is not published. Its section shows **Needs review** with the suggested text: press **Use this text as the draft** or **Dismiss the suggestion**, then **Mark reviewed**.

> Tip: The card "The guides keep up by themselves" at the top of Guides lists the last runs: when, how many screenshots were replaced, how many sections were rewritten or wait for review, and how many PDFs were printed.

## Insurers and the other lists

1. Open Insurers. Each insurer on file opens to edit its billing contact, email, phone, address and notes.
2. To add one, fill in the Add form (Name, Billing contact, Billing email and the rest) and press **Add**.
3. Deposit tiers, Kilometre choices, Vehicle classes, Airports, Promo codes and Quick replies work the same way.
', 'Settings', 'Site, program settings, official forms mapping, insurers and the other lists.',
  'Settings change the public site and the rules of the program at once. Program settings are kept as dated rows, so earlier values stay on record.

## The Settings page

1. Site setup lists what is still missing on the public site, with **Open site settings**.
2. Site settings: contact details, hours, tagline, logo, socials, Google place id and featured cars.
3. Program settings: every timing and policy value.
4. Forms: the official ServiceOntario PDFs and what goes in each field.
5. Insurers: insurance companies billed for bookings.

![](/guides/img/admin-24-settings-desktop-89b31691.jpg "desktop; size: 1440 900; address: carmacars.ca/admin/settings; pins: 1 32.6 33.0, 2 25.8 40.2, 3 77.4 40.2, 4 25.8 73.2, 5 25.8 84.9")

The other tiles: Site content (headings, FAQs, legal text), Fee defaults, Deposit tiers, Kilometre choices, Vehicle classes, Airports and delivery, Coverage prices, Email aliases and reply-to, Staff and roles, Promo codes and Quick replies.

## Program settings

1. Turnaround between trips: the time held between two trips. The cleaning block after a trip is this time.
2. Settings come in groups such as Company, Booking requests and offers, Owner debits and statement emails, Deposits, Delivery, Owners and fleet, and Tolls and damage. Open one to see its fields.
3. First reply target for customer service and sales (minutes), under Booking requests and offers: 5 by default. New booking requests, enquiries, changes renters ask for and renter messages are due that many minutes after they come in; the scorecard and the staff screens use it. What renters are told (Reply wording, in Site settings) is separate.
4. Staff commissions and prices typed by hand: the commission outside Sales (10%), the three Sales tiers and their days (10%, 15% from 50 days, 20% from 100 days, the month''s target), the price floor a day (empty: none) and the discount from the rate sheet that flags a price (20%). The owner confirmed these values in October 2026.
5. Staff agreement defaults by function, at the bottom: pay (a month, an hour or commission only), the rate, the schedule (full time, part time or flexible), days a week and hours a day for Customer service, Fleet, Finance and Sales, the values every assistant shares, and the field staff wage. Sales is commission only: no rate and a flexible schedule. Press **Save the defaults**.
6. Change a value and press **Save**. It is saved as a new row from today; the rows before stay as they were.

![](/guides/img/admin-25-program-settings-desktop-d16b066c.jpg "desktop; size: 1440 1000; address: carmacars.ca/admin/settings/program; pins: 1 25.8 22.0, 2 27.8 49.0")

## Official ServiceOntario forms

The five official forms are loaded with a draft mapping to the owner, car, company and lender details. Until you check a form, owners get a data sheet with the values.

1. Open **Settings** > **Forms**. Each form shows "Mapping to check" (a draft is ready) or "Official PDF in use". Its notes say what the form is for and which boxes are left blank on purpose.
2. Press **Download a filled preview** for one car and check each value against the form.
3. Change a field if needed: What goes in it (or "The owner signs here"), a Format (for example YYYY/MM/DD) and Only when. Press Save the mapping.
4. Press **Checked: use for owners**. Every owner''s form of that kind is filled again, except ones already signed or filed, and owners sign it with their other documents.
5. A new version from ServiceOntario? Press **Upload the official fillable PDF**: the fields of the same name keep their mapping.

> Good to know: SR-LV-006 (registration), SR-LV-012 (two registrants), ON00453 (a company''s RIN), 013-1155 and 013-0169 (the tax-exempt transfer into an owner''s corporation). 013-1155 is sworn before a commissioner, so it is printed and signed in person.

## Agreements to sign: investors and staff

Investment agreements and staff agreements are made from the person''s record and signed in their own portal, or on paper.

1. Investor: open **People** > **Investors** and the investor. Under Investment agreement, press **Send the agreement to sign**. Check the values it is filled with (amount, yearly percentage, dates, exemption) and press **Send to sign**.
2. Once the investor signs, the agreement shows **Awaiting countersignature** on the investor''s page and on To do. It is not countersigned automatically: check it and press **Countersign**. CarmaCars is bound once it has countersigned and the funds clear.
3. Staff: open **People** > **Staff**. Under Staff agreements, press **Send the agreement to sign** beside the person. Pay, schedule, hours and the other values start from the staff profile and the defaults of their function in Program settings; change any before sending. For Sales the Pay is Commission only: the agreement then has no rate, schedule or hours, and pays the commission of section 3.4.
4. A field staff member''s agreement prints the home address they entered themselves. Staff enter their home address at their first sign-in, before they sign, or in their profile.
5. They get a notice, check the key values and sign in their portal in a few taps (their name is the signature, or they draw it). The signed copy is filed with their documents.
6. Your own PDF instead? **Send a PDF to sign** still works.
7. Signed on paper instead? Press **Record paper signature** in the same place and upload the scan.
8. Sent by mistake? Press **Withdraw** and give the reason.

## The user guides

**Settings** > **Guides**. The guide of each portal, as people read it under Guide.

1. Each guide shows its version, when it was published and whether there are unpublished changes.
2. Open a guide and press a section. Change its text and press **Show the preview** to see it as people will. Press **Save the draft**; each save is kept in the section''s history.
3. Move a section with the arrows, hide it, or press **Add a chapter**. Upload a screenshot under Screenshots and paste the line it gives you.
4. Press **Publish version** (the next number). The portals show the new version at once.
5. The stored PDF is printed again by the guides-pdf workflow. Until then the guide says the web guide has newer edits.

## The guides keep up by themselves

After every update of the site that changes the portals, the guides are checked without anyone asking.

1. Every screenshot is taken again on the new version of the site. One whose screen changed replaces the old one in the guide.
2. The text of each section whose screen changed, or that names a button the portals no longer show, is rewritten from the portal''s own labels and menu, checked, and published. The PDFs of those guides are printed again.
3. Such a section says **Changed automatically on** and the date, in the list of guides and in the guide''s editor. Not right? Open the section and press **Revert**: the text it replaced comes back, published at once.
4. This includes sections you edited: the newest automatic text is published, and every earlier version stays in the section''s history. There is nothing to review.
5. A rewrite that does not pass the checks is asked again, more strictly. If it still does not pass, the screenshots and button names are updated, the rest of the text stays as it was, and the next run tries again.

> Tip: The card "The guides keep up by themselves" at the top of Guides lists the last runs: when, how many screenshots were replaced, how many sections were rewritten, and how many PDFs were printed.

## Insurers and the other lists

1. Open Insurers. Each insurer on file opens to edit its billing contact, email, phone, address and notes.
2. To add one, fill in the Add form (Name, Billing contact, Billing email and the rest) and press **Add**.
3. Deposit tiers, Kilometre choices, Vehicle classes, Airports, Promo codes and Quick replies work the same way.
',
  '<p class="gd-p">Settings change the public site and the rules of the program at once. Program settings are kept as dated rows, so earlier values stay on record.</p><section class="gd-task" id="settings-the-settings-page" data-gd-task><h2 class="gd-h2">The Settings page</h2><div class="gd-stepblock gd-stepblock--below"><div class="gd-stepcol"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Site setup lists what is still missing on the public site, with <b class="gd-ui">Open site settings</b>.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Site settings: contact details, hours, tagline, logo, socials, Google place id and featured cars.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Program settings: every timing and policy value.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">Forms: the official ServiceOntario PDFs and what goes in each field.</div></li><li><span class="gd-n" aria-hidden="true">5</span><div class="gd-t">Insurers: insurance companies billed for bookings.</div></li></ol></div><figure class="gd-fig gd-fig--desk"><div class="gd-browser"><div class="gd-bar" aria-hidden="true"><i></i><i></i><i></i><span class="gd-addr">carmacars.ca/admin/settings</span></div><div class="gd-imgwrap" style="aspect-ratio:1440/900"><img src="/guides/img/admin-24-settings-desktop-89b31691.jpg" alt="" loading="lazy" decoding="async" width="1440" height="900"><span class="gd-pin" style="left:32.6%;top:33%" aria-hidden="true">1</span><span class="gd-pin" style="left:25.8%;top:40.2%" aria-hidden="true">2</span><span class="gd-pin" style="left:77.4%;top:40.2%" aria-hidden="true">3</span><span class="gd-pin" style="left:25.8%;top:73.2%" aria-hidden="true">4</span><span class="gd-pin" style="left:25.8%;top:84.9%" aria-hidden="true">5</span></div></div></figure></div><p class="gd-p">The other tiles: Site content (headings, FAQs, legal text), Fee defaults, Deposit tiers, Kilometre choices, Vehicle classes, Airports and delivery, Coverage prices, Email aliases and reply-to, Staff and roles, Promo codes and Quick replies.</p></section><section class="gd-task" id="settings-program-settings" data-gd-task><h2 class="gd-h2">Program settings</h2><div class="gd-stepblock gd-stepblock--below"><div class="gd-stepcol"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Turnaround between trips: the time held between two trips. The cleaning block after a trip is this time.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Settings come in groups such as Company, Booking requests and offers, Owner debits and statement emails, Deposits, Delivery, Owners and fleet, and Tolls and damage. Open one to see its fields.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">First reply target for customer service and sales (minutes), under Booking requests and offers: 5 by default. New booking requests, enquiries, changes renters ask for and renter messages are due that many minutes after they come in; the scorecard and the staff screens use it. What renters are told (Reply wording, in Site settings) is separate.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">Staff commissions and prices typed by hand: the commission outside Sales (10%), the three Sales tiers and their days (10%, 15% from 50 days, 20% from 100 days, the month&#39;s target), the price floor a day (empty: none) and the discount from the rate sheet that flags a price (20%). The owner confirmed these values in October 2026.</div></li><li><span class="gd-n" aria-hidden="true">5</span><div class="gd-t">Staff agreement defaults by function, at the bottom: pay (a month, an hour or commission only), the rate, the schedule (full time, part time or flexible), days a week and hours a day for Customer service, Fleet, Finance and Sales, the values every assistant shares, and the field staff wage. Sales is commission only: no rate and a flexible schedule. Press <b class="gd-ui">Save the defaults</b>.</div></li><li><span class="gd-n" aria-hidden="true">6</span><div class="gd-t">Change a value and press <b class="gd-ui">Save</b>. It is saved as a new row from today; the rows before stay as they were.</div></li></ol></div><figure class="gd-fig gd-fig--desk"><div class="gd-browser"><div class="gd-bar" aria-hidden="true"><i></i><i></i><i></i><span class="gd-addr">carmacars.ca/admin/settings/program</span></div><div class="gd-imgwrap" style="aspect-ratio:1440/1000"><img src="/guides/img/admin-25-program-settings-desktop-d16b066c.jpg" alt="" loading="lazy" decoding="async" width="1440" height="1000"><span class="gd-pin" style="left:25.8%;top:22%" aria-hidden="true">1</span><span class="gd-pin" style="left:27.8%;top:49%" aria-hidden="true">2</span></div></div></figure></div></section><section class="gd-task" id="settings-official-serviceontario-forms" data-gd-task><h2 class="gd-h2">Official ServiceOntario forms</h2><p class="gd-p">The five official forms are loaded with a draft mapping to the owner, car, company and lender details. Until you check a form, owners get a data sheet with the values.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Open <b class="gd-ui">Settings</b> &gt; <b class="gd-ui">Forms</b>. Each form shows &quot;Mapping to check&quot; (a draft is ready) or &quot;Official PDF in use&quot;. Its notes say what the form is for and which boxes are left blank on purpose.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Press <b class="gd-ui">Download a filled preview</b> for one car and check each value against the form.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Change a field if needed: What goes in it (or &quot;The owner signs here&quot;), a Format (for example YYYY/MM/DD) and Only when. Press Save the mapping.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">Press <b class="gd-ui">Checked: use for owners</b>. Every owner&#39;s form of that kind is filled again, except ones already signed or filed, and owners sign it with their other documents.</div></li><li><span class="gd-n" aria-hidden="true">5</span><div class="gd-t">A new version from ServiceOntario? Press <b class="gd-ui">Upload the official fillable PDF</b>: the fields of the same name keep their mapping.</div></li></ol></div><aside class="gd-box"><span class="gd-lbl">Good to know</span><div>SR-LV-006 (registration), SR-LV-012 (two registrants), ON00453 (a company&#39;s RIN), 013-1155 and 013-0169 (the tax-exempt transfer into an owner&#39;s corporation). 013-1155 is sworn before a commissioner, so it is printed and signed in person.</div></aside></section><section class="gd-task" id="settings-agreements-to-sign-investors-and-staff" data-gd-task><h2 class="gd-h2">Agreements to sign: investors and staff</h2><p class="gd-p">Investment agreements and staff agreements are made from the person&#39;s record and signed in their own portal, or on paper.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Investor: open <b class="gd-ui">People</b> &gt; <b class="gd-ui">Investors</b> and the investor. Under Investment agreement, press <b class="gd-ui">Send the agreement to sign</b>. Check the values it is filled with (amount, yearly percentage, dates, exemption) and press <b class="gd-ui">Send to sign</b>.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Once the investor signs, the agreement shows <b class="gd-ui">Awaiting countersignature</b> on the investor&#39;s page and on To do. It is not countersigned automatically: check it and press <b class="gd-ui">Countersign</b>. CarmaCars is bound once it has countersigned and the funds clear.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Staff: open <b class="gd-ui">People</b> &gt; <b class="gd-ui">Staff</b>. Under Staff agreements, press <b class="gd-ui">Send the agreement to sign</b> beside the person. Pay, schedule, hours and the other values start from the staff profile and the defaults of their function in Program settings; change any before sending. For Sales the Pay is Commission only: the agreement then has no rate, schedule or hours, and pays the commission of section 3.4.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">A field staff member&#39;s agreement prints the home address they entered themselves. Staff enter their home address at their first sign-in, before they sign, or in their profile.</div></li><li><span class="gd-n" aria-hidden="true">5</span><div class="gd-t">They get a notice, check the key values and sign in their portal in a few taps (their name is the signature, or they draw it). The signed copy is filed with their documents.</div></li><li><span class="gd-n" aria-hidden="true">6</span><div class="gd-t">Your own PDF instead? <b class="gd-ui">Send a PDF to sign</b> still works.</div></li><li><span class="gd-n" aria-hidden="true">7</span><div class="gd-t">Signed on paper instead? Press <b class="gd-ui">Record paper signature</b> in the same place and upload the scan.</div></li><li><span class="gd-n" aria-hidden="true">8</span><div class="gd-t">Sent by mistake? Press <b class="gd-ui">Withdraw</b> and give the reason.</div></li></ol></div></section><section class="gd-task" id="settings-the-user-guides" data-gd-task><h2 class="gd-h2">The user guides</h2><p class="gd-p"><b class="gd-ui">Settings</b> &gt; <b class="gd-ui">Guides</b>. The guide of each portal, as people read it under Guide.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Each guide shows its version, when it was published and whether there are unpublished changes.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Open a guide and press a section. Change its text and press <b class="gd-ui">Show the preview</b> to see it as people will. Press <b class="gd-ui">Save the draft</b>; each save is kept in the section&#39;s history.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Move a section with the arrows, hide it, or press <b class="gd-ui">Add a chapter</b>. Upload a screenshot under Screenshots and paste the line it gives you.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">Press <b class="gd-ui">Publish version</b> (the next number). The portals show the new version at once.</div></li><li><span class="gd-n" aria-hidden="true">5</span><div class="gd-t">The stored PDF is printed again by the guides-pdf workflow. Until then the guide says the web guide has newer edits.</div></li></ol></div></section><section class="gd-task" id="settings-the-guides-keep-up-by-themselves" data-gd-task><h2 class="gd-h2">The guides keep up by themselves</h2><p class="gd-p">After every update of the site that changes the portals, the guides are checked without anyone asking.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Every screenshot is taken again on the new version of the site. One whose screen changed replaces the old one in the guide.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">The text of each section whose screen changed, or that names a button the portals no longer show, is rewritten from the portal&#39;s own labels and menu, checked, and published. The PDFs of those guides are printed again.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Such a section says <b class="gd-ui">Changed automatically on</b> and the date, in the list of guides and in the guide&#39;s editor. Not right? Open the section and press <b class="gd-ui">Revert</b>: the text it replaced comes back, published at once.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">This includes sections you edited: the newest automatic text is published, and every earlier version stays in the section&#39;s history. There is nothing to review.</div></li><li><span class="gd-n" aria-hidden="true">5</span><div class="gd-t">A rewrite that does not pass the checks is asked again, more strictly. If it still does not pass, the screenshots and button names are updated, the rest of the text stays as it was, and the next run tries again.</div></li></ol></div><aside class="gd-box"><span class="gd-lbl">Tip</span><div>The card &quot;The guides keep up by themselves&quot; at the top of Guides lists the last runs: when, how many screenshots were replaced, how many sections were rewritten, and how many PDFs were printed.</div></aside></section><section class="gd-task" id="settings-insurers-and-the-other-lists" data-gd-task><h2 class="gd-h2">Insurers and the other lists</h2><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Open Insurers. Each insurer on file opens to edit its billing contact, email, phone, address and notes.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">To add one, fill in the Add form (Name, Billing contact, Billing email and the rest) and press <b class="gd-ui">Add</b>.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Deposit tiers, Kilometre choices, Vehicle classes, Airports, Promo codes and Quick replies work the same way.</div></li></ol></div></section>');
select app.guide_release_0059('va', 'start-here', 'start', null, '### Who this guide is for

CarmaCars assistants (VAs) in Customer service, Finance, Fleet and Sales. Read chapter 1, then the chapter for your function. If you cover more than one, read each of them.

### What you need

- The invitation email from CarmaCars (the link works for 24 hours)
- A computer for your shift. The portal also works on a phone
- An authenticator app on your phone, if your Admin turns on two-step sign-in

## Your first sign-in

1. Open the invitation email and press its link within 24 hours. Choose a password of 8 characters or more and press **Save the new password**.
2. You land in your portal, on **To do**, working as your main function.
3. Next time, sign in at `carmacars.ca/sign-in` with your Email and Password, then **Sign in**.
4. Link expired? Press **Send me a new link** on the page it opens, or ask an Admin for a password link.

![](/guides/img/public-09-sign-in-phone-1f766061.jpg "phone; size: 390 645; pins: 3 95.4 78.4")

> Good to know: Recommended: open your profile and press **Set up two-step sign-in**. Scan the code with your authenticator app, type the 6 digits and press **Continue**. After that every sign-in asks for a code.
', 'Start here', 'Who this is for and your first sign-in.',
  '### Who this guide is for

CarmaCars assistants (VAs) in Customer service, Finance, Fleet and Sales. Read chapter 1, then the chapter for your function. If you cover more than one, read each of them.

### What you need

- The invitation email from CarmaCars (the link works for 24 hours)
- A computer for your shift. The portal also works on a phone
- An authenticator app on your phone, if your Admin turns on two-step sign-in

## Your first sign-in

1. Open the invitation email and press its link within 24 hours. Choose a password of 8 characters or more and press **Save the new password**.
2. You land in your portal, on **To do**, working as your main function.
3. At the top of the page, fill in your Home address and Postal code and press **Save my home address**. You need it before you add a rental or earn a commission. Change it later under **Profile**, at the top of the menu.
4. Next time, sign in at `carmacars.ca/sign-in` with your Email and Password, then **Sign in**.
5. Link expired? Press **Send me a new link** on the page it opens, or ask an Admin for a password link.

![](/guides/img/public-09-sign-in-phone-1f766061.jpg "phone; size: 390 645; pins: 3 95.4 78.4")

> Good to know: Recommended: open your profile and press **Set up two-step sign-in**. Scan the code with your authenticator app, type the 6 digits and press **Continue**. After that every sign-in asks for a code.
',
  '<h3 class="gd-h3">Who this guide is for</h3><p class="gd-p">CarmaCars assistants (VAs) in Customer service, Finance, Fleet and Sales. Read chapter 1, then the chapter for your function. If you cover more than one, read each of them.</p><h3 class="gd-h3">What you need</h3><ul class="gd-ul"><li>The invitation email from CarmaCars (the link works for 24 hours)</li><li>A computer for your shift. The portal also works on a phone</li><li>An authenticator app on your phone, if your Admin turns on two-step sign-in</li></ul><section class="gd-task" id="start-here-your-first-sign-in" data-gd-task><h2 class="gd-h2">Your first sign-in</h2><div class="gd-stepblock gd-stepblock--side"><div class="gd-stepcol"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Open the invitation email and press its link within 24 hours. Choose a password of 8 characters or more and press <b class="gd-ui">Save the new password</b>.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">You land in your portal, on <b class="gd-ui">To do</b>, working as your main function.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">At the top of the page, fill in your Home address and Postal code and press <b class="gd-ui">Save my home address</b>. You need it before you add a rental or earn a commission. Change it later under <b class="gd-ui">Profile</b>, at the top of the menu.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">Next time, sign in at <span class="gd-url">carmacars.ca/sign-in</span> with your Email and Password, then <b class="gd-ui">Sign in</b>.</div></li><li><span class="gd-n" aria-hidden="true">5</span><div class="gd-t">Link expired? Press <b class="gd-ui">Send me a new link</b> on the page it opens, or ask an Admin for a password link.</div></li></ol></div><figure class="gd-fig gd-fig--phone"><div class="gd-phone"><div class="gd-imgwrap" style="aspect-ratio:390/645"><img src="/guides/img/public-09-sign-in-phone-1f766061.jpg" alt="" loading="lazy" decoding="async" width="390" height="645"><span class="gd-pin" style="left:95.4%;top:78.4%" aria-hidden="true">3</span></div></div></figure></div><aside class="gd-box"><span class="gd-lbl">Good to know</span><div>Recommended: open your profile and press <b class="gd-ui">Set up two-step sign-in</b>. Scan the code with your authenticator app, type the 6 digits and press <b class="gd-ui">Continue</b>. After that every sign-in asks for a code.</div></aside></section>');
select app.guide_release_0059('va', 'add-a-rental-by-hand', 'chapter', 'sales', 'Every function adds rentals that come in by phone, at the counter, from Turo, a partner, an insurer or someone you know. The rental is confirmed and on the calendar at once.

## Add a rental

Open **Bookings** > **Add a rental**.

1. Choose the car, the dates and the places. The check shows any clash with another booking or with the cleaning time after a trip. You cannot book over a clash: ask an Admin.
2. Find the renter by name, email or phone, or add a new one with their name, email, phone, date of birth and licence. Add any other drivers.
3. Press **Check the calendar and the price**. The price comes from the rate sheet. You may add the extras, the coverage and an allowed promo code.
4. To charge another price, type the rental charge and the reason. The rate-sheet price stays on the booking. A price far under the rate sheet is flagged for an Admin to review, but the rental is still added.
5. Choose Where it came from and how it is paid. The ways open to you are set by an Admin, such as **Paid another way**, **Send a payment link** or **Charge the saved card when the renter signs**.
6. Under Who found this client, choose **I sourced this client** or **Entered for CarmaCars**.
7. Press **Add the rental**. The renter gets the confirmation email unless you tick **Do not email the renter**.
8. A rental you add is credited to you and shows in My sales as a rental you added. If you sourced it, its commission shows there too.

> Tip: The renter signs the rental agreement in their portal before pickup. With the saved card, nothing is charged when you add the rental: the card is charged when the renter presses Accept and sign. If they sign on paper at the counter, an Admin records it. A payment link keeps the booking waiting for payment.
', 'Add a rental by hand', 'Choose the car and dates, find the renter, price it, record how it is paid.',
  'Every function adds rentals that come in by phone, at the counter, from Turo, a partner, an insurer or someone you know. The rental is confirmed and on the calendar at once.

## Add a rental

Open **Bookings** > **Add a rental**. Your home address must be in your profile first: until it is, the page asks for it.

1. Choose the car, the dates and the places. The check shows any clash with another booking or with the cleaning time after a trip. You cannot book over a clash: ask an Admin.
2. Find the renter by name, email or phone, or add a new one with their name, email, phone, date of birth and licence. Add any other drivers.
3. Press **Check the calendar and the price**. The price comes from the rate sheet. You may add the extras, the coverage and an allowed promo code.
4. To charge another price, type the rental charge and the reason. The rate-sheet price stays on the booking. A price far under the rate sheet is flagged for an Admin to review, but the rental is still added.
5. Choose Where it came from and how it is paid. The ways open to you are set by an Admin, such as **Paid another way**, **Send a payment link** or **Charge the saved card when the renter signs**.
6. Under Who found this client, choose **I sourced this client** or **Entered for CarmaCars**.
7. Press **Add the rental**. The renter gets the confirmation email unless you tick **Do not email the renter**.
8. A rental you add is credited to you and shows in My sales as a rental you added. If you sourced it, its commission shows there too.

> Tip: The renter signs the rental agreement in their portal before pickup. With the saved card, nothing is charged when you add the rental: the card is charged when the renter presses Accept and sign. If they sign on paper at the counter, an Admin records it. A payment link keeps the booking waiting for payment.
',
  '<p class="gd-p">Every function adds rentals that come in by phone, at the counter, from Turo, a partner, an insurer or someone you know. The rental is confirmed and on the calendar at once.</p><section class="gd-task" id="add-a-rental-by-hand-add-a-rental" data-gd-task><h2 class="gd-h2">Add a rental</h2><p class="gd-p">Open <b class="gd-ui">Bookings</b> &gt; <b class="gd-ui">Add a rental</b>. Your home address must be in your profile first: until it is, the page asks for it.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Choose the car, the dates and the places. The check shows any clash with another booking or with the cleaning time after a trip. You cannot book over a clash: ask an Admin.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Find the renter by name, email or phone, or add a new one with their name, email, phone, date of birth and licence. Add any other drivers.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Press <b class="gd-ui">Check the calendar and the price</b>. The price comes from the rate sheet. You may add the extras, the coverage and an allowed promo code.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">To charge another price, type the rental charge and the reason. The rate-sheet price stays on the booking. A price far under the rate sheet is flagged for an Admin to review, but the rental is still added.</div></li><li><span class="gd-n" aria-hidden="true">5</span><div class="gd-t">Choose Where it came from and how it is paid. The ways open to you are set by an Admin, such as <b class="gd-ui">Paid another way</b>, <b class="gd-ui">Send a payment link</b> or <b class="gd-ui">Charge the saved card when the renter signs</b>.</div></li><li><span class="gd-n" aria-hidden="true">6</span><div class="gd-t">Under Who found this client, choose <b class="gd-ui">I sourced this client</b> or <b class="gd-ui">Entered for CarmaCars</b>.</div></li><li><span class="gd-n" aria-hidden="true">7</span><div class="gd-t">Press <b class="gd-ui">Add the rental</b>. The renter gets the confirmation email unless you tick <b class="gd-ui">Do not email the renter</b>.</div></li><li><span class="gd-n" aria-hidden="true">8</span><div class="gd-t">A rental you add is credited to you and shows in My sales as a rental you added. If you sourced it, its commission shows there too.</div></li></ol></div><aside class="gd-box"><span class="gd-lbl">Tip</span><div>The renter signs the rental agreement in their portal before pickup. With the saved card, nothing is charged when you add the rental: the card is charged when the renter presses Accept and sign. If they sign on paper at the counter, an Admin records it. A payment link keeps the booking waiting for payment.</div></aside></section>');
select app.guide_release_0059('va', 'commissions', 'chapter', 'add-a-rental-by-hand', 'Every function earns a commission on the rentals it sources: a renter you found yourself. Say so when you enter the rental, the quote or the offer.

## Mark who found the client

Every rental, quote and offer you enter asks: **I sourced this client** or **Entered for CarmaCars**.

1. Choose **I sourced this client** when you found the renter yourself: someone you know, your own post or your own outreach.
2. Choose **Entered for CarmaCars** when the renter came to CarmaCars: the website, the phone line, a walk-in, a partner.
3. A website request earns nothing by itself. If you sourced it anyway, choose I sourced this client on its offer: an Admin decides.

|  | Commission |
| --- | --- |
| Sales | By the rental days of the month: under 50 days 10%, from 50 days 15%, from 100 days 20%, on all of that month''s rentals |
| Customer service, finance, fleet | 10% |
| How much | The rate on the rental charge before tax, after discounts, less refunds |
| When earned | When the rental is completed and paid in full. Never on a cancelled, refunded, unpaid or charged-back rental, or on your own or a household rental |
| Paid | After an Admin approves it, by transfer or on your pay statement. My sales shows each step: not earned yet, pending approval, approved, paid, reversed |

> Tip: A refund or chargeback after a commission was paid comes off your next payment. Your staff agreement has the full rule.
', 'Commissions', 'I sourced this client, your rate, when it is earned, approved and paid.',
  'Every function earns a commission on the rentals it sources: a renter you found yourself. Say so when you enter the rental, the quote or the offer.

## Mark who found the client

Every rental, quote and offer you enter asks: **I sourced this client** or **Entered for CarmaCars**.

1. Choose **I sourced this client** when you found the renter yourself: someone you know, your own post or your own outreach.
2. Choose **Entered for CarmaCars** when the renter came to CarmaCars: the website, the phone line, a walk-in, a partner.
3. A website request earns nothing by itself. If you sourced it anyway, choose I sourced this client on its offer: an Admin decides.

|  | Commission |
| --- | --- |
| Sales | Commission only, with no base pay and no set hours. By the rental days of the month: under 50 days 10%, from 50 days 15%, from 100 days 20%, on all of that month''s rentals |
| Customer service, finance, fleet | 10% |
| How much | The rate on the rental charge before tax, after discounts, less refunds |
| When earned | When the rental is completed and paid in full. Never on a cancelled, refunded, unpaid or charged-back rental, or on your own or a household rental |
| Your home address | It must be in your profile. Until it is, a commission waits as not earned yet, and you cannot add a rental or mark I sourced this client |
| Paid | After an Admin approves it, by transfer or on your pay statement. My sales shows each step: not earned yet, pending approval, approved, paid, reversed |

> Tip: A refund or chargeback after a commission was paid comes off your next payment. Your staff agreement has the full rule.
',
  '<p class="gd-p">Every function earns a commission on the rentals it sources: a renter you found yourself. Say so when you enter the rental, the quote or the offer.</p><section class="gd-task" id="commissions-mark-who-found-the-client" data-gd-task><h2 class="gd-h2">Mark who found the client</h2><p class="gd-p">Every rental, quote and offer you enter asks: <b class="gd-ui">I sourced this client</b> or <b class="gd-ui">Entered for CarmaCars</b>.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Choose <b class="gd-ui">I sourced this client</b> when you found the renter yourself: someone you know, your own post or your own outreach.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Choose <b class="gd-ui">Entered for CarmaCars</b> when the renter came to CarmaCars: the website, the phone line, a walk-in, a partner.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">A website request earns nothing by itself. If you sourced it anyway, choose I sourced this client on its offer: an Admin decides.</div></li></ol></div><div class="gd-tablewrap"><table class="gd-table"><thead><tr><th scope="col"></th><th scope="col">Commission</th></tr></thead><tbody><tr><td>Sales</td><td>Commission only, with no base pay and no set hours. By the rental days of the month: under 50 days 10%, from 50 days 15%, from 100 days 20%, on all of that month&#39;s rentals</td></tr><tr><td>Customer service, finance, fleet</td><td>10%</td></tr><tr><td>How much</td><td>The rate on the rental charge before tax, after discounts, less refunds</td></tr><tr><td>When earned</td><td>When the rental is completed and paid in full. Never on a cancelled, refunded, unpaid or charged-back rental, or on your own or a household rental</td></tr><tr><td>Your home address</td><td>It must be in your profile. Until it is, a commission waits as not earned yet, and you cannot add a rental or mark I sourced this client</td></tr><tr><td>Paid</td><td>After an Admin approves it, by transfer or on your pay statement. My sales shows each step: not earned yet, pending approval, approved, paid, reversed</td></tr></tbody></table></div><aside class="gd-box"><span class="gd-lbl">Tip</span><div>A refund or chargeback after a commission was paid comes off your next payment. Your staff agreement has the full rule.</div></aside></section>');
select app.guide_release_0059('field', 'start-here', 'start', null, '### Who this guide is for

CarmaCars field staff: drivers, detailers, and drivers who also detail. You hand cars over, take them back, move them and shoot listing photos. Everything is on your phone.

### What you need

- Your phone, charged, with a data connection (photos and signatures save as you take them)
- The invitation email from CarmaCars (the link works for 24 hours)
- A car charger and a cloth for the camera lens

## Your first sign-in

1. Open the invitation email on your phone and press its link within 24 hours. Choose a password and press **Save the new password**.
2. You land on **My jobs**. Next time, sign in at `carmacars.ca/sign-in` with your Email and Password.
3. In your browser''s menu, choose **Add to Home Screen**. The portal then opens full screen, like an app.
4. Open **Profile**, add your mobile number and press **Save my phone**.

![](/guides/img/field-04-profile-phone-7f54561f.jpg "phone; size: 390 630; pins: 4 93.6 91.7")

> Good to know: Recommended: on Profile, press **Set up two-step sign-in** and follow the steps with an authenticator app.
', 'Start here', 'Who this is for and your first sign-in.',
  '### Who this guide is for

CarmaCars field staff: drivers, detailers, and drivers who also detail. You hand cars over, take them back, move them and shoot listing photos. Everything is on your phone.

### What you need

- Your phone, charged, with a data connection (photos and signatures save as you take them)
- The invitation email from CarmaCars (the link works for 24 hours)
- A car charger and a cloth for the camera lens

## Your first sign-in

1. Open the invitation email on your phone and press its link within 24 hours. Choose a password and press **Save the new password**.
2. You land on **My jobs**. Next time, sign in at `carmacars.ca/sign-in` with your Email and Password.
3. In your browser''s menu, choose **Add to Home Screen**. The portal then opens full screen, like an app.
4. Open **Profile**, add your mobile number and press **Save my phone**.
5. At the top of the page, fill in your Home address and Postal code and press **Save my home address**. You need it before you add a rental or earn a commission.

![](/guides/img/field-04-profile-phone-7f54561f.jpg "phone; size: 390 630; pins: 4 93.6 91.7")

> Good to know: Recommended: on Profile, press **Set up two-step sign-in** and follow the steps with an authenticator app.
',
  '<h3 class="gd-h3">Who this guide is for</h3><p class="gd-p">CarmaCars field staff: drivers, detailers, and drivers who also detail. You hand cars over, take them back, move them and shoot listing photos. Everything is on your phone.</p><h3 class="gd-h3">What you need</h3><ul class="gd-ul"><li>Your phone, charged, with a data connection (photos and signatures save as you take them)</li><li>The invitation email from CarmaCars (the link works for 24 hours)</li><li>A car charger and a cloth for the camera lens</li></ul><section class="gd-task" id="start-here-your-first-sign-in" data-gd-task><h2 class="gd-h2">Your first sign-in</h2><div class="gd-stepblock gd-stepblock--side"><div class="gd-stepcol"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Open the invitation email on your phone and press its link within 24 hours. Choose a password and press <b class="gd-ui">Save the new password</b>.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">You land on <b class="gd-ui">My jobs</b>. Next time, sign in at <span class="gd-url">carmacars.ca/sign-in</span> with your Email and Password.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">In your browser&#39;s menu, choose <b class="gd-ui">Add to Home Screen</b>. The portal then opens full screen, like an app.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">Open <b class="gd-ui">Profile</b>, add your mobile number and press <b class="gd-ui">Save my phone</b>.</div></li><li><span class="gd-n" aria-hidden="true">5</span><div class="gd-t">At the top of the page, fill in your Home address and Postal code and press <b class="gd-ui">Save my home address</b>. You need it before you add a rental or earn a commission.</div></li></ol></div><figure class="gd-fig gd-fig--phone"><div class="gd-phone"><div class="gd-imgwrap" style="aspect-ratio:390/630"><img src="/guides/img/field-04-profile-phone-7f54561f.jpg" alt="" loading="lazy" decoding="async" width="390" height="630"><span class="gd-pin" style="left:93.6%;top:91.7%" aria-hidden="true">4</span></div></div></figure></div><aside class="gd-box"><span class="gd-lbl">Good to know</span><div>Recommended: on Profile, press <b class="gd-ui">Set up two-step sign-in</b> and follow the steps with an authenticator app.</div></aside></section>');
select app.guide_release_0059('field', 'my-jobs', 'chapter', 'start-here', 'Your day, in order: handovers, returns, deliveries, moves and photo shoots. Each job card has the car, the plate, the place and the time.

## Your job list

1. The menu: **My jobs**, **Report**, **Add a rental**, **My sales**, **Referrals** and **Profile**. **Sign out** is top right.
2. Switch between **Today** and **Tomorrow**. Jobs are in time order.
3. Each card: the kind, the time, the status, the car and plate.
4. Press **Open the job** to start.
5. Moving a car that has no job? Use Vehicle moves (see below).

![](/guides/img/field-01-today-phone-421eca90.jpg "phone; size: 390 945; pins: 1 7.7 19.6, 2 76.9 27.5, 3 89.7 37.0, 4 88.5 46.6, 5 76.9 56.3")

> Tip: Need help on a job? Call CarmaCars at 647-575-3377. The link is at the bottom of My jobs.

## Open a job

1. The card shows the kind, the time, the car, the plate and colour.
2. The address, with **Open in maps** for directions.
3. For a handover: the booking, the renter''s name and phone, the Card on File and the licence on file.
4. Press **Acknowledge** so the office knows you have it. Then press **Start** when you are with the car.

![](/guides/img/field-02-job-phone-a0feec93.jpg "phone; size: 390 635; pins: 1 94.9 51.2, 2 94.9 64.3, 3 94.9 79.5, 4 94.9 93.9")

## Move a car

1. Under Vehicle moves, choose the Car and Why (for example Reposition).
2. Fill in From and the Odometer (km).
3. Press **Start a move**. When you arrive, press **End the move** and enter the odometer again.

![](/guides/img/field-01-today-phone-27dfe7af.jpg "phone; size: 390 450; pins: 1 87.2 22.2, 2 87.2 60.4, 3 87.2 93.3")

## Documents to sign

Your staff agreement, when CarmaCars sends it.

1. My jobs shows "You have a document to sign". Press **Read and sign**.
2. Check the key values at the top (your role, wage and start date), then press **Read the PDF** and read it.
3. Press **Sign**. Your full legal name is your signature (or press **Draw instead**).
', 'My jobs', 'Your job list, a job card, maps and car moves.',
  'Your day, in order: handovers, returns, deliveries, moves and photo shoots. Each job card has the car, the plate, the place and the time.

## Your job list

1. The menu: **My jobs**, **Report**, **Add a rental**, **My sales**, **Referrals** and **Profile**. **Sign out** is top right.
2. Switch between **Today** and **Tomorrow**. Jobs are in time order.
3. Each card: the kind, the time, the status, the car and plate.
4. Press **Open the job** to start.
5. Moving a car that has no job? Use Vehicle moves (see below).

![](/guides/img/field-01-today-phone-421eca90.jpg "phone; size: 390 945; pins: 1 7.7 19.6, 2 76.9 27.5, 3 89.7 37.0, 4 88.5 46.6, 5 76.9 56.3")

> Tip: Need help on a job? Call CarmaCars at 647-575-3377. The link is at the bottom of My jobs.

## Open a job

1. The card shows the kind, the time, the car, the plate and colour.
2. The address, with **Open in maps** for directions.
3. For a handover: the booking, the renter''s name and phone, the Card on File and the licence on file.
4. Press **Acknowledge** so the office knows you have it. Then press **Start** when you are with the car.

![](/guides/img/field-02-job-phone-a0feec93.jpg "phone; size: 390 635; pins: 1 94.9 51.2, 2 94.9 64.3, 3 94.9 79.5, 4 94.9 93.9")

## Move a car

1. Under Vehicle moves, choose the Car and Why (for example Reposition).
2. Fill in From and the Odometer (km).
3. Press **Start a move**. When you arrive, press **End the move** and enter the odometer again.

![](/guides/img/field-01-today-phone-27dfe7af.jpg "phone; size: 390 450; pins: 1 87.2 22.2, 2 87.2 60.4, 3 87.2 93.3")

## Documents to sign

Your staff agreement, when CarmaCars sends it.

1. My jobs shows "You have a document to sign". Press **Read and sign**.
2. Check the key values at the top (your role, wage and start date), then press **Read the PDF** and read it.
3. Press **Sign**. Your full legal name is your signature (or press **Draw instead**).
',
  '<p class="gd-p">Your day, in order: handovers, returns, deliveries, moves and photo shoots. Each job card has the car, the plate, the place and the time.</p><section class="gd-task" id="my-jobs-your-job-list" data-gd-task><h2 class="gd-h2">Your job list</h2><div class="gd-stepblock gd-stepblock--side"><div class="gd-stepcol"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">The menu: <b class="gd-ui">My jobs</b>, <b class="gd-ui">Report</b>, <b class="gd-ui">Add a rental</b>, <b class="gd-ui">My sales</b>, <b class="gd-ui">Referrals</b> and <b class="gd-ui">Profile</b>. <b class="gd-ui">Sign out</b> is top right.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Switch between <b class="gd-ui">Today</b> and <b class="gd-ui">Tomorrow</b>. Jobs are in time order.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Each card: the kind, the time, the status, the car and plate.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">Press <b class="gd-ui">Open the job</b> to start.</div></li><li><span class="gd-n" aria-hidden="true">5</span><div class="gd-t">Moving a car that has no job? Use Vehicle moves (see below).</div></li></ol></div><figure class="gd-fig gd-fig--phone"><div class="gd-phone"><div class="gd-imgwrap" style="aspect-ratio:390/945"><img src="/guides/img/field-01-today-phone-421eca90.jpg" alt="" loading="lazy" decoding="async" width="390" height="945"><span class="gd-pin" style="left:7.7%;top:19.6%" aria-hidden="true">1</span><span class="gd-pin" style="left:76.9%;top:27.5%" aria-hidden="true">2</span><span class="gd-pin" style="left:89.7%;top:37%" aria-hidden="true">3</span><span class="gd-pin" style="left:88.5%;top:46.6%" aria-hidden="true">4</span><span class="gd-pin" style="left:76.9%;top:56.3%" aria-hidden="true">5</span></div></div></figure></div><aside class="gd-box"><span class="gd-lbl">Tip</span><div>Need help on a job? Call CarmaCars at 647-575-3377. The link is at the bottom of My jobs.</div></aside></section><section class="gd-task" id="my-jobs-open-a-job" data-gd-task><h2 class="gd-h2">Open a job</h2><div class="gd-stepblock gd-stepblock--side"><div class="gd-stepcol"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">The card shows the kind, the time, the car, the plate and colour.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">The address, with <b class="gd-ui">Open in maps</b> for directions.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">For a handover: the booking, the renter&#39;s name and phone, the Card on File and the licence on file.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">Press <b class="gd-ui">Acknowledge</b> so the office knows you have it. Then press <b class="gd-ui">Start</b> when you are with the car.</div></li></ol></div><figure class="gd-fig gd-fig--phone"><div class="gd-phone"><div class="gd-imgwrap" style="aspect-ratio:390/635"><img src="/guides/img/field-02-job-phone-a0feec93.jpg" alt="" loading="lazy" decoding="async" width="390" height="635"><span class="gd-pin" style="left:94.9%;top:51.2%" aria-hidden="true">1</span><span class="gd-pin" style="left:94.9%;top:64.3%" aria-hidden="true">2</span><span class="gd-pin" style="left:94.9%;top:79.5%" aria-hidden="true">3</span><span class="gd-pin" style="left:94.9%;top:93.9%" aria-hidden="true">4</span></div></div></figure></div></section><section class="gd-task" id="my-jobs-move-a-car" data-gd-task><h2 class="gd-h2">Move a car</h2><div class="gd-stepblock gd-stepblock--side"><div class="gd-stepcol"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Under Vehicle moves, choose the Car and Why (for example Reposition).</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Fill in From and the Odometer (km).</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Press <b class="gd-ui">Start a move</b>. When you arrive, press <b class="gd-ui">End the move</b> and enter the odometer again.</div></li></ol></div><figure class="gd-fig gd-fig--phone"><div class="gd-phone"><div class="gd-imgwrap" style="aspect-ratio:390/450"><img src="/guides/img/field-01-today-phone-27dfe7af.jpg" alt="" loading="lazy" decoding="async" width="390" height="450"><span class="gd-pin" style="left:87.2%;top:22.2%" aria-hidden="true">1</span><span class="gd-pin" style="left:87.2%;top:60.4%" aria-hidden="true">2</span><span class="gd-pin" style="left:87.2%;top:93.3%" aria-hidden="true">3</span></div></div></figure></div></section><section class="gd-task" id="my-jobs-documents-to-sign" data-gd-task><h2 class="gd-h2">Documents to sign</h2><p class="gd-p">Your staff agreement, when CarmaCars sends it.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">My jobs shows &quot;You have a document to sign&quot;. Press <b class="gd-ui">Read and sign</b>.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Check the key values at the top (your role, wage and start date), then press <b class="gd-ui">Read the PDF</b> and read it.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Press <b class="gd-ui">Sign</b>. Your full legal name is your signature (or press <b class="gd-ui">Draw instead</b>).</div></li></ol></div></section>');
select app.guide_release_0059('field', 'report-rentals-referrals-and-profile', 'chapter', 'photo-shoots', 'Report anything that happens on the road, add a rental for a renter you found, share your referral link, and keep your details up to date.

## Report something

1. Open **Report** and choose the Car.
2. Choose What happened: **New damage found**, **Warning light**, **Collision while I was driving**, **Ticket or toll while I was driving**, **Lost property found** or **Something else**.
3. Write the Details: where, when and what you see.
4. Press **Take a photo** for each photo, then **Send the report**.

![](/guides/img/field-03-report-phone-2adac4d1.jpg "phone; size: 390 965; pins: 1 92.3 29.5, 2 92.3 37.3, 3 92.3 83.4, 4 92.3 97.9")

> Watch out: In a collision, make sure everyone is safe and call 911 if anyone is hurt. Then call CarmaCars at 647-575-3377 before you send the report.

## Add a rental for a renter you found

1. Open **Add a rental**. Choose the car, the dates and the places, then type the renter''s details. A renter already on file is found by their email.
2. Press **Check the calendar and the price**. To charge another price, type it with the reason: a price far under the rate sheet is flagged for an Admin, not refused.
3. Choose **Send a payment link** or **Charge the saved card when the renter signs**. You never take payment yourself.
4. Under Who found this client, choose **I sourced this client** or **Entered for CarmaCars**, then press **Add the rental**.

## Commissions

1. You earn 10% of the rental charge (before tax, after discounts, less refunds) of each rental you sourced: one you added and marked I sourced this client, or a booking made with your referral link.
2. It is earned when the rental is completed and paid in full, then an Admin approves it and it is paid on your pay date.
3. **My sales** shows each commission: not earned yet, pending approval, approved, paid or reversed. A refund after payment comes off a later commission.

## Referrals and profile

1. **Referrals**: your own referral link. Press **Copy the link**, or let someone scan its QR code. A booking made with it counts as a rental you sourced.
2. **Profile**: **Save my phone**, **Set up two-step sign-in**, **Change my password** and **Sign out**.

![](/guides/img/field-04-profile-phone-56e58ae3.jpg "phone; size: 390 905; pins: 2 93.6 63.9")
', 'Report, rentals, referrals and profile', 'Report an incident, add a rental, commissions, your referral link and your profile.',
  'Report anything that happens on the road, add a rental for a renter you found, share your referral link, and keep your details up to date.

## Report something

1. Open **Report** and choose the Car.
2. Choose What happened: **New damage found**, **Warning light**, **Collision while I was driving**, **Ticket or toll while I was driving**, **Lost property found** or **Something else**.
3. Write the Details: where, when and what you see.
4. Press **Take a photo** for each photo, then **Send the report**.

![](/guides/img/field-03-report-phone-2adac4d1.jpg "phone; size: 390 965; pins: 1 92.3 29.5, 2 92.3 37.3, 3 92.3 83.4, 4 92.3 97.9")

> Watch out: In a collision, make sure everyone is safe and call 911 if anyone is hurt. Then call CarmaCars at 647-575-3377 before you send the report.

## Add a rental for a renter you found

Your home address must be in your profile first: until it is, the page asks for it.

1. Open **Add a rental**. Choose the car, the dates and the places, then type the renter''s details. A renter already on file is found by their email.
2. Press **Check the calendar and the price**. To charge another price, type it with the reason: a price far under the rate sheet is flagged for an Admin, not refused.
3. Choose **Send a payment link** or **Charge the saved card when the renter signs**. You never take payment yourself.
4. Under Who found this client, choose **I sourced this client** or **Entered for CarmaCars**, then press **Add the rental**.

## Commissions

1. You earn 10% of the rental charge (before tax, after discounts, less refunds) of each rental you sourced: one you added and marked I sourced this client, or a booking made with your referral link.
2. It is earned when the rental is completed and paid in full, then an Admin approves it and it is paid on your pay date. Your home address must be in your profile: until it is, a commission waits as not earned yet.
3. **My sales** shows each commission: not earned yet, pending approval, approved, paid or reversed. A refund after payment comes off a later commission.

## Referrals and profile

1. **Referrals**: your own referral link. Press **Copy the link**, or let someone scan its QR code. A booking made with it counts as a rental you sourced.
2. **Profile**: **Save my phone**, your home address (**Change my home address**), **Set up two-step sign-in**, **Change my password** and **Sign out**.

![](/guides/img/field-04-profile-phone-56e58ae3.jpg "phone; size: 390 905; pins: 2 93.6 63.9")
',
  '<p class="gd-p">Report anything that happens on the road, add a rental for a renter you found, share your referral link, and keep your details up to date.</p><section class="gd-task" id="report-rentals-referrals-and-profile-report-something" data-gd-task><h2 class="gd-h2">Report something</h2><div class="gd-stepblock gd-stepblock--side"><div class="gd-stepcol"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Open <b class="gd-ui">Report</b> and choose the Car.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Choose What happened: <b class="gd-ui">New damage found</b>, <b class="gd-ui">Warning light</b>, <b class="gd-ui">Collision while I was driving</b>, <b class="gd-ui">Ticket or toll while I was driving</b>, <b class="gd-ui">Lost property found</b> or <b class="gd-ui">Something else</b>.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Write the Details: where, when and what you see.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">Press <b class="gd-ui">Take a photo</b> for each photo, then <b class="gd-ui">Send the report</b>.</div></li></ol></div><figure class="gd-fig gd-fig--phone"><div class="gd-phone"><div class="gd-imgwrap" style="aspect-ratio:390/965"><img src="/guides/img/field-03-report-phone-2adac4d1.jpg" alt="" loading="lazy" decoding="async" width="390" height="965"><span class="gd-pin" style="left:92.3%;top:29.5%" aria-hidden="true">1</span><span class="gd-pin" style="left:92.3%;top:37.3%" aria-hidden="true">2</span><span class="gd-pin" style="left:92.3%;top:83.4%" aria-hidden="true">3</span><span class="gd-pin" style="left:92.3%;top:97.9%" aria-hidden="true">4</span></div></div></figure></div><aside class="gd-box gd-box--warn"><span class="gd-lbl">Watch out</span><div>In a collision, make sure everyone is safe and call 911 if anyone is hurt. Then call CarmaCars at 647-575-3377 before you send the report.</div></aside></section><section class="gd-task" id="report-rentals-referrals-and-profile-add-a-rental-for-a-renter-you-found" data-gd-task><h2 class="gd-h2">Add a rental for a renter you found</h2><p class="gd-p">Your home address must be in your profile first: until it is, the page asks for it.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Open <b class="gd-ui">Add a rental</b>. Choose the car, the dates and the places, then type the renter&#39;s details. A renter already on file is found by their email.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Press <b class="gd-ui">Check the calendar and the price</b>. To charge another price, type it with the reason: a price far under the rate sheet is flagged for an Admin, not refused.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Choose <b class="gd-ui">Send a payment link</b> or <b class="gd-ui">Charge the saved card when the renter signs</b>. You never take payment yourself.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">Under Who found this client, choose <b class="gd-ui">I sourced this client</b> or <b class="gd-ui">Entered for CarmaCars</b>, then press <b class="gd-ui">Add the rental</b>.</div></li></ol></div></section><section class="gd-task" id="report-rentals-referrals-and-profile-commissions" data-gd-task><h2 class="gd-h2">Commissions</h2><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">You earn 10% of the rental charge (before tax, after discounts, less refunds) of each rental you sourced: one you added and marked I sourced this client, or a booking made with your referral link.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">It is earned when the rental is completed and paid in full, then an Admin approves it and it is paid on your pay date. Your home address must be in your profile: until it is, a commission waits as not earned yet.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t"><b class="gd-ui">My sales</b> shows each commission: not earned yet, pending approval, approved, paid or reversed. A refund after payment comes off a later commission.</div></li></ol></div></section><section class="gd-task" id="report-rentals-referrals-and-profile-referrals-and-profile" data-gd-task><h2 class="gd-h2">Referrals and profile</h2><div class="gd-stepblock gd-stepblock--side"><div class="gd-stepcol"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t"><b class="gd-ui">Referrals</b>: your own referral link. Press <b class="gd-ui">Copy the link</b>, or let someone scan its QR code. A booking made with it counts as a rental you sourced.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t"><b class="gd-ui">Profile</b>: <b class="gd-ui">Save my phone</b>, your home address (<b class="gd-ui">Change my home address</b>), <b class="gd-ui">Set up two-step sign-in</b>, <b class="gd-ui">Change my password</b> and <b class="gd-ui">Sign out</b>.</div></li></ol></div><figure class="gd-fig gd-fig--phone"><div class="gd-phone"><div class="gd-imgwrap" style="aspect-ratio:390/905"><img src="/guides/img/field-04-profile-phone-56e58ae3.jpg" alt="" loading="lazy" decoding="async" width="390" height="905"><span class="gd-pin" style="left:93.6%;top:63.9%" aria-hidden="true">2</span></div></div></figure></div></section>');
select app.guide_release_0059('field', 'quick-reference', 'reference', 'report-rentals-referrals-and-profile', '### Where things are

| Item | What it is for |
| --- | --- |
| **My jobs** | Today and Tomorrow, in order; Vehicle moves |
| **A job** | Open in maps, Acknowledge, Start |
| **Report** | Damage, warning light, collision, ticket, lost property |
| **Add a rental** | A renter you found: a payment link or the saved card |
| **My sales** | Your rentals and commissions |
| **Referrals** | Your link and QR code |
| **Profile** | Phone, two-step sign-in, password, Sign out |

### Top tasks

1. *Start a job:* **Open the job**, **Acknowledge**, **Start**
2. *Hand over a car:* Every step, then **Hand over the keys**
3. *Stop a handover:* **Stop: do not release the car**, call us
4. *Take a car back:* Every step, then **Complete the return**
5. *Shoot listing photos:* **Take photo**, then **Submit for listing**
6. *Move a car:* **Start a move**, then **End the move**
7. *Report an incident:* **Report** > **Send the report**
8. *Add a rental:* **Add a rental**, **I sourced this client**, **Add the rental**

### If something goes wrong

| What you see | What to do |
| --- | --- |
| **A link says it expired** | Links in our emails work for 24 hours, once. Press **Send me a new link** on that page. |
| **"Error 1102" on a page** | A short limit on our web host. Reload the page. You are still signed in. |
| **"That email and password do not match an account."** | Check the address, or use **Set a new password** on the sign-in page. |
| **A photo did not upload** | Check your signal, then press **Send again**. |
| **The renter does not match** | Do not hand over. Press Stop and call us. |
', 'Quick reference', 'One page with the essentials.',
  '### Where things are

| Item | What it is for |
| --- | --- |
| **My jobs** | Today and Tomorrow, in order; Vehicle moves |
| **A job** | Open in maps, Acknowledge, Start |
| **Report** | Damage, warning light, collision, ticket, lost property |
| **Add a rental** | A renter you found: a payment link or the saved card |
| **My sales** | Your rentals and commissions |
| **Referrals** | Your link and QR code |
| **Profile** | Phone, home address, two-step sign-in, password, Sign out |

### Top tasks

1. *Start a job:* **Open the job**, **Acknowledge**, **Start**
2. *Hand over a car:* Every step, then **Hand over the keys**
3. *Stop a handover:* **Stop: do not release the car**, call us
4. *Take a car back:* Every step, then **Complete the return**
5. *Shoot listing photos:* **Take photo**, then **Submit for listing**
6. *Move a car:* **Start a move**, then **End the move**
7. *Report an incident:* **Report** > **Send the report**
8. *Add a rental:* **Add a rental**, **I sourced this client**, **Add the rental**

### If something goes wrong

| What you see | What to do |
| --- | --- |
| **A link says it expired** | Links in our emails work for 24 hours, once. Press **Send me a new link** on that page. |
| **"Error 1102" on a page** | A short limit on our web host. Reload the page. You are still signed in. |
| **"That email and password do not match an account."** | Check the address, or use **Set a new password** on the sign-in page. |
| **A photo did not upload** | Check your signal, then press **Send again**. |
| **The renter does not match** | Do not hand over. Press Stop and call us. |
',
  '<h3 class="gd-h3">Where things are</h3><div class="gd-tablewrap"><table class="gd-table"><thead><tr><th scope="col">Item</th><th scope="col">What it is for</th></tr></thead><tbody><tr><td><b class="gd-ui">My jobs</b></td><td>Today and Tomorrow, in order; Vehicle moves</td></tr><tr><td><b class="gd-ui">A job</b></td><td>Open in maps, Acknowledge, Start</td></tr><tr><td><b class="gd-ui">Report</b></td><td>Damage, warning light, collision, ticket, lost property</td></tr><tr><td><b class="gd-ui">Add a rental</b></td><td>A renter you found: a payment link or the saved card</td></tr><tr><td><b class="gd-ui">My sales</b></td><td>Your rentals and commissions</td></tr><tr><td><b class="gd-ui">Referrals</b></td><td>Your link and QR code</td></tr><tr><td><b class="gd-ui">Profile</b></td><td>Phone, home address, two-step sign-in, password, Sign out</td></tr></tbody></table></div><h3 class="gd-h3">Top tasks</h3><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t"><em>Start a job:</em> <b class="gd-ui">Open the job</b>, <b class="gd-ui">Acknowledge</b>, <b class="gd-ui">Start</b></div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t"><em>Hand over a car:</em> Every step, then <b class="gd-ui">Hand over the keys</b></div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t"><em>Stop a handover:</em> <b class="gd-ui">Stop: do not release the car</b>, call us</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t"><em>Take a car back:</em> Every step, then <b class="gd-ui">Complete the return</b></div></li><li><span class="gd-n" aria-hidden="true">5</span><div class="gd-t"><em>Shoot listing photos:</em> <b class="gd-ui">Take photo</b>, then <b class="gd-ui">Submit for listing</b></div></li><li><span class="gd-n" aria-hidden="true">6</span><div class="gd-t"><em>Move a car:</em> <b class="gd-ui">Start a move</b>, then <b class="gd-ui">End the move</b></div></li><li><span class="gd-n" aria-hidden="true">7</span><div class="gd-t"><em>Report an incident:</em> <b class="gd-ui">Report</b> &gt; <b class="gd-ui">Send the report</b></div></li><li><span class="gd-n" aria-hidden="true">8</span><div class="gd-t"><em>Add a rental:</em> <b class="gd-ui">Add a rental</b>, <b class="gd-ui">I sourced this client</b>, <b class="gd-ui">Add the rental</b></div></li></ol></div><h3 class="gd-h3">If something goes wrong</h3><div class="gd-tablewrap"><table class="gd-table"><thead><tr><th scope="col">What you see</th><th scope="col">What to do</th></tr></thead><tbody><tr><td><b class="gd-ui">A link says it expired</b></td><td>Links in our emails work for 24 hours, once. Press <b class="gd-ui">Send me a new link</b> on that page.</td></tr><tr><td><b class="gd-ui">&quot;Error 1102&quot; on a page</b></td><td>A short limit on our web host. Reload the page. You are still signed in.</td></tr><tr><td><b class="gd-ui">&quot;That email and password do not match an account.&quot;</b></td><td>Check the address, or use <b class="gd-ui">Set a new password</b> on the sign-in page.</td></tr><tr><td><b class="gd-ui">A photo did not upload</b></td><td>Check your signal, then press <b class="gd-ui">Send again</b>.</td></tr><tr><td><b class="gd-ui">The renter does not match</b></td><td>Do not hand over. Press Stop and call us.</td></tr></tbody></table></div>');
-- GUIDES 0059 END

-- Every suggestion still waiting is older than the text published since (an automatic rewrite kept before a release
-- published newer text): the published text stays, the suggestion is kept in the audit log. Every flag and note is
-- cleared; a section whose screenshot changed stays internal to the upkeep (pending), so the next run checks its text.
insert into audit_log (action, entity_table, entity_id, after)
select 'guide_suggestion_dropped', 'guide_sections', s.id::text,
       jsonb_build_object('portal', s.portal, 'section', s.slug, 'suggestion_at', s.suggestion_at, 'published_at', s.published_at, 'model', s.suggestion_model,
                          'suggestion_md', s.suggestion_md, 'why', 'Older than the published text (0059)')
  from guide_sections s where s.suggestion_md is not null;
update guide_sections set needs_review = needs_review and suggestion_md is null and review_images <> '[]'::jsonb, review_note = null, review_flagged_at = null,
       suggestion_md = null, suggestion_at = null, suggestion_model = null
 where needs_review or suggestion_md is not null or review_note is not null;
