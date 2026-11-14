-- 2921 (release 48): a pay link for the booking's money asks for what is owed, never more.
--
-- The owner's report (Nov 14): a renter paid the booking total; the total later changed and staff sent a pay link for
-- the whole new total instead of the difference, so the renter paid twice. Another renter whose payment had gone
-- through got a balance pay link although nothing was owed. Root causes in app.payreq_create (0129, 0139):
--   * the amount came from the screen (the staff member's figure, or one read before the payment landed) and only had
--     to be at most booking_part_open; for an Admin even that was not checked ("an Admin charges more"), so a link for
--     the whole new total went out with the old total already paid;
--   * a new link cancelled only the open links of the same part: a rental link and a balance link could both be open
--     and both be paid;
--   * nothing cancelled an open link once a payment landed, so a link sent while the renter was paying stayed payable.
-- Now:
--   1. app.booking_amount_owed(booking): the booking's total (the renter's share on an insurer's booking) less every
--      succeeded payment of it, refunds counted back. A link (and the renter's own Pay the balance, and a saved card
--      charged for the rental or the fees) for the rental, the fees or the balance defaults to and is capped at
--      what is owed (and what is open for that part); with nothing owed it is refused. A charge on top is a later
--      charge, with its reason, as before. On a total change the link is for the difference, by the same rule.
--   2. A new link for the booking's money cancels every open link of the rental, the fees and the balance.
--   3. When a payment of the booking lands, every open link of those parts for more than is then owed is cancelled
--      (at commit, so the link that was paid is already marked paid), and the pay page checks the link again before
--      the card is captured (public.server_payreq_still_owed): a cancelled or too large link is voided, never charged.
-- No applied migration is edited: functions are patched in place or wrapped (_pre2921).
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

create function pg_temp.patch_fn(p_sig regprocedure, p_old text, p_new text) returns void
language plpgsql as $$
declare
  d text := pg_get_functiondef(p_sig);
begin
  if position(p_old in d) = 0 then
    raise exception '2921: the text to change was not found in %: %', p_sig, left(p_old, 160);
  end if;
  execute replace(d, p_old, p_new);
end $$;

-- ================================================================ 1. what is owed
-- The booking's total (the renter's share when an insurer pays the rest) less the succeeded payments of it (a card at
-- booking, a pay link, a saved card, cash or an e-Transfer recorded), less nothing for the deposit or later charges,
-- with every refund of those payments counted back. Never below zero.
create function app.booking_amount_owed(p_booking uuid) returns bigint
language sql stable security definer set search_path = public, app as $$
  with b as (select * from bookings where id = p_booking),
  paid as (
    select x.id, x.amount_cents from payments x
     where x.booking_id = p_booking and x.purpose = 'booking_total' and x.kind in ('charge', 'capture') and x.status = 'succeeded' and x.method <> 'insurer'
       and not exists (select 1 from payment_requests q where q.payment_id = x.id and q.covers in ('later', 'deposit', 'card'))
       and not exists (select 1 from manual_payments m where m.payment_id = x.id and m.covers in ('later', 'deposit')))
  select greatest(coalesce((select coalesce(b.renter_due_at_booking_cents, b.total_due_at_booking_cents) from b), 0)
    - coalesce((select sum(amount_cents) from paid), 0)
    + coalesce((select sum(r.amount_cents) from payments r where r.kind = 'refund' and r.status = 'succeeded' and r.parent_payment_id in (select id from paid)), 0)
    + coalesce((select sum(rf.amount_cents) from refunds rf where rf.status = 'paid' and rf.payment_id in (select id from paid)
                  and (rf.refund_payment_id is null or not exists (select 1 from payments r2 where r2.id = rf.refund_payment_id and r2.kind = 'refund' and r2.status = 'succeeded'))), 0), 0)
$$;
comment on function app.booking_amount_owed(uuid) is 'r48 (2921): what the renter still owes on the booking: its total (the renter''s share) less every succeeded payment of it, refunds counted back. Pay links for the rental, the fees or the balance are capped at it.';

