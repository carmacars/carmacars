-- 3101 (release 48, part MR; docs/changes/2026-11-20-r48-money-rules.md): extensions handled by a salesperson, their money,
-- and deposits.
--
-- 1. Extensions: each extension has who handles it (booking_extensions.handled_by), by default the booking's salesperson;
--    an Admin (or whoever handles it now) gives it to another salesperson, or to Admin (handled_queue 'admin', when the
--    salesperson is not helping), with the reason, in the booking's history.
-- 2. Commission on an extension goes to whoever handled it: the booking's salesperson earns on the booking less the
--    extensions handled by someone else; a salesperson who handled an extension earns on that extension (its rental
--    difference) as their own commission line on the booking, at their own rate and tier. An extension given to Admin
--    earns no commission (Customer service, Fleet and Finance never earn commission).
-- 3. The Money of an approved extension (app.extension_money, on the booking's extensions): the amount, whether it was
--    charged or paid, how (card and last 4, or the way received and its reference) and by whom; "Charge the card on file"
--    (extension_charge_begin, the server charges, extension_charge_finish) and "Record a payment" received another way
--    (extension_record_payment). Admin, Finance, and the salesperson handling it or the booking's salesperson.
-- 4. Debit deposits: a salesperson turns on "Allow debit and prepaid cards for this booking" (and off) like an Admin,
--    logged in the audit log and the booking's history (ops_do booking_allow_debit).
-- 5. The deposit hold on the card on file tapped twice (the owner's report, E-OKN1RH on CC-10481, November 16): the
--    staff hold request was made with channel 'auto', which a unique index of 0261 keeps to one per booking for the
--    pickup-day hold. After a first try was declined, the second tap inserted another 'auto' request and hit that index:
--    "That is already recorded ... Refresh the page" and nothing else. Now the staff request is channel 'link' with
--    auto false (as 2970's morning try), the index covers the pickup-day job only (auto), and a second tap while the
--    first is still with the bank says so in plain words; a hold already placed is shown, not asked again.
-- 6. Deposits are kept 30 days after the return before the release review (Program setting deposit_toll_window_days,
--    "Days a deposit is kept after the return before it is released", 30 by default; it was 7). Releasing sooner is an
--    Admin's decision with the reason (0155's release_in_window, logged).
-- No applied migration is edited: app.commission_sync and app.door are wrapped (_pre3101); app.commission_sync_pre0340
-- and app.deposit_hold_saved_begin are patched in place (the text replaced is checked).
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
declare d text := pg_get_functiondef(p_sig);
begin
  if position(p_old in d) = 0 then raise exception '3101: the text to change was not found in %: %', p_sig, left(p_old, 120); end if;
  execute replace(d, p_old, p_new);
end $$;

-- a salesperson: a staff member with the sales function (app.user_is_sales_staff is any staff member)
create function app.user_va_has_sales(p_user uuid) returns boolean
language sql stable security definer set search_path = public, app as $$ select p_user is not null and app.user_va_has(p_user, 'sales') $$;

-- ================================================================ 1. who handles an extension
alter table booking_extensions
  add column if not exists handled_by uuid references users (id),
  add column if not exists handled_queue text not null default 'sales',
  add column if not exists handled_set_by uuid references users (id),
  add column if not exists handled_set_at timestamptz,
  add column if not exists handled_reason text;
alter table booking_extensions drop constraint if exists booking_extensions_handled_queue_check;
alter table booking_extensions add constraint booking_extensions_handled_queue_check check (handled_queue in ('sales', 'admin'));
create index if not exists booking_extensions_handled_by_idx on booking_extensions (handled_by);
comment on column booking_extensions.handled_by is 'Who handles this extension (3101): the booking''s salesperson by default; another salesperson or an Admin when it is given to them. Commission on the extension goes to them (a salesperson only).';
comment on column booking_extensions.handled_queue is 'sales (a salesperson handles it) or admin (given to Admin: no commission) (3101)';

create function app.extension_default_handler() returns trigger
language plpgsql security definer set search_path = public, app as $$
declare v_sales uuid;
begin
  if new.handled_by is null and new.handled_queue = 'sales' then
    select b.sales_staff_id into v_sales from bookings b where b.id = new.booking_id;
    new.handled_by := v_sales;
    if v_sales is null or not app.user_va_has_sales(v_sales) then new.handled_queue := 'admin'; end if;
  end if;
  return new;
end $$;
create trigger booking_extensions_default_handler before insert on booking_extensions for each row execute function app.extension_default_handler();

-- the extensions that exist: the booking's salesperson (as their commission already counted them)
update booking_extensions e set handled_by = b.sales_staff_id
  from bookings b where b.id = e.booking_id and e.handled_by is null and b.sales_staff_id is not null;
update booking_extensions e set handled_queue = 'admin' where e.handled_by is null or not app.user_va_has_sales(e.handled_by);

-- p: {extension, to: a person's id or 'admin', reason}
create function app.extension_assign(p_by uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  e booking_extensions;
  b bookings;
  v_to text := nullif(btrim(coalesce(p ->> 'to', '')), '');
  v_user uuid;
  v_queue text;
  v_reason text := nullif(btrim(coalesce(p ->> 'reason', '')), '');
  v_name text;
begin
  select * into e from booking_extensions where id = nullif(p ->> 'extension', '')::uuid for update;
  if e.id is null then raise exception 'Extension not found' using errcode = 'P0002'; end if;
  if not (app.user_is_admin(p_by) or e.handled_by = p_by) then
    raise exception 'An Admin, or the salesperson handling it, gives an extension to someone else' using errcode = '42501';
  end if;
  if e.status in ('declined', 'lapsed', 'cancelled') then raise exception 'This extension is %: there is nothing to handle', e.status using errcode = '23514'; end if;
  if v_reason is null or char_length(v_reason) < 3 then raise exception 'Say why it is given to someone else' using errcode = '22023'; end if;
  if v_to is null then raise exception 'Choose who handles it: a salesperson, or Admin' using errcode = '22023'; end if;
  if lower(v_to) = 'admin' then
    v_queue := 'admin'; v_user := case when app.user_is_admin(p_by) then p_by end;
  else
    v_user := v_to::uuid;
    if app.user_va_has_sales(v_user) then v_queue := 'sales';
    elsif app.user_is_admin(v_user) then v_queue := 'admin';
    else raise exception 'An extension is handled by a salesperson or by Admin' using errcode = '23514'; end if;
  end if;
  if (e.handled_by, e.handled_queue) is not distinct from (v_user, v_queue) then raise exception 'It is already theirs' using errcode = '22023'; end if;
  select * into b from bookings where id = e.booking_id;
  update booking_extensions set handled_by = v_user, handled_queue = v_queue, handled_set_by = p_by, handled_set_at = now(), handled_reason = left(v_reason, 300) where id = e.id;
  v_name := case when v_queue = 'admin' then 'Admin' else coalesce((select u.full_name from users u where u.id = v_user), 'a salesperson') end;
  perform app.log_booking_event(b.id, 'adjusted', b.status::text, b.status::text, null,
    format('Extension %s given to %s (was %s): %s', e.seq, v_name,
           case when e.handled_queue = 'admin' then 'Admin' else coalesce((select u.full_name from users u where u.id = e.handled_by), 'nobody') end, v_reason),
    p_by, 'staff', jsonb_build_object('extension_id', e.id, 'handled_by', v_user, 'handled_queue', v_queue, 'was', e.handled_by));
  insert into audit_log (actor_user_id, action, entity_table, entity_id, before, after)
  values (p_by, 'extension_assign', 'booking_extensions', e.id::text, jsonb_build_object('handled_by', e.handled_by, 'handled_queue', e.handled_queue),
          jsonb_build_object('handled_by', v_user, 'handled_queue', v_queue, 'reason', v_reason));
  perform app.commission_sync(b.id);
  return jsonb_build_object('ok', true, 'extension_id', e.id, 'handled_by', v_user, 'handled_queue', v_queue, 'name', v_name);
end $$;

-- ================================================================ 2. commission on an extension
-- the rental difference of the paid extensions of a booking handled by someone other than p_staff
create function app.ext_other_base_cents(p_booking uuid, p_staff uuid) returns bigint
language sql stable security definer set search_path = public, app as $$
  select coalesce(sum(greatest(e.rental_difference_cents, 0)), 0)::bigint from booking_extensions e
   where e.booking_id = p_booking and e.status = 'confirmed' and e.handled_by is distinct from p_staff
$$;
create function app.ext_handles(p_booking uuid, p_staff uuid) returns boolean
language sql stable security definer set search_path = public, app as $$
  select exists (select 1 from booking_extensions e where e.booking_id = p_booking and e.status = 'confirmed' and e.handled_queue = 'sales' and e.handled_by = p_staff)
$$;

select pg_temp.patch_fn('app.commission_sync_pre0340(uuid)'::regprocedure,
  $o$  v_base := case when v_reason is null then app.commission_base_cents(b.id) else 0 end;$o$,
  $n$  v_base := case when v_reason is null then greatest(app.commission_base_cents(b.id) - app.ext_other_base_cents(b.id, v_staff), 0) else 0 end;$n$);
select pg_temp.patch_fn('app.commission_sync_pre0340(uuid)'::regprocedure,
  $o$x.kind = 'commission' and x.staff_id is distinct from v_staff$o$,
  $n$x.kind = 'commission' and x.staff_id is distinct from v_staff and not app.ext_handles(b.id, x.staff_id)$n$);

alter function app.commission_sync(uuid) rename to commission_sync_pre3101;
create function app.commission_sync(p_booking uuid) returns void
language plpgsql security definer set search_path = public, app as $$
declare
  b bookings;
  v_main uuid;
  h record;
  c staff_commissions;
  v_reason text;
  v_earned boolean;
  v_month date;
begin
  perform app.commission_sync_pre3101(p_booking);
  select * into b from bookings where id = p_booking;
  if b.id is null then return; end if;
  v_main := case when b.sales_sourced then b.sales_staff_id end;
  v_reason := case when b.booking_type = 'owner' then 'Owner Booking'
                   when b.status in ('cancelled', 'no_show', 'expired', 'declined') then 'Cancelled booking'
                   when exists (select 1 from disputes d where d.booking_id = b.id and d.status = 'lost') then 'Charged back' end;
  v_month := app.month_start(app.local_date(coalesce(b.checked_in_at, b.return_at)));
  -- each salesperson who handled a paid extension (not the booking's own salesperson): their own line on the extension
  for h in select e.handled_by as staff, sum(greatest(e.rental_difference_cents, 0))::bigint as base, sum(greatest(e.new_days - e.previous_days, 0))::integer as days
             from booking_extensions e
            where e.booking_id = b.id and e.status = 'confirmed' and e.handled_queue = 'sales' and e.handled_by is not null
              and e.handled_by is distinct from v_main and app.user_va_has_sales(e.handled_by)
            group by e.handled_by loop
    select * into c from staff_commissions where booking_id = b.id and staff_id = h.staff and kind = 'commission' for update;
    if c.id is not null and c.admin_reversed then continue; end if;
    if v_reason is not null then
      if c.id is not null and c.status not in ('void', 'reversed') then perform app.commission_close(c.id, v_reason); end if;
      continue;
    end if;
    v_earned := b.status in ('returned', 'closed') and app.booking_paid_in_full(b.id) and not app.staff_home_address_missing(h.staff)
                and not exists (select 1 from disputes d where d.booking_id = b.id and d.status in ('open', 'evidence_submitted'));
    if c.id is null then
      if app.credit_blocked(h.staff) then continue; end if;
      insert into staff_commissions (booking_id, staff_id, kind, month, rental_days, base_cents, status, earned_at, note)
      values (b.id, h.staff, 'commission', v_month, h.days, h.base, case when v_earned then 'pending_approval' else 'accruing' end,
              case when v_earned then now() end, 'Extension handled');
    elsif c.status in ('void', 'reversed') then
      update staff_commissions set status = case when v_earned then 'pending_approval' else 'accruing' end, reversed_at = null, reversed_by = null, reason = null,
             earned_at = case when v_earned then coalesce(earned_at, now()) end, month = v_month, rental_days = h.days, base_cents = h.base, note = 'Extension handled', updated_at = now()
       where id = c.id;
    elsif c.status <> 'paid' then
      update staff_commissions set month = v_month, rental_days = h.days, base_cents = h.base,
             status = case when status = 'accruing' and v_earned then 'pending_approval' when status = 'pending_approval' and not v_earned then 'accruing'
                           when status = 'approved' and base_cents <> h.base then 'pending_approval' else status end,
             earned_at = case when status = 'accruing' and v_earned then now() when status = 'pending_approval' and not v_earned then null else earned_at end,
             approved_at = case when status = 'approved' and base_cents <> h.base then null else approved_at end,
             approved_by = case when status = 'approved' and base_cents <> h.base then null else approved_by end, updated_at = now()
       where id = c.id;
    end if;
    perform app.commission_retier(h.staff, v_month);
  end loop;
  -- a salesperson whose extension was given to someone else (and who is not the booking's salesperson): closed
  for c in select x.* from staff_commissions x
            where x.booking_id = b.id and x.kind = 'commission' and x.staff_id is distinct from v_main and x.status not in ('void', 'reversed', 'paid')
              and x.reversed_at is null and x.note = 'Extension handled' and not app.ext_handles(b.id, x.staff_id) loop
    perform app.commission_close(c.id, 'The extension is credited to someone else now');
  end loop;
end $$;
select pg_temp.copy_grants('app.commission_sync(uuid)'::regprocedure, 'app.commission_sync_pre3101(uuid)'::regprocedure);

-- ================================================================ 3. the money of an extension
create function app.extension_money(p_extension uuid) returns jsonb
language sql stable security definer set search_path = public, app as $$
  select jsonb_build_object('amount_cents', e.total_cents, 'rental_cents', e.rental_difference_cents, 'fees_cents', e.fees_difference_cents, 'hst_cents', e.hst_cents,
           'state', case when e.status = 'confirmed' then 'paid' when e.status = 'approved' then 'waiting for payment' else e.status end,
           'paid', e.status = 'confirmed' and (e.total_cents = 0 or pay.status = 'succeeded'),
           'paid_at', e.paid_at, 'method', pay.method, 'method_label', case when pay.id is not null then app.payment_method_label(pay.method) end,
           'card', case when pay.card_last4 is not null then coalesce(initcap(pay.card_brand), 'Card') || ' ' || pay.card_last4 end,
           'reference', case when ppd.processor = 'offline' then ppd.raw ->> 'reference' end,
           'recorded_by', (select u.full_name from users u where u.id = e.confirmed_by),
           'handled_by', e.handled_by, 'handled_queue', e.handled_queue,
           'handler', case when e.handled_queue = 'admin' then 'Admin' else (select u.full_name from users u where u.id = e.handled_by) end,
           'link', (select jsonb_build_object('status', q.status, 'sent_at', coalesce(q.texted_at, q.emailed_at), 'expires_at', q.expires_at) from payment_requests q
                     where q.extension_id = e.id order by q.created_at desc limit 1),
           'may_charge', e.status = 'approved' and exists (select 1 from bookings b where b.id = e.booking_id and b.card_on_file_id is not null))
    from booking_extensions e
    left join payments pay on pay.id = e.payment_id
    left join payment_processor_details ppd on ppd.payment_id = pay.id
   where e.id = p_extension
$$;

-- who may collect an extension: an Admin, Finance, the salesperson handling it or the booking's salesperson
create function app.extension_collect_check(p_by uuid, e booking_extensions) returns void
language plpgsql stable security definer set search_path = public, app as $$
begin
  if app.user_is_admin(p_by) or app.user_runs_finance(p_by) then return; end if;
  if app.user_va_has_sales(p_by) and (e.handled_by = p_by or exists (select 1 from bookings b where b.id = e.booking_id and b.sales_staff_id = p_by)) then return; end if;
  raise exception 'An Admin, Finance, or the salesperson handling the extension collects it' using errcode = '42501';
end $$;

create function app.extension_charge_begin(p_by uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  e booking_extensions;
  c jsonb;
begin
  select * into e from booking_extensions where id = nullif(p ->> 'extension', '')::uuid;
  if e.id is null then raise exception 'Extension not found' using errcode = 'P0002'; end if;
  perform app.extension_collect_check(p_by, e);
  if e.status = 'confirmed' then raise exception 'This extension is already paid' using errcode = '23514'; end if;
  if e.status <> 'approved' then raise exception 'This extension is %, not approved and waiting for payment', e.status using errcode = '23514'; end if;
  if e.total_cents <= 0 then raise exception 'This extension has nothing to pay: record it as paid instead' using errcode = '23514'; end if;
  select jsonb_build_object('method_id', s.processor_method_id, 'customer_id', s.processor_customer_id, 'brand', pm.card_brand, 'last4', pm.card_last4)
    into c from bookings b join payment_methods pm on pm.id = b.card_on_file_id join payment_method_secrets s on s.payment_method_id = pm.id where b.id = e.booking_id;
  if c is null or c ->> 'method_id' is null then raise exception 'No card is on file for this booking: send the pay link or record a payment received another way' using errcode = '23514'; end if;
  return jsonb_build_object('extension_id', e.id, 'booking_id', e.booking_id, 'booking_number', (select b.booking_number from bookings b where b.id = e.booking_id),
    'amount_cents', e.total_cents, 'customer_id', c ->> 'customer_id', 'method_id', c ->> 'method_id', 'card', c - 'method_id' - 'customer_id');
end $$;

-- p: {extension, ok, intent_id, charge_id, amount_cents, card_brand, card_last4, error}
create function app.extension_charge_finish(p_by uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  e booking_extensions;
  b bookings;
  r jsonb;
begin
  select * into e from booking_extensions where id = nullif(p ->> 'extension', '')::uuid;
  if e.id is null then raise exception 'Extension not found' using errcode = 'P0002'; end if;
  perform app.extension_collect_check(p_by, e);
  select * into b from bookings where id = e.booking_id;
  if not coalesce((p ->> 'ok')::boolean, false) then
    perform app.log_booking_event(b.id, 'extension', b.status::text, b.status::text, null,
      format('Extension %s: the card on file was not charged (%s)', e.seq, coalesce(nullif(p ->> 'error', ''), 'declined')), p_by, 'staff',
      jsonb_build_object('extension_id', e.id, 'step', 'charge_failed'));
    return jsonb_build_object('ok', false, 'message', coalesce(nullif(p ->> 'error', ''), 'The card was declined. Nothing was charged.'));
  end if;
  r := app.confirm_extension_payment(e.id, jsonb_build_object('processor', 'stripe', 'payment_id', p ->> 'intent_id', 'charge_id', p ->> 'charge_id'),
                                     nullif(p ->> 'amount_cents', '')::bigint, now(), p_by);
  if coalesce((r ->> 'ok')::boolean, false) and r ->> 'payment_id' is not null then
    update payments set card_brand = coalesce(nullif(p ->> 'card_brand', ''), card_brand), card_last4 = coalesce(nullif(p ->> 'card_last4', ''), card_last4)
     where id = (r ->> 'payment_id')::uuid;
    perform app.commission_sync(b.id);
  end if;
  return r;
end $$;

-- p: {extension, method (e_transfer, cash, cheque, bank_transfer, other), reference, received_on, note}
create function app.extension_record_payment(p_by uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  e booking_extensions;
  v_method text := nullif(btrim(coalesce(p ->> 'method', '')), '');
  v_ref text := nullif(btrim(coalesce(p ->> 'reference', '')), '');
  v_note text := nullif(btrim(coalesce(p ->> 'note', '')), '');
  v_on date := coalesce(nullif(p ->> 'received_on', '')::date, app.today());
  r jsonb;
begin
  select * into e from booking_extensions where id = nullif(p ->> 'extension', '')::uuid;
  if e.id is null then raise exception 'Extension not found' using errcode = 'P0002'; end if;
  perform app.extension_collect_check(p_by, e);
  if e.status = 'confirmed' then return jsonb_build_object('ok', true, 'already_confirmed', true, 'extension_id', e.id); end if;
  if v_method is null or v_method not in ('e_transfer', 'cash', 'cheque', 'bank_transfer', 'other') then
    raise exception 'Choose how it was received: e-Transfer, cash, cheque, bank transfer or another way' using errcode = '22023';
  end if;
  if v_method = 'e_transfer' and (v_ref is null or char_length(v_ref) < 3) then raise exception 'Enter the e-Transfer reference number' using errcode = '22023'; end if;
  if v_method = 'other' and v_note is null then raise exception 'Say how it was received' using errcode = '22023'; end if;
  if v_on > app.today() then raise exception 'The day it was received cannot be in the future' using errcode = '22023'; end if;
  r := app.confirm_extension_payment(e.id, jsonb_build_object('processor', 'offline', 'payment_id', v_method || ':' || coalesce(v_ref, gen_random_uuid()::text)),
                                     e.total_cents, now(), p_by);
  if not coalesce((r ->> 'ok')::boolean, false) then return r; end if;
  if r ->> 'payment_id' is not null then
    update payments set method = v_method, payment_method_id = null where id = (r ->> 'payment_id')::uuid;
    update payment_processor_details set raw = jsonb_strip_nulls(jsonb_build_object('reference', v_ref, 'received_on', v_on, 'recorded_by', p_by, 'note', v_note, 'covers', 'extension'))
     where payment_id = (r ->> 'payment_id')::uuid;
  end if;
  perform app.log_booking_event(e.booking_id, 'extension', null, (select status::text from bookings where id = e.booking_id), null,
    format('Extension %s paid: %s received by %s%s', e.seq, app.fmt_money(e.total_cents), app.payment_method_label(v_method), coalesce(' (' || v_ref || ')', '')),
    p_by, 'staff', jsonb_build_object('extension_id', e.id, 'method', v_method, 'reference', v_ref));
  perform app.commission_sync(e.booking_id);
  return r;
end $$;

-- the booking page's extensions carry their money
alter function app.admin_booking_detail(uuid) rename to admin_booking_detail_pre3101;
create function app.admin_booking_detail(p_booking uuid) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare
  v jsonb := app.admin_booking_detail_pre3101(p_booking);
begin
  if v is null then return v; end if;
  return v || jsonb_build_object('extensions', coalesce((select jsonb_agg(to_jsonb(x) || jsonb_build_object('money', app.extension_money(x.id)) order by x.seq)
                                                          from booking_extensions x where x.booking_id = p_booking), '[]'::jsonb));
end $$;
select pg_temp.copy_grants('app.admin_booking_detail(uuid)'::regprocedure, 'app.admin_booking_detail_pre3101(uuid)'::regprocedure);

-- ================================================================ 4. a salesperson allows a debit deposit
create function app.booking_allow_debit_staff(p_by uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  r jsonb;
  b bookings;
  v_on boolean := coalesce((p ->> 'allow')::boolean, true);
begin
  if not (app.user_is_admin(p_by) or app.user_va_has_sales(p_by)) then
    raise exception 'An Admin or a salesperson allows debit and prepaid cards for a booking' using errcode = '42501';
  end if;
  -- the person is checked here: 0500's staff read lets app.assert_admin through for this one call
  perform set_config('app.staff_view', p_by::text, true);
  r := app.booking_allow_debit(p_by, p);
  perform set_config('app.staff_view', '', true);
  select * into b from bookings where id = (r ->> 'booking_id')::uuid;
  perform app.log_booking_event(b.id, 'adjusted', b.status::text, b.status::text, null,
    case when v_on then 'Debit and prepaid cards allowed for this booking: ' || coalesce(nullif(btrim(p ->> 'reason'), ''), '')
         else 'A credit card is required again for this booking' end, p_by, 'staff', jsonb_build_object('debit_allowed', v_on));
  return r;
end $$;

-- ================================================================ 5. the deposit hold on the card on file, tapped twice
drop index if exists payment_requests_auto_hold_once;
create unique index if not exists payment_requests_auto_hold_once on payment_requests (booking_id) where channel = 'auto' and auto;
select pg_temp.patch_fn('app.deposit_hold_saved_begin(uuid, jsonb)'::regprocedure,
  $o$  if exists (select 1 from deposits d where d.booking_id = b.id and d.status in ('held', 'captured', 'settled')) then
    raise exception 'The deposit on % is already taken', b.booking_number using errcode = '23514';
  end if;$o$,
  $n$  if exists (select 1 from deposits d where d.booking_id = b.id and d.status in ('held', 'captured', 'settled')) then
    raise exception 'The deposit on % is already taken: %', b.booking_number,
      (select format('%s %s%s', app.fmt_money(d.amount_cents), case d.status when 'held' then 'held on the card' else 'taken' end,
                     case when d.paid_method is not null and d.method = 'offline' then ' by ' || app.payment_method_label(d.paid_method) else '' end)
         from deposits d where d.booking_id = b.id) using errcode = '23514';
  end if;
  -- a second tap while the first is still with the bank: said, not asked again (3101)
  if exists (select 1 from payment_requests pr where pr.booking_id = b.id and pr.kind = 'hold' and pr.covers = 'deposit' and pr.status = 'open'
                and pr.reason = 'Deposit hold on the card on file' and pr.created_at > now() - interval '2 minutes') then
    raise exception 'The deposit hold on the card on file is already being placed (asked a moment ago). Wait a few seconds, then refresh the page to see the result' using errcode = '23514';
  end if;$n$);
select pg_temp.patch_fn('app.deposit_hold_saved_begin(uuid, jsonb)'::regprocedure,
  $o$'Deposit hold on the card on file', p ->> 'token_sha256', 'auto', now() + interval '1 day', p_by, false, 'open')$o$,
  $n$'Deposit hold on the card on file', p ->> 'token_sha256', 'link', now() + interval '1 day', p_by, false, 'open')$n$);
-- the failure of a staff hold names its request by its reason now (the channel is link)
select pg_temp.patch_fn('app.deposit_hold_saved_failed(uuid, jsonb)'::regprocedure,
  $o$if q.id is null or q.kind <> 'hold' or q.covers <> 'deposit' or q.created_by is distinct from p_by then$o$,
  $n$if q.id is null or q.kind <> 'hold' or q.covers <> 'deposit' or (q.created_by is distinct from p_by and not app.user_is_admin(p_by)) then$n$);

-- ================================================================ 6. deposits kept 30 days after the return
alter table program_settings alter column deposit_toll_window_days set default 30;
update program_settings set deposit_toll_window_days = 30 where deposit_toll_window_days = 7;
comment on column program_settings.deposit_toll_window_days is
  'Days a deposit is kept after the return before it is released (3101: 30 by default, was 7): tolls, tickets and damage come in during this time; the release review (Fleet, then Finance) finishes it after. Releasing sooner is an Admin''s decision with the reason (0155). The longest hold-back stays deposit_holdback_days.';

-- ================================================================ the door
alter function app.door(uuid, text, text, text, jsonb) rename to door_pre3101;
create function app.door(p_user uuid, p_aal text, p_call text, p_name text, p jsonb default '{}'::jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare v jsonb := coalesce(p, '{}'::jsonb) - '_va';
begin
  if p_call = 'ops_do' and p_name in ('extension_assign', 'extension_charge_begin', 'extension_charge_finish', 'extension_record_payment', 'booking_allow_debit') then
    if coalesce(p, '{}'::jsonb) ? '_va' then perform set_config('app.va_active', coalesce(p ->> '_va', ''), true); end if;
    perform app.door_begin(p_user, p_aal);
    return case p_name
      when 'extension_assign' then app.extension_assign(p_user, v)
      when 'extension_charge_begin' then app.extension_charge_begin(p_user, v)
      when 'extension_charge_finish' then app.extension_charge_finish(p_user, v)
      when 'extension_record_payment' then app.extension_record_payment(p_user, v)
      else app.booking_allow_debit_staff(p_user, v) end;
  end if;
  return app.door_pre3101(p_user, p_aal, p_call, p_name, p);
end $$;
select pg_temp.copy_grants('app.door(uuid, text, text, text, jsonb)'::regprocedure, 'app.door_pre3101(uuid, text, text, text, jsonb)'::regprocedure);

revoke all on function app.user_va_has_sales(uuid), app.extension_default_handler(), app.extension_assign(uuid, jsonb), app.ext_other_base_cents(uuid, uuid), app.ext_handles(uuid, uuid),
  app.commission_sync_pre3101(uuid), app.extension_money(uuid), app.extension_collect_check(uuid, booking_extensions), app.extension_charge_begin(uuid, jsonb),
  app.extension_charge_finish(uuid, jsonb), app.extension_record_payment(uuid, jsonb), app.admin_booking_detail_pre3101(uuid), app.booking_allow_debit_staff(uuid, jsonb),
  app.door_pre3101(uuid, text, text, text, jsonb) from public, anon, authenticated;
grant execute on function app.user_va_has_sales(uuid), app.extension_default_handler(), app.extension_assign(uuid, jsonb), app.ext_other_base_cents(uuid, uuid), app.ext_handles(uuid, uuid),
  app.commission_sync_pre3101(uuid), app.extension_money(uuid), app.extension_collect_check(uuid, booking_extensions), app.extension_charge_begin(uuid, jsonb),
  app.extension_charge_finish(uuid, jsonb), app.extension_record_payment(uuid, jsonb), app.admin_booking_detail_pre3101(uuid), app.booking_allow_debit_staff(uuid, jsonb),
  app.door_pre3101(uuid, text, text, text, jsonb) to service_role;
