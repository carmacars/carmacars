-- 1110_r35x_renter_dob.sql
-- Release 35, UX batch (docs/changes/2026-11-09-r35-ux-batch.md). SCHEMA_MARKER 1110.
-- The owner, November 9: "renters have the ability to extend rentals and to adjust all of the details on their profile
-- right? like dob and email and phone number and name".
-- Email and phone stay self-serve with their verification (ChangeEmail, SignInSettings, 0812). The name and the date of
-- birth: a renter sets or edits them in the profile while no licence of theirs is verified (the renter record, the account
-- and the account holder's driver change at once). Once a licence is verified (the date of birth drives the young driver
-- fees and the insurer's eligibility), a change is a correction request (0812's name_change_requests, now with the date of
-- birth), shown in the profile as waiting, which Sales, customer service or an Admin approve or decline against the licence
-- (the task goes to customer service's queue). Owners and investors keep 0812's Admin-only name change.
-- No applied migration is edited: app.self_profile_view, app.name_change_decide, app.name_change_pending and app.door are
-- wrapped (_pre1110).
set local check_function_bodies = off;

create or replace function pg_temp.copy_grants(p_new regprocedure, p_old regprocedure) returns void
language plpgsql as $$
declare g text;
begin
  execute format('revoke all on function %s from public, anon, authenticated', p_new);
  foreach g in array array['anon', 'authenticated', 'service_role'] loop
    if has_function_privilege(g, p_old, 'execute') then execute format('grant execute on function %s to %I', p_new, g); end if;
  end loop;
end $$;

alter table name_change_requests
  add column if not exists current_dob date,
  add column if not exists requested_dob date;
comment on column name_change_requests.requested_dob is 'A renter''s date of birth correction (1110), checked against the licence: approving changes the renter and the account holder''s driver. Null: the name only.';

-- a licence of the renter is verified: the name and the date of birth are checked against it from then on
create or replace function app.renter_identity_locked(p_renter uuid) returns boolean
language sql stable security definer set search_path = public, app as $$
  select exists (select 1 from renters r where r.id = p_renter and r.identity_status = 'verified')
      or exists (select 1 from drivers d where d.renter_id = p_renter and d.is_account_holder and d.identity_status = 'verified')
$$;

-- p: legal_name, date_of_birth (YYYY-MM-DD), reason. Saved at once while no licence is verified; a correction request after.
create or replace function app.profile_identity_save(p_by uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  r renters;
  v_name text := nullif(btrim(coalesce(p ->> 'legal_name', '')), '');
  v_dob date;
  v_reason text := nullif(btrim(coalesce(p ->> 'reason', '')), '');
  v_age integer;
  n name_change_requests;
begin
  select * into r from renters where user_id = p_by limit 1;
  if r.id is null then raise exception 'Your details are saved with your first booking request' using errcode = 'P0002'; end if;
  begin
    v_dob := nullif(p ->> 'date_of_birth', '')::date;
  exception when others then raise exception 'Enter the date of birth as on your licence' using errcode = '22023';
  end;
  if v_name is not null and length(v_name) < 3 then raise exception 'Write your full legal name, as on your licence' using errcode = '22023'; end if;
  if v_dob is not null then
    v_age := extract(year from age(app.today(), v_dob));
    if v_dob > app.today() or v_age > 110 then raise exception 'Check the date of birth' using errcode = '22023'; end if;
    if v_age < 16 then raise exception 'A driver is 16 or older' using errcode = '22023'; end if;
  end if;
  v_name := coalesce(v_name, r.legal_name);
  if v_name is not distinct from r.legal_name and (v_dob is null or v_dob is not distinct from r.date_of_birth) then
    raise exception 'Nothing changed' using errcode = '22023';
  end if;
  if not app.renter_identity_locked(r.id) then
    update renters set legal_name = v_name, date_of_birth = coalesce(v_dob, date_of_birth) where id = r.id;
    update users set full_name = v_name where id = p_by;
    update drivers set full_name = v_name, date_of_birth = coalesce(v_dob, date_of_birth) where renter_id = r.id and is_account_holder;
    return jsonb_build_object('ok', true, 'saved', true, 'legal_name', v_name, 'date_of_birth', coalesce(v_dob, r.date_of_birth));
  end if;
  if v_reason is null or length(v_reason) < 5 then raise exception 'Say why it changes (a typo, a legal name change): it is checked against your licence' using errcode = '22023'; end if;
  update name_change_requests set status = 'cancelled', decided_at = now(), decision_note = 'Replaced by a new request' where user_id = p_by and status = 'requested';
  insert into name_change_requests (user_id, current_name, requested_name, reason, current_dob, requested_dob)
  values (p_by, r.legal_name, v_name, left(v_reason, 500), r.date_of_birth, case when v_dob is distinct from r.date_of_birth then v_dob end) returning * into n;
  perform app.raise_task(p_type => 'name_change_approve', p_queue => 'cs',
    p_title => left(format('Check against the licence: %s%s', case when v_name <> r.legal_name then format('name %s to %s', r.legal_name, v_name) else r.legal_name end,
                           case when n.requested_dob is not null then format(', date of birth %s to %s', coalesce(r.date_of_birth::text, 'none'), n.requested_dob) else '' end), 200),
    p_detail => left(format('A verified renter asked to correct their details: %s. Approve only if the licence shows them.', v_reason), 2000),
    p_renter => r.id, p_related_table => 'name_change_requests', p_related_id => n.id, p_dedupe => 'name_change_approve:' || n.id, p_created_by => p_by);
  return jsonb_build_object('ok', true, 'pending', true, 'id', n.id);
end $$;
comment on function app.profile_identity_save(uuid, jsonb) is 'A renter''s name and date of birth (1110): saved at once while no licence is verified, a correction request for Sales, customer service or an Admin after.';

-- the profile: the date of birth, whether it is checked against a licence now, and a waiting correction with its date
alter function app.self_profile_view(uuid, jsonb) rename to self_profile_view_pre1110;
create function app.self_profile_view(p_by uuid, p jsonb default '{}'::jsonb) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare
  v jsonb := app.self_profile_view_pre1110(p_by, p);
  r renters;
begin
  select * into r from renters where user_id = (v ->> 'user_id')::uuid limit 1;
  if r.id is null then return v; end if;
  return v || jsonb_build_object('renter', true, 'date_of_birth', r.date_of_birth, 'identity_locked', app.renter_identity_locked(r.id),
    'pending', (select jsonb_build_object('id', n.id, 'requested_name', n.requested_name, 'requested_dob', n.requested_dob, 'reason', n.reason, 'requested_at', n.requested_at)
                  from name_change_requests n where n.user_id = r.user_id and n.status = 'requested'));
end $$;
select pg_temp.copy_grants('app.self_profile_view(uuid, jsonb)'::regprocedure, 'app.self_profile_view_pre1110(uuid, jsonb)'::regprocedure);

-- Sales, customer service or an Admin decide a renter's correction; an Admin alone decides an owner's or investor's
alter function app.name_change_decide(uuid, jsonb) rename to name_change_decide_pre1110;
create function app.name_change_decide(p_by uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  n name_change_requests;
  v text := coalesce(p ->> 'decision', 'approve');
  v_note text := nullif(btrim(coalesce(p ->> 'note', '')), '');
  v_renter uuid;
  v_out jsonb;
begin
  select * into n from name_change_requests where id::text = p ->> 'id';
  if n.id is null then raise exception 'Request not found' using errcode = 'P0002'; end if;
  select r.id into v_renter from renters r where r.user_id = n.user_id limit 1;
  if v in ('approve', 'decline') and not app.user_is_admin(p_by) then
    if v_renter is null or not app.user_va_has(p_by, 'cs', 'sales') then
      raise exception 'An Admin approves or declines a name change (a renter''s correction: Sales, customer service or an Admin)' using errcode = '42501';
    end if;
    if n.status <> 'requested' then raise exception 'This request was already %', n.status using errcode = '23514'; end if;
    update name_change_requests set status = case v when 'approve' then 'approved' else 'declined' end, decided_by = p_by, decided_at = now(), decision_note = v_note where id = n.id;
    if v = 'approve' then
      update users set full_name = n.requested_name where id = n.user_id;
      update renters set legal_name = n.requested_name where user_id = n.user_id;
    end if;
    update tasks set status = 'done', completed_at = now(), completed_by = p_by, completion_note = initcap(v) || 'd' || coalesce(': ' || v_note, '')
     where task_type = 'name_change_approve' and related_table = 'name_change_requests' and related_id = n.id and status in ('open', 'in_progress', 'waiting');
    v_out := jsonb_build_object('ok', true, 'status', case v when 'approve' then 'approved' else 'declined' end, 'user_id', n.user_id);
  else
    v_out := app.name_change_decide_pre1110(p_by, p);
  end if;
  if v = 'approve' and v_renter is not null then
    update drivers set full_name = n.requested_name, date_of_birth = coalesce(n.requested_dob, date_of_birth) where renter_id = v_renter and is_account_holder;
    if n.requested_dob is not null then update renters set date_of_birth = n.requested_dob where id = v_renter; end if;
  end if;
  return v_out;
end $$;
select pg_temp.copy_grants('app.name_change_decide(uuid, jsonb)'::regprocedure, 'app.name_change_decide_pre1110(uuid, jsonb)'::regprocedure);

-- the waiting corrections of one renter for Sales and customer service too (with the date of birth)
alter function app.name_change_pending(uuid, jsonb) rename to name_change_pending_pre1110;
create function app.name_change_pending(p_by uuid, p jsonb default '{}'::jsonb) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare
  v_user uuid := (select r.user_id from renters r where r.id::text = coalesce(p ->> 'renter_id', ''));
begin
  if not app.user_is_admin(p_by) then
    if not (app.user_va_has(p_by, 'cs', 'sales') and p ? 'renter_id') then raise exception 'Admin only' using errcode = '42501'; end if;
  end if;
  if p ? 'renter_id' then
    if v_user is null then return '[]'::jsonb; end if;
    return coalesce((select jsonb_agg(jsonb_build_object('id', n.id, 'user_id', n.user_id, 'current_name', n.current_name, 'requested_name', n.requested_name,
                                                         'current_dob', n.current_dob, 'requested_dob', n.requested_dob, 'reason', n.reason, 'requested_at', n.requested_at) order by n.requested_at)
                       from name_change_requests n where n.status = 'requested' and n.user_id = v_user), '[]'::jsonb);
  end if;
  return app.name_change_pending_pre1110(p_by, p);
end $$;
select pg_temp.copy_grants('app.name_change_pending(uuid, jsonb)'::regprocedure, 'app.name_change_pending_pre1110(uuid, jsonb)'::regprocedure);

alter function app.door(uuid, text, text, text, jsonb) rename to door_pre1110;
create function app.door(p_user uuid, p_aal text, p_call text, p_name text, p jsonb default '{}'::jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
begin
  if p_call = 'ops_do' and p_name = 'profile_identity_save' then
    perform app.door_begin(p_user, p_aal);
    return app.profile_identity_save(p_user, coalesce(p, '{}'::jsonb) - '_va');
  end if;
  return app.door_pre1110(p_user, p_aal, p_call, p_name, p);
end $$;
select pg_temp.copy_grants('app.door(uuid, text, text, text, jsonb)'::regprocedure, 'app.door_pre1110(uuid, text, text, text, jsonb)'::regprocedure);

do $$
declare f record;
begin
  for f in select p.oid::regprocedure as sig from pg_proc p join pg_namespace n on n.oid = p.pronamespace
            where n.nspname = 'app' and p.proname = any (array['renter_identity_locked', 'profile_identity_save', 'self_profile_view_pre1110', 'name_change_decide_pre1110',
                    'name_change_pending_pre1110', 'door_pre1110'])
  loop
    execute format('revoke all on function %s from public, anon, authenticated', f.sig);
    execute format('grant execute on function %s to service_role', f.sig);
  end loop;
end $$;

-- The guides of the UX batch: Sales get a renter ready, the Prepare checklist, commission on add-ons, the renter's date of birth
-- GUIDES 1110 START (generated by supabase/seed/1110_gen_guides.mjs from docs/guides/content; do not edit by hand)
select app.guide_release_section('renter', 'before-pickup', 'chapter', 'sign-and-pay', 'Your booking is confirmed. A few things are left: your licence photos, a selfie and proof of coverage, a signature from each additional driver, and the deposit.

## Your booking page

Every booking opens with a large photo of your car, its name, the status and a clock: "Pickup in 2 days 4 h", or "Return by Sun 7 PM" while you have the car.

1. Open **Trips**, then your booking. The status is on the photo, for example Confirmed, with your booking number.
2. Under the photo: when and where you pick up and return the car (tap a place to open it in Maps), the kilometres included, the fuel rule and the deposit.
3. Next step tells you the one thing still needed, with its button, for example **Upload documents**. When nothing is needed it says you are all set, with **Add to calendar**.
4. Manage your trip holds **Licence and coverage**, **Extend**, **Ask to change dates**, **Message us**, **Call us**, **Add a driver**, **Documents** and **Cancel booking**.

![](/guides/img/renter-08-booking-confirmed-desktop-b5603da5.jpg "desktop; size: 1440 972; address: carmacars.ca/account/bookings/CC-10003; pins: 1 10.4 54.9, 2 9.4 78.9, 3 92.4 76.9")

Money, on the right (below on a phone), shows what you paid and what is owing, part by part, with a **Pay** button when something is open and your receipts. **Price details** opens every line of the price. Progress shows how many steps are done; **Every step** lists them, from Request sent to Statement.

## Your rental, step by step

**Your rental, step by step** on your booking opens the walkthrough: the whole rental in four stages, Before pickup, At pickup, On the road and The return.

1. Press **Start the walkthrough** (**Continue** once you have begun). The top shows how many steps are done and which stage you are at.
2. The step to do now is in black at the top. A task opens its page, for example **Add your licence** or **Sign the agreement**, and is ticked once it is done. A step to read (what to bring, where we meet, your own photos, the road rules, what to do if something goes wrong, how to bring the car back) has **Got it**.
3. At pickup, the walk-around: we photograph the car with you and you sign the condition report on your phone. Once done, **See the photo report** opens every photo.
4. Every stage is listed below with its steps, so you can read ahead.

## Upload your licence, selfie and coverage

Do this at least 24 hours before pickup. It takes a few minutes with your phone.

1. On your booking, press **Upload documents** (or **Licence and coverage**).
2. Licence, front: lay the licence on a dark surface with all four corners visible. Press **Take a photo**, or **Choose from my photos** for a photo already on your phone.
3. Licence, back: do the same for the back.
4. Selfie with your licence: hold the licence beside your face, then press **Take selfie**.
5. Coverage for damage to the car: add what your option asks for, then press **Take a photo** or **Choose from my photos** (a PDF works too). Not sure your credit card covers rentals? Use the card coverage checker first.

While your booking still needs them, **Your trips** shows **Upload your licence**, **Upload proof of insurance** and **Check if your credit card covers rentals**, and our request and offer emails link straight to the licence upload.

![](/guides/img/renter-09-verify-desktop-d20f668d.jpg "desktop; size: 1440 1232; address: carmacars.ca/account/bookings/CC-10003/verify; pins: 2 18.5 65.3, 3 50.0 63.6, 4 81.2 63.6, 5 50.0 95.3")

| Your option | What we need |
| --- | --- |
| Option 1, OPCF 27 on your own policy | Your insurer, the policy number and its expiry (after your return date), and the policy or endorsement that shows OPCF 27, as a PDF or photos (up to 6 pages). |
| Option 2, your credit card''s rental coverage | Pay with that card: it must be a credit card (debit and prepaid cards are refused) in your name. Tick that it covers this kind of car for this many days. The card''s benefits document is optional. |
| Option 3, the CarmaCars Protection Plan | Ask for it on your booking; we confirm it once it is active. |

> Good to know: Which cards include rental car coverage? `carmacars.ca/credit-card-rental-coverage` lists them, with each card''s car value limit (MSRP), its longest rental and a link to its guide. Most cards stop at a car priced $65,000 or $85,000, and some of our cars are priced higher. Only your card''s issuer decides a claim: call the number on the back of your card before you rent.

> Tip: A person checks your proof and approves it, or tells you what to fix. The car is handed over only once it is approved. Changing your option replaces the earlier proof. We remind you 48 and 24 hours before pickup while it is missing. We delete licence and face photos 90 days after your rental ends.

## Additional drivers

Each additional driver signs the agreement with their own link.

1. When the agreement is ready, each driver with an email gets their own signing link.
2. On your booking, press **Copy their signing link** to send it yourself, or **Send a new link**.
3. Each driver adds their own licence photos and selfie, like you did.

> Watch out: Signing links expire after 72 hours. A new link ends the older one, so always send the newest.

## Add something to your trip

Until 24 hours before pickup (or the notice an add-on needs), add add-ons from your booking.

1. On your booking, under Add-ons, press **Add something to your trip**.
2. Tick the add-on you want. Its price shows below.
3. Press **Add and pay**. It is charged at once on the card you paid with, and shows on your booking and receipt.
4. A chauffeur needs our confirmation: press **Ask for it**. We confirm it and charge your card then.

No card on file for this booking? The add-on is added and waits for payment: press **Pay for your add-ons** under Add-ons, enter a card and press **Pay**. It is charged at once; that card is not kept.

> Tip: If you cancel, add-ons are refunded like the rest of your booking. Flowers and a chauffeur are not refunded once their notice before pickup has started.

## What to bring to pickup

- Your original licence. A photo is not enough.
- The card you paid with. The deposit is taken on it about an hour before pickup.
- A few minutes to walk around the car with us. We photograph it together.

## Check in yourself (release 28)

From 24 hours before pickup, **Check in yourself** on your booking: take the photos of the car as you get it (pick them all at once from your camera roll: all sides, odometer, fuel gauge, inside, any damage), the odometer and the fuel. If your booking is ready, you are checked in at once; otherwise a team member confirms it. If you do not take the photos, we take them.

## If we change your coverage (release 35)

If your card does not cover the car, or you ask for the CarmaCars Protection Plan, our team can switch your booking for you. You get an email with what changed and the new total. On an offer you approve the new price. On a booking you have paid, any extra is sent to you as a secure payment link, or you pay it from your booking page. You then do not need to send a card coverage document. If you go back to your card, the booking page asks you to confirm it again.

## Your accident card

Your booking shows your **Accident card**: what to do after an accident, and the coverage of this booking.

- With your own auto policy (OPCF 27): your insurer and policy number, as on the proof you uploaded.
- With your credit card coverage: the card and its coverage provider.
- With the Protection Plan: the provider, the policy number, the claims phone and your plan reference.

Press **Print it** to print the card at its size for the glovebox, or keep the page on your phone.', 'Before pickup', 'Upload your licence and coverage, send driver links, and know what to bring.',
  'Your booking is confirmed. A few things are left: your licence photos, a selfie and proof of coverage, a signature from each additional driver, and the deposit.

## Your booking page

Every booking opens with a large photo of your car, its name, the status and a clock: "Pickup in 2 days 4 h", or "Return by Sun 7 PM" while you have the car.

1. Open **Trips**, then your booking. The status is on the photo, for example Confirmed, with your booking number.
2. Under the photo: when and where you pick up and return the car (tap a place to open it in Maps), the kilometres included, the fuel rule and the deposit.
3. Next step tells you the one thing still needed, with its button, for example **Upload documents**. When nothing is needed it says you are all set, with **Add to calendar**.
4. Manage your trip holds **Licence and coverage**, **Extend**, **Ask to change dates**, **Message us**, **Call us**, **Add a driver**, **Documents** and **Cancel booking**.

![](/guides/img/renter-08-booking-confirmed-desktop-b5603da5.jpg "desktop; size: 1440 972; address: carmacars.ca/account/bookings/CC-10003; pins: 1 10.4 54.9, 2 9.4 78.9, 3 92.4 76.9")

Money, on the right (below on a phone), shows what you paid and what is owing, part by part, with a **Pay** button when something is open and your receipts. **Price details** opens every line of the price. Progress shows how many steps are done; **Every step** lists them, from Request sent to Statement.

## Your rental, step by step

**Your rental, step by step** on your booking opens the walkthrough: the whole rental in four stages, Before pickup, At pickup, On the road and The return.

1. Press **Start the walkthrough** (**Continue** once you have begun). The top shows how many steps are done and which stage you are at.
2. The step to do now is in black at the top. A task opens its page, for example **Add your licence** or **Sign the agreement**, and is ticked once it is done. A step to read (what to bring, where we meet, your own photos, the road rules, what to do if something goes wrong, how to bring the car back) has **Got it**.
3. At pickup, the walk-around: we photograph the car with you and you sign the condition report on your phone. Once done, **See the photo report** opens every photo.
4. Every stage is listed below with its steps, so you can read ahead.

## Upload your licence, selfie and coverage

Do this at least 24 hours before pickup. It takes a few minutes with your phone.

1. On your booking, press **Upload documents** (or **Licence and coverage**).
2. Licence, front: lay the licence on a dark surface with all four corners visible. Press **Take a photo**, or **Choose from my photos** for a photo already on your phone.
3. Licence, back: do the same for the back.
4. Selfie with your licence: hold the licence beside your face, then press **Take selfie**.
5. Coverage for damage to the car: add what your option asks for, then press **Take a photo** or **Choose from my photos** (a PDF works too). Not sure your credit card covers rentals? Use the card coverage checker first.

While your booking still needs them, **Your trips** shows **Upload your licence**, **Upload proof of insurance** and **Check if your credit card covers rentals**, and our request and offer emails link straight to the licence upload.

![](/guides/img/renter-09-verify-desktop-d20f668d.jpg "desktop; size: 1440 1232; address: carmacars.ca/account/bookings/CC-10003/verify; pins: 2 18.5 65.3, 3 50.0 63.6, 4 81.2 63.6, 5 50.0 95.3")

| Your option | What we need |
| --- | --- |
| Option 1, OPCF 27 on your own policy | Your insurer, the policy number and its expiry (after your return date), and the policy or endorsement that shows OPCF 27, as a PDF or photos (up to 6 pages). |
| Option 2, your credit card''s rental coverage | Pay with that card: it must be a credit card (debit and prepaid cards are refused) in your name. Tick that it covers this kind of car for this many days. The card''s benefits document is optional. |
| Option 3, the CarmaCars Protection Plan | Ask for it on your booking; we confirm it once it is active. |

> Good to know: Which cards include rental car coverage? `carmacars.ca/credit-card-rental-coverage` lists them, with each card''s car value limit (MSRP), its longest rental and a link to its guide. Most cards stop at a car priced $65,000 or $85,000, and some of our cars are priced higher. Only your card''s issuer decides a claim: call the number on the back of your card before you rent.

> Tip: A person checks your proof and approves it, or tells you what to fix. The car is handed over only once it is approved. Changing your option replaces the earlier proof. We remind you 48 and 24 hours before pickup while it is missing. We delete licence and face photos 90 days after your rental ends.

## Additional drivers

Each additional driver signs the agreement with their own link.

1. When the agreement is ready, each driver with an email gets their own signing link.
2. On your booking, press **Copy their signing link** to send it yourself, or **Send a new link**.
3. Each driver adds their own licence photos and selfie, like you did.

> Watch out: Signing links expire after 72 hours. A new link ends the older one, so always send the newest.

## Add something to your trip

Until 24 hours before pickup (or the notice an add-on needs), add add-ons from your booking.

1. On your booking, under Add-ons, press **Add something to your trip**.
2. Tick the add-on you want. Its price shows below.
3. Press **Add and pay**. It is charged at once on the card you paid with, and shows on your booking and receipt.
4. A chauffeur needs our confirmation: press **Ask for it**. We confirm it and charge your card then.

No card on file for this booking? The add-on is added and waits for payment: press **Pay for your add-ons** under Add-ons, enter a card and press **Pay**. It is charged at once; that card is not kept.

> Tip: If you cancel, add-ons are refunded like the rest of your booking. Flowers and a chauffeur are not refunded once their notice before pickup has started.

## What to bring to pickup

- Your original licence. A photo is not enough.
- The card you paid with. The deposit is taken on it about an hour before pickup.
- A few minutes to walk around the car with us. We photograph it together.

## Check in yourself (release 28)

From 24 hours before pickup, **Check in yourself** on your booking: take the photos of the car as you get it (pick them all at once from your camera roll: all sides, odometer, fuel gauge, inside, any damage), the odometer and the fuel. If your booking is ready, you are checked in at once; otherwise a team member confirms it. If you do not take the photos, we take them.

## If we change your coverage (release 35)

If your card does not cover the car, or you ask for the CarmaCars Protection Plan, our team can switch your booking for you. You get an email with what changed and the new total. On an offer you approve the new price. On a booking you have paid, any extra is sent to you as a secure payment link, or you pay it from your booking page. You then do not need to send a card coverage document. If you go back to your card, the booking page asks you to confirm it again.

## Your accident card

Your booking shows your **Accident card**: what to do after an accident, and the coverage of this booking.

- With your own auto policy (OPCF 27): your insurer and policy number, as on the proof you uploaded.
- With your credit card coverage: the card and its coverage provider.
- With the Protection Plan: the provider, the policy number, the claims phone and your plan reference.

Press **Print it** to print the card at its size for the glovebox, or keep the page on your phone.

### Your name and date of birth
Set them in your profile. Once your licence is verified they must match it: a change is sent as a correction request, shown as waiting until our team checks it against your licence.',
  '<p class="gd-p">Your booking is confirmed. A few things are left: your licence photos, a selfie and proof of coverage, a signature from each additional driver, and the deposit.</p><section class="gd-task" id="before-pickup-your-booking-page" data-gd-task><h2 class="gd-h2">Your booking page</h2><p class="gd-p">Every booking opens with a large photo of your car, its name, the status and a clock: &quot;Pickup in 2 days 4 h&quot;, or &quot;Return by Sun 7 PM&quot; while you have the car.</p><div class="gd-stepblock gd-stepblock--below"><div class="gd-stepcol"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Open <b class="gd-ui">Trips</b>, then your booking. The status is on the photo, for example Confirmed, with your booking number.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Under the photo: when and where you pick up and return the car (tap a place to open it in Maps), the kilometres included, the fuel rule and the deposit.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Next step tells you the one thing still needed, with its button, for example <b class="gd-ui">Upload documents</b>. When nothing is needed it says you are all set, with <b class="gd-ui">Add to calendar</b>.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">Manage your trip holds <b class="gd-ui">Licence and coverage</b>, <b class="gd-ui">Extend</b>, <b class="gd-ui">Ask to change dates</b>, <b class="gd-ui">Message us</b>, <b class="gd-ui">Call us</b>, <b class="gd-ui">Add a driver</b>, <b class="gd-ui">Documents</b> and <b class="gd-ui">Cancel booking</b>.</div></li></ol></div><figure class="gd-fig gd-fig--desk"><div class="gd-browser"><div class="gd-bar" aria-hidden="true"><i></i><i></i><i></i><span class="gd-addr">carmacars.ca/account/bookings/CC-10003</span></div><div class="gd-imgwrap" style="aspect-ratio:1440/972"><img src="/guides/img/renter-08-booking-confirmed-desktop-b5603da5.jpg" alt="" loading="lazy" decoding="async" width="1440" height="972"><span class="gd-pin" style="left:10.4%;top:54.9%" aria-hidden="true">1</span><span class="gd-pin" style="left:9.4%;top:78.9%" aria-hidden="true">2</span><span class="gd-pin" style="left:92.4%;top:76.9%" aria-hidden="true">3</span></div></div></figure></div><p class="gd-p">Money, on the right (below on a phone), shows what you paid and what is owing, part by part, with a <b class="gd-ui">Pay</b> button when something is open and your receipts. <b class="gd-ui">Price details</b> opens every line of the price. Progress shows how many steps are done; <b class="gd-ui">Every step</b> lists them, from Request sent to Statement.</p></section><section class="gd-task" id="before-pickup-your-rental-step-by-step" data-gd-task><h2 class="gd-h2">Your rental, step by step</h2><p class="gd-p"><b class="gd-ui">Your rental, step by step</b> on your booking opens the walkthrough: the whole rental in four stages, Before pickup, At pickup, On the road and The return.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Press <b class="gd-ui">Start the walkthrough</b> (<b class="gd-ui">Continue</b> once you have begun). The top shows how many steps are done and which stage you are at.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">The step to do now is in black at the top. A task opens its page, for example <b class="gd-ui">Add your licence</b> or <b class="gd-ui">Sign the agreement</b>, and is ticked once it is done. A step to read (what to bring, where we meet, your own photos, the road rules, what to do if something goes wrong, how to bring the car back) has <b class="gd-ui">Got it</b>.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">At pickup, the walk-around: we photograph the car with you and you sign the condition report on your phone. Once done, <b class="gd-ui">See the photo report</b> opens every photo.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">Every stage is listed below with its steps, so you can read ahead.</div></li></ol></div></section><section class="gd-task" id="before-pickup-upload-your-licence-selfie-and-coverage" data-gd-task><h2 class="gd-h2">Upload your licence, selfie and coverage</h2><p class="gd-p">Do this at least 24 hours before pickup. It takes a few minutes with your phone.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">On your booking, press <b class="gd-ui">Upload documents</b> (or <b class="gd-ui">Licence and coverage</b>).</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Licence, front: lay the licence on a dark surface with all four corners visible. Press <b class="gd-ui">Take a photo</b>, or <b class="gd-ui">Choose from my photos</b> for a photo already on your phone.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Licence, back: do the same for the back.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">Selfie with your licence: hold the licence beside your face, then press <b class="gd-ui">Take selfie</b>.</div></li><li><span class="gd-n" aria-hidden="true">5</span><div class="gd-t">Coverage for damage to the car: add what your option asks for, then press <b class="gd-ui">Take a photo</b> or <b class="gd-ui">Choose from my photos</b> (a PDF works too). Not sure your credit card covers rentals? Use the card coverage checker first.</div></li></ol></div><p class="gd-p">While your booking still needs them, <b class="gd-ui">Your trips</b> shows <b class="gd-ui">Upload your licence</b>, <b class="gd-ui">Upload proof of insurance</b> and <b class="gd-ui">Check if your credit card covers rentals</b>, and our request and offer emails link straight to the licence upload.</p><div class="gd-figblock"><figure class="gd-fig gd-fig--desk"><div class="gd-browser"><div class="gd-bar" aria-hidden="true"><i></i><i></i><i></i><span class="gd-addr">carmacars.ca/account/bookings/CC-10003/verify</span></div><div class="gd-imgwrap" style="aspect-ratio:1440/1232"><img src="/guides/img/renter-09-verify-desktop-d20f668d.jpg" alt="" loading="lazy" decoding="async" width="1440" height="1232"><span class="gd-pin" style="left:18.5%;top:65.3%" aria-hidden="true">2</span><span class="gd-pin" style="left:50%;top:63.6%" aria-hidden="true">3</span><span class="gd-pin" style="left:81.2%;top:63.6%" aria-hidden="true">4</span><span class="gd-pin" style="left:50%;top:95.3%" aria-hidden="true">5</span></div></div></figure></div><div class="gd-tablewrap"><table class="gd-table"><thead><tr><th scope="col">Your option</th><th scope="col">What we need</th></tr></thead><tbody><tr><td>Option 1, OPCF 27 on your own policy</td><td>Your insurer, the policy number and its expiry (after your return date), and the policy or endorsement that shows OPCF 27, as a PDF or photos (up to 6 pages).</td></tr><tr><td>Option 2, your credit card&#39;s rental coverage</td><td>Pay with that card: it must be a credit card (debit and prepaid cards are refused) in your name. Tick that it covers this kind of car for this many days. The card&#39;s benefits document is optional.</td></tr><tr><td>Option 3, the CarmaCars Protection Plan</td><td>Ask for it on your booking; we confirm it once it is active.</td></tr></tbody></table></div><aside class="gd-box"><span class="gd-lbl">Good to know</span><div>Which cards include rental car coverage? <span class="gd-url">carmacars.ca/credit-card-rental-coverage</span> lists them, with each card&#39;s car value limit (MSRP), its longest rental and a link to its guide. Most cards stop at a car priced $65,000 or $85,000, and some of our cars are priced higher. Only your card&#39;s issuer decides a claim: call the number on the back of your card before you rent.</div></aside><aside class="gd-box"><span class="gd-lbl">Tip</span><div>A person checks your proof and approves it, or tells you what to fix. The car is handed over only once it is approved. Changing your option replaces the earlier proof. We remind you 48 and 24 hours before pickup while it is missing. We delete licence and face photos 90 days after your rental ends.</div></aside></section><section class="gd-task" id="before-pickup-additional-drivers" data-gd-task><h2 class="gd-h2">Additional drivers</h2><p class="gd-p">Each additional driver signs the agreement with their own link.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">When the agreement is ready, each driver with an email gets their own signing link.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">On your booking, press <b class="gd-ui">Copy their signing link</b> to send it yourself, or <b class="gd-ui">Send a new link</b>.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Each driver adds their own licence photos and selfie, like you did.</div></li></ol></div><aside class="gd-box gd-box--warn"><span class="gd-lbl">Watch out</span><div>Signing links expire after 72 hours. A new link ends the older one, so always send the newest.</div></aside></section><section class="gd-task" id="before-pickup-add-something-to-your-trip" data-gd-task><h2 class="gd-h2">Add something to your trip</h2><p class="gd-p">Until 24 hours before pickup (or the notice an add-on needs), add add-ons from your booking.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">On your booking, under Add-ons, press <b class="gd-ui">Add something to your trip</b>.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Tick the add-on you want. Its price shows below.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Press <b class="gd-ui">Add and pay</b>. It is charged at once on the card you paid with, and shows on your booking and receipt.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">A chauffeur needs our confirmation: press <b class="gd-ui">Ask for it</b>. We confirm it and charge your card then.</div></li></ol></div><p class="gd-p">No card on file for this booking? The add-on is added and waits for payment: press <b class="gd-ui">Pay for your add-ons</b> under Add-ons, enter a card and press <b class="gd-ui">Pay</b>. It is charged at once; that card is not kept.</p><aside class="gd-box"><span class="gd-lbl">Tip</span><div>If you cancel, add-ons are refunded like the rest of your booking. Flowers and a chauffeur are not refunded once their notice before pickup has started.</div></aside></section><section class="gd-task" id="before-pickup-what-to-bring-to-pickup" data-gd-task><h2 class="gd-h2">What to bring to pickup</h2><ul class="gd-ul"><li>Your original licence. A photo is not enough.</li><li>The card you paid with. The deposit is taken on it about an hour before pickup.</li><li>A few minutes to walk around the car with us. We photograph it together.</li></ul></section><section class="gd-task" id="before-pickup-check-in-yourself-release-28" data-gd-task><h2 class="gd-h2">Check in yourself (release 28)</h2><p class="gd-p">From 24 hours before pickup, <b class="gd-ui">Check in yourself</b> on your booking: take the photos of the car as you get it (pick them all at once from your camera roll: all sides, odometer, fuel gauge, inside, any damage), the odometer and the fuel. If your booking is ready, you are checked in at once; otherwise a team member confirms it. If you do not take the photos, we take them.</p></section><section class="gd-task" id="before-pickup-if-we-change-your-coverage-release-35" data-gd-task><h2 class="gd-h2">If we change your coverage (release 35)</h2><p class="gd-p">If your card does not cover the car, or you ask for the CarmaCars Protection Plan, our team can switch your booking for you. You get an email with what changed and the new total. On an offer you approve the new price. On a booking you have paid, any extra is sent to you as a secure payment link, or you pay it from your booking page. You then do not need to send a card coverage document. If you go back to your card, the booking page asks you to confirm it again.</p></section><section class="gd-task" id="before-pickup-your-accident-card" data-gd-task><h2 class="gd-h2">Your accident card</h2><p class="gd-p">Your booking shows your <b class="gd-ui">Accident card</b>: what to do after an accident, and the coverage of this booking.</p><ul class="gd-ul"><li>With your own auto policy (OPCF 27): your insurer and policy number, as on the proof you uploaded.</li><li>With your credit card coverage: the card and its coverage provider.</li><li>With the Protection Plan: the provider, the policy number, the claims phone and your plan reference.</li></ul><p class="gd-p">Press <b class="gd-ui">Print it</b> to print the card at its size for the glovebox, or keep the page on your phone.</p><h3 class="gd-h3">Your name and date of birth</h3><p class="gd-p">Set them in your profile. Once your licence is verified they must match it: a change is sent as a correction request, shown as waiting until our team checks it against your licence.</p></section>');
select app.guide_release_section('va', 'sales', 'chapter', 'fleet', 'You turn enquiries into bookings and owners into fleet: requests and offers, quotes for callers, and owner leads.

Your menu: To do, Today, My scorecard and My sales, then Requests and offers, Send an offer, Add a rental, New quote, Calendar and Buyer leads. The owners you bring in are on My sales.

## Requests, offers and new quotes

1. **Requests and offers**: the same queue customer service works, showing only what you can answer now. A request still with customer service is folded under "more not open to you yet", with the time it opens to you.
2. **Rentals** > **Bookings**: **My bookings**, every booking credited to you, offered by you or added by you, from the offer to the return, with its status, money and your commission (counting this month, waiting for approval, approved, paid).
3. **Send an offer**: one screen for a caller, sent at once, as in chapter 2. **New quote** still makes a request to offer later.
3. An offer that is out: **More actions** > **Edit the offer**, then **Save and send the update**.

![](/guides/img/va-sales-02-requests-desktop-2ab1d17d.jpg "desktop; size: 1230 580; address: carmacars.ca/va/requests; pins: 1 39.8 59.5")

> Tip: Your first reply target is 5 minutes, the "Quote sent" measure on your scorecard. Follow every offer out before it expires.

## Check the renter''s licence

Sales approve the renter''s licence like customer service: the licence front, the licence back and the selfie. The proof of coverage and the Protection Plan stay with customer service and Admins.

1. On **To do**, **Licences to check** lists each booking with an image waiting, the longest wait first. Press **Review the licence**.
2. On a booking, the card **Renter licence** has the same: press **Review the licence**.
3. Look at each image and each Flag line of the licence reader under the driver: no alteration, the selfie matches the licence photo.
4. One is wrong? Open **Reject this one** under it, type the reason the renter reads and press **Reject**. The renter is told and asked for a new image.
5. Then press **Approve all**: every image still waiting is approved at once. An image the system refuses is named with the reason.

> Tip: The booking history says who decided and the role, sales. Each opening of the images is logged and the links last one minute.

## In person or remote

Every Sales person works in one of two modes, on the same Sales screens. An Admin sets yours; it shows at the top of To do and on My sales.

|  | In person (Toronto) | Remote (anywhere) |
| --- | --- | --- |
| Commission | Under 50 rental days in the month 10%, from 50 days 15%, from 100 days 20% | Under 50 rental days 5%, from 50 days 10%, from 100 days 15% |
| Credit | Walk-ins, handovers you close, partner visits and the rentals you source | Only the rentals you source. A website request you answer with the first offer during one of your blocks counts as yours. Walk-ins and partner deals earn nothing |
| Hours | You choose | At least 20 hours a week of Thursday to Sunday afternoons (noon to 6 pm, Toronto time), replying within 15 minutes to the chats, texts and calls assigned to you |
| Every day | Nothing set | Marketplace and classified reposts, social media DM replies, three follow-ups on every quote, long-term and business outreach |
| Every month | Nothing set | 400 touches. Under 400 when the month ends, the month''s rate is one tier lower: 15% becomes 10%, 10% becomes 5%, 5% becomes 2.5% |

## Remote: your duties

On **To do**, **Remote duties** shows this month''s touches against 400, today''s checklist, the peak hours you scheduled this week and your reply time.

1. Most touches count by themselves: an offer you send, a message or text you send from the portal, a live chat you answer (once a day for each chat), a call or text from the phone line, an ad you post, a call or message to a car owner.
2. For anything else press **Log a touch**: choose the type and add the link of the post, profile or listing if there is one.
3. The checklist ticks itself as the day''s touches come in. Three follow-ups on every quote stays open while a deal of yours has fewer than three.
4. Under My availability choose this week or next, press **Add a block** for each time you will be on, then **Save the week**. Days already past stay as they were.
5. A website request you answer with the first offer during a block is credited to you as sourced, even if you chose Entered for CarmaCars. Off your blocks it stays a claim for an Admin.

> Tip: An Admin can void a touch logged by mistake. Once an Admin approves a month, its mode, its rates and its touches no longer change; a refund can still lower the tier, as for everyone.

## My sales

Open **Me**, the **My sales** tab. It shows your own sales and commissions only.

1. Commissions comes first. Your rate depends on your mode and the rental days of the month: in person 10%, 15% from 50 days, 20% from 100; remote 5%, 10% and 15%. The bar shows your days against the target of 100, and says when your rate rises. By month gives each month in one line: the mode, the days, the rate and, for remote, the touches and any drop.
2. The tiles show this week: quotes created, offers sent, rentals added, bookings confirmed, conversion, booked revenue and follow-ups due. Press **By month** for months, **By week** for weeks.
3. By week (or By month) lists each period with the same figures, newest first.
4. Follow-ups due lists your open deals with what to do next: send the offer, follow up before the offer expires, or follow up while the renter signs and pays. Red means it is past due.
5. Deals lists every booking you created, added or sent an offer on in the last 180 days, with its status and what it counts. Open a request, an offer or a rental you added from its number.

| Figure | How it is counted |
| --- | --- |
| Credited to you | A quote you created, a rental you added, or a website request whose first offer you sent. An Admin can give a deal to someone else. |
| Quotes created, offers sent, rentals added | Counted on the day they happened. |
| Bookings confirmed, booked revenue | Counted on the day the booking was confirmed. |
| Conversion | Of the deals credited to you in the period, the share confirmed so far. |
| Booked revenue | The rental charge before tax, after discounts. A cancelled booking counts only what was kept; refunds come off. |
| Rental days (Sales) | The days of the completed, paid rentals you sourced that end in the month. The month''s tier applies to all of that month''s rentals. |

> Tip: Sales commissions are approved after the month ends, when the month''s tier is known. A refund that drops the month under a tier lowers every commission of that month; anything already paid comes off your next payment.

## Owners you bring in

Bring in car owners on **My work** > **My sales**, card **Owners you bring in**. Every owner you bring in is credited to you as "sourced by", with their cars. Only an Admin can change that later.

1. **Invite an owner**: enter their name, email and phone, tick **The owner asked me to send it**, then press **Send the invitation**. They get an email with your link to apply.
2. **Copy my owner link**: your own link to the application, for a message or a post. Anyone who applies with it is credited to you.
3. **Start an application**: you fill in the owner and the car for them, with **Take a photo** (or **Choose a photo**) of the ownership permit to fill in the car. It goes to an Admin as an application to approve. The terms and invoices are the Admin''s. A corporation that leases its cars to CarmaCars: choose **A corporation**, then Route **Fleet supplier: leases the cars to CarmaCars**, and each car''s tier (**Regular** or **Troubled**). A fleet supplier can also apply himself from `carmacars.ca/list-your-car`: your owner link works for it too.
4. The row of five figures follows your owners: **Invited**, **Applied**, **Approved**, **Car live** and **First paid rental**. Below, each owner shows their stage and their cars.

5. Someone who starts the application on the website and stops for 30 minutes comes to you: a task "Unfinished owner application" and their row on My sales (Lead). Call or text them; the follow-up emails go by themselves until they finish.

> Tip: An owner already on file, or invited first by another salesperson, cannot be invited again. Ask an Admin if you brought them in.

## Ask for your commission on an owner

There is no set amount. For each owner you bring in, you ask for one, and an Admin decides.

1. On the owner''s row press **Ask for a commission**.
2. Choose **A flat amount** and type it, or **A percent**: type the percent, choose what it is of (the company''s share of their cars'' rentals, or their cars'' rental revenue) and for how long (a number of months, or as long as the car is with us).
3. Add a note for the Admin if you like, then press **Send to an Admin**.
4. While it waits you can press **Change my request**. Once an Admin approves, changes or declines it, the row says so, with their note.

| Approved as | When it is earned |
| --- | --- |
| A flat amount | Once, at the owner''s first paid rental: the first completed rental of any of their cars, paid in full |
| A percent | On each completed, paid rental of their cars that ends after the approval, from the month of the first one, for the months approved |

> Tip: Nothing is earned before an Admin approves the request, and nothing on CarmaCars'' own cars, a partner''s, a shareholder''s or your own. Each commission then goes through the usual steps on My sales: pending approval, approved, paid.

## Buyer leads

1. **Buyer leads**: each request from the /buy pages, with the car, budget and timing.
2. Press **Take it** to make it yours, then call them.
3. Press **Update** to set the status. When you close a lead, say why.

> Tip: Owner leads are not here. The owners you invite or add are on **My sales**, **Owners you bring in**, and you see only your own. Customer service works the full owner pipeline.

An offer that has been expired for 7 days leaves Requests and offers and becomes a renter lead: you get the To do "Expired offer: win the renter back" (the lead goes to the Sales person with the fewest open leads) with the renter''s contact, the car and the dates they wanted. Call or text them, then mark the lead contacted or closed.

**Reopen offer** on an expired booking (or the **Expired** filter of Requests) sends the offer again in one click, open 24 hours unless you set the hours; a pickup time that has passed asks for new dates first. "Renter wants expired offer reopened" To dos come from the renter''s own button. The offer screens block **Send** with **Pickup time has passed: update it** until the pickup is moved.

## Book it now (release 33)
When you send an offer, tick **Book it now (no renter approval)** when the renter has already agreed. The offer goes out and an Admin approves it in one tap: the booking then waits for payment, the car is held, and the renter gets one link to sign and pay. You can also have them sign and pay with you: open the booking, **Sign now on this device**, then take the card on this device.
Already sent the offer? Ask the assistant: "Book the offer of CC-10482 now, the customer agreed by phone". It shows a card; **Confirm** sends the same request to an Admin, who approves in one tap.

## When a check stops the pickup or the return (release 33)
On the booking page, **What stops the pickup now** (or the return) lists each check that stops it, in plain words. When the trip must go ahead anyway, press **Ask an Admin to override the pickup** (or the return), give the actual time, the km and fuel if you know them, and why. An Admin gets an alert and approves in one tap; the pickup (or the return) is then recorded with the time you entered, and the booking''s history says who asked and who approved. You can cancel your request while it waits. A trip that happened and was never recorded: **Ask to record a past trip** with both times; once an Admin approves, the booking lands in Returned so the deposit can be settled.

## Leads and claims

Open **Leads**. Every lead is there: renter leads (forms, live chat, the phone number box, games, expired offers, requests not sent, missed calls, Live visitors), owner leads and partner leads, new and hot first. A new-lead alert on your phone opens that lead.

1. Press **Next lead**, or **Claim** on a card. The lead is yours for 15 minutes.
2. Press **Call**, **Text** or **Email**: your phone or mail app opens and the contact is logged. Each contact (or **Note**) adds 15 minutes, up to 60 minutes from your claim.
3. Press **Outcome**: Contacted, Call booked, Applied, Won or Lost (say why). Or **Mark handled** when there is nothing more to do.
4. Can''t finish? Press **Unclaim** so someone else can take it. A claim that runs out goes back to the pool by itself.

You hold at most 25 leads at once. Your numbers are on To do under **My leads**: leads claimed, won, close rate (won out of claimed), contacted, time to first contact and claims that ran out, today, this week and this month. Owner leads are also under **Owners** > **Leads**.
## Call minutes (release 35)
Your home shows **My call minutes**: today, this week and this month, for connected calls made with the site''s **Call** button. Customer numbers are hidden for Sales; call and text with the buttons on the page.
', 'Sales', 'Requests and offers, new quotes and owner leads.',
  'You turn enquiries into bookings and owners into fleet: requests and offers, quotes for callers, and owner leads.

Your menu: To do, Today, My scorecard and My sales, then Requests and offers, Send an offer, Add a rental, New quote, Calendar and Buyer leads. The owners you bring in are on My sales.

## Requests, offers and new quotes

1. **Requests and offers**: the same queue customer service works, showing only what you can answer now. A request still with customer service is folded under "more not open to you yet", with the time it opens to you.
2. **Rentals** > **Bookings**: **My bookings**, every booking credited to you, offered by you or added by you, from the offer to the return, with its status, money and your commission (counting this month, waiting for approval, approved, paid).
3. **Send an offer**: one screen for a caller, sent at once, as in chapter 2. **New quote** still makes a request to offer later.
3. An offer that is out: **More actions** > **Edit the offer**, then **Save and send the update**.

![](/guides/img/va-sales-02-requests-desktop-2ab1d17d.jpg "desktop; size: 1230 580; address: carmacars.ca/va/requests; pins: 1 39.8 59.5")

> Tip: Your first reply target is 5 minutes, the "Quote sent" measure on your scorecard. Follow every offer out before it expires.

## Check the renter''s licence

Sales approve the renter''s licence like customer service: the licence front, the licence back and the selfie. The proof of coverage and the Protection Plan stay with customer service and Admins.

1. On **To do**, **Licences to check** lists each booking with an image waiting, the longest wait first. Press **Review the licence**.
2. On a booking, the card **Renter licence** has the same: press **Review the licence**.
3. Look at each image and each Flag line of the licence reader under the driver: no alteration, the selfie matches the licence photo.
4. One is wrong? Open **Reject this one** under it, type the reason the renter reads and press **Reject**. The renter is told and asked for a new image.
5. Then press **Approve all**: every image still waiting is approved at once. An image the system refuses is named with the reason.

> Tip: The booking history says who decided and the role, sales. Each opening of the images is logged and the links last one minute.

## In person or remote

Every Sales person works in one of two modes, on the same Sales screens. An Admin sets yours; it shows at the top of To do and on My sales.

|  | In person (Toronto) | Remote (anywhere) |
| --- | --- | --- |
| Commission | Under 50 rental days in the month 10%, from 50 days 15%, from 100 days 20% | Under 50 rental days 5%, from 50 days 10%, from 100 days 15% |
| Credit | Walk-ins, handovers you close, partner visits and the rentals you source | Only the rentals you source. A website request you answer with the first offer during one of your blocks counts as yours. Walk-ins and partner deals earn nothing |
| Hours | You choose | At least 20 hours a week of Thursday to Sunday afternoons (noon to 6 pm, Toronto time), replying within 15 minutes to the chats, texts and calls assigned to you |
| Every day | Nothing set | Marketplace and classified reposts, social media DM replies, three follow-ups on every quote, long-term and business outreach |
| Every month | Nothing set | 400 touches. Under 400 when the month ends, the month''s rate is one tier lower: 15% becomes 10%, 10% becomes 5%, 5% becomes 2.5% |

## Remote: your duties

On **To do**, **Remote duties** shows this month''s touches against 400, today''s checklist, the peak hours you scheduled this week and your reply time.

1. Most touches count by themselves: an offer you send, a message or text you send from the portal, a live chat you answer (once a day for each chat), a call or text from the phone line, an ad you post, a call or message to a car owner.
2. For anything else press **Log a touch**: choose the type and add the link of the post, profile or listing if there is one.
3. The checklist ticks itself as the day''s touches come in. Three follow-ups on every quote stays open while a deal of yours has fewer than three.
4. Under My availability choose this week or next, press **Add a block** for each time you will be on, then **Save the week**. Days already past stay as they were.
5. A website request you answer with the first offer during a block is credited to you as sourced, even if you chose Entered for CarmaCars. Off your blocks it stays a claim for an Admin.

> Tip: An Admin can void a touch logged by mistake. Once an Admin approves a month, its mode, its rates and its touches no longer change; a refund can still lower the tier, as for everyone.

## My sales

Open **Me**, the **My sales** tab. It shows your own sales and commissions only.

1. Commissions comes first. Your rate depends on your mode and the rental days of the month: in person 10%, 15% from 50 days, 20% from 100; remote 5%, 10% and 15%. The bar shows your days against the target of 100, and says when your rate rises. By month gives each month in one line: the mode, the days, the rate and, for remote, the touches and any drop.
2. The tiles show this week: quotes created, offers sent, rentals added, bookings confirmed, conversion, booked revenue and follow-ups due. Press **By month** for months, **By week** for weeks.
3. By week (or By month) lists each period with the same figures, newest first.
4. Follow-ups due lists your open deals with what to do next: send the offer, follow up before the offer expires, or follow up while the renter signs and pays. Red means it is past due.
5. Deals lists every booking you created, added or sent an offer on in the last 180 days, with its status and what it counts. Open a request, an offer or a rental you added from its number.

| Figure | How it is counted |
| --- | --- |
| Credited to you | A quote you created, a rental you added, or a website request whose first offer you sent. An Admin can give a deal to someone else. |
| Quotes created, offers sent, rentals added | Counted on the day they happened. |
| Bookings confirmed, booked revenue | Counted on the day the booking was confirmed. |
| Conversion | Of the deals credited to you in the period, the share confirmed so far. |
| Booked revenue | The rental charge before tax, after discounts. A cancelled booking counts only what was kept; refunds come off. |
| Rental days (Sales) | The days of the completed, paid rentals you sourced that end in the month. The month''s tier applies to all of that month''s rentals. |

> Tip: Sales commissions are approved after the month ends, when the month''s tier is known. A refund that drops the month under a tier lowers every commission of that month; anything already paid comes off your next payment.

## Owners you bring in

Bring in car owners on **My work** > **My sales**, card **Owners you bring in**. Every owner you bring in is credited to you as "sourced by", with their cars. Only an Admin can change that later.

1. **Invite an owner**: enter their name, email and phone, tick **The owner asked me to send it**, then press **Send the invitation**. They get an email with your link to apply.
2. **Copy my owner link**: your own link to the application, for a message or a post. Anyone who applies with it is credited to you.
3. **Start an application**: you fill in the owner and the car for them, with **Take a photo** (or **Choose a photo**) of the ownership permit to fill in the car. It goes to an Admin as an application to approve. The terms and invoices are the Admin''s. A corporation that leases its cars to CarmaCars: choose **A corporation**, then Route **Fleet supplier: leases the cars to CarmaCars**, and each car''s tier (**Regular** or **Troubled**). A fleet supplier can also apply himself from `carmacars.ca/list-your-car`: your owner link works for it too.
4. The row of five figures follows your owners: **Invited**, **Applied**, **Approved**, **Car live** and **First paid rental**. Below, each owner shows their stage and their cars.

5. Someone who starts the application on the website and stops for 30 minutes comes to you: a task "Unfinished owner application" and their row on My sales (Lead). Call or text them; the follow-up emails go by themselves until they finish.

> Tip: An owner already on file, or invited first by another salesperson, cannot be invited again. Ask an Admin if you brought them in.

## Ask for your commission on an owner

There is no set amount. For each owner you bring in, you ask for one, and an Admin decides.

1. On the owner''s row press **Ask for a commission**.
2. Choose **A flat amount** and type it, or **A percent**: type the percent, choose what it is of (the company''s share of their cars'' rentals, or their cars'' rental revenue) and for how long (a number of months, or as long as the car is with us).
3. Add a note for the Admin if you like, then press **Send to an Admin**.
4. While it waits you can press **Change my request**. Once an Admin approves, changes or declines it, the row says so, with their note.

| Approved as | When it is earned |
| --- | --- |
| A flat amount | Once, at the owner''s first paid rental: the first completed rental of any of their cars, paid in full |
| A percent | On each completed, paid rental of their cars that ends after the approval, from the month of the first one, for the months approved |

> Tip: Nothing is earned before an Admin approves the request, and nothing on CarmaCars'' own cars, a partner''s, a shareholder''s or your own. Each commission then goes through the usual steps on My sales: pending approval, approved, paid.

## Buyer leads

1. **Buyer leads**: each request from the /buy pages, with the car, budget and timing.
2. Press **Take it** to make it yours, then call them.
3. Press **Update** to set the status. When you close a lead, say why.

> Tip: Owner leads are not here. The owners you invite or add are on **My sales**, **Owners you bring in**, and you see only your own. Customer service works the full owner pipeline.

An offer that has been expired for 7 days leaves Requests and offers and becomes a renter lead: you get the To do "Expired offer: win the renter back" (the lead goes to the Sales person with the fewest open leads) with the renter''s contact, the car and the dates they wanted. Call or text them, then mark the lead contacted or closed.

**Reopen offer** on an expired booking (or the **Expired** filter of Requests) sends the offer again in one click, open 24 hours unless you set the hours; a pickup time that has passed asks for new dates first. "Renter wants expired offer reopened" To dos come from the renter''s own button. The offer screens block **Send** with **Pickup time has passed: update it** until the pickup is moved.

## Book it now (release 33)
When you send an offer, tick **Book it now (no renter approval)** when the renter has already agreed. The offer goes out and an Admin approves it in one tap: the booking then waits for payment, the car is held, and the renter gets one link to sign and pay. You can also have them sign and pay with you: open the booking, **Sign now on this device**, then take the card on this device.
Already sent the offer? Ask the assistant: "Book the offer of CC-10482 now, the customer agreed by phone". It shows a card; **Confirm** sends the same request to an Admin, who approves in one tap.

## When a check stops the pickup or the return (release 33)
On the booking page, **What stops the pickup now** (or the return) lists each check that stops it, in plain words. When the trip must go ahead anyway, press **Ask an Admin to override the pickup** (or the return), give the actual time, the km and fuel if you know them, and why. An Admin gets an alert and approves in one tap; the pickup (or the return) is then recorded with the time you entered, and the booking''s history says who asked and who approved. You can cancel your request while it waits. A trip that happened and was never recorded: **Ask to record a past trip** with both times; once an Admin approves, the booking lands in Returned so the deposit can be settled.

## Leads and claims

Open **Leads**. Every lead is there: renter leads (forms, live chat, the phone number box, games, expired offers, requests not sent, missed calls, Live visitors), owner leads and partner leads, new and hot first. A new-lead alert on your phone opens that lead.

1. Press **Next lead**, or **Claim** on a card. The lead is yours for 15 minutes.
2. Press **Call**, **Text** or **Email**: your phone or mail app opens and the contact is logged. Each contact (or **Note**) adds 15 minutes, up to 60 minutes from your claim.
3. Press **Outcome**: Contacted, Call booked, Applied, Won or Lost (say why). Or **Mark handled** when there is nothing more to do.
4. Can''t finish? Press **Unclaim** so someone else can take it. A claim that runs out goes back to the pool by itself.

You hold at most 25 leads at once. Your numbers are on To do under **My leads**: leads claimed, won, close rate (won out of claimed), contacted, time to first contact and claims that ran out, today, this week and this month. Owner leads are also under **Owners** > **Leads**.
## Call minutes (release 35)
Your home shows **My call minutes**: today, this week and this month, for connected calls made with the site''s **Call** button. Customer numbers are hidden for Sales; call and text with the buttons on the page.


## Get a renter ready for the pickup (release 35)
Your work does not stop at the offer. Until the car is handed over you can do everything that gets the renter good to go:
- **Payment**: send a pay link or a deposit link on Money (text or email), or take the card on this device, also on a confirmed booking.
- **The offer**: edit it, send it again with a later expiry, withdraw it or record that the renter approved by phone, also while it waits for payment.
- **ID and coverage**: approve or reject the licence, the selfie and the proof of coverage, with the reason the renter sees.
- **Drivers and agreement**: send each additional driver their signing link, or the agreement again.
- **A name or date of birth correction**: when a verified renter asks for one, it shows on the booking; check it against the licence and approve or decline.

The booking page shows **Ready for the rental**: one line for each thing the pickup needs (offer accepted, paid, licence and selfie, coverage, deposit, drivers, agreement, add-ons in the car), green when done, with what to press when not. Refunds, cancellations, deposit releases and removing a paid add-on stay with customer service, Finance and Admins.

## The Prepare checklist (release 35)
On a booking with add-ons, **Prepare** shows each add-on with its quantity, ticked or not by field staff, who ticked it and when, and the pickup or delivery job with its field person. It is on the booking and on the car page, for Sales, customer service, Fleet and Finance.',
  '<p class="gd-p">You turn enquiries into bookings and owners into fleet: requests and offers, quotes for callers, and owner leads.</p><p class="gd-p">Your menu: To do, Today, My scorecard and My sales, then Requests and offers, Send an offer, Add a rental, New quote, Calendar and Buyer leads. The owners you bring in are on My sales.</p><section class="gd-task" id="sales-requests-offers-and-new-quotes" data-gd-task><h2 class="gd-h2">Requests, offers and new quotes</h2><div class="gd-stepblock gd-stepblock--below"><div class="gd-stepcol"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t"><b class="gd-ui">Requests and offers</b>: the same queue customer service works, showing only what you can answer now. A request still with customer service is folded under &quot;more not open to you yet&quot;, with the time it opens to you.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t"><b class="gd-ui">Rentals</b> &gt; <b class="gd-ui">Bookings</b>: <b class="gd-ui">My bookings</b>, every booking credited to you, offered by you or added by you, from the offer to the return, with its status, money and your commission (counting this month, waiting for approval, approved, paid).</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t"><b class="gd-ui">Send an offer</b>: one screen for a caller, sent at once, as in chapter 2. <b class="gd-ui">New quote</b> still makes a request to offer later.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">An offer that is out: <b class="gd-ui">More actions</b> &gt; <b class="gd-ui">Edit the offer</b>, then <b class="gd-ui">Save and send the update</b>.</div></li></ol></div><figure class="gd-fig gd-fig--desk"><div class="gd-browser"><div class="gd-bar" aria-hidden="true"><i></i><i></i><i></i><span class="gd-addr">carmacars.ca/va/requests</span></div><div class="gd-imgwrap" style="aspect-ratio:1230/580"><img src="/guides/img/va-sales-02-requests-desktop-2ab1d17d.jpg" alt="" loading="lazy" decoding="async" width="1230" height="580"><span class="gd-pin" style="left:39.8%;top:59.5%" aria-hidden="true">1</span></div></div></figure></div><aside class="gd-box"><span class="gd-lbl">Tip</span><div>Your first reply target is 5 minutes, the &quot;Quote sent&quot; measure on your scorecard. Follow every offer out before it expires.</div></aside></section><section class="gd-task" id="sales-check-the-renter-s-licence" data-gd-task><h2 class="gd-h2">Check the renter&#39;s licence</h2><p class="gd-p">Sales approve the renter&#39;s licence like customer service: the licence front, the licence back and the selfie. The proof of coverage and the Protection Plan stay with customer service and Admins.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">On <b class="gd-ui">To do</b>, <b class="gd-ui">Licences to check</b> lists each booking with an image waiting, the longest wait first. Press <b class="gd-ui">Review the licence</b>.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">On a booking, the card <b class="gd-ui">Renter licence</b> has the same: press <b class="gd-ui">Review the licence</b>.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Look at each image and each Flag line of the licence reader under the driver: no alteration, the selfie matches the licence photo.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">One is wrong? Open <b class="gd-ui">Reject this one</b> under it, type the reason the renter reads and press <b class="gd-ui">Reject</b>. The renter is told and asked for a new image.</div></li><li><span class="gd-n" aria-hidden="true">5</span><div class="gd-t">Then press <b class="gd-ui">Approve all</b>: every image still waiting is approved at once. An image the system refuses is named with the reason.</div></li></ol></div><aside class="gd-box"><span class="gd-lbl">Tip</span><div>The booking history says who decided and the role, sales. Each opening of the images is logged and the links last one minute.</div></aside></section><section class="gd-task" id="sales-in-person-or-remote" data-gd-task><h2 class="gd-h2">In person or remote</h2><p class="gd-p">Every Sales person works in one of two modes, on the same Sales screens. An Admin sets yours; it shows at the top of To do and on My sales.</p><div class="gd-tablewrap"><table class="gd-table"><thead><tr><th scope="col"></th><th scope="col">In person (Toronto)</th><th scope="col">Remote (anywhere)</th></tr></thead><tbody><tr><td>Commission</td><td>Under 50 rental days in the month 10%, from 50 days 15%, from 100 days 20%</td><td>Under 50 rental days 5%, from 50 days 10%, from 100 days 15%</td></tr><tr><td>Credit</td><td>Walk-ins, handovers you close, partner visits and the rentals you source</td><td>Only the rentals you source. A website request you answer with the first offer during one of your blocks counts as yours. Walk-ins and partner deals earn nothing</td></tr><tr><td>Hours</td><td>You choose</td><td>At least 20 hours a week of Thursday to Sunday afternoons (noon to 6 pm, Toronto time), replying within 15 minutes to the chats, texts and calls assigned to you</td></tr><tr><td>Every day</td><td>Nothing set</td><td>Marketplace and classified reposts, social media DM replies, three follow-ups on every quote, long-term and business outreach</td></tr><tr><td>Every month</td><td>Nothing set</td><td>400 touches. Under 400 when the month ends, the month&#39;s rate is one tier lower: 15% becomes 10%, 10% becomes 5%, 5% becomes 2.5%</td></tr></tbody></table></div></section><section class="gd-task" id="sales-remote-your-duties" data-gd-task><h2 class="gd-h2">Remote: your duties</h2><p class="gd-p">On <b class="gd-ui">To do</b>, <b class="gd-ui">Remote duties</b> shows this month&#39;s touches against 400, today&#39;s checklist, the peak hours you scheduled this week and your reply time.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Most touches count by themselves: an offer you send, a message or text you send from the portal, a live chat you answer (once a day for each chat), a call or text from the phone line, an ad you post, a call or message to a car owner.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">For anything else press <b class="gd-ui">Log a touch</b>: choose the type and add the link of the post, profile or listing if there is one.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">The checklist ticks itself as the day&#39;s touches come in. Three follow-ups on every quote stays open while a deal of yours has fewer than three.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">Under My availability choose this week or next, press <b class="gd-ui">Add a block</b> for each time you will be on, then <b class="gd-ui">Save the week</b>. Days already past stay as they were.</div></li><li><span class="gd-n" aria-hidden="true">5</span><div class="gd-t">A website request you answer with the first offer during a block is credited to you as sourced, even if you chose Entered for CarmaCars. Off your blocks it stays a claim for an Admin.</div></li></ol></div><aside class="gd-box"><span class="gd-lbl">Tip</span><div>An Admin can void a touch logged by mistake. Once an Admin approves a month, its mode, its rates and its touches no longer change; a refund can still lower the tier, as for everyone.</div></aside></section><section class="gd-task" id="sales-my-sales" data-gd-task><h2 class="gd-h2">My sales</h2><p class="gd-p">Open <b class="gd-ui">Me</b>, the <b class="gd-ui">My sales</b> tab. It shows your own sales and commissions only.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Commissions comes first. Your rate depends on your mode and the rental days of the month: in person 10%, 15% from 50 days, 20% from 100; remote 5%, 10% and 15%. The bar shows your days against the target of 100, and says when your rate rises. By month gives each month in one line: the mode, the days, the rate and, for remote, the touches and any drop.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">The tiles show this week: quotes created, offers sent, rentals added, bookings confirmed, conversion, booked revenue and follow-ups due. Press <b class="gd-ui">By month</b> for months, <b class="gd-ui">By week</b> for weeks.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">By week (or By month) lists each period with the same figures, newest first.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">Follow-ups due lists your open deals with what to do next: send the offer, follow up before the offer expires, or follow up while the renter signs and pays. Red means it is past due.</div></li><li><span class="gd-n" aria-hidden="true">5</span><div class="gd-t">Deals lists every booking you created, added or sent an offer on in the last 180 days, with its status and what it counts. Open a request, an offer or a rental you added from its number.</div></li></ol></div><div class="gd-tablewrap"><table class="gd-table"><thead><tr><th scope="col">Figure</th><th scope="col">How it is counted</th></tr></thead><tbody><tr><td>Credited to you</td><td>A quote you created, a rental you added, or a website request whose first offer you sent. An Admin can give a deal to someone else.</td></tr><tr><td>Quotes created, offers sent, rentals added</td><td>Counted on the day they happened.</td></tr><tr><td>Bookings confirmed, booked revenue</td><td>Counted on the day the booking was confirmed.</td></tr><tr><td>Conversion</td><td>Of the deals credited to you in the period, the share confirmed so far.</td></tr><tr><td>Booked revenue</td><td>The rental charge before tax, after discounts. A cancelled booking counts only what was kept; refunds come off.</td></tr><tr><td>Rental days (Sales)</td><td>The days of the completed, paid rentals you sourced that end in the month. The month&#39;s tier applies to all of that month&#39;s rentals.</td></tr></tbody></table></div><aside class="gd-box"><span class="gd-lbl">Tip</span><div>Sales commissions are approved after the month ends, when the month&#39;s tier is known. A refund that drops the month under a tier lowers every commission of that month; anything already paid comes off your next payment.</div></aside></section><section class="gd-task" id="sales-owners-you-bring-in" data-gd-task><h2 class="gd-h2">Owners you bring in</h2><p class="gd-p">Bring in car owners on <b class="gd-ui">My work</b> &gt; <b class="gd-ui">My sales</b>, card <b class="gd-ui">Owners you bring in</b>. Every owner you bring in is credited to you as &quot;sourced by&quot;, with their cars. Only an Admin can change that later.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t"><b class="gd-ui">Invite an owner</b>: enter their name, email and phone, tick <b class="gd-ui">The owner asked me to send it</b>, then press <b class="gd-ui">Send the invitation</b>. They get an email with your link to apply.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t"><b class="gd-ui">Copy my owner link</b>: your own link to the application, for a message or a post. Anyone who applies with it is credited to you.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t"><b class="gd-ui">Start an application</b>: you fill in the owner and the car for them, with <b class="gd-ui">Take a photo</b> (or <b class="gd-ui">Choose a photo</b>) of the ownership permit to fill in the car. It goes to an Admin as an application to approve. The terms and invoices are the Admin&#39;s. A corporation that leases its cars to CarmaCars: choose <b class="gd-ui">A corporation</b>, then Route <b class="gd-ui">Fleet supplier: leases the cars to CarmaCars</b>, and each car&#39;s tier (<b class="gd-ui">Regular</b> or <b class="gd-ui">Troubled</b>). A fleet supplier can also apply himself from <span class="gd-url">carmacars.ca/list-your-car</span>: your owner link works for it too.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">The row of five figures follows your owners: <b class="gd-ui">Invited</b>, <b class="gd-ui">Applied</b>, <b class="gd-ui">Approved</b>, <b class="gd-ui">Car live</b> and <b class="gd-ui">First paid rental</b>. Below, each owner shows their stage and their cars.</div></li></ol></div><div class="gd-stepblock"><ol class="gd-ol" start="5"><li><span class="gd-n" aria-hidden="true">5</span><div class="gd-t">Someone who starts the application on the website and stops for 30 minutes comes to you: a task &quot;Unfinished owner application&quot; and their row on My sales (Lead). Call or text them; the follow-up emails go by themselves until they finish.</div></li></ol></div><aside class="gd-box"><span class="gd-lbl">Tip</span><div>An owner already on file, or invited first by another salesperson, cannot be invited again. Ask an Admin if you brought them in.</div></aside></section><section class="gd-task" id="sales-ask-for-your-commission-on-an-owner" data-gd-task><h2 class="gd-h2">Ask for your commission on an owner</h2><p class="gd-p">There is no set amount. For each owner you bring in, you ask for one, and an Admin decides.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">On the owner&#39;s row press <b class="gd-ui">Ask for a commission</b>.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Choose <b class="gd-ui">A flat amount</b> and type it, or <b class="gd-ui">A percent</b>: type the percent, choose what it is of (the company&#39;s share of their cars&#39; rentals, or their cars&#39; rental revenue) and for how long (a number of months, or as long as the car is with us).</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Add a note for the Admin if you like, then press <b class="gd-ui">Send to an Admin</b>.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">While it waits you can press <b class="gd-ui">Change my request</b>. Once an Admin approves, changes or declines it, the row says so, with their note.</div></li></ol></div><div class="gd-tablewrap"><table class="gd-table"><thead><tr><th scope="col">Approved as</th><th scope="col">When it is earned</th></tr></thead><tbody><tr><td>A flat amount</td><td>Once, at the owner&#39;s first paid rental: the first completed rental of any of their cars, paid in full</td></tr><tr><td>A percent</td><td>On each completed, paid rental of their cars that ends after the approval, from the month of the first one, for the months approved</td></tr></tbody></table></div><aside class="gd-box"><span class="gd-lbl">Tip</span><div>Nothing is earned before an Admin approves the request, and nothing on CarmaCars&#39; own cars, a partner&#39;s, a shareholder&#39;s or your own. Each commission then goes through the usual steps on My sales: pending approval, approved, paid.</div></aside></section><section class="gd-task" id="sales-buyer-leads" data-gd-task><h2 class="gd-h2">Buyer leads</h2><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t"><b class="gd-ui">Buyer leads</b>: each request from the /buy pages, with the car, budget and timing.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Press <b class="gd-ui">Take it</b> to make it yours, then call them.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Press <b class="gd-ui">Update</b> to set the status. When you close a lead, say why.</div></li></ol></div><aside class="gd-box"><span class="gd-lbl">Tip</span><div>Owner leads are not here. The owners you invite or add are on <b class="gd-ui">My sales</b>, <b class="gd-ui">Owners you bring in</b>, and you see only your own. Customer service works the full owner pipeline.</div></aside><p class="gd-p">An offer that has been expired for 7 days leaves Requests and offers and becomes a renter lead: you get the To do &quot;Expired offer: win the renter back&quot; (the lead goes to the Sales person with the fewest open leads) with the renter&#39;s contact, the car and the dates they wanted. Call or text them, then mark the lead contacted or closed.</p><p class="gd-p"><b class="gd-ui">Reopen offer</b> on an expired booking (or the <b class="gd-ui">Expired</b> filter of Requests) sends the offer again in one click, open 24 hours unless you set the hours; a pickup time that has passed asks for new dates first. &quot;Renter wants expired offer reopened&quot; To dos come from the renter&#39;s own button. The offer screens block <b class="gd-ui">Send</b> with <b class="gd-ui">Pickup time has passed: update it</b> until the pickup is moved.</p></section><section class="gd-task" id="sales-book-it-now-release-33" data-gd-task><h2 class="gd-h2">Book it now (release 33)</h2><p class="gd-p">When you send an offer, tick <b class="gd-ui">Book it now (no renter approval)</b> when the renter has already agreed. The offer goes out and an Admin approves it in one tap: the booking then waits for payment, the car is held, and the renter gets one link to sign and pay. You can also have them sign and pay with you: open the booking, <b class="gd-ui">Sign now on this device</b>, then take the card on this device. Already sent the offer? Ask the assistant: &quot;Book the offer of CC-10482 now, the customer agreed by phone&quot;. It shows a card; <b class="gd-ui">Confirm</b> sends the same request to an Admin, who approves in one tap.</p></section><section class="gd-task" id="sales-when-a-check-stops-the-pickup-or-the-return-release-33" data-gd-task><h2 class="gd-h2">When a check stops the pickup or the return (release 33)</h2><p class="gd-p">On the booking page, <b class="gd-ui">What stops the pickup now</b> (or the return) lists each check that stops it, in plain words. When the trip must go ahead anyway, press <b class="gd-ui">Ask an Admin to override the pickup</b> (or the return), give the actual time, the km and fuel if you know them, and why. An Admin gets an alert and approves in one tap; the pickup (or the return) is then recorded with the time you entered, and the booking&#39;s history says who asked and who approved. You can cancel your request while it waits. A trip that happened and was never recorded: <b class="gd-ui">Ask to record a past trip</b> with both times; once an Admin approves, the booking lands in Returned so the deposit can be settled.</p></section><section class="gd-task" id="sales-leads-and-claims" data-gd-task><h2 class="gd-h2">Leads and claims</h2><p class="gd-p">Open <b class="gd-ui">Leads</b>. Every lead is there: renter leads (forms, live chat, the phone number box, games, expired offers, requests not sent, missed calls, Live visitors), owner leads and partner leads, new and hot first. A new-lead alert on your phone opens that lead.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Press <b class="gd-ui">Next lead</b>, or <b class="gd-ui">Claim</b> on a card. The lead is yours for 15 minutes.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Press <b class="gd-ui">Call</b>, <b class="gd-ui">Text</b> or <b class="gd-ui">Email</b>: your phone or mail app opens and the contact is logged. Each contact (or <b class="gd-ui">Note</b>) adds 15 minutes, up to 60 minutes from your claim.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Press <b class="gd-ui">Outcome</b>: Contacted, Call booked, Applied, Won or Lost (say why). Or <b class="gd-ui">Mark handled</b> when there is nothing more to do.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">Can&#39;t finish? Press <b class="gd-ui">Unclaim</b> so someone else can take it. A claim that runs out goes back to the pool by itself.</div></li></ol></div><p class="gd-p">You hold at most 25 leads at once. Your numbers are on To do under <b class="gd-ui">My leads</b>: leads claimed, won, close rate (won out of claimed), contacted, time to first contact and claims that ran out, today, this week and this month. Owner leads are also under <b class="gd-ui">Owners</b> &gt; <b class="gd-ui">Leads</b>.</p></section><section class="gd-task" id="sales-call-minutes-release-35" data-gd-task><h2 class="gd-h2">Call minutes (release 35)</h2><p class="gd-p">Your home shows <b class="gd-ui">My call minutes</b>: today, this week and this month, for connected calls made with the site&#39;s <b class="gd-ui">Call</b> button. Customer numbers are hidden for Sales; call and text with the buttons on the page.</p></section><section class="gd-task" id="sales-get-a-renter-ready-for-the-pickup-release-35" data-gd-task><h2 class="gd-h2">Get a renter ready for the pickup (release 35)</h2><p class="gd-p">Your work does not stop at the offer. Until the car is handed over you can do everything that gets the renter good to go:</p><ul class="gd-ul"><li><b class="gd-ui">Payment</b>: send a pay link or a deposit link on Money (text or email), or take the card on this device, also on a confirmed booking.</li><li><b class="gd-ui">The offer</b>: edit it, send it again with a later expiry, withdraw it or record that the renter approved by phone, also while it waits for payment.</li><li><b class="gd-ui">ID and coverage</b>: approve or reject the licence, the selfie and the proof of coverage, with the reason the renter sees.</li><li><b class="gd-ui">Drivers and agreement</b>: send each additional driver their signing link, or the agreement again.</li><li><b class="gd-ui">A name or date of birth correction</b>: when a verified renter asks for one, it shows on the booking; check it against the licence and approve or decline.</li></ul><p class="gd-p">The booking page shows <b class="gd-ui">Ready for the rental</b>: one line for each thing the pickup needs (offer accepted, paid, licence and selfie, coverage, deposit, drivers, agreement, add-ons in the car), green when done, with what to press when not. Refunds, cancellations, deposit releases and removing a paid add-on stay with customer service, Finance and Admins.</p></section><section class="gd-task" id="sales-the-prepare-checklist-release-35" data-gd-task><h2 class="gd-h2">The Prepare checklist (release 35)</h2><p class="gd-p">On a booking with add-ons, <b class="gd-ui">Prepare</b> shows each add-on with its quantity, ticked or not by field staff, who ticked it and when, and the pickup or delivery job with its field person. It is on the booking and on the car page, for Sales, customer service, Fleet and Finance.</p></section>');
select app.guide_release_section('va', 'commissions', 'chapter', 'add-a-rental-by-hand', 'Every function earns a commission on the rentals it sources: a renter you found yourself. Say so when you enter the rental, the quote or the offer.

## Mark who found the client

Every rental, quote and offer you enter asks: **I sourced this client** or **Entered for CarmaCars**.

1. Choose **I sourced this client** when you found the renter yourself: someone you know, your own post or your own outreach.
2. Choose **Entered for CarmaCars** when the renter came to CarmaCars: the website, the phone line, a walk-in, a partner.
3. A website request earns nothing by itself. If you sourced it anyway, choose I sourced this client on its offer: an Admin decides.

|  | Commission |
| --- | --- |
| Sales | Commission only, with no base pay. By the rental days of the month, on all of that month''s rentals: in person under 50 days 10%, from 50 days 15%, from 100 days 20%; remote 5%, 10% and 15%, one tier lower in a month under 400 touches (chapter Sales) |
| Customer service, finance, fleet | 10% |
| An owner you bring in (Sales) | What you ask for and an Admin approves: a flat amount at the owner''s first paid rental, or a percent of their cars'' rentals for a time (chapter Sales). A CarmaCars expense: it never changes the owner''s revenue |
| How much | The rate on the rental charge before tax, after discounts, with late extra days; never on delivery, kilometres, add-ons or anything else bought. Only a refund of the rental charge comes off |
| When earned | When the rental is completed and paid in full. Never on a cancelled, refunded, unpaid or charged-back rental, or on your own or a household rental |
| Your home address | It must be in your profile. Until it is, a commission waits as not earned yet, and you cannot add a rental or mark I sourced this client |
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
| Sales | Commission only, with no base pay. By the rental days of the month, on all of that month''s rentals: in person under 50 days 10%, from 50 days 15%, from 100 days 20%; remote 5%, 10% and 15%, one tier lower in a month under 400 touches (chapter Sales) |
| Customer service, finance, fleet | 10% |
| An owner you bring in (Sales) | What you ask for and an Admin approves: a flat amount at the owner''s first paid rental, or a percent of their cars'' rentals for a time (chapter Sales). A CarmaCars expense: it never changes the owner''s revenue |
| How much | The rate on the rental charge before tax, after discounts, with late extra days, plus the add-ons (release 35: the same rate on each confirmed add-on''s own charge before tax; not prepaid fuel). Never on delivery, kilometres, young driver, the Protection Plan or other fees. Only a refund of the rental charge, or an add-on removed after booking, comes off |
| When earned | When the rental is completed and paid in full. Never on a cancelled, refunded, unpaid or charged-back rental, or on your own or a household rental |
| Your home address | It must be in your profile. Until it is, a commission waits as not earned yet, and you cannot add a rental or mark I sourced this client |
| Paid | After an Admin approves it, by transfer or on your pay statement. My sales shows each step: not earned yet, pending approval, approved, paid, reversed |

> Tip: A refund or chargeback after a commission was paid comes off your next payment. Your staff agreement has the full rule.
',
  '<p class="gd-p">Every function earns a commission on the rentals it sources: a renter you found yourself. Say so when you enter the rental, the quote or the offer.</p><section class="gd-task" id="commissions-mark-who-found-the-client" data-gd-task><h2 class="gd-h2">Mark who found the client</h2><p class="gd-p">Every rental, quote and offer you enter asks: <b class="gd-ui">I sourced this client</b> or <b class="gd-ui">Entered for CarmaCars</b>.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Choose <b class="gd-ui">I sourced this client</b> when you found the renter yourself: someone you know, your own post or your own outreach.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Choose <b class="gd-ui">Entered for CarmaCars</b> when the renter came to CarmaCars: the website, the phone line, a walk-in, a partner.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">A website request earns nothing by itself. If you sourced it anyway, choose I sourced this client on its offer: an Admin decides.</div></li></ol></div><div class="gd-tablewrap"><table class="gd-table"><thead><tr><th scope="col"></th><th scope="col">Commission</th></tr></thead><tbody><tr><td>Sales</td><td>Commission only, with no base pay. By the rental days of the month, on all of that month&#39;s rentals: in person under 50 days 10%, from 50 days 15%, from 100 days 20%; remote 5%, 10% and 15%, one tier lower in a month under 400 touches (chapter Sales)</td></tr><tr><td>Customer service, finance, fleet</td><td>10%</td></tr><tr><td>An owner you bring in (Sales)</td><td>What you ask for and an Admin approves: a flat amount at the owner&#39;s first paid rental, or a percent of their cars&#39; rentals for a time (chapter Sales). A CarmaCars expense: it never changes the owner&#39;s revenue</td></tr><tr><td>How much</td><td>The rate on the rental charge before tax, after discounts, with late extra days, plus the add-ons (release 35: the same rate on each confirmed add-on&#39;s own charge before tax; not prepaid fuel). Never on delivery, kilometres, young driver, the Protection Plan or other fees. Only a refund of the rental charge, or an add-on removed after booking, comes off</td></tr><tr><td>When earned</td><td>When the rental is completed and paid in full. Never on a cancelled, refunded, unpaid or charged-back rental, or on your own or a household rental</td></tr><tr><td>Your home address</td><td>It must be in your profile. Until it is, a commission waits as not earned yet, and you cannot add a rental or mark I sourced this client</td></tr><tr><td>Paid</td><td>After an Admin approves it, by transfer or on your pay statement. My sales shows each step: not earned yet, pending approval, approved, paid, reversed</td></tr></tbody></table></div><aside class="gd-box"><span class="gd-lbl">Tip</span><div>A refund or chargeback after a commission was paid comes off your next payment. Your staff agreement has the full rule.</div></aside></section>');
select app.guide_release_section('va', 'add-ons', 'chapter', 'discount-game-leads', 'Renters buy add-ons with a rental: seats, flowers, a chauffeur, an umbrella, a phone charger, a full tank. You add them in offers and rentals, confirm the ones that need it, and Fleet keeps the stock.

## In an offer or a rental you add

1. On the review screen of a request, under Add-ons, tick or count what the renter wants. The price on the right follows. Choose the hours for a chauffeur.
2. Add-ons the renter asked for are already ticked. One waiting for confirmation (a chauffeur) is confirmed when you keep it and send the offer; untick it to remove it.
3. In **Bookings**, the **Add a rental** button, the Add-ons list sits under The rental: tick them before you press **Check the calendar and the price**.
4. Notice is yours to judge: you may add flowers with less than 24 hours if Fleet can do it.

## After booking

1. The booking page shows the add-ons, paid or not, and any waiting for confirmation.
2. A renter asked for a chauffeur from their portal: you get a task. Press **Confirm and charge** (the card on file is charged) or **Decline**.
3. Press **Remove** and give the reason to take one off. Unpaid, it goes; paid, a refund for it waits for approval.

## Fleet: tasks and stock

Flowers and a chauffeur give Fleet a task to get them ready, due before pickup by their notice.

1. Open **Cars** > **Add-ons**. Each add-on shows its price, its notice and how many are booked in the next 30 days.
2. For seats, umbrellas and chargers, type how many we have under In stock and press **Save**. Renters cannot ask for more than are free for their dates.
3. A confirmed booking with more than we have gives you an urgent task: find another or tell the renter.

Add-on revenue is CarmaCars'' own. It is never in a commission: your commission stays on the rental charge.
', 'Add-ons', 'Add-ons in offers and rentals, confirming a chauffeur, Fleet tasks and stock.',
  'Renters buy add-ons with a rental: seats, flowers, a chauffeur, an umbrella, a phone charger, a full tank. You add them in offers and rentals, confirm the ones that need it, and Fleet keeps the stock.

## In an offer or a rental you add

1. On the review screen of a request, under Add-ons, tick or count what the renter wants. The price on the right follows. Choose the hours for a chauffeur.
2. Add-ons the renter asked for are already ticked. One waiting for confirmation (a chauffeur) is confirmed when you keep it and send the offer; untick it to remove it.
3. In **Bookings**, the **Add a rental** button, the Add-ons list sits under The rental: tick them before you press **Check the calendar and the price**.
4. Notice is yours to judge: you may add flowers with less than 24 hours if Fleet can do it.

## After booking

1. The booking page shows the add-ons, paid or not, and any waiting for confirmation.
2. A renter asked for a chauffeur from their portal: you get a task. Press **Confirm and charge** (the card on file is charged) or **Decline**.
3. Press **Remove** and give the reason to take one off. Unpaid, it goes; paid, a refund for it waits for approval.

## Fleet: tasks and stock

Flowers and a chauffeur give Fleet a task to get them ready, due before pickup by their notice.

1. Open **Cars** > **Add-ons**. Each add-on shows its price, its notice and how many are booked in the next 30 days.
2. For seats, umbrellas and chargers, type how many we have under In stock and press **Save**. Renters cannot ask for more than are free for their dates.
3. A confirmed booking with more than we have gives you an urgent task: find another or tell the renter.

Since release 35 your commission counts the add-ons at your same rate (not prepaid fuel); an add-on removed after booking leaves it. Sales cannot remove a paid add-on: ask customer service.

An add-on not returned has a charge in the agreement''s fine print (Program settings); the deposit review shows it as a suggestion for Fleet and Finance.
',
  '<p class="gd-p">Renters buy add-ons with a rental: seats, flowers, a chauffeur, an umbrella, a phone charger, a full tank. You add them in offers and rentals, confirm the ones that need it, and Fleet keeps the stock.</p><section class="gd-task" id="add-ons-in-an-offer-or-a-rental-you-add" data-gd-task><h2 class="gd-h2">In an offer or a rental you add</h2><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">On the review screen of a request, under Add-ons, tick or count what the renter wants. The price on the right follows. Choose the hours for a chauffeur.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Add-ons the renter asked for are already ticked. One waiting for confirmation (a chauffeur) is confirmed when you keep it and send the offer; untick it to remove it.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">In <b class="gd-ui">Bookings</b>, the <b class="gd-ui">Add a rental</b> button, the Add-ons list sits under The rental: tick them before you press <b class="gd-ui">Check the calendar and the price</b>.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">Notice is yours to judge: you may add flowers with less than 24 hours if Fleet can do it.</div></li></ol></div></section><section class="gd-task" id="add-ons-after-booking" data-gd-task><h2 class="gd-h2">After booking</h2><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">The booking page shows the add-ons, paid or not, and any waiting for confirmation.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">A renter asked for a chauffeur from their portal: you get a task. Press <b class="gd-ui">Confirm and charge</b> (the card on file is charged) or <b class="gd-ui">Decline</b>.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Press <b class="gd-ui">Remove</b> and give the reason to take one off. Unpaid, it goes; paid, a refund for it waits for approval.</div></li></ol></div></section><section class="gd-task" id="add-ons-fleet-tasks-and-stock" data-gd-task><h2 class="gd-h2">Fleet: tasks and stock</h2><p class="gd-p">Flowers and a chauffeur give Fleet a task to get them ready, due before pickup by their notice.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Open <b class="gd-ui">Cars</b> &gt; <b class="gd-ui">Add-ons</b>. Each add-on shows its price, its notice and how many are booked in the next 30 days.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">For seats, umbrellas and chargers, type how many we have under In stock and press <b class="gd-ui">Save</b>. Renters cannot ask for more than are free for their dates.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">A confirmed booking with more than we have gives you an urgent task: find another or tell the renter.</div></li></ol></div><p class="gd-p">Since release 35 your commission counts the add-ons at your same rate (not prepaid fuel); an add-on removed after booking leaves it. Sales cannot remove a paid add-on: ask customer service.</p><p class="gd-p">An add-on not returned has a charge in the agreement&#39;s fine print (Program settings); the deposit review shows it as a suggestion for Fleet and Finance.</p></section>');
select app.guide_release_section('field', 'my-jobs', 'chapter', 'start-here', 'The portal has four tabs at the bottom of the screen: **Today**, **My shifts**, **My pay** and **Training** (and **Sales** if you asked to do sales too). Today is where the work is.

## Your shift and the clock

1. At the top of **Today**: your shift, and **Clock in**. Press it when you start. The phone shares where you are at that moment only.
2. The bar shows how many of the day''s must-dos are done.
3. When you finish, press **Clock out**. Anything still open is listed: give a reason for each, then press **Clock out with these reasons**. Fleet is told, so someone can cover them.

## One list, in order

The list is built for you from the bookings and the cars:

1. **Your work**: every pickup and return of the day (deliveries and collections too) at its time, and onboarding prep Fleet gave you. Each car and time is one card.
2. **When you have time**: cars to clean (not checked clean for a week), cars needing service or not roadworthy, and cars that need listing photos.
3. Switch to **Tomorrow** to see what is planned so far.

## A card

1. The time, what it is (Pickup, Return, Delivery to the renter), the car and its plate, the renter and the booking.
2. The steps of the card, ticked as they are done: the clean check, the add-ons in the car, the pickup photos and handover.
3. One big button: the next thing to do. **Start the pickup** or **Start the return** opens the job screen, where the clean check and the add-ons come first.
4. **More** has the place with **Open in maps**, the call to the renter, and helping the renter.

> Watch out: The pickup cannot be finished until every add-on (a child seat, for example) is ticked as in the car. If the trip must go without it, ask an Admin to override on the job.

## Clean checks

Every car is checked clean before each pickup and after each return: choose **Clean** or **Needs cleaning**, take the photo and press **Save the clean check**. On a cleaning card in spare time, press **Check it clean** the same way.

## Cars needing service, and listing photos

1. On a service card, press **Give an update** (taken in, at the shop, waiting for parts, sorted) and **Send the update to Fleet**.
2. On a photo card, press **Take the listing photos**: the photo shoot opens with the angles the listing is missing.

## Onboarding prep

Fleet gives you the prep of a car joining the fleet on a day you hold a shift. Press **Open the prep**, then each item: upload what it needs (the safety certificate with its date) and press **Mark it done**. When every item is done, the owner''s onboarding checklist updates and Fleet is told.

## The Add button

The red **Add** button at the bottom right of Today:

1. **Money spent**: gas, a wash, parts, parking. The amount, the car, the booking and a photo of the receipt, then **Send to Finance**. Finance approves it and pays you back if you used your own money. No receipt yet: you get a To do until you add it.
2. **Service record**: what was done, where, the odometer, the cost and the invoice photo, then **Record the service**. The car''s maintenance resets, the expense is made on the car, and Fleet and Finance are told.
3. **Photos of a car**: a photo and a note, saved on the car.
4. **A problem with a car**: damage, a warning light, a ticket or lost property (see Report, rentals, referrals and profile).

## Help a renter on the spot

From a card''s **More**, or with **Find the booking** on Help a renter (by booking number, name or phone):

1. **Take a payment** or **Take the deposit hold**: **Show a QR for their phone** (they pay on their own phone), **Text the link**, **Email the link**, or **Use the card reader** when you have it. Never type a card number.
2. The licence: check it in person on the pickup.
3. The agreement: **They sign on my phone**, with their own finger.

> Good to know: Refunds stay with Finance and Admin.

## Check the renter''s licence

The renter''s licence photos and selfie are checked before the handover. You can check them yourself, for a booking on one of your own jobs today or in the next 7 days. Everything you do is recorded with your name and "field staff".

1. My jobs shows **Licences to check** when the licence front, back or selfie of a renter on one of your jobs waits for a decision. The same check is on the job itself, under **Check the licence**.
2. Press **Review the licence**. The images open with the name, date of birth and licence details on the booking.
3. Look at each image and the licence reader''s lines under each driver (Pass or Flag: valid to the return, class, age, name and date of birth, the Ontario number, front and back): no sign of alteration, and the selfie matches the licence photo. A photo you take that is blurry or cut off says so at once: take it again.
4. One is wrong? Open **Reject this one** under it, type the reason the renter reads and press **Reject**. The renter is told why and sends a new one.
5. Then press **Approve all**: everything still waiting is approved at once.

> Tip: The renter''s proof of coverage stays with the office. Meeting the renter at the handover? You can still check the original licence in person from the ready check (see A handover).

## Documents to sign

Your staff agreement, when CarmaCars sends it.

1. My jobs shows "You have a document to sign". Press **Read and sign**.
2. Check the key values at the top (your role, wage and start date), then press **Read the PDF** and read it.
3. Sign in a few steps: press **Send the code** and type the 6-digit code from your phone or email, tick that you read it, draw your initials beside the key terms (confidentiality, the rules on money, keys and cars, ending the agreement), tick the two consents and draw your signature.
4. Press **Sign**. The signed copy, with its certificate of completion, stays on the same page.

## Move a car

1. Under Moving a car, press **Start a move**. Choose the Car and Why (for example Reposition).
2. Fill in From and the Odometer (km), then press **Start the move now**.
3. When you arrive, press **End the move**, fill in Now at and the odometer, then press **End the move now**.

## Call and text the renter

**Call** on a card opens the Quo app with the renter''s number, so the call comes from the CarmaCars number; **Text** opens a small window that sends from the CarmaCars number and keeps the text with the booking.

**Cars now** and **Map of your cars** are links at the bottom of Today.
', 'Today', 'Your shift, then one list of the day: each car and time is one card. The Add button, and helping a renter on the spot.',
  'The portal has four tabs at the bottom of the screen: **Today**, **My shifts**, **My pay** and **Training** (and **Sales** if you asked to do sales too). Today is where the work is.

## Your shift and the clock

1. At the top of **Today**: your shift, and **Clock in**. Press it when you start. The phone shares where you are at that moment only.
2. The bar shows how many of the day''s must-dos are done.
3. When you finish, press **Clock out**. Anything still open is listed: give a reason for each, then press **Clock out with these reasons**. Fleet is told, so someone can cover them.

## One list, in order

The list is built for you from the bookings and the cars:

1. **Your work**: every pickup and return of the day (deliveries and collections too) at its time, and onboarding prep Fleet gave you. Each car and time is one card.
2. **When you have time**: cars to clean (not checked clean for a week), cars needing service or not roadworthy, and cars that need listing photos.
3. Switch to **Tomorrow** to see what is planned so far.

## A card

1. The time, what it is (Pickup, Return, Delivery to the renter), the car and its plate, the renter and the booking.
2. The steps of the card, ticked as they are done: the clean check, the add-ons in the car, the pickup photos and handover.
3. One big button: the next thing to do. **Start the pickup** or **Start the return** opens the job screen, where the clean check and the add-ons come first.
4. **More** has the place with **Open in maps**, the call to the renter, and helping the renter.

The card''s **Prepare** checklist lists every add-on to put in the car with its quantity. The office sees your ticks as you go.

> Watch out: The pickup cannot be finished until every add-on (a child seat, for example) is ticked as in the car. If the trip must go without it, ask an Admin to override on the job.

## Clean checks

Every car is checked clean before each pickup and after each return: choose **Clean** or **Needs cleaning**, take the photo and press **Save the clean check**. On a cleaning card in spare time, press **Check it clean** the same way.

## Cars needing service, and listing photos

1. On a service card, press **Give an update** (taken in, at the shop, waiting for parts, sorted) and **Send the update to Fleet**.
2. On a photo card, press **Take the listing photos**: the photo shoot opens with the angles the listing is missing.

## Onboarding prep

Fleet gives you the prep of a car joining the fleet on a day you hold a shift. Press **Open the prep**, then each item: upload what it needs (the safety certificate with its date) and press **Mark it done**. When every item is done, the owner''s onboarding checklist updates and Fleet is told.

## The Add button

The red **Add** button at the bottom right of Today:

1. **Money spent**: gas, a wash, parts, parking. The amount, the car, the booking and a photo of the receipt, then **Send to Finance**. Finance approves it and pays you back if you used your own money. No receipt yet: you get a To do until you add it.
2. **Service record**: what was done, where, the odometer, the cost and the invoice photo, then **Record the service**. The car''s maintenance resets, the expense is made on the car, and Fleet and Finance are told.
3. **Photos of a car**: a photo and a note, saved on the car.
4. **A problem with a car**: damage, a warning light, a ticket or lost property (see Report, rentals, referrals and profile).

## Help a renter on the spot

From a card''s **More**, or with **Find the booking** on Help a renter (by booking number, name or phone):

1. **Take a payment** or **Take the deposit hold**: **Show a QR for their phone** (they pay on their own phone), **Text the link**, **Email the link**, or **Use the card reader** when you have it. Never type a card number.
2. The licence: check it in person on the pickup.
3. The agreement: **They sign on my phone**, with their own finger.

> Good to know: Refunds stay with Finance and Admin.

## Check the renter''s licence

The renter''s licence photos and selfie are checked before the handover. You can check them yourself, for a booking on one of your own jobs today or in the next 7 days. Everything you do is recorded with your name and "field staff".

1. My jobs shows **Licences to check** when the licence front, back or selfie of a renter on one of your jobs waits for a decision. The same check is on the job itself, under **Check the licence**.
2. Press **Review the licence**. The images open with the name, date of birth and licence details on the booking.
3. Look at each image and the licence reader''s lines under each driver (Pass or Flag: valid to the return, class, age, name and date of birth, the Ontario number, front and back): no sign of alteration, and the selfie matches the licence photo. A photo you take that is blurry or cut off says so at once: take it again.
4. One is wrong? Open **Reject this one** under it, type the reason the renter reads and press **Reject**. The renter is told why and sends a new one.
5. Then press **Approve all**: everything still waiting is approved at once.

> Tip: The renter''s proof of coverage stays with the office. Meeting the renter at the handover? You can still check the original licence in person from the ready check (see A handover).

## Documents to sign

Your staff agreement, when CarmaCars sends it.

1. My jobs shows "You have a document to sign". Press **Read and sign**.
2. Check the key values at the top (your role, wage and start date), then press **Read the PDF** and read it.
3. Sign in a few steps: press **Send the code** and type the 6-digit code from your phone or email, tick that you read it, draw your initials beside the key terms (confidentiality, the rules on money, keys and cars, ending the agreement), tick the two consents and draw your signature.
4. Press **Sign**. The signed copy, with its certificate of completion, stays on the same page.

## Move a car

1. Under Moving a car, press **Start a move**. Choose the Car and Why (for example Reposition).
2. Fill in From and the Odometer (km), then press **Start the move now**.
3. When you arrive, press **End the move**, fill in Now at and the odometer, then press **End the move now**.

## Call and text the renter

**Call** on a card opens the Quo app with the renter''s number, so the call comes from the CarmaCars number; **Text** opens a small window that sends from the CarmaCars number and keeps the text with the booking.

**Cars now** and **Map of your cars** are links at the bottom of Today.
',
  '<p class="gd-p">The portal has four tabs at the bottom of the screen: <b class="gd-ui">Today</b>, <b class="gd-ui">My shifts</b>, <b class="gd-ui">My pay</b> and <b class="gd-ui">Training</b> (and <b class="gd-ui">Sales</b> if you asked to do sales too). Today is where the work is.</p><section class="gd-task" id="my-jobs-your-shift-and-the-clock" data-gd-task><h2 class="gd-h2">Your shift and the clock</h2><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">At the top of <b class="gd-ui">Today</b>: your shift, and <b class="gd-ui">Clock in</b>. Press it when you start. The phone shares where you are at that moment only.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">The bar shows how many of the day&#39;s must-dos are done.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">When you finish, press <b class="gd-ui">Clock out</b>. Anything still open is listed: give a reason for each, then press <b class="gd-ui">Clock out with these reasons</b>. Fleet is told, so someone can cover them.</div></li></ol></div></section><section class="gd-task" id="my-jobs-one-list-in-order" data-gd-task><h2 class="gd-h2">One list, in order</h2><p class="gd-p">The list is built for you from the bookings and the cars:</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t"><b class="gd-ui">Your work</b>: every pickup and return of the day (deliveries and collections too) at its time, and onboarding prep Fleet gave you. Each car and time is one card.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t"><b class="gd-ui">When you have time</b>: cars to clean (not checked clean for a week), cars needing service or not roadworthy, and cars that need listing photos.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Switch to <b class="gd-ui">Tomorrow</b> to see what is planned so far.</div></li></ol></div></section><section class="gd-task" id="my-jobs-a-card" data-gd-task><h2 class="gd-h2">A card</h2><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">The time, what it is (Pickup, Return, Delivery to the renter), the car and its plate, the renter and the booking.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">The steps of the card, ticked as they are done: the clean check, the add-ons in the car, the pickup photos and handover.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">One big button: the next thing to do. <b class="gd-ui">Start the pickup</b> or <b class="gd-ui">Start the return</b> opens the job screen, where the clean check and the add-ons come first.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t"><b class="gd-ui">More</b> has the place with <b class="gd-ui">Open in maps</b>, the call to the renter, and helping the renter.</div></li></ol></div><p class="gd-p">The card&#39;s <b class="gd-ui">Prepare</b> checklist lists every add-on to put in the car with its quantity. The office sees your ticks as you go.</p><aside class="gd-box gd-box--warn"><span class="gd-lbl">Watch out</span><div>The pickup cannot be finished until every add-on (a child seat, for example) is ticked as in the car. If the trip must go without it, ask an Admin to override on the job.</div></aside></section><section class="gd-task" id="my-jobs-clean-checks" data-gd-task><h2 class="gd-h2">Clean checks</h2><p class="gd-p">Every car is checked clean before each pickup and after each return: choose <b class="gd-ui">Clean</b> or <b class="gd-ui">Needs cleaning</b>, take the photo and press <b class="gd-ui">Save the clean check</b>. On a cleaning card in spare time, press <b class="gd-ui">Check it clean</b> the same way.</p></section><section class="gd-task" id="my-jobs-cars-needing-service-and-listing-photos" data-gd-task><h2 class="gd-h2">Cars needing service, and listing photos</h2><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">On a service card, press <b class="gd-ui">Give an update</b> (taken in, at the shop, waiting for parts, sorted) and <b class="gd-ui">Send the update to Fleet</b>.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">On a photo card, press <b class="gd-ui">Take the listing photos</b>: the photo shoot opens with the angles the listing is missing.</div></li></ol></div></section><section class="gd-task" id="my-jobs-onboarding-prep" data-gd-task><h2 class="gd-h2">Onboarding prep</h2><p class="gd-p">Fleet gives you the prep of a car joining the fleet on a day you hold a shift. Press <b class="gd-ui">Open the prep</b>, then each item: upload what it needs (the safety certificate with its date) and press <b class="gd-ui">Mark it done</b>. When every item is done, the owner&#39;s onboarding checklist updates and Fleet is told.</p></section><section class="gd-task" id="my-jobs-the-add-button" data-gd-task><h2 class="gd-h2">The Add button</h2><p class="gd-p">The red <b class="gd-ui">Add</b> button at the bottom right of Today:</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t"><b class="gd-ui">Money spent</b>: gas, a wash, parts, parking. The amount, the car, the booking and a photo of the receipt, then <b class="gd-ui">Send to Finance</b>. Finance approves it and pays you back if you used your own money. No receipt yet: you get a To do until you add it.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t"><b class="gd-ui">Service record</b>: what was done, where, the odometer, the cost and the invoice photo, then <b class="gd-ui">Record the service</b>. The car&#39;s maintenance resets, the expense is made on the car, and Fleet and Finance are told.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t"><b class="gd-ui">Photos of a car</b>: a photo and a note, saved on the car.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t"><b class="gd-ui">A problem with a car</b>: damage, a warning light, a ticket or lost property (see Report, rentals, referrals and profile).</div></li></ol></div></section><section class="gd-task" id="my-jobs-help-a-renter-on-the-spot" data-gd-task><h2 class="gd-h2">Help a renter on the spot</h2><p class="gd-p">From a card&#39;s <b class="gd-ui">More</b>, or with <b class="gd-ui">Find the booking</b> on Help a renter (by booking number, name or phone):</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t"><b class="gd-ui">Take a payment</b> or <b class="gd-ui">Take the deposit hold</b>: <b class="gd-ui">Show a QR for their phone</b> (they pay on their own phone), <b class="gd-ui">Text the link</b>, <b class="gd-ui">Email the link</b>, or <b class="gd-ui">Use the card reader</b> when you have it. Never type a card number.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">The licence: check it in person on the pickup.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">The agreement: <b class="gd-ui">They sign on my phone</b>, with their own finger.</div></li></ol></div><aside class="gd-box"><span class="gd-lbl">Good to know</span><div>Refunds stay with Finance and Admin.</div></aside></section><section class="gd-task" id="my-jobs-check-the-renter-s-licence" data-gd-task><h2 class="gd-h2">Check the renter&#39;s licence</h2><p class="gd-p">The renter&#39;s licence photos and selfie are checked before the handover. You can check them yourself, for a booking on one of your own jobs today or in the next 7 days. Everything you do is recorded with your name and &quot;field staff&quot;.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">My jobs shows <b class="gd-ui">Licences to check</b> when the licence front, back or selfie of a renter on one of your jobs waits for a decision. The same check is on the job itself, under <b class="gd-ui">Check the licence</b>.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Press <b class="gd-ui">Review the licence</b>. The images open with the name, date of birth and licence details on the booking.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Look at each image and the licence reader&#39;s lines under each driver (Pass or Flag: valid to the return, class, age, name and date of birth, the Ontario number, front and back): no sign of alteration, and the selfie matches the licence photo. A photo you take that is blurry or cut off says so at once: take it again.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">One is wrong? Open <b class="gd-ui">Reject this one</b> under it, type the reason the renter reads and press <b class="gd-ui">Reject</b>. The renter is told why and sends a new one.</div></li><li><span class="gd-n" aria-hidden="true">5</span><div class="gd-t">Then press <b class="gd-ui">Approve all</b>: everything still waiting is approved at once.</div></li></ol></div><aside class="gd-box"><span class="gd-lbl">Tip</span><div>The renter&#39;s proof of coverage stays with the office. Meeting the renter at the handover? You can still check the original licence in person from the ready check (see A handover).</div></aside></section><section class="gd-task" id="my-jobs-documents-to-sign" data-gd-task><h2 class="gd-h2">Documents to sign</h2><p class="gd-p">Your staff agreement, when CarmaCars sends it.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">My jobs shows &quot;You have a document to sign&quot;. Press <b class="gd-ui">Read and sign</b>.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Check the key values at the top (your role, wage and start date), then press <b class="gd-ui">Read the PDF</b> and read it.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Sign in a few steps: press <b class="gd-ui">Send the code</b> and type the 6-digit code from your phone or email, tick that you read it, draw your initials beside the key terms (confidentiality, the rules on money, keys and cars, ending the agreement), tick the two consents and draw your signature.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">Press <b class="gd-ui">Sign</b>. The signed copy, with its certificate of completion, stays on the same page.</div></li></ol></div></section><section class="gd-task" id="my-jobs-move-a-car" data-gd-task><h2 class="gd-h2">Move a car</h2><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Under Moving a car, press <b class="gd-ui">Start a move</b>. Choose the Car and Why (for example Reposition).</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Fill in From and the Odometer (km), then press <b class="gd-ui">Start the move now</b>.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">When you arrive, press <b class="gd-ui">End the move</b>, fill in Now at and the odometer, then press <b class="gd-ui">End the move now</b>.</div></li></ol></div></section><section class="gd-task" id="my-jobs-call-and-text-the-renter" data-gd-task><h2 class="gd-h2">Call and text the renter</h2><p class="gd-p"><b class="gd-ui">Call</b> on a card opens the Quo app with the renter&#39;s number, so the call comes from the CarmaCars number; <b class="gd-ui">Text</b> opens a small window that sends from the CarmaCars number and keeps the text with the booking.</p><p class="gd-p"><b class="gd-ui">Cars now</b> and <b class="gd-ui">Map of your cars</b> are links at the bottom of Today.</p></section>');
-- GUIDES 1110 END
