-- 2423_r40_my_discounts.sql (release 40)
-- The owner, Nov 12: "Let renters see their stored discounts." Every code the renter holds, read from promo_codes and
-- promo_redemptions (no new storage): codes made from points (rewards), tier codes already issued (rewards_tier), the
-- Black tier's free day (rewards_free_day), referral and personal codes an Admin gave them, come-back offers and game
-- prizes. Each with what it gives, what it applies to (the rental charge only), its last day and days left, and its
-- status: open (unused), on a request (booking number), used (booking number) or expired. Used codes stay a year,
-- expired ones 90 days. Codes switched off by our team are left out (they were never usable).
--   app.my_discounts(user) -> jsonb array; public.server_my_discounts(p_user) for the server (service_role).
set local check_function_bodies = off;

create or replace function app.discount_kind(pc promo_codes) returns text
language sql immutable as $$
  select case
    when pc.source = 'rewards' then 'points'
    when pc.source = 'rewards_tier' then 'tier'
    when pc.source = 'rewards_free_day' then 'free_day'
    when pc.source like 'referral%' then 'referral'
    when pc.source in ('discount_game', 'game') then 'game'
    when pc.source like 'followup%' then 'offer'
    else 'personal' end
$$;

create or replace function app.my_discounts(p_user uuid) returns jsonb
language sql stable security definer set search_path = public, app as $$
  with mine as (
    select pc from promo_codes pc
     where pc.renter_id in (select r.id from renters r where r.user_id = p_user and r.merged_into is null)
        or exists (select 1 from game_claims g where g.promo_code_id = pc.id
                    and (g.user_id = p_user or g.renter_id in (select r.id from renters r where r.user_id = p_user)))
  ), x as (
    select m.pc, app.promo_status(m.pc) as st,
           (select b.booking_number from promo_redemptions pr join bookings b on b.id = pr.booking_id
             where pr.promo_code_id = (m.pc).id and pr.status in ('applied', 'redeemed') order by pr.applied_at desc nulls last limit 1) as booking_number,
           (select max(coalesce(pr.redeemed_at, pr.applied_at)) from promo_redemptions pr where pr.promo_code_id = (m.pc).id and pr.status = 'redeemed') as used_at
      from mine m
  )
  select coalesce(jsonb_agg(jsonb_build_object('code', (x.pc).code, 'kind', app.discount_kind(x.pc), 'what', app.promo_label(x.pc), 'applies_to', app.promo_applies_to(x.pc),
           'percent_bps', (x.pc).percent_bps, 'amount_cents', (x.pc).amount_cents, 'free_days', (x.pc).free_days, 'valid_until', (x.pc).valid_until,
           'ends', case when (x.pc).valid_until is null then null else app.fmt_day(app.promo_last_day(x.pc)) end,
           'days_left', case when (x.pc).valid_until is null or (x.pc).valid_until <= now() then null else greatest(app.promo_last_day(x.pc) - app.today(), 0) end,
           'status', x.st, 'booking_number', x.booking_number, 'company_funded', (x.pc).company_funded)
         order by case x.st when 'open' then 0 when 'on_request' then 1 when 'used' then 2 else 3 end, (x.pc).valid_until nulls last, (x.pc).created_at desc), '[]'::jsonb)
    from x
   where x.st in ('open', 'on_request')
      or (x.st = 'used' and coalesce(x.used_at, (x.pc).created_at) > now() - interval '1 year')
      or (x.st = 'expired' and (x.pc).valid_until > now() - interval '90 days')
$$;
revoke all on function app.my_discounts(uuid), app.discount_kind(promo_codes) from public, anon, authenticated;
grant execute on function app.my_discounts(uuid), app.discount_kind(promo_codes) to service_role;

create or replace function public.server_my_discounts(p_user uuid) returns jsonb
language sql stable set search_path = public, app as $$ select app.my_discounts(p_user) $$;
revoke all on function public.server_my_discounts(uuid) from public, anon, authenticated;
grant execute on function public.server_my_discounts(uuid) to service_role;