-- the most a link of a part may ask: what is open for the part, and never more than is owed
create function app.payreq_part_max(p_booking uuid, p_covers text) returns bigint
language sql stable security definer set search_path = public, app as $$
  select least(greatest(app.booking_part_open(p_booking, p_covers), 0), app.booking_amount_owed(p_booking))
$$;

-- staff links (and the reader, which goes through the same function)
select pg_temp.patch_fn('app.payreq_create_pre0202(uuid, jsonb)'::regprocedure,
  $o$    v_open := app.booking_part_open(b.id, v_covers);$o$,
  $n$    v_open := app.booking_part_open(b.id, v_covers);
    -- r48 (2921): the rental, the fees or the balance: at most what is owed, by default exactly that; nothing owed, no link
    if v_covers in ('rental', 'fees', 'balance') then
      v_open := app.payreq_part_max(b.id, v_covers);
      if v_open <= 0 then
        raise exception 'Nothing is owed on booking %: it is paid in full. A new charge is a later charge, with its reason', b.booking_number using errcode = '23514';
      end if;
      if nullif(p ->> 'amount_cents', '')::bigint > v_open then
        raise exception 'That is more than is owed on booking % (%): the renter already paid the rest. A charge on top is a later charge, with its reason', b.booking_number, app.fmt_money(v_open) using errcode = '23514';
      end if;
    end if;$n$);
-- a new link for the booking's money replaces every open one for the rental, the fees or the balance (they overlap)
select pg_temp.patch_fn('app.payreq_create_pre0202(uuid, jsonb)'::regprocedure,
  $o$  update payment_requests set status = 'cancelled' where booking_id = b.id and status = 'open' and kind = v_kind and covers = v_covers;$o$,
  $n$  update payment_requests set status = 'cancelled', last_error = coalesce(last_error, 'Replaced by a newer pay link')
   where booking_id = b.id and status = 'open' and kind = v_kind
     and (covers = v_covers or (v_kind = 'charge' and v_covers in ('rental', 'fees', 'balance') and covers in ('rental', 'fees', 'balance')));$n$);

-- the renter's own Pay the balance
select pg_temp.patch_fn('public.renter_balance_payreq(uuid, uuid, text)'::regprocedure,
  $o$  v_open := app.booking_part_open(b.id, 'balance');$o$,
  $n$  v_open := app.payreq_part_max(b.id, 'balance');$n$);
select pg_temp.patch_fn('public.renter_balance_payreq(uuid, uuid, text)'::regprocedure,
  $o$  update payment_requests set status = 'cancelled' where booking_id = b.id and status = 'open' and kind = 'charge' and covers = 'balance';$o$,
  $n$  update payment_requests set status = 'cancelled', last_error = coalesce(last_error, 'Replaced by a newer pay link')
   where booking_id = b.id and status = 'open' and kind = 'charge' and covers in ('rental', 'fees', 'balance');$n$);

