-- 3050 (release 48): the fixes of the release 48 checks (docs/changes/2026-11-15-r48-ci-fixes.md). 1. The Rewards welcome of an
-- account goes to renters only, when the account is confirmed. 2. Published guide tables can be reached with the keyboard.
--
-- 3000 sent renter_rewards_welcome when a renter record got a sign-in. An owner's application makes the account and its
-- renter record first and the owner record after, so an owner who applied to list a car got "Welcome to CarmaCars
-- Rewards" beside the application receipt (deploy run 43743996484, tests/e2e/signup.spec.ts). The account's welcome now
-- goes when the email address is confirmed, to the same people as the account email renter_account_created (0045,
-- app.ntf_users_confirmed_after): a renter-only account, never an owner, a staff member or an investor. A renter record
-- that gets its sign-in after the address is confirmed (an earlier request linked to the account) still gets it then.
-- The first confirmed booking still sends it to anyone who has not had it (3000, unchanged). Each is once (dedupe key).
set local check_function_bodies = off;

create function pg_temp.patch_fn(p_sig regprocedure, p_old text, p_new text) returns void
language plpgsql as $$
declare
  d text := pg_get_functiondef(p_sig);
begin
  if position(p_old in d) = 0 then
    raise exception '3050: the text to change was not found in %: %', p_sig, left(p_old, 160);
  end if;
  execute replace(d, p_old, p_new);
end $$;

create function pg_temp.copy_grants(p_new regprocedure, p_old regprocedure) returns void
language plpgsql as $$
declare g text;
begin
  execute format('revoke all on function %s from public, anon, authenticated', p_new);
  foreach g in array array['anon', 'authenticated', 'service_role'] loop
    if has_function_privilege(g, p_old, 'execute') then execute format('grant execute on function %s to %I', p_new, g); end if;
  end loop;
end $$;

-- a confirmed account that is a renter's only (the people renter_account_created goes to)
create function app.rewards_welcome_account_ok(p_user uuid) returns boolean
language sql stable security definer set search_path = public, app as $$
  select exists (select 1 from users u where u.id = p_user and u.email_verified_at is not null)
     and exists (select 1 from user_roles r where r.user_id = p_user and r.role = 'renter')
     and not exists (select 1 from user_roles r where r.user_id = p_user and r.role <> 'renter')
     and not exists (select 1 from investors i where i.user_id = p_user)
     and not exists (select 1 from owners o where o.user_id = p_user)
$$;
revoke all on function app.rewards_welcome_account_ok(uuid) from public, anon, authenticated;
grant execute on function app.rewards_welcome_account_ok(uuid) to service_role;
comment on function app.rewards_welcome_account_ok(uuid) is
  '3050: the account''s Rewards welcome goes only to a confirmed account that is a renter''s only (as renter_account_created).';

-- a renter record that gets its sign-in: only for a confirmed renter-only account (at sign-up the address is not confirmed yet)
select pg_temp.patch_fn('app.rewards_welcome_renter()'::regprocedure,
  $o$if new.user_id is not null and (tg_op = 'INSERT' or old.user_id is null) and app.rewards_notice_renter_ok(new.id) then$o$,
  $n$if new.user_id is not null and (tg_op = 'INSERT' or old.user_id is null) and app.rewards_notice_renter_ok(new.id)
     and app.rewards_welcome_account_ok(new.user_id) then$n$);

-- the account's address is confirmed: the welcome, with the account email
create function app.rewards_welcome_confirmed() returns trigger
language plpgsql security definer set search_path = public, app as $$
declare v_renter uuid;
begin
  if old.email_verified_at is not null or new.email_verified_at is null then return null; end if;
  if not app.rewards_welcome_account_ok(new.id) then return null; end if;
  select r.id into v_renter from renters r where r.user_id = new.id order by r.created_at limit 1;
  if v_renter is not null and app.rewards_notice_renter_ok(v_renter) then perform app.rewards_welcome(v_renter); end if;
  return null;
end $$;
revoke all on function app.rewards_welcome_confirmed() from public, anon, authenticated;
grant execute on function app.rewards_welcome_confirmed() to service_role;
create trigger users_rewards_welcome after update of email_verified_at on users for each row execute function app.rewards_welcome_confirmed();

