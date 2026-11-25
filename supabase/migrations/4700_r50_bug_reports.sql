-- 4700_r50_bug_reports.sql
-- Release 50: the open staff bug reports (blocks_work).
--   BR-4 (Sales, /staff/sales-leads, "I cannot call any leads or clients"): every Call and Text of a Sales rep answered 400.
--        A Sales rep is shown numbers masked ("(647) •••-••11", 0970) and the server found the real number only in
--        phone_masks, by the masked text: a masked text carries the area code and two digits only, so on a list of hundreds
--        of leads several numbers share it, and the tie was broken only by an exact name (a lead without a name, two leads of
--        one person under two spellings, a renter's client page with no booking: refused). A number seen more than 30 days ago
--        was refused too. Now the button also sends the record it sits on (the lead, the renter, the booking): the server
--        takes that record's own number when it masks to what the rep was shown, then phone_masks as before (90 days), then
--        the leads, renters and conversations whose number masks to it, tie broken by the record, the booking or the name.
--        The number still never reaches the browser.
--   BR-3 (Admin, CC-10599, "Renter approved by phone" refused after the coverage was changed): moving a booking to the
--        renter's own insurance removes the Protection Plan line, so the booking's charges no longer matched the open offer
--        and staff were told "The charges on this booking changed after the offer was sent". Staff approving on the renter's
--        word now accept the booking as it stands: the open offer is sent again with the current charges (same expiry) and
--        that version is approved at once, with a line in the history. A renter accepting by themself still gets the
--        refusal (they must see the new charges first). The coverage itself is approved by hand since 3410.
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

-- ================================================================ BR-4: the number behind a masked one
create or replace function app.phone_unmask_for(p_user uuid, p jsonb, p_any_user boolean default false) returns text
language plpgsql stable security definer set search_path = public, app, pg_temp as $$
declare
  v_masked text := btrim(coalesce(p ->> 'masked', ''));
  v_name text := nullif(btrim(coalesce(p ->> 'name', '')), '');
  v_booking text := upper(nullif(btrim(coalesce(p ->> 'booking', p ->> 'booking_number', '')), ''));
  v_lead uuid := case when coalesce(p ->> 'lead', '') ~* '^[0-9a-f-]{36}$' then (p ->> 'lead')::uuid end;
  v_renter uuid := case when coalesce(p ->> 'renter', '') ~* '^[0-9a-f-]{36}$' then (p ->> 'renter')::uuid end;
  v_list text[];
  v_pick text;
begin
  if v_masked = '' then raise exception 'Open the record again and press Call or Text there' using errcode = 'P0002'; end if;
  -- 1. the record the button sits on: its own number, when it masks to what was shown
  if v_lead is not null then
    select app.phone_e164(l.phone) into v_pick from leads l where l.id = v_lead and app.phone_mask_display(l.phone) = v_masked;
    if v_pick is not null then return v_pick; end if;
  end if;
  if v_renter is not null then
    select app.phone_e164(r.mobile) into v_pick from renters r where r.id = v_renter and app.phone_mask_display(r.mobile) = v_masked;
    if v_pick is not null then return v_pick; end if;
  end if;
  if v_booking is not null then
    select app.phone_e164(r.mobile) into v_pick from bookings b join renters r on r.id = b.renter_id
     where b.booking_number = v_booking and app.phone_mask_display(r.mobile) = v_masked;
    if v_pick is not null then return v_pick; end if;
  end if;
  -- 2. what this person was shown (0970), now for 90 days
  select array_agg(distinct m.number) into v_list from phone_masks m
   where m.display = v_masked and m.seen_at > now() - interval '90 days' and (p_any_user or m.user_id = p_user);
  -- 3. nothing kept (a page read before the mask was kept, an alert, a cached list): the people whose number masks to it
  if coalesce(cardinality(v_list), 0) = 0 then
    select array_agg(distinct n) into v_list from (
      select app.phone_e164(l.phone) n from leads l where app.phone_mask_display(l.phone) = v_masked
      union select app.phone_e164(r.mobile) from renters r where app.phone_mask_display(r.mobile) = v_masked
      union select t.number from phone_threads t where app.phone_mask_display(t.number) = v_masked) x where n is not null;
    -- with no name or booking to choose by, only a single match is used
    if cardinality(v_list) > 1 and v_name is null and v_booking is null then v_list := null; end if;
  end if;
  if coalesce(cardinality(v_list), 0) = 0 then raise exception 'Open the record again and press Call or Text there' using errcode = 'P0002'; end if;
  if cardinality(v_list) = 1 then return v_list[1]; end if;
  -- several people share the masked digits: the booking's renter, then the name (any spacing or case)
  select n into v_pick from unnest(v_list) n
   where (v_booking is not null and n = (select app.phone_e164(r.mobile) from bookings b join renters r on r.id = b.renter_id where b.booking_number = v_booking))
      or (v_name is not null and exists (select 1 from phone_threads t where t.number = n and lower(btrim(t.name)) = lower(v_name)))
      or (v_name is not null and exists (select 1 from renters r where app.phone_e164(r.mobile) = n and lower(btrim(r.legal_name)) = lower(v_name)))
      or (v_name is not null and exists (select 1 from leads l where app.phone_e164(l.phone) = n and lower(btrim(l.name)) = lower(v_name)))
   order by n limit 1;
  if v_pick is null then raise exception 'Open the record again and press Call or Text there' using errcode = 'P0002'; end if;
  return v_pick;
end $$;
revoke all on function app.phone_unmask_for(uuid, jsonb, boolean) from public, anon, authenticated;
grant execute on function app.phone_unmask_for(uuid, jsonb, boolean) to service_role;

-- ================================================================ BR-3: staff accept the booking as it stands
alter function app.approve_offer(uuid, integer, uuid, timestamptz) rename to approve_offer_pre4700;
create function app.approve_offer(p_booking uuid, p_version integer, p_by uuid, p_now timestamptz default now()) returns void
language plpgsql security definer set search_path = public, app, pg_temp as $$
declare
  b bookings;
  o booking_offers;
  v_total bigint;
  v_staff boolean;
  v_n integer;
begin
  select * into b from bookings where id = p_booking;
  v_staff := p_by is not null and app.user_is_staff(p_by)
             and not exists (select 1 from renters r where r.id = b.renter_id and r.user_id = p_by);
  if v_staff and b.id is not null and b.status::text = 'offered' and p_version is not distinct from b.current_offer_version then
    select * into o from booking_offers where booking_id = p_booking and version = p_version;
    select coalesce(sum(amount_cents + hst_cents), 0) into v_total from booking_line_items
     where booking_id = p_booking and stage = 'booking' and charged_to_renter and voided_at is null;
    if o.id is not null and o.status = 'sent' and o.expires_at > p_now and v_total <> o.total_cents then
      perform app.withdraw_offer(p_booking, p_by, 'Charges changed (coverage or fees): sent again with the current charges, approved by phone');
      v_n := app.send_offer(p_booking, p_by, null, o.expires_at);
      perform app.log_booking_event(p_booking, 'adjusted', 'offered', 'offered', v_n,
        format('Approved by phone with the current charges (%s, was %s on version %s)',
               to_char(v_total / 100.0, 'FM$999,999,990.00'), to_char(o.total_cents / 100.0, 'FM$999,999,990.00'), p_version), p_by, 'staff');
      perform app.approve_offer_pre4700(p_booking, v_n, p_by, p_now);
      return;
    end if;
  end if;
  perform app.approve_offer_pre4700(p_booking, p_version, p_by, p_now);
end $$;
select pg_temp.copy_grants('app.approve_offer(uuid, integer, uuid, timestamptz)'::regprocedure, 'app.approve_offer_pre4700(uuid, integer, uuid, timestamptz)'::regprocedure);