-- the saved card charged for the rental or the fees: the same cap
alter function app.card_charge_begin(uuid, jsonb) rename to card_charge_begin_pre2921;
create function app.card_charge_begin(p_by uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  b bookings;
  v_covers text := coalesce(nullif(p ->> 'covers', ''), 'later');
  v_max bigint;
begin
  if v_covers in ('rental', 'fees', 'balance') then
    select * into b from bookings where id::text = p ->> 'booking' or booking_number = upper(btrim(coalesce(p ->> 'booking', '')));
    if b.id is not null then
      v_max := app.payreq_part_max(b.id, v_covers);
      if v_max <= 0 then
        raise exception 'Nothing is owed on booking %: it is paid in full. A new charge is a later charge, with its reason', b.booking_number using errcode = '23514';
      end if;
      if nullif(p ->> 'amount_cents', '')::bigint > v_max then
        raise exception 'That is more than is owed on booking % (%): the renter already paid the rest. A charge on top is a later charge, with its reason', b.booking_number, app.fmt_money(v_max) using errcode = '23514';
      end if;
    end if;
  end if;
  return app.card_charge_begin_pre2921(p_by, p);
end $$;
select pg_temp.copy_grants('app.card_charge_begin(uuid, jsonb)'::regprocedure, 'app.card_charge_begin_pre2921(uuid, jsonb)'::regprocedure);

-- ================================================================ 3. a payment lands: links for more than is owed end
create function app.payreq_cancel_overpaying(p_booking uuid) returns integer
language plpgsql security definer set search_path = public, app as $$
declare
  v_owed bigint := app.booking_amount_owed(p_booking);
  n integer;
begin
  update payment_requests q set status = 'cancelled',
         last_error = 'Cancelled by itself: a payment landed and ' || case when v_owed <= 0 then 'nothing is owed now' else 'only ' || app.fmt_money(v_owed) || ' is owed now' end
   where q.booking_id = p_booking and q.status = 'open' and q.kind = 'charge' and q.covers in ('rental', 'fees', 'balance') and q.amount_cents > v_owed;
  get diagnostics n = row_count;
  if n > 0 then
    perform app.log_booking_event(p_booking, 'adjusted', b.status::text, b.status::text, null,
      format('%s open pay %s cancelled by itself: a payment landed and %s', n, case when n = 1 then 'link' else 'links' end,
             case when v_owed <= 0 then 'nothing is owed now' else 'only ' || app.fmt_money(v_owed) || ' is owed now' end), null, 'system', '{}'::jsonb)
      from bookings b where b.id = p_booking;
  end if;
  return n;
end $$;

create function app.payments_cancel_overpaying_links() returns trigger
language plpgsql security definer set search_path = public, app as $$
begin
  if new.booking_id is not null and new.purpose = 'booking_total' and new.kind in ('charge', 'capture') and new.status = 'succeeded' then
    perform app.payreq_cancel_overpaying(new.booking_id);
  end if;
  return null;
end $$;
-- at commit: the link that was paid is marked paid by then, so only the others are looked at
create constraint trigger payments_cancel_overpaying_links after insert or update of status on payments
  deferrable initially deferred for each row execute function app.payments_cancel_overpaying_links();

-- the pay page asks again just before the card is captured: is this link still open, and still at most what is owed?
create function public.server_payreq_still_owed(p_id uuid) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare
  q payment_requests;
  v_owed bigint;
begin
  select * into q from payment_requests where id = p_id;
  if q.id is null then return jsonb_build_object('ok', false, 'message', 'This pay link is not valid.'); end if;
  if q.kind <> 'charge' or q.covers not in ('rental', 'fees', 'balance') or q.status = 'paid' then return jsonb_build_object('ok', true); end if;
  if q.status <> 'open' then
    return jsonb_build_object('ok', false, 'message', 'This pay link was cancelled: nothing was charged. Your booking page shows what is owed.');
  end if;
  v_owed := app.booking_amount_owed(q.booking_id);
  if q.amount_cents > v_owed then
    return jsonb_build_object('ok', false, 'owed_cents', v_owed,
      'message', case when v_owed <= 0 then 'Your booking is already paid in full: nothing was charged.'
                      else 'Your booking now owes ' || app.fmt_money(v_owed) || ', less than this link: nothing was charged. Your booking page shows what is owed.' end);
  end if;
  return jsonb_build_object('ok', true, 'owed_cents', v_owed);
end $$;

-- a link found too large at capture is cancelled, so it cannot be tried again
create function public.server_payreq_void_overpaying(p_id uuid) returns void
language sql security definer set search_path = public, app as $$
  update payment_requests set status = 'cancelled', last_error = 'Cancelled at payment: more than is owed'
   where id = p_id and status = 'open' and kind = 'charge' and covers in ('rental', 'fees', 'balance')
$$;

do $$
declare f text;
begin
  foreach f in array array['app.booking_amount_owed(uuid)', 'app.payreq_part_max(uuid, text)', 'app.payreq_cancel_overpaying(uuid)', 'app.payments_cancel_overpaying_links()',
                           'public.server_payreq_still_owed(uuid)', 'public.server_payreq_void_overpaying(uuid)'] loop
    execute format('revoke all on function %s from public, anon, authenticated', f);
    execute format('grant execute on function %s to service_role', f);
  end loop;
end $$;