-- The guide tables a reader can scroll sideways (a phone, Release 48's text that no longer breaks inside a word) can be
-- reached with the keyboard (axe scrollable-region-focusable): the published chapters get the same wrapper as
-- web/src/features/guides/markdown.ts now writes. The text and the version do not change.
update guide_sections
   set published_html = replace(published_html, '<div class="gd-tablewrap">', '<div class="gd-tablewrap" tabindex="0" role="region" aria-label="Table">')
 where published_html like '%<div class="gd-tablewrap">%';

-- ================================================================ 3. Propose a change: the price the change really lands on
-- The owner, Nov 15 (booking CC-10474: 1 day, $220 rental, $401.15 in all): one more day in Propose a change showed $931.12
-- in all, a difference of $529.97; Edit booking (and the connector's change_booking) priced the same day at $401.15, $802.30
-- in all. app.preview_booking_change (0040) added the booking's own fee lines (v_other) to lines it priced again from the
-- booking's spec: a fee in both (an add-on, a per-day fee) counted twice, and accepting the change then landed on another
-- total (sync_booking_price) than the one the renter agreed to. Now:
--   * a later return alone (no other change, no price typed) costs the booking's all-in price a day, prorated, as Edit
--     booking and extensions do (1201, 2370: app.extension_all_in_target): the rental charge is solved to land on it;
--   * staff may type the new total (changes.total_cents, HST included): the rental charge is solved to land on it;
--   * for these two the total is the one the change lands on: the change is made for a moment (app.change_trial), priced
--     by sync_booking_price as on acceptance, and undone; the rental charge is solved until that total is the target;
--   * the preview gives the booking's all-in price a day (per_day_cents) and how it was priced (pricing). Other changes
--     (another car, earlier dates, a rental charge typed) are priced as before.
-- The function was STABLE; it is VOLATILE now (the trial writes, then undoes), and so are the previews that call it.
alter function app.preview_booking_change(uuid, jsonb) rename to preview_booking_change_pre3050;

-- the booking's total if the change were made with this rental charge: made as app.apply_booking_change makes it, priced,
-- read, and undone (nothing stays)
create function app.change_trial(p_booking uuid, p_vehicle uuid, p_pickup timestamptz, p_return timestamptz, p_days integer, p_rental bigint)
returns jsonb language plpgsql volatile security definer set search_path = public, app as $$
declare
  b bookings;
  r record;
  v_set program_settings;
  v_out jsonb;
begin
  select * into b from bookings where id = p_booking;
  v_set := app.settings(app.local_date(b.booked_at));
  begin
    select * into r from public.calc_rental_charge(p_pickup, p_days, b.daily_rate_cents, b.weekend_rate_cents, b.weekly_rate_cents, b.monthly_rate_cents,
                                                   'America/Toronto', b.multi_day_rate_cents);
    update bookings
       set vehicle_id = p_vehicle, pickup_at = p_pickup, return_at = p_return, original_return_at = p_return,
           billable_days = p_days, km_allowance_total = km_allowance_per_day * p_days,
           rate_applied = case when booking_type = 'owner' then 'none' else r.rate_applied end, daily_days = r.daily_days, weekend_days = r.weekend_days,
           rental_charge_cents = p_rental,
           discount_cents = case when booking_type = 'non_refundable' then public.calc_bps(p_rental, v_set.non_refundable_discount_bps) else 0 end
     where id = p_booking;
    perform app.sync_booking_price(p_booking);
    select jsonb_build_object('subtotal_cents', subtotal_at_booking_cents, 'hst_cents', hst_at_booking_cents, 'total_cents', total_due_at_booking_cents)
      into v_out from bookings where id = p_booking;
    raise exception using errcode = 'P0001', message = 'change-trial-dry-run';
  exception when others then
    if sqlerrm <> 'change-trial-dry-run' then raise; end if;
  end;
  return v_out;
end $$;
revoke all on function app.change_trial(uuid, uuid, timestamptz, timestamptz, integer, bigint) from public, anon, authenticated;
grant execute on function app.change_trial(uuid, uuid, timestamptz, timestamptz, integer, bigint) to service_role;

create function app.preview_booking_change(p_booking uuid, p_changes jsonb)
returns jsonb language plpgsql volatile security definer set search_path = public, app as $$
declare
  ch jsonb := coalesce(p_changes, '{}'::jsonb);
  v_typed bigint;
  v jsonb;
  b bookings;
  a jsonb;
  v_vehicle uuid; v_pickup timestamptz; v_return timestamptz; v_days integer;
  v_target bigint;
  v_pricing text := 'rates';
  r0 bigint; r1 bigint; r bigint;
  t0 bigint; t1 bigint;
  t jsonb;
  k integer;
begin
  if jsonb_typeof(ch) = 'object' and ch ? 'total_cents' then
    v_typed := nullif(ch ->> 'total_cents', '')::bigint;
    if v_typed is not null and v_typed < 0 then raise exception 'The total is an amount of $0.00 or more' using errcode = '22023'; end if;
    ch := ch - 'total_cents' - 'rental_charge_cents';
  end if;
  v := app.preview_booking_change_pre3050(p_booking, ch);
  select * into b from bookings where id = p_booking;
  a := app.booking_all_in(p_booking);
  v := v || jsonb_build_object('per_day_cents', (a ->> 'per_day_cents')::bigint, 'booked_days', (a ->> 'days')::integer);
  if not coalesce((v ->> 'ok')::boolean, false) or b.booking_type = 'owner' or v -> 'after' is null then return v; end if;
  v_vehicle := (v -> 'after' ->> 'vehicle_id')::uuid;
  v_pickup := (v -> 'after' ->> 'pickup_at')::timestamptz;
  v_return := (v -> 'after' ->> 'return_at')::timestamptz;
  v_days := (v -> 'after' ->> 'billable_days')::integer;
  r := (v -> 'after' ->> 'rental_charge_cents')::bigint;
  if v_typed is not null then
    v_target := v_typed; v_pricing := 'typed_total';
  elsif ch ? 'rental_charge_cents' then
    v_pricing := 'typed_rental';
  elsif (select array_agg(x order by x) from jsonb_object_keys(ch) x) = array['return_at'] and v_return > b.return_at
        and b.bill_to = 'renter' and coalesce(b.billable_days, 0) > 0 and coalesce((a ->> 'total_cents')::bigint, 0) > 0 then
    v_target := app.extension_all_in_target(p_booking, v_return); v_pricing := 'all_in_day';
  end if;
  if v_target is not null then
    -- the rental charge that lands the total on the target (the total grows with the rental charge and its HST)
    r0 := r;
    t0 := (app.change_trial(p_booking, v_vehicle, v_pickup, v_return, v_days, r0) ->> 'total_cents')::bigint;
    r1 := greatest(0, r0 + round((v_target - t0) * 10000.0 / (10000 + coalesce(b.hst_bps, 1300)))::bigint);
    t1 := (app.change_trial(p_booking, v_vehicle, v_pickup, v_return, v_days, r1) ->> 'total_cents')::bigint;
    r := case when t1 = v_target or t1 = t0 or r1 = r0 then r1 else greatest(0, r1 + round((v_target - t1)::numeric * (r1 - r0) / (t1 - t0))::bigint) end;
    for k in 0 .. 3 loop
      t1 := (app.change_trial(p_booking, v_vehicle, v_pickup, v_return, v_days, r) ->> 'total_cents')::bigint;
      exit when t1 = v_target or r = 0;
      r := greatest(0, r + case when t1 < v_target then 1 else -1 end);
    end loop;
  else
    return v || jsonb_build_object('pricing', v_pricing);
  end if;
  t := app.change_trial(p_booking, v_vehicle, v_pickup, v_return, v_days, r);
  return v || jsonb_build_object(
    'pricing', v_pricing,
    'changes', case when v_typed is not null then ch || jsonb_build_object('total_cents', v_typed) else ch end,
    'after', (v -> 'after') || jsonb_build_object('rental_charge_cents', r) || t,
    'difference_cents', (t ->> 'subtotal_cents')::bigint - b.subtotal_at_booking_cents,
    'hst_cents', (t ->> 'hst_cents')::bigint - b.hst_at_booking_cents,
    'total_difference_cents', (t ->> 'total_cents')::bigint - b.total_due_at_booking_cents);
end $$;
revoke all on function app.preview_booking_change(uuid, jsonb) from public, anon, authenticated;
select pg_temp.copy_grants('app.preview_booking_change(uuid, jsonb)'::regprocedure, 'app.preview_booking_change_pre3050(uuid, jsonb)'::regprocedure);
alter function app.propose_preview(uuid, jsonb) volatile;
alter function public.my_booking_change_preview(uuid, jsonb) volatile;
alter function app.calendar_preview_change(uuid, jsonb, timestamptz) volatile;
-- Propose a change passes the total staff typed (HST included) to the preview, which solves the rental charge for it; the
-- form then proposes that rental charge (the renter agrees to the total shown)
select pg_temp.patch_fn('app.propose_preview(uuid, jsonb)'::regprocedure,
  $o$then to_jsonb((p_ ->> 'rental_charge_cents')::bigint) end));$o$,
  $n$then to_jsonb((p_ ->> 'rental_charge_cents')::bigint) end,
    'total_cents', case when nullif(p_ ->> 'total_cents', '') is not null then to_jsonb((p_ ->> 'total_cents')::bigint) end));$n$);
-- the calendar's change shows the rental charge the change lands on (the same preview), not its own count at the rates
select pg_temp.patch_fn('app.calendar_preview_change(uuid, jsonb, timestamptz)'::regprocedure,
  $o$      v_out := v_out || jsonb_build_object('difference_cents', v_19 -> 'total_difference_cents',$o$,
  $n$      v_out := v_out || jsonb_build_object('new', coalesce(v_out -> 'new', '{}'::jsonb) || jsonb_build_object('rental_charge_cents', v_19 -> 'after' -> 'rental_charge_cents'))
                     || jsonb_build_object('difference_cents', v_19 -> 'total_difference_cents',$n$);
