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

-- The sections a run reads (0055), with the ones the last run could not rewrite (retry), whatever run they come from.
create or replace function app.guide_upkeep_sections(p_run text) returns jsonb
language sql stable security definer set search_path = public, app as $$
  select coalesce(jsonb_agg(jsonb_build_object('id', s.id, 'portal', s.portal, 'slug', s.slug, 'kind', s.kind, 'title', s.title,
           'body_md', coalesce(s.published_md, s.body_md), 'draft_waiting', s.body_md is distinct from s.published_md or s.draft_version is distinct from s.published_version,
           'is_hidden', s.is_hidden, 'retry', s.auto_retry_at is not null, 'retry_note', s.auto_retry_note, 'retry_count', s.auto_retry_count,
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
-- GUIDES 0059 END

-- Every suggestion still waiting is older than the text published since (an automatic rewrite kept before a release
-- published newer text): the published text stays, the suggestion is kept in the audit log, and every flag is cleared.
insert into audit_log (action, entity_table, entity_id, after)
select 'guide_suggestion_dropped', 'guide_sections', s.id::text,
       jsonb_build_object('portal', s.portal, 'section', s.slug, 'suggestion_at', s.suggestion_at, 'published_at', s.published_at, 'model', s.suggestion_model,
                          'suggestion_md', s.suggestion_md, 'why', 'Older than the published text (0059)')
  from guide_sections s where s.suggestion_md is not null;
update guide_sections set needs_review = false, review_note = null, review_images = '[]'::jsonb, review_flagged_at = null,
       suggestion_md = null, suggestion_at = null, suggestion_model = null
 where needs_review or suggestion_md is not null or review_note is not null or review_images <> '[]'::jsonb;
