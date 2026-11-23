-- 3600 (release 49): gift cards, vouchers and gifted rentals (docs/changes/2026-11-23-r49-gift-cards.md).
--
-- The owner's backlog, Nov 20: "Gift cards, vouchers and gifted rentals."
--   1. A gift card bought on /gift-cards: a fixed or typed amount, paid by card (Stripe, captured at once), emailed to
--      the recipient with the buyer's message on the day the buyer picks (at once without one), with a printable card
--      (/gift-cards/card/<token>, print or save as PDF). No HST is charged on the sale (Excise Tax Act s. 181.2: a gift
--      certificate is not a supply); HST is in the rental it later pays for, as the site already charges it.
--   2. A gifted rental: a car and a number of days bought for someone. Priced with the site's own quote
--      (app.price_quote: the rental, its fees and HST as the site applies them, insurance never with HST), it becomes a
--      credit tied to the recipient's email: only the account with that address may use it, on that car or any other.
--   3. Vouchers by an Admin: an amount (a stored credit that keeps its remainder, kind voucher) or a percentage (a promo
--      code, promo_codes of 0016, with its limits). A gift card or gifted rental sold for money never expires (Ontario
--      Consumer Protection Act, O. Reg. 17/05 s. 25.3): the table refuses an end date on one. A voucher given free may end.
--      Every issue and void names the Admin and the reason (audit_log and the ledger).
--   4. Redemption on Sign and pay: the balance is applied before the card, a part leaves the rest on the card, and it
--      never pays the refundable deposit (it applies only to what is due at booking; the deposit is a separate hold). A
--      renter with no saved card pays at least gift_card_min_card_cents by card, so the card for the deposit is saved.
--      Credit card coverage (option 2) needs the rental paid on that card: no gift card there.
--   5. gift_card_ledger: every issue, redeem, release, refund, void and adjustment, in cents, insert-only; the balance is
--      kept by the ledger's trigger and can never go below zero (checks on both tables). A refund of a booking paid in
--      part by gift card returns that part to the card balance first (a refund row of its own, approved with the card
--      refund, paid at once), the rest to the card it was paid with.
--   6. Admin and Finance: Money > Gift cards (list, search, balance history, liability outstanding); Admin issues,
--      voids with a reason and resends. Renter: Account > Gift cards (balances, add a code, gifts sent).
-- Emails: renter_gift_card_receipt, renter_gift_card_delivered, renter_gift_card_sent, renter_gift_card_used,
-- renter_gift_card_refunded, staff_gift_card_sold (Finance and Admin digest), staff_gift_card_voided (immediate).
-- Every function is for the server (service_role); nothing is added to the browser roles. No applied migration is edited.
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

-- ================================================================ 1. settings
alter table program_settings
  add column if not exists gift_cards_on boolean not null default true,
  add column if not exists gift_card_min_cents bigint not null default 2500 check (gift_card_min_cents between 100 and 100000),
  add column if not exists gift_card_max_cents bigint not null default 200000 check (gift_card_max_cents between 1000 and 1000000),
  add column if not exists gift_card_presets_cents bigint[] not null default array[5000, 10000, 25000, 50000]::bigint[],
  add column if not exists gift_rental_max_days integer not null default 14 check (gift_rental_max_days between 1 and 60),
  add column if not exists gift_card_min_card_cents bigint not null default 100 check (gift_card_min_card_cents between 0 and 10000),
  add column if not exists gift_voucher_max_cents bigint not null default 100000 check (gift_voucher_max_cents between 100 and 1000000);
comment on column program_settings.gift_cards_on is 'Gift cards (3600): gift cards and gifted rentals are sold on /gift-cards and redeemed on Sign and pay (on by default).';
comment on column program_settings.gift_card_min_cents is 'Gift cards (3600): the smallest amount a buyer may type ($25).';
comment on column program_settings.gift_card_max_cents is 'Gift cards (3600): the largest gift card or gifted rental sold online ($2,000).';
comment on column program_settings.gift_card_presets_cents is 'Gift cards (3600): the amounts offered as buttons ($50, $100, $250, $500).';
comment on column program_settings.gift_rental_max_days is 'Gift cards (3600): the most days a gifted rental may be bought for (14).';
comment on column program_settings.gift_card_min_card_cents is 'Gift cards (3600): a renter with no saved card pays at least this by card ($1.00), so the card for the deposit is saved.';
comment on column program_settings.gift_voucher_max_cents is 'Gift cards (3600): the largest voucher credit an Admin issues in one go ($1,000).';

-- payments: a booking paid (in part) from a gift card balance is a payment of its own, method gift_card
alter table payments drop constraint payments_method_check;
alter table payments add constraint payments_method_check check (method = any (array['card', 'pre_authorized_debit', 'e_transfer', 'bank_transfer',
  'cheque', 'cash', 'other', 'platform_payout', 'insurer', 'gift_card']));

-- ================================================================ 2. tables
create table gift_cards (
  id                 uuid primary key default gen_random_uuid(),
  code               text not null unique check (code ~ '^CCGC-[A-HJ-NP-Z2-9]{4}-[A-HJ-NP-Z2-9]{4}-[A-HJ-NP-Z2-9]{4}$'),
  code_last4         text generated always as (right(code, 4)) stored,
  kind               text not null check (kind in ('purchased', 'gifted_rental', 'voucher')),
  status             text not null default 'pending_payment' check (status in ('pending_payment', 'active', 'voided', 'cancelled')),
  initial_cents      bigint not null check (initial_cents > 0),
  balance_cents      bigint not null default 0 check (balance_cents >= 0),
  currency           text not null default 'CAD' check (currency = 'CAD'),
  expires_at         timestamptz,
  buyer_user_id      uuid references users (id),
  buyer_name         text check (buyer_name is null or length(buyer_name) between 1 and 120),
  buyer_email        text check (buyer_email is null or buyer_email = lower(buyer_email)),
  recipient_name     text not null check (length(recipient_name) between 1 and 120),
  recipient_email    text check (recipient_email is null or (recipient_email = lower(btrim(recipient_email)) and recipient_email ~ '^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$')),
  message            text check (message is null or length(message) <= 500),
  send_on            date,
  sent_at            timestamptz,
  send_count         integer not null default 0,
  recipient_user_id  uuid references users (id),
  claimed_at         timestamptz,
  vehicle_id         uuid references vehicles (id),
  rental_days        integer check (rental_days is null or rental_days between 1 and 60),
  rental_text        text,
  view_token         text not null unique default (replace(gen_random_uuid()::text, '-', '') || replace(gen_random_uuid()::text, '-', '')),
  stripe_intent_id   text unique,
  card_text          text,
  paid_at            timestamptz,
  issued_by          uuid references users (id),
  issue_reason       text check (issue_reason is null or length(issue_reason) between 3 and 300),
  voided_at          timestamptz,
  voided_by          uuid references users (id),
  void_reason        text check (void_reason is null or length(void_reason) between 3 and 300),
  created_at         timestamptz not null default now(),
  updated_at         timestamptz not null default now(),
  -- Ontario: a gift card sold for money has no end date; only a voucher given free may end
  constraint gift_cards_no_expiry_when_sold check (expires_at is null or kind = 'voucher'),
  constraint gift_cards_balance_within check (balance_cents <= initial_cents),
  constraint gift_cards_rental_car check (kind <> 'gifted_rental' or (vehicle_id is not null and rental_days is not null and recipient_email is not null)),
  constraint gift_cards_sold_by check (kind = 'voucher' or buyer_user_id is not null),
  constraint gift_cards_voucher_by check (kind <> 'voucher' or (issued_by is not null and issue_reason is not null)),
  constraint gift_cards_void_why check (status <> 'voided' or (voided_by is not null and void_reason is not null and voided_at is not null))
);
create index gift_cards_buyer_idx on gift_cards (buyer_user_id);
create index gift_cards_recipient_user_idx on gift_cards (recipient_user_id);
create index gift_cards_recipient_email_idx on gift_cards (recipient_email);
create index gift_cards_vehicle_idx on gift_cards (vehicle_id);
create index gift_cards_send_idx on gift_cards (send_on) where status = 'active' and sent_at is null;
comment on table gift_cards is 'Gift cards (3600): a gift card or gifted rental sold online, or a voucher credit an Admin issued. The balance is kept by gift_card_ledger and never goes below zero. A card sold for money never expires.';
comment on column gift_cards.view_token is 'The secret of the printable card page (/gift-cards/card/<token>), sent only to the recipient and the buyer.';

create table gift_card_applications (
  id            uuid primary key default gen_random_uuid(),
  gift_card_id  uuid not null references gift_cards (id),
  booking_id    uuid not null references bookings (id),
  amount_cents  bigint not null check (amount_cents > 0),
  status        text not null default 'applied' check (status in ('applied', 'paid', 'released')),
  payment_id    uuid references payments (id),
  applied_by    uuid references users (id),
  applied_at    timestamptz not null default now(),
  released_at   timestamptz,
  release_reason text,
  check (status <> 'paid' or payment_id is not null)
);
create index gift_card_applications_card_idx on gift_card_applications (gift_card_id);
create index gift_card_applications_booking_idx on gift_card_applications (booking_id);
create index gift_card_applications_payment_idx on gift_card_applications (payment_id);
create unique index gift_card_applications_one_open on gift_card_applications (gift_card_id, booking_id) where status = 'applied';
comment on table gift_card_applications is 'Gift cards (3600): a gift card balance set aside for a booking on Sign and pay (applied), used when the booking is confirmed (paid), or put back (released).';

create table gift_card_ledger (
  id                  bigint generated always as identity primary key,
  gift_card_id        uuid not null references gift_cards (id),
  kind                text not null check (kind in ('issue', 'redeem', 'release', 'refund', 'void', 'adjust')),
  amount_cents        bigint not null check (amount_cents <> 0),
  balance_after_cents bigint not null check (balance_after_cents >= 0),
  booking_id          uuid references bookings (id),
  application_id      uuid references gift_card_applications (id),
  payment_id          uuid references payments (id),
  refund_id           uuid references refunds (id),
  created_by          uuid references users (id),
  reason              text check (reason is null or length(reason) <= 300),
  created_at          timestamptz not null default now(),
  check ((kind in ('issue', 'release', 'refund') and amount_cents > 0) or (kind in ('redeem', 'void') and amount_cents < 0) or kind = 'adjust')
);
create index gift_card_ledger_card_idx on gift_card_ledger (gift_card_id, id);
create index gift_card_ledger_booking_idx on gift_card_ledger (booking_id);
create index gift_card_ledger_application_idx on gift_card_ledger (application_id);
create index gift_card_ledger_payment_idx on gift_card_ledger (payment_id);
create index gift_card_ledger_refund_idx on gift_card_ledger (refund_id);
comment on table gift_card_ledger is 'Gift cards (3600): every change to a gift card balance, in cents, insert-only. The trigger keeps gift_cards.balance_cents and refuses a balance below zero.';

-- a refund of a booking paid in part by gift card: the gift card part is a refund row of its own, tied to the card refund
alter table refunds add column if not exists gift_split_of uuid references refunds (id) deferrable initially deferred;
create index if not exists refunds_gift_split_of_idx on refunds (gift_split_of);
comment on column refunds.gift_split_of is 'Gift cards (3600): this refund returns the gift card part of that refund to the gift card balance; it follows its approval.';

create trigger gift_cards_updated before update on gift_cards for each row execute function app.set_updated_at();
create trigger audit_gift_cards after insert or update or delete on gift_cards for each row execute function app.audit_row();
create trigger audit_gift_card_applications after insert or update or delete on gift_card_applications for each row execute function app.audit_row();
create trigger audit_gift_card_ledger after insert or update or delete on gift_card_ledger for each row execute function app.audit_row();
alter table gift_cards enable row level security;
alter table gift_card_applications enable row level security;
alter table gift_card_ledger enable row level security;
create policy admin_all on gift_cards for select to authenticated using (app.is_admin());
create policy admin_all on gift_card_applications for select to authenticated using (app.is_admin());
create policy admin_all on gift_card_ledger for select to authenticated using (app.is_admin());
revoke all on gift_cards, gift_card_applications, gift_card_ledger from anon, authenticated;
grant select on gift_cards, gift_card_applications, gift_card_ledger to authenticated;
grant all on gift_cards, gift_card_applications, gift_card_ledger to service_role;

-- ================================================================ 3. the ledger keeps the balance
create function app.gift_ledger_before() returns trigger
language plpgsql security definer set search_path = public, app, pg_temp as $$
declare
  g gift_cards;
begin
  select * into g from gift_cards where id = new.gift_card_id for update;
  if g.id is null then raise exception 'Gift card not found' using errcode = 'P0002'; end if;
  if g.status <> 'active' then raise exception 'This gift card is not active' using errcode = '23514'; end if;
  new.balance_after_cents := g.balance_cents + new.amount_cents;
  if new.balance_after_cents < 0 then
    raise exception 'The gift card balance is %, not enough for %', app.fmt_money(g.balance_cents), app.fmt_money(-new.amount_cents) using errcode = '23514';
  end if;
  if new.balance_after_cents > g.initial_cents then
    raise exception 'A gift card balance never goes above what it was issued for' using errcode = '23514';
  end if;
  perform set_config('app.gift_ledger', g.id::text, true);
  update gift_cards set balance_cents = new.balance_after_cents where id = g.id;
  perform set_config('app.gift_ledger', '', true);
  return new;
end $$;
create trigger gift_card_ledger_balance before insert on gift_card_ledger for each row execute function app.gift_ledger_before();

create function app.gift_ledger_frozen() returns trigger
language plpgsql security definer set search_path = public, app, pg_temp as $$
begin
  raise exception 'The gift card ledger is never changed: add an adjustment instead' using errcode = '42501';
end $$;
create trigger gift_card_ledger_frozen before update or delete on gift_card_ledger for each row execute function app.gift_ledger_frozen();

-- the balance changes only through the ledger
create function app.gift_cards_balance_guard() returns trigger
language plpgsql security definer set search_path = public, app, pg_temp as $$
begin
  if new.balance_cents is distinct from old.balance_cents and coalesce(current_setting('app.gift_ledger', true), '') <> new.id::text then
    raise exception 'A gift card balance changes only through its ledger' using errcode = '42501';
  end if;
  if new.code is distinct from old.code or new.kind is distinct from old.kind or new.initial_cents is distinct from old.initial_cents then
    raise exception 'A gift card''s code, kind and amount never change' using errcode = '42501';
  end if;
  return new;
end $$;
create trigger gift_cards_balance_guard before update on gift_cards for each row execute function app.gift_cards_balance_guard();

-- ================================================================ 4. helpers
create function app.gift_code_new() returns text
language plpgsql volatile security definer set search_path = public, app, pg_temp as $$
declare
  a constant text := 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';
  b bytea;
  v text;
  i integer;
begin
  loop
    b := decode(replace(gen_random_uuid()::text, '-', ''), 'hex');
    v := '';
    -- 12 random bytes (6 and 8 carry the uuid version and variant bits); 256 is a multiple of 32, so each letter is even
    foreach i in array array[0, 1, 2, 3, 4, 5, 9, 10, 11, 12, 13, 14] loop
      v := v || substr(a, get_byte(b, i) % 32 + 1, 1);
    end loop;
    v := 'CCGC-' || substr(v, 1, 4) || '-' || substr(v, 5, 4) || '-' || substr(v, 9, 4);
    exit when not exists (select 1 from gift_cards where code = v);
  end loop;
  return v;
end $$;

-- a code as typed (spaces, dashes, lower case; the letters I and O and the digits 0 and 1 are never used): the stored form, or null
create function app.gift_code_norm(p text) returns text
language sql immutable as $$
  select case when length(x) = 16 and left(x, 4) = 'CCGC' then 'CCGC-' || substr(x, 5, 4) || '-' || substr(x, 9, 4) || '-' || substr(x, 13, 4)
              when length(x) = 12 and left(x, 4) <> 'CCGC' then 'CCGC-' || substr(x, 1, 4) || '-' || substr(x, 5, 4) || '-' || substr(x, 9, 4) end
    from (select regexp_replace(upper(coalesce(p, '')), '[^A-Z0-9]', '', 'g') x) s
$$;

create function app.gift_kind_label(p_kind text) returns text
language sql immutable as $$
  select case p_kind when 'purchased' then 'Gift card' when 'gifted_rental' then 'Gifted rental' when 'voucher' then 'Voucher credit' else p_kind end
$$;

create function app.gift_base_url() returns text
language sql stable security definer set search_path = public, app, pg_temp as $$
  select rtrim(coalesce((app.settings()).notify_base_url, 'https://carmacars.ca'), '/')
$$;

-- the live (unspent, unvoided, not ended) balance of every card sold for money: what CarmaCars owes in rentals
create function app.gift_liability_cents() returns bigint
language sql stable security definer set search_path = public, app, pg_temp as $$
  select coalesce(sum(balance_cents), 0)::bigint from gift_cards where status = 'active' and kind in ('purchased', 'gifted_rental')
$$;

-- may this user spend this card? (claimed by them, or tied to their verified email and not claimed by anyone else)
create function app.gift_card_mine(g gift_cards, p_user uuid) returns boolean
language sql stable security definer set search_path = public, app, pg_temp as $$
  select g.recipient_user_id = p_user
      or (g.recipient_user_id is null and g.recipient_email is not null
          and exists (select 1 from users u where u.id = p_user and lower(u.email) = g.recipient_email and u.email_verified_at is not null))
$$;

create function app.gift_card_usable(g gift_cards) returns boolean
language sql stable as $$
  select g.status = 'active' and g.balance_cents > 0 and (g.expires_at is null or g.expires_at > now())
$$;

create function app.gift_card_row(g gift_cards, p_full boolean default false) returns jsonb
language sql stable security definer set search_path = public, app, pg_temp as $$
  select jsonb_build_object('id', g.id, 'code_last4', g.code_last4, 'kind', g.kind, 'kind_label', app.gift_kind_label(g.kind), 'status', g.status,
           'initial_cents', g.initial_cents, 'balance_cents', g.balance_cents, 'expires_at', g.expires_at, 'usable', app.gift_card_usable(g),
           'recipient_name', g.recipient_name, 'recipient_email', g.recipient_email, 'buyer_name', g.buyer_name, 'message', g.message,
           'send_on', g.send_on, 'sent_at', g.sent_at, 'claimed_at', g.claimed_at, 'rental_text', g.rental_text, 'paid_at', g.paid_at, 'created_at', g.created_at)
      || case when p_full then jsonb_build_object('code', g.code, 'buyer_email', g.buyer_email, 'card_text', g.card_text, 'issue_reason', g.issue_reason,
           'void_reason', g.void_reason, 'voided_at', g.voided_at, 'send_count', g.send_count,
           'issued_by_name', (select coalesce(u.display_name, u.full_name, u.email) from users u where u.id = g.issued_by),
           'voided_by_name', (select coalesce(u.display_name, u.full_name, u.email) from users u where u.id = g.voided_by)) else '{}'::jsonb end
$$;

-- ================================================================ 5. notices
create function app.gift_notice_codes() returns text[]
language sql immutable as $$
  select array['renter_gift_card_receipt', 'renter_gift_card_delivered', 'renter_gift_card_sent', 'renter_gift_card_used',
               'renter_gift_card_refunded', 'staff_gift_card_sold', 'staff_gift_card_voided']
$$;

create function app.gift_first_name(p_name text) returns text
language sql immutable as $$ select coalesce(nullif(split_part(btrim(coalesce(p_name, '')), ' ', 1), ''), 'there') $$;

-- the recipient: the payload names them (the buyer, the recipient or the holder); never anyone else
create function app.gift_emit(p_code text, g gift_cards, p_disc text, p_to_email text, p_to_name text, p_to_user uuid, p_values jsonb default '{}'::jsonb) returns bigint
language plpgsql security definer set search_path = public, app, pg_temp as $$
begin
  if p_code like 'renter_%' and nullif(btrim(coalesce(p_to_email, '')), '') is null and p_to_user is null then return null; end if;
  return app.ntf_emit(p_code, 'gift_card', g.id, p_disc, jsonb_build_object(
    'gift_card_id', g.id, 'to_email', p_to_email, 'to_name', p_to_name, 'to_user_id', p_to_user,
    'gift_amount', app.fmt_money(g.initial_cents), 'gift_code_last4', g.code_last4, 'recipient_name', g.recipient_name,
    'recipient_email', coalesce(g.recipient_email, ''), 'gift_type', app.gift_kind_label(g.kind))
    || case when p_code like 'renter_%' then jsonb_build_object('first_name', app.gift_first_name(p_to_name)) else '{}'::jsonb end
    || coalesce(p_values, '{}'::jsonb));
end $$;

alter function app.notification_recipients(app_events, notification_catalogue) rename to notification_recipients_pre3600;
create function app.notification_recipients(p_event app_events, p_c notification_catalogue)
returns table (audience text, user_id uuid, email text, name text, renter_id uuid, owner_id uuid, immediate boolean)
language plpgsql stable security definer set search_path = public, app, pg_temp as $$
declare
  v_email text;
  v_user uuid;
begin
  if p_c.code like 'renter_gift_card_%' then
    v_user := nullif(p_event.payload ->> 'to_user_id', '')::uuid;
    v_email := coalesce(nullif(btrim(coalesce(p_event.payload ->> 'to_email', '')), ''), (select u.email from users u where u.id = v_user));
    if v_email is null and v_user is null then return; end if;
    return query select 'renter'::text, v_user, v_email, coalesce(nullif(p_event.payload ->> 'to_name', ''), 'there'),
                        (select r.id from renters r where r.user_id = v_user and r.merged_into is null order by r.created_at limit 1), null::uuid, true;
    return;
  end if;
  return query select * from app.notification_recipients_pre3600(p_event, p_c);
end $$;
select pg_temp.copy_grants('app.notification_recipients(app_events, notification_catalogue)'::regprocedure, 'app.notification_recipients_pre3600(app_events, notification_catalogue)'::regprocedure);

alter function app.notification_payload(text, app_events, jsonb) rename to ntf_payload_pre3600;
create function app.notification_payload(p_code text, p_event app_events, p_to jsonb) returns jsonb
language plpgsql stable security definer set search_path = public, app, pg_temp as $$
declare
  x jsonb := app.ntf_payload_pre3600(p_code, p_event, p_to);
begin
  if not (p_code = any (app.gift_notice_codes())) then return x; end if;
  -- the values were fixed when the event happened (the balance of that moment); the outstanding total is read now
  x := coalesce(x, '{}'::jsonb) || (coalesce(p_event.payload, '{}'::jsonb) - 'to_email' - 'to_name' - 'to_user_id' - 'gift_card_id');
  if p_code = 'staff_gift_card_sold' then x := x || jsonb_build_object('outstanding_total', app.fmt_money(app.gift_liability_cents())); end if;
  return x;
end $$;
select pg_temp.copy_grants('app.notification_payload(text, app_events, jsonb)'::regprocedure, 'app.ntf_payload_pre3600(text, app_events, jsonb)'::regprocedure);

-- the email to the recipient (with the code, the printable card and the redeem link); again on a resend
create function app.gift_deliver(p_card uuid, p_by uuid, p_scheduled boolean default false) returns jsonb
language plpgsql security definer set search_path = public, app, pg_temp as $$
declare
  g gift_cards;
  v_base text := app.gift_base_url();
  v_from text;
begin
  select * into g from gift_cards where id = p_card for update;
  if g.id is null then raise exception 'Gift card not found' using errcode = 'P0002'; end if;
  if g.status <> 'active' then raise exception 'Only an active gift card is sent' using errcode = '23514'; end if;
  if g.recipient_email is null then raise exception 'This card has no recipient email: give the code by hand' using errcode = '22023'; end if;
  update gift_cards set sent_at = now(), send_count = send_count + 1 where id = g.id returning * into g;
  v_from := coalesce(nullif(g.buyer_name, ''), 'CarmaCars');
  perform app.gift_emit('renter_gift_card_delivered', g, 'sent' || g.send_count, g.recipient_email, g.recipient_name, g.recipient_user_id,
    jsonb_build_object('from_name', v_from, 'has_message', nullif(btrim(coalesce(g.message, '')), '') is not null, 'gift_message', coalesce(g.message, ''),
      'gift_code', g.code, 'is_rental', g.kind = 'gifted_rental', 'rental_text', coalesce(g.rental_text, ''),
      'expiry_text', case when g.expires_at is null then 'Never' else app.fmt_date(g.expires_at) end,
      'redeem_url', v_base || '/account/gift-cards?code=' || g.code, 'card_url', v_base || '/gift-cards/card/' || g.view_token));
  if p_scheduled and g.buyer_user_id is not null then
    perform app.gift_emit('renter_gift_card_sent', g, 'sent', g.buyer_email, g.buyer_name, g.buyer_user_id, '{}'::jsonb);
  end if;
  if p_by is not null and g.send_count > 1 then
    insert into audit_log (actor_user_id, action, entity_table, entity_id, after)
    values (p_by, 'gift_card_resent', 'gift_cards', g.id::text, jsonb_build_object('send_count', g.send_count, 'to', g.recipient_email));
  end if;
  return jsonb_build_object('id', g.id, 'sent_to', g.recipient_email, 'send_count', g.send_count);
end $$;

-- the job: cards whose send date has come (Toronto time)
create function app.job_gift_cards_send(p_now timestamptz default now()) returns jsonb
language plpgsql security definer set search_path = public, app, pg_temp as $$
declare
  r record;
  n integer := 0;
begin
  if not coalesce((app.settings()).gift_cards_on, false) then return jsonb_build_object('off', true); end if;
  for r in select id from gift_cards where status = 'active' and sent_at is null and recipient_email is not null
                and send_on is not null and send_on <= (p_now at time zone 'America/Toronto')::date order by send_on, created_at limit 200 loop
    perform app.gift_deliver(r.id, null, true);
    n := n + 1;
  end loop;
  return jsonb_build_object('sent', n);
end $$;

-- ================================================================ 6. buying a gift card
-- p: {kind purchased|gifted_rental, amount_cents (purchased), vehicle_id + days (gifted_rental), recipient_name, recipient_email,
--     message, send_on (YYYY-MM-DD, Toronto), buyer_name}
create function app.gift_order_create(p_by uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app, pg_temp as $$
declare
  s program_settings := app.settings();
  u users;
  v_kind text := coalesce(nullif(p ->> 'kind', ''), 'purchased');
  v_amount bigint;
  v_vehicle uuid;
  v_days integer;
  v_text text;
  v_send date;
  v_email text := lower(btrim(coalesce(p ->> 'recipient_email', '')));
  v_name text := btrim(coalesce(p ->> 'recipient_name', ''));
  v_msg text := nullif(btrim(coalesce(p ->> 'message', '')), '');
  v_today date := (now() at time zone 'America/Toronto')::date;
  q jsonb;
  l record;
  g gift_cards;
begin
  if not coalesce(s.gift_cards_on, false) then raise exception 'Gift cards are not on sale right now' using errcode = '23514'; end if;
  select * into u from users where id = p_by;
  if u.id is null then raise exception 'Sign in to buy a gift card' using errcode = '42501'; end if;
  if not app.rate_limit('gift_order:' || p_by, 8, interval '1 hour') then
    raise exception 'Too many gift card orders in an hour. Please wait and try again, or call us.' using errcode = '53400';
  end if;
  if v_kind not in ('purchased', 'gifted_rental') then raise exception 'Choose a gift card or a gifted rental' using errcode = '22023'; end if;
  if length(v_name) not between 1 and 120 then raise exception 'Enter the recipient''s name' using errcode = '22023'; end if;
  if v_email !~ '^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$' then raise exception 'Enter the recipient''s email' using errcode = '22023'; end if;
  if v_msg is not null and length(v_msg) > 500 then raise exception 'The message is 500 characters at most' using errcode = '22023'; end if;
  if nullif(p ->> 'send_on', '') is not null then
    v_send := (p ->> 'send_on')::date;
    if v_send < v_today or v_send > v_today + 365 then raise exception 'Pick a send date from today to a year from now' using errcode = '22023'; end if;
    if v_send = v_today then v_send := null; end if;
  end if;
  if v_kind = 'purchased' then
    v_amount := (p ->> 'amount_cents')::bigint;
    if v_amount is null or v_amount < s.gift_card_min_cents or v_amount > s.gift_card_max_cents or v_amount % 100 <> 0 then
      raise exception 'Choose an amount from % to %, in whole dollars', app.fmt_money(s.gift_card_min_cents), app.fmt_money(s.gift_card_max_cents) using errcode = '22023';
    end if;
  else
    v_vehicle := (p ->> 'vehicle_id')::uuid;
    v_days := (p ->> 'days')::integer;
    if v_days is null or v_days < 1 or v_days > s.gift_rental_max_days then
      raise exception 'Choose 1 to % days', s.gift_rental_max_days using errcode = '22023';
    end if;
    select * into l from public_vehicle_listings x where x.vehicle_id = v_vehicle;
    if l.vehicle_id is null then raise exception 'This car is not available to gift' using errcode = '22023'; end if;
    -- the site's own price for that car and those days, a week from now at 10 am (the rental, its fees and the HST as the
    -- site charges them; the gift is a credit of that amount, usable on that car or another)
    q := app.price_quote(v_vehicle, ((v_today + 7)::timestamp + time '10:00') at time zone 'America/Toronto',
                         ((v_today + 7 + v_days)::timestamp + time '10:00') at time zone 'America/Toronto', '{}'::jsonb);
    v_amount := nullif(q ->> 'total_due_at_booking_cents', '')::bigint;
    if v_amount is null or v_amount <= 0 then raise exception 'This car cannot be priced for those days. Choose a gift card amount instead.' using errcode = '22023'; end if;
    if v_amount > s.gift_card_max_cents then raise exception 'A gifted rental is % at most online. Choose fewer days, or call us.', app.fmt_money(s.gift_card_max_cents) using errcode = '22023'; end if;
    v_text := format('%s %s in the %s %s %s', v_days, case when v_days = 1 then 'day' else 'days' end, l.year, l.make, l.model);
  end if;
  -- an unpaid order of the same person for the same gift is reused (a second press, a reload)
  select * into g from gift_cards where buyer_user_id = p_by and status = 'pending_payment' and kind = v_kind and initial_cents = v_amount
     and recipient_email = v_email and created_at > now() - interval '1 day' and vehicle_id is not distinct from v_vehicle
   order by created_at desc limit 1;
  if g.id is not null then
    update gift_cards set recipient_name = v_name, message = v_msg, send_on = v_send, buyer_name = coalesce(nullif(btrim(p ->> 'buyer_name'), ''), buyer_name)
     where id = g.id returning * into g;
  else
    insert into gift_cards (code, kind, status, initial_cents, buyer_user_id, buyer_name, buyer_email, recipient_name, recipient_email, message, send_on,
                            vehicle_id, rental_days, rental_text)
    values (app.gift_code_new(), v_kind, 'pending_payment', v_amount, p_by,
            coalesce(nullif(btrim(p ->> 'buyer_name'), ''), u.display_name, u.full_name, split_part(u.email, '@', 1)), lower(u.email),
            v_name, v_email, v_msg, v_send, v_vehicle, v_days, v_text)
    returning * into g;
  end if;
  return jsonb_build_object('id', g.id, 'amount_cents', g.initial_cents, 'kind', g.kind, 'rental_text', g.rental_text, 'buyer_email', g.buyer_email,
                            'buyer_name', g.buyer_name, 'stripe_intent_id', g.stripe_intent_id);
end $$;

-- the gifted rental's price, before the buyer pays (the same quote as the order)
create function app.gift_rental_price(p_vehicle uuid, p_days integer) returns jsonb
language plpgsql stable security definer set search_path = public, app, pg_temp as $$
declare
  v_today date := (now() at time zone 'America/Toronto')::date;
  q jsonb;
  l record;
begin
  select * into l from public_vehicle_listings x where x.vehicle_id = p_vehicle;
  if l.vehicle_id is null or p_days is null or p_days < 1 or p_days > (app.settings()).gift_rental_max_days then return null; end if;
  q := app.price_quote(p_vehicle, ((v_today + 7)::timestamp + time '10:00') at time zone 'America/Toronto',
                       ((v_today + 7 + p_days)::timestamp + time '10:00') at time zone 'America/Toronto', '{}'::jsonb);
  return jsonb_build_object('amount_cents', nullif(q ->> 'total_due_at_booking_cents', '')::bigint, 'hst_cents', nullif(q ->> 'hst_cents', '')::bigint,
                            'car', format('%s %s %s', l.year, l.make, l.model), 'days', p_days);
end $$;

create function app.gift_order_intent(p_id uuid, p_intent text) returns void
language plpgsql security definer set search_path = public, app, pg_temp as $$
begin
  update gift_cards set stripe_intent_id = p_intent where id = p_id and status = 'pending_payment' and (stripe_intent_id is null or stripe_intent_id = p_intent);
  if not found and not exists (select 1 from gift_cards where id = p_id and stripe_intent_id = p_intent) then
    raise exception 'This gift card order is not waiting for payment' using errcode = '23514';
  end if;
end $$;

-- p: {id, amount_cents, currency, status, card_text} as the server read the PaymentIntent from Stripe
create function app.gift_order_paid(p_id uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app, pg_temp as $$
declare
  g gift_cards;
  v_now date := (now() at time zone 'America/Toronto')::date;
begin
  select * into g from gift_cards where id = p_id for update;
  if g.id is null then raise exception 'Gift card order not found' using errcode = 'P0002'; end if;
  if g.status = 'active' and g.stripe_intent_id = p ->> 'id' then return jsonb_build_object('ok', true, 'already', true, 'id', g.id); end if;
  if g.status <> 'pending_payment' then return jsonb_build_object('ok', false, 'reason', 'not_pending', 'message', 'This gift card order is not waiting for payment.'); end if;
  if g.stripe_intent_id is distinct from p ->> 'id' then return jsonb_build_object('ok', false, 'reason', 'other_payment', 'message', 'This payment is not for this gift card.'); end if;
  if coalesce(p ->> 'status', '') <> 'succeeded' then return jsonb_build_object('ok', false, 'reason', 'not_paid', 'message', 'The card was not charged.'); end if;
  if lower(coalesce(p ->> 'currency', '')) <> 'cad' or (p ->> 'amount_cents')::bigint is distinct from g.initial_cents then
    return jsonb_build_object('ok', false, 'reason', 'amount_mismatch', 'message', 'The amount paid does not match the gift card. We will look into it and contact you.');
  end if;
  update gift_cards set status = 'active', paid_at = now(), card_text = nullif(left(btrim(coalesce(p ->> 'card_text', '')), 60), '') where id = g.id returning * into g;
  insert into gift_card_ledger (gift_card_id, kind, amount_cents, created_by, reason) values (g.id, 'issue', g.initial_cents, g.buyer_user_id, 'Paid online');
  select * into g from gift_cards where id = g.id;
  perform app.gift_emit('renter_gift_card_receipt', g, 'paid', g.buyer_email, g.buyer_name, g.buyer_user_id, jsonb_build_object(
    'delivery_text', case when g.send_on is null or g.send_on <= v_now then 'Emailed today' else 'Emailed on ' || app.fmt_day(g.send_on) end,
    'payment_date', app.fmt_date(now()), 'card_text', coalesce(g.card_text, 'Card'), 'is_rental', g.kind = 'gifted_rental', 'rental_text', coalesce(g.rental_text, '')));
  perform app.gift_emit('staff_gift_card_sold', g, 'paid', null, null, null, jsonb_build_object('gift_kind', 'sold', 'buyer_name', coalesce(g.buyer_name, 'A buyer')));
  if g.send_on is null or g.send_on <= v_now then perform app.gift_deliver(g.id, null, false); end if;
  return jsonb_build_object('ok', true, 'id', g.id, 'code_last4', g.code_last4, 'view_token', g.view_token, 'amount_cents', g.initial_cents,
                            'recipient_name', g.recipient_name, 'send_on', g.send_on);
end $$;

-- the printable card (the token is the card's secret)
create function app.gift_card_view(p_token text) returns jsonb
language sql stable security definer set search_path = public, app, pg_temp as $$
  select app.gift_card_row(g) || jsonb_build_object('code', g.code, 'from_name', coalesce(nullif(g.buyer_name, ''), 'CarmaCars'))
    from gift_cards g where g.view_token = p_token and length(p_token) = 64 and g.status = 'active'
$$;

-- ================================================================ 7. the renter: my gift cards, add a code
create function app.my_gift_cards(p_user uuid) returns jsonb
language sql stable security definer set search_path = public, app, pg_temp as $$
  select jsonb_build_object(
    'cards', coalesce((select jsonb_agg(app.gift_card_row(g) || jsonb_build_object('claimed', g.recipient_user_id is not null,
                         'history', (select coalesce(jsonb_agg(jsonb_build_object('kind', l.kind, 'amount_cents', l.amount_cents, 'balance_after_cents', l.balance_after_cents,
                                       'at', l.created_at, 'booking_number', (select b.booking_number from bookings b where b.id = l.booking_id)) order by l.id desc), '[]'::jsonb)
                                       from gift_card_ledger l where l.gift_card_id = g.id))
                       order by app.gift_card_usable(g) desc, g.created_at desc)
                  from gift_cards g where g.status in ('active', 'voided') and app.gift_card_mine(g, p_user)), '[]'::jsonb),
    'sent', coalesce((select jsonb_agg(app.gift_card_row(g) order by g.created_at desc)
                 from gift_cards g where g.buyer_user_id = p_user and g.status in ('active', 'voided')), '[]'::jsonb),
    'balance_cents', coalesce((select sum(g.balance_cents) from gift_cards g where app.gift_card_usable(g) and app.gift_card_mine(g, p_user)), 0))
$$;

create function app.gift_card_claim(p_user uuid, p_code text) returns jsonb
language plpgsql security definer set search_path = public, app, pg_temp as $$
declare
  v_code text := app.gift_code_norm(p_code);
  g gift_cards;
  u users;
begin
  select * into u from users where id = p_user;
  if u.id is null then raise exception 'Sign in to add a gift card' using errcode = '42501'; end if;
  -- guessing codes: 10 tries an hour per account
  if not app.rate_limit('gift_claim:' || p_user, 10, interval '1 hour') then
    raise exception 'Too many tries. Please wait an hour, or call us.' using errcode = '53400';
  end if;
  if v_code is null then raise exception 'Enter the 16-character code, for example CCGC-7KQ4-XM2P-Q7XM' using errcode = '22023'; end if;
  select * into g from gift_cards where code = v_code for update;
  if g.id is null or g.status not in ('active', 'voided') then raise exception 'We do not know this code. Check it and try again.' using errcode = '22023'; end if;
  if g.status = 'voided' then raise exception 'This gift card was cancelled. Contact us if you think that is wrong.' using errcode = '23514'; end if;
  if g.expires_at is not null and g.expires_at <= now() then raise exception 'This voucher ended on %', app.fmt_date(g.expires_at) using errcode = '23514'; end if;
  if g.recipient_user_id = p_user then return jsonb_build_object('ok', true, 'already', true, 'card', app.gift_card_row(g)); end if;
  if g.recipient_user_id is not null then raise exception 'This gift card is already in another account' using errcode = '23514'; end if;
  -- a gifted rental, and a voucher made for a person, belong to the address they were sent to
  if g.kind in ('gifted_rental', 'voucher') and g.recipient_email is not null and lower(u.email) is distinct from g.recipient_email then
    raise exception 'This gift was made for another email address. Sign in with the address it was sent to.' using errcode = '23514';
  end if;
  update gift_cards set recipient_user_id = p_user, claimed_at = now() where id = g.id returning * into g;
  return jsonb_build_object('ok', true, 'card', app.gift_card_row(g));
end $$;

-- ================================================================ 8. Sign and pay: apply, remove, pay
create function app.gift_booking_applied(p_booking uuid) returns bigint
language sql stable security definer set search_path = public, app, pg_temp as $$
  select coalesce(sum(amount_cents), 0)::bigint from gift_card_applications where booking_id = p_booking and status = 'applied'
$$;

create function app.gift_booking_state(p_booking uuid, p_user uuid) returns jsonb
language plpgsql stable security definer set search_path = public, app, pg_temp as $$
declare
  b bookings;
  s program_settings := app.settings();
  v_applied bigint := app.gift_booking_applied(p_booking);
  v_card boolean;
  v_why text;
  v_room bigint;
begin
  select * into b from bookings where id = p_booking;
  if b.id is null or not app.is_booking_renter(p_booking, p_user) then return null; end if;
  v_card := exists (select 1 from payment_methods pm where pm.renter_id = b.renter_id and pm.status = 'active');
  v_why := case when not coalesce(s.gift_cards_on, false) then 'off'
                when b.status <> 'pending_payment' or app.booking_link_due(b) then 'not_payable'
                when b.booking_type = 'owner' or b.renter_due_at_booking_cents <= 0 then 'nothing_due'
                when b.coverage_option = 2 then 'card_coverage' end;
  v_room := greatest(b.renter_due_at_booking_cents - v_applied - case when v_card then 0 else s.gift_card_min_card_cents end, 0);
  return jsonb_build_object('due_cents', b.renter_due_at_booking_cents, 'applied_cents', v_applied, 'card_due_cents', greatest(b.renter_due_at_booking_cents - v_applied, 0),
    'has_saved_card', v_card, 'min_card_cents', case when v_card then 0 else s.gift_card_min_card_cents end, 'room_cents', v_room,
    'blocked', v_why, 'deposit_cents', b.deposit_cents,
    'applications', coalesce((select jsonb_agg(jsonb_build_object('id', a.id, 'gift_card_id', a.gift_card_id, 'code_last4', g.code_last4, 'amount_cents', a.amount_cents) order by a.applied_at)
                     from gift_card_applications a join gift_cards g on g.id = a.gift_card_id where a.booking_id = b.id and a.status = 'applied'), '[]'::jsonb),
    'cards', coalesce((select jsonb_agg(jsonb_build_object('id', g.id, 'code_last4', g.code_last4, 'kind_label', app.gift_kind_label(g.kind),
                          'balance_cents', g.balance_cents, 'rental_text', g.rental_text) order by g.expires_at nulls last, g.created_at)
                     from gift_cards g where app.gift_card_usable(g) and app.gift_card_mine(g, p_user)), '[]'::jsonb));
end $$;

create function app.gift_booking_apply(p_booking uuid, p_user uuid, p_card uuid, p_amount bigint default null) returns jsonb
language plpgsql security definer set search_path = public, app, pg_temp as $$
declare
  b bookings;
  g gift_cards;
  st jsonb;
  v_amount bigint;
  v_app uuid;
begin
  -- one change at a time per booking
  select * into b from bookings where id = p_booking for update;
  if b.id is null or not app.is_booking_renter(p_booking, p_user) then raise exception 'Booking not found' using errcode = 'P0002'; end if;
  st := app.gift_booking_state(p_booking, p_user);
  case st ->> 'blocked'
    when 'off' then raise exception 'Gift cards cannot be used right now' using errcode = '23514';
    when 'not_payable' then raise exception 'A gift card is used while the booking waits for payment' using errcode = '23514';
    when 'nothing_due' then raise exception 'Nothing is due on this booking' using errcode = '23514';
    when 'card_coverage' then raise exception 'You chose the rental coverage of your credit card, so the rental is paid on that card. Change how the car is covered to use a gift card.' using errcode = '23514';
    else null;
  end case;
  select * into g from gift_cards where id = p_card for update;
  if g.id is null or not app.gift_card_mine(g, p_user) then raise exception 'Add this gift card to your account first' using errcode = '42501'; end if;
  if not app.gift_card_usable(g) then raise exception 'This gift card has no balance to use' using errcode = '23514'; end if;
  -- a card tied to this person by email is theirs once used
  if g.recipient_user_id is null then update gift_cards set recipient_user_id = p_user, claimed_at = now() where id = g.id returning * into g; end if;
  if exists (select 1 from gift_card_applications a where a.gift_card_id = g.id and a.booking_id = b.id and a.status = 'applied') then
    raise exception 'This gift card is already applied. Remove it first to change the amount.' using errcode = '23514';
  end if;
  v_amount := least(g.balance_cents, (st ->> 'room_cents')::bigint, coalesce(nullif(p_amount, 0), g.balance_cents));
  if v_amount <= 0 then
    raise exception 'Nothing more can be paid by gift card. % is paid by card, which also saves it for the deposit.', app.fmt_money((st ->> 'card_due_cents')::bigint) using errcode = '23514';
  end if;
  insert into gift_card_applications (gift_card_id, booking_id, amount_cents, applied_by) values (g.id, b.id, v_amount, p_user) returning id into v_app;
  insert into gift_card_ledger (gift_card_id, kind, amount_cents, booking_id, application_id, created_by, reason)
  values (g.id, 'redeem', -v_amount, b.id, v_app, p_user, 'Applied to booking ' || b.booking_number);
  return app.gift_booking_state(p_booking, p_user);
end $$;

create function app.gift_release(p_application uuid, p_by uuid, p_reason text) returns void
language plpgsql security definer set search_path = public, app, pg_temp as $$
declare
  a gift_card_applications;
begin
  select * into a from gift_card_applications where id = p_application for update;
  if a.id is null or a.status <> 'applied' then return; end if;
  update gift_card_applications set status = 'released', released_at = now(), release_reason = left(p_reason, 200) where id = a.id;
  insert into gift_card_ledger (gift_card_id, kind, amount_cents, booking_id, application_id, created_by, reason)
  values (a.gift_card_id, 'release', a.amount_cents, a.booking_id, a.id, p_by, left(p_reason, 300));
end $$;

create function app.gift_booking_remove(p_booking uuid, p_user uuid, p_application uuid default null) returns jsonb
language plpgsql security definer set search_path = public, app, pg_temp as $$
declare
  r record;
begin
  perform 1 from bookings where id = p_booking for update;
  if not app.is_booking_renter(p_booking, p_user) then raise exception 'Booking not found' using errcode = 'P0002'; end if;
  for r in select id from gift_card_applications where booking_id = p_booking and status = 'applied' and (p_application is null or id = p_application) loop
    perform app.gift_release(r.id, p_user, 'Removed on Sign and pay');
  end loop;
  return app.gift_booking_state(p_booking, p_user);
end $$;

-- every open application of a booking goes back (the booking ended unpaid, its price changed, or it was paid another way)
create function app.gift_booking_release_all(p_booking uuid, p_reason text) returns integer
language plpgsql security definer set search_path = public, app, pg_temp as $$
declare
  r record;
  n integer := 0;
begin
  for r in select id from gift_card_applications where booking_id = p_booking and status = 'applied' loop
    perform app.gift_release(r.id, null, p_reason);
    n := n + 1;
  end loop;
  return n;
end $$;

create function app.gift_bookings_after() returns trigger
language plpgsql security definer set search_path = public, app, pg_temp as $$
begin
  -- the payment of this booking is being recorded with its gift cards (app.finalize_booking below)
  if coalesce(current_setting('app.gift_capturing', true), '') = new.id::text then return null; end if;
  if not exists (select 1 from gift_card_applications a where a.booking_id = new.id and a.status = 'applied') then return null; end if;
  if new.status is distinct from old.status then
    perform app.gift_booking_release_all(new.id, 'Booking ' || new.booking_number || ' is ' || replace(new.status::text, '_', ' ') || ': the gift card balance is back');
  elsif new.renter_due_at_booking_cents is distinct from old.renter_due_at_booking_cents then
    perform app.gift_booking_release_all(new.id, 'The amount due on booking ' || new.booking_number || ' changed: apply the gift card again');
  end if;
  return null;
end $$;
create trigger bookings_gift_release after update of status, renter_due_at_booking_cents on bookings
  for each row when (old.status = 'pending_payment') execute function app.gift_bookings_after();

-- the gift cards of a confirmed booking: one payment, method gift_card; the card payment is what was charged on the card
create function app.gift_capture(p_booking uuid, p_card_payment uuid, p_by uuid) returns bigint
language plpgsql security definer set search_path = public, app, pg_temp as $$
declare
  b bookings;
  v_total bigint := app.gift_booking_applied(p_booking);
  v_pay uuid;
  r record;
  g gift_cards;
begin
  if v_total <= 0 then return 0; end if;
  select * into b from bookings where id = p_booking;
  if p_card_payment is not null then
    -- the full card payment row stands for the card part and the gift part: the card part stays on it, the gift part
    -- becomes its own payment (the line items stay tied to the card payment, as one paid booking)
    update payments set amount_cents = amount_cents - v_total where id = p_card_payment and amount_cents > v_total;
    if not found then raise exception 'The card payment does not cover its part of booking %', b.booking_number using errcode = '23514'; end if;
  end if;
  insert into payments (booking_id, renter_id, purpose, kind, method, amount_cents, status, processed_at, created_by)
  values (p_booking, b.renter_id, 'booking_total', 'charge', 'gift_card', v_total, 'succeeded', now(), p_by)
  returning id into v_pay;
  for r in select a.* from gift_card_applications a where a.booking_id = p_booking and a.status = 'applied' order by a.applied_at loop
    update gift_card_applications set status = 'paid', payment_id = v_pay where id = r.id;
    select * into g from gift_cards where id = r.gift_card_id;
    perform app.gift_emit('renter_gift_card_used', g, 'booking:' || p_booking, (select u.email from users u where u.id = g.recipient_user_id),
      (select coalesce(u.display_name, u.full_name) from users u where u.id = g.recipient_user_id), g.recipient_user_id,
      jsonb_build_object('amount_used', app.fmt_money(r.amount_cents), 'balance_left', app.fmt_money(g.balance_cents), 'booking_number', b.booking_number));
  end loop;
  return v_total;
end $$;

-- the confirmation: what the renter owes at booking is the card amount plus the gift cards applied
alter function app.finalize_booking(uuid, text, jsonb, bigint, integer, jsonb, uuid) rename to finalize_booking_pre3600;
create function app.finalize_booking(p_booking uuid, p_mode text, p_processor jsonb, p_amount_cents bigint,
                                     p_offer_version integer, p_card jsonb, p_by uuid)
returns jsonb language plpgsql security definer set search_path = public, app, pg_temp as $$
declare
  v_gift bigint := app.gift_booking_applied(p_booking);
  r jsonb;
begin
  if v_gift <= 0 or p_mode <> 'payment' then
    return app.finalize_booking_pre3600(p_booking, p_mode, p_processor, p_amount_cents, p_offer_version, p_card, p_by);
  end if;
  perform set_config('app.gift_capturing', p_booking::text, true);
  r := app.finalize_booking_pre3600(p_booking, p_mode, p_processor, p_amount_cents + v_gift, p_offer_version, p_card, p_by);
  perform set_config('app.gift_capturing', '', true);
  if coalesce((r ->> 'ok')::boolean, false) and not coalesce((r ->> 'already_confirmed')::boolean, false) then
    perform app.gift_capture(p_booking, nullif(r ->> 'payment_id', '')::uuid, p_by);
    r := r || jsonb_build_object('amount_cents', p_amount_cents, 'gift_cents', v_gift);
  elsif not coalesce((r ->> 'ok')::boolean, false) then
    -- refused (the car was taken, the offer changed): the balance goes back at once
    perform app.gift_booking_release_all(p_booking, 'The booking was not confirmed: the gift card balance is back');
  end if;
  return r;
end $$;
select pg_temp.copy_grants('app.finalize_booking(uuid, text, jsonb, bigint, integer, jsonb, uuid)'::regprocedure,
                           'app.finalize_booking_pre3600(uuid, text, jsonb, bigint, integer, jsonb, uuid)'::regprocedure);

-- the gift cards cover everything due: confirmed without a card charge (a saved card is needed for the deposit)
create function app.gift_booking_pay(p_booking uuid, p_user uuid) returns jsonb
language plpgsql security definer set search_path = public, app, pg_temp as $$
declare
  b bookings;
  v_gift bigint;
  r jsonb;
begin
  select * into b from bookings where id = p_booking;
  if b.id is null or not app.is_booking_renter(p_booking, p_user) then raise exception 'Booking not found' using errcode = 'P0002'; end if;
  perform app.capture_gate(p_user, 'pay');
  v_gift := app.gift_booking_applied(p_booking);
  if v_gift <= 0 or v_gift <> b.renter_due_at_booking_cents then
    return jsonb_build_object('ok', false, 'reason', 'amount_mismatch', 'message', 'Your gift cards do not cover the whole amount: pay the rest by card.');
  end if;
  if not exists (select 1 from payment_methods pm where pm.renter_id = b.renter_id and pm.status = 'active') then
    return jsonb_build_object('ok', false, 'reason', 'no_card', 'message', 'A saved card is needed for the deposit. Pay part of the booking by card to save one.');
  end if;
  perform set_config('app.gift_capturing', p_booking::text, true);
  r := app.finalize_booking_pre3600(p_booking, 'payment', jsonb_build_object('processor', 'gift_card', 'payment_id', 'gift:' || p_booking || ':' || coalesce(b.offer_approved_version, 0)),
                                    v_gift, b.offer_approved_version, null, p_user);
  perform set_config('app.gift_capturing', '', true);
  if coalesce((r ->> 'ok')::boolean, false) and not coalesce((r ->> 'already_confirmed')::boolean, false) then
    -- the payment the confirmation wrote is the gift card payment: no processor behind it
    delete from payment_processor_details where payment_id = (r ->> 'payment_id')::uuid;
    update payments set method = 'gift_card', amount_cents = v_gift where id = (r ->> 'payment_id')::uuid;
    update gift_card_applications set status = 'paid', payment_id = (r ->> 'payment_id')::uuid where booking_id = p_booking and status = 'applied';
    perform app.gift_emit('renter_gift_card_used', g, 'booking:' || p_booking, (select u.email from users u where u.id = g.recipient_user_id),
        (select coalesce(u.display_name, u.full_name) from users u where u.id = g.recipient_user_id), g.recipient_user_id,
        jsonb_build_object('amount_used', app.fmt_money(a.amount_cents), 'balance_left', app.fmt_money(g.balance_cents), 'booking_number', b.booking_number))
       from gift_card_applications a join gift_cards g on g.id = a.gift_card_id where a.booking_id = p_booking and a.payment_id = (r ->> 'payment_id')::uuid;
    r := r || jsonb_build_object('action', 'none', 'gift_cents', v_gift);
  elsif not coalesce((r ->> 'ok')::boolean, false) then
    perform app.gift_booking_release_all(p_booking, 'The booking was not confirmed: the gift card balance is back');
  end if;
  return r;
end $$;

-- what the server checks before and after the card is authorized: the card part is what is due less the gift cards
alter function public.server_booking_payment_facts(uuid) rename to server_booking_payment_facts_pre3600;
alter function public.server_booking_payment_facts_pre3600(uuid) set schema app;
create function public.server_booking_payment_facts(p_booking uuid) returns jsonb
language sql stable security definer set search_path = public, app, pg_temp as $$
  select f || jsonb_build_object('gift_applied_cents', app.gift_booking_applied(p_booking),
                                 'card_due_cents', greatest((f ->> 'renter_due_at_booking_cents')::bigint - app.gift_booking_applied(p_booking), 0))
    from (select app.server_booking_payment_facts_pre3600(p_booking) f) x
$$;
select pg_temp.copy_grants('public.server_booking_payment_facts(uuid)'::regprocedure, 'app.server_booking_payment_facts_pre3600(uuid)'::regprocedure);
revoke all on function app.server_booking_payment_facts_pre3600(uuid) from public, anon, authenticated;
grant execute on function app.server_booking_payment_facts_pre3600(uuid) to service_role;

-- ================================================================ 9. refunds: the gift card part goes back to the card balance
-- the gift card part of a booking still to return: what was paid by gift card less what was already returned or waits
create function app.gift_refundable(p_booking uuid) returns table (payment_id uuid, left_cents bigint)
language sql stable security definer set search_path = public, app, pg_temp as $$
  select p.id, p.amount_cents - coalesce((select sum(x.amount_cents) from refunds x where x.payment_id = p.id and x.status <> 'rejected'), 0)
    from payments p where p.booking_id = p_booking and p.method = 'gift_card' and p.kind = 'charge' and p.status = 'succeeded'
   order by p.created_at limit 1
$$;

create function app.gift_refunds_before() returns trigger
language plpgsql security definer set search_path = public, app, pg_temp as $$
declare
  v_pay uuid;
  v_left bigint;
  v_part bigint;
  v_card uuid := new.payment_id;
begin
  if new.gift_split_of is not null or new.amount_cents <= 0 then return new; end if;
  select x.payment_id, x.left_cents into v_pay, v_left from app.gift_refundable(new.booking_id) x;
  if v_pay is null or v_left <= 0 then return new; end if;
  if v_card = v_pay then
    -- the refund named the gift card payment: the card part goes to the card payment of the booking
    select p.id into v_card from payments p
     where p.booking_id = new.booking_id and p.purpose = 'booking_total' and p.kind = 'charge' and p.status = 'succeeded' and p.method <> 'gift_card'
     order by p.processed_at desc nulls last, p.created_at desc limit 1;
  end if;
  v_part := least(v_left, new.amount_cents);
  if v_part = new.amount_cents or v_card is null then
    -- all of it goes back to the gift card (never more than it paid: app.gift_refunds_after refuses that)
    new.payment_id := v_pay;
    return new;
  end if;
  new.payment_id := v_card;
  new.amount_cents := new.amount_cents - v_part;
  insert into refunds (booking_id, payment_id, reason, refund_bps, amount_cents, status, requested_by, note, gift_split_of)
  values (new.booking_id, v_pay, new.reason, new.refund_bps, v_part, 'pending_approval', new.requested_by,
          concat_ws(' | ', new.note, 'Gift card part, back to the gift card balance'), new.id);
  return new;
end $$;
create trigger refunds_a_gift_split before insert on refunds for each row execute function app.gift_refunds_before();

-- the gift card part follows the card refund's decision; an approved gift card refund is paid back to the balance at once
create function app.gift_refunds_after() returns trigger
language plpgsql security definer set search_path = public, app, pg_temp as $$
declare
  pay payments;
  v_card uuid;
  v_back bigint;
  v_ref uuid;
  g gift_cards;
  r record;
  v_left bigint;
begin
  -- a card refund decided: its gift card part with it
  if tg_op = 'UPDATE' and new.gift_split_of is null and new.status is distinct from old.status and new.status in ('approved', 'rejected') then
    update refunds set status = new.status, approved_by = case when new.status = 'approved' then new.approved_by else approved_by end
     where gift_split_of = new.id and status = 'pending_approval';
  end if;
  select * into pay from payments where id = new.payment_id;
  if pay.id is null or pay.method <> 'gift_card' or new.status <> 'approved' then return null; end if;
  if tg_op = 'UPDATE' and old.status = 'approved' then return null; end if;
  -- back to the cards, in the order they paid, up to what each paid
  v_left := new.amount_cents;
  for r in select a.gift_card_id, a.amount_cents - coalesce((select sum(l.amount_cents) from gift_card_ledger l
                                                              where l.gift_card_id = a.gift_card_id and l.kind = 'refund' and l.payment_id = pay.id), 0) as room
             from gift_card_applications a where a.payment_id = pay.id and a.status = 'paid' order by a.applied_at loop
    exit when v_left <= 0;
    v_back := least(v_left, r.room);
    continue when v_back <= 0;
    select * into g from gift_cards where id = r.gift_card_id;
    if g.status = 'voided' then continue; end if;
    insert into gift_card_ledger (gift_card_id, kind, amount_cents, booking_id, payment_id, refund_id, created_by, reason)
    values (g.id, 'refund', v_back, new.booking_id, pay.id, new.id, new.approved_by, 'Refund of booking ' || (select booking_number from bookings where id = new.booking_id));
    select * into g from gift_cards where id = g.id;
    perform app.gift_emit('renter_gift_card_refunded', g, 'refund:' || new.id, (select u.email from users u where u.id = g.recipient_user_id),
      (select coalesce(u.display_name, u.full_name) from users u where u.id = g.recipient_user_id), g.recipient_user_id,
      jsonb_build_object('amount_returned', app.fmt_money(v_back), 'balance_left', app.fmt_money(g.balance_cents),
                         'booking_number', (select booking_number from bookings where id = new.booking_id)));
    v_left := v_left - v_back;
  end loop;
  if v_left > 0 then
    raise exception 'The gift card part of this refund is more than the gift cards paid (% left over)', app.fmt_money(v_left) using errcode = '23514';
  end if;
  insert into payments (booking_id, renter_id, purpose, kind, method, amount_cents, status, parent_payment_id, processed_at, created_by)
  values (new.booking_id, pay.renter_id, pay.purpose, 'refund', 'gift_card', new.amount_cents, 'succeeded', pay.id, now(), new.approved_by)
  returning id into v_ref;
  update refunds set status = 'paid', paid_at = now(), refund_payment_id = v_ref where id = new.id;
  return null;
end $$;
create trigger refunds_gift_after after insert or update of status on refunds for each row execute function app.gift_refunds_after();

-- the card-refund email is not sent for the gift card part (renter_gift_card_refunded says it); otherwise as 0023
create or replace function app.ntf_refunds_after() returns trigger
language plpgsql security definer set search_path = public, app, pg_temp as $$
begin
  if exists (select 1 from payments p where p.id = new.payment_id and p.method = 'gift_card') then return null; end if;
  if new.status = 'paid' and (tg_op = 'INSERT' or old.status is distinct from 'paid')
     and not exists (select 1 from booking_cancellations c where c.refund_id = new.id and c.created_at > now() - interval '1 hour') then
    perform app.ntf_emit('renter_refund_issued', 'refund', new.id, 'paid', jsonb_build_object('booking_id', new.booking_id));
  end if;
  return null;
end $$;

-- the refund's spread over the booking's lines (0005) stays the whole refund's: on the card refund, its gift card part
-- included (the gift card part has no allocation of its own)
create or replace function app.allocate_refund(p_refund uuid) returns integer
language plpgsql security definer set search_path = public, app, pg_temp as $$
declare
  r refunds;
  v_sum bigint;
  v_target bigint;
  n integer;
begin
  select * into r from refunds where id = p_refund;
  if r.refund_bps is null then
    raise exception 'Refund % has no percentage to allocate by', p_refund using errcode = '23514';
  end if;
  v_target := r.amount_cents + coalesce((select sum(x.amount_cents) from refunds x where x.gift_split_of = p_refund and x.status <> 'rejected'), 0);
  delete from refund_allocations where refund_id = p_refund;
  insert into refund_allocations (refund_id, line_item_id, amount_cents, hst_cents)
  select p_refund, li.id, public.calc_bps(li.amount_cents, r.refund_bps), public.calc_bps(li.hst_cents, r.refund_bps)
    from booking_line_items li
   where li.booking_id = r.booking_id and li.stage in ('booking', 'extension')
     and li.charged_to_renter and li.voided_at is null
     and not exists (select 1 from booking_addons ba where ba.id = li.booking_addon_id and ba.kept_on_cancel);
  get diagnostics n = row_count;
  select coalesce(sum(amount_cents + hst_cents), 0) into v_sum from refund_allocations where refund_id = p_refund;
  if v_sum <> v_target and n > 0 then
    update refund_allocations set amount_cents = amount_cents + (v_target - v_sum)
     where id = (select id from refund_allocations where refund_id = p_refund order by amount_cents desc, id limit 1);
  end if;
  return n;
end $$;

-- the cancellation table's rule (0012) counts the gift card part with its card refund: the two together are the
-- cancellation refund, so Finance approves them within the table as before
create or replace function app.guard_refund_approval() returns trigger
language plpgsql security definer set search_path = public, app, pg_temp as $$
declare
  v_group bigint;
begin
  -- refunds are paid within 10 business days
  new.due_by := coalesce(new.due_by, app.add_business_days(app.local_date(coalesce(new.created_at, now())),
                                                           (app.settings()).refund_business_days));
  if new.status in ('approved', 'processing', 'paid')
     and (tg_op = 'INSERT' or old.status in ('pending_approval', 'rejected')
          or new.amount_cents is distinct from old.amount_cents or new.approved_by is distinct from old.approved_by) then
    v_group := new.amount_cents + coalesce((select sum(x.amount_cents) from refunds x where x.id <> new.id and x.status <> 'rejected'
                 and (x.gift_split_of = new.id or x.id = new.gift_split_of or (new.gift_split_of is not null and x.gift_split_of = new.gift_split_of))), 0);
    -- a refund outside the cancellation table, or above the limit, is an Admin's decision
    if not app.may_release_payment(new.approved_by, new.amount_cents,
         new.reason in ('cancellation', 'carmacars_cancelled', 'driver_not_verifiable')
         and exists (select 1 from booking_cancellations c
                      where c.booking_id = new.booking_id and c.refund_cents in (new.amount_cents, v_group))) then
      raise exception 'This refund needs an Admin''s approval' using errcode = '42501';
    end if;
    new.approved_at := coalesce(new.approved_at, now());
  end if;
  return new;
end $$;

-- ================================================================ 10. Admin and Finance
create function app.gift_cards_admin(p_by uuid, p jsonb) returns jsonb
language plpgsql stable security definer set search_path = public, app, pg_temp as $$
declare
  v_q text := nullif(btrim(coalesce(p ->> 'q', '')), '');
  v_status text := nullif(p ->> 'status', '');
  v_kind text := nullif(p ->> 'kind', '');
  v_code text := app.gift_code_norm(v_q);
begin
  if not app.user_runs_finance(p_by) then raise exception 'Gift cards are for Finance and Admins' using errcode = '42501'; end if;
  return jsonb_build_object(
    'summary', jsonb_build_object(
      'liability_cents', app.gift_liability_cents(),
      'liability_count', (select count(*) from gift_cards where status = 'active' and kind in ('purchased', 'gifted_rental') and balance_cents > 0),
      'voucher_cents', (select coalesce(sum(balance_cents), 0) from gift_cards where status = 'active' and kind = 'voucher' and (expires_at is null or expires_at > now())),
      'sold_30d_cents', (select coalesce(sum(initial_cents), 0) from gift_cards where kind in ('purchased', 'gifted_rental') and paid_at > now() - interval '30 days'),
      'redeemed_30d_cents', (select coalesce(-sum(l.amount_cents), 0) from gift_card_ledger l where l.kind = 'redeem' and l.created_at > now() - interval '30 days')
                          - (select coalesce(sum(l.amount_cents), 0) from gift_card_ledger l where l.kind = 'release' and l.created_at > now() - interval '30 days'),
      'waiting_to_send', (select count(*) from gift_cards where status = 'active' and sent_at is null and send_on is not null)),
    'rows', '[]'::jsonb
      || coalesce((select jsonb_agg(app.gift_card_row(g, true) order by g.created_at desc) from (
        select g.* from gift_cards g
         where (v_status is null or g.status = v_status) and (v_kind is null or g.kind = v_kind)
           and (v_status = 'pending_payment' or g.status <> 'pending_payment')
           and (v_q is null or g.code = v_code or g.code_last4 = upper(v_q) or g.recipient_email ilike '%' || v_q || '%' or g.buyer_email ilike '%' || v_q || '%'
                or g.recipient_name ilike '%' || v_q || '%' or g.buyer_name ilike '%' || v_q || '%')
         order by g.created_at desc limit 200) g), '[]'::jsonb),
    'can_issue', app.user_is_admin(p_by),
    'voucher_max_cents', (app.settings()).gift_voucher_max_cents);
end $$;

create function app.gift_card_history(p_by uuid, p jsonb) returns jsonb
language plpgsql stable security definer set search_path = public, app, pg_temp as $$
declare
  g gift_cards;
begin
  if not app.user_runs_finance(p_by) then raise exception 'Gift cards are for Finance and Admins' using errcode = '42501'; end if;
  select * into g from gift_cards where id = (p ->> 'id')::uuid;
  if g.id is null then raise exception 'Gift card not found' using errcode = 'P0002'; end if;
  return app.gift_card_row(g, true) || jsonb_build_object('history', coalesce((select jsonb_agg(jsonb_build_object('id', l.id, 'kind', l.kind, 'amount_cents', l.amount_cents,
      'balance_after_cents', l.balance_after_cents, 'at', l.created_at, 'reason', l.reason,
      'booking_number', (select b.booking_number from bookings b where b.id = l.booking_id),
      'by_name', (select coalesce(u.display_name, u.full_name, u.email) from users u where u.id = l.created_by)) order by l.id desc)
    from gift_card_ledger l where l.gift_card_id = g.id), '[]'::jsonb));
end $$;

-- p: {type amount|percent, amount_cents | percent_bps, recipient_name, recipient_email, message, expires_on (YYYY-MM-DD),
--     max_uses (percent), code (percent, optional), reason}
create function app.gift_card_issue(p_by uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app, pg_temp as $$
declare
  s program_settings := app.settings();
  v_type text := coalesce(nullif(p ->> 'type', ''), 'amount');
  v_reason text := btrim(coalesce(p ->> 'reason', ''));
  v_email text := nullif(lower(btrim(coalesce(p ->> 'recipient_email', ''))), '');
  v_until timestamptz;
  v_amount bigint;
  v_bps integer;
  v_code text;
  g gift_cards;
  pc promo_codes;
begin
  if not app.user_is_admin(p_by) then raise exception 'Only an Admin issues vouchers' using errcode = '42501'; end if;
  if length(v_reason) < 3 then raise exception 'Say why this voucher is given' using errcode = '22023'; end if;
  if nullif(p ->> 'expires_on', '') is not null then
    v_until := (((p ->> 'expires_on')::date + 1)::timestamp) at time zone 'America/Toronto';
    if v_until <= now() then raise exception 'The end date is in the past' using errcode = '22023'; end if;
  end if;
  if v_email is not null and v_email !~ '^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$' then raise exception 'Check the email address' using errcode = '22023'; end if;
  if v_type = 'percent' then
    v_bps := (p ->> 'percent_bps')::integer;
    if v_bps is null or v_bps < 100 or v_bps > 10000 then raise exception 'A percentage from 1 to 100' using errcode = '22023'; end if;
    v_code := upper(regexp_replace(coalesce(nullif(p ->> 'code', ''), 'GIFT' || substr(replace(app.gift_code_new(), '-', ''), 5, 6)), '[^A-Za-z0-9]', '', 'g'));
    if length(v_code) not between 3 and 40 then raise exception 'A code of 3 to 40 letters and digits' using errcode = '22023'; end if;
    if exists (select 1 from promo_codes where code = v_code) then raise exception 'The code % is taken', v_code using errcode = '23505'; end if;
    insert into promo_codes (code, description, percent_bps, valid_until, max_uses, once_per_renter, renter_id, source, created_by)
    values (v_code, left(v_reason, 200), v_bps, v_until, nullif((p ->> 'max_uses')::integer, 0), true,
            (select r.id from renters r join users u on u.id = r.user_id where v_email is not null and lower(u.email) = v_email and r.merged_into is null limit 1),
            'admin_voucher', p_by)
    returning * into pc;
    insert into audit_log (actor_user_id, action, entity_table, entity_id, after)
    values (p_by, 'voucher_issued', 'promo_codes', pc.id::text, jsonb_build_object('code', pc.code, 'percent_bps', v_bps, 'valid_until', pc.valid_until,
            'max_uses', pc.max_uses, 'reason', v_reason, 'recipient_email', v_email));
    return jsonb_build_object('type', 'percent', 'code', pc.code, 'id', pc.id, 'valid_until', pc.valid_until);
  end if;
  v_amount := (p ->> 'amount_cents')::bigint;
  if v_amount is null or v_amount < 100 or v_amount > s.gift_voucher_max_cents then
    raise exception 'A voucher from $1.00 to %', app.fmt_money(s.gift_voucher_max_cents) using errcode = '22023';
  end if;
  insert into gift_cards (code, kind, status, initial_cents, recipient_name, recipient_email, message, expires_at, issued_by, issue_reason, buyer_name)
  values (app.gift_code_new(), 'voucher', 'active', v_amount, coalesce(nullif(btrim(p ->> 'recipient_name'), ''), 'A CarmaCars customer'), v_email,
          nullif(btrim(coalesce(p ->> 'message', '')), ''), v_until, p_by, left(v_reason, 300), 'CarmaCars')
  returning * into g;
  insert into gift_card_ledger (gift_card_id, kind, amount_cents, created_by, reason) values (g.id, 'issue', v_amount, p_by, left(v_reason, 300));
  insert into audit_log (actor_user_id, action, entity_table, entity_id, after)
  values (p_by, 'voucher_issued', 'gift_cards', g.id::text, jsonb_build_object('amount_cents', v_amount, 'expires_at', v_until, 'reason', v_reason, 'recipient_email', v_email));
  select * into g from gift_cards where id = g.id;
  perform app.gift_emit('staff_gift_card_sold', g, 'issued', null, null, null, jsonb_build_object('gift_kind', 'issued',
    'buyer_name', (select coalesce(u.display_name, u.full_name, u.email) from users u where u.id = p_by)));
  if v_email is not null then perform app.gift_deliver(g.id, null, false); end if;
  return jsonb_build_object('type', 'amount', 'code', g.code, 'id', g.id, 'sent_to', v_email);
end $$;

create function app.gift_card_void(p_by uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app, pg_temp as $$
declare
  g gift_cards;
  v_reason text := btrim(coalesce(p ->> 'reason', ''));
  v_bal bigint;
  r record;
begin
  if not app.user_is_admin(p_by) then raise exception 'Only an Admin voids a gift card' using errcode = '42501'; end if;
  if length(v_reason) < 3 then raise exception 'Say why the gift card is voided' using errcode = '22023'; end if;
  select * into g from gift_cards where id = (p ->> 'id')::uuid for update;
  if g.id is null then raise exception 'Gift card not found' using errcode = 'P0002'; end if;
  if g.status <> 'active' then raise exception 'Only an active gift card is voided' using errcode = '23514'; end if;
  -- a balance set aside for a booking not yet paid goes back first, then all of it is taken off
  for r in select id from gift_card_applications where gift_card_id = g.id and status = 'applied' loop
    perform app.gift_release(r.id, p_by, 'Gift card voided');
  end loop;
  select balance_cents into v_bal from gift_cards where id = g.id;
  if v_bal > 0 then
    insert into gift_card_ledger (gift_card_id, kind, amount_cents, created_by, reason) values (g.id, 'void', -v_bal, p_by, left(v_reason, 300));
  end if;
  update gift_cards set status = 'voided', voided_at = now(), voided_by = p_by, void_reason = left(v_reason, 300) where id = g.id returning * into g;
  perform app.gift_emit('staff_gift_card_voided', g, 'void', null, null, null, jsonb_build_object('amount_voided', app.fmt_money(v_bal), 'void_reason', g.void_reason,
    'actor_name', (select coalesce(u.display_name, u.full_name, u.email) from users u where u.id = p_by)));
  return jsonb_build_object('id', g.id, 'status', g.status, 'voided_cents', v_bal);
end $$;

create function app.gift_card_resend(p_by uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app, pg_temp as $$
begin
  if not app.user_is_admin(p_by) then raise exception 'Only an Admin resends a gift card' using errcode = '42501'; end if;
  return app.gift_deliver((p ->> 'id')::uuid, p_by, false);
end $$;

alter function app.door(uuid, text, text, text, jsonb) rename to door_pre3600;
create function app.door(p_user uuid, p_aal text, p_call text, p_name text, p jsonb default '{}'::jsonb) returns jsonb
language plpgsql security definer set search_path = public, app, pg_temp as $$
begin
  if p_call in ('ops_read', 'admin_read', 'va_read') and p_name in ('gift_cards', 'gift_card_history') then
    perform app.door_begin(p_user, p_aal);
    if p_name = 'gift_cards' then return app.gift_cards_admin(p_user, coalesce(p, '{}'::jsonb) - '_va'); end if;
    return app.gift_card_history(p_user, coalesce(p, '{}'::jsonb) - '_va');
  elsif p_call in ('admin_do', 'ops_do') and p_name in ('gift_card_issue', 'gift_card_void', 'gift_card_resend') then
    perform app.door_begin(p_user, p_aal);
    if p_name = 'gift_card_issue' then return app.gift_card_issue(p_user, coalesce(p, '{}'::jsonb) - '_va'); end if;
    if p_name = 'gift_card_void' then return app.gift_card_void(p_user, coalesce(p, '{}'::jsonb) - '_va'); end if;
    return app.gift_card_resend(p_user, coalesce(p, '{}'::jsonb) - '_va');
  end if;
  return app.door_pre3600(p_user, p_aal, p_call, p_name, p);
end $$;
select pg_temp.copy_grants('app.door(uuid, text, text, text, jsonb)'::regprocedure, 'app.door_pre3600(uuid, text, text, text, jsonb)'::regprocedure);

-- ================================================================ 11. the server's functions (service_role only)
create function public.server_gift_cards_facts() returns jsonb
language sql stable security definer set search_path = public, app, pg_temp as $$
  select jsonb_build_object('on', s.gift_cards_on, 'min_cents', s.gift_card_min_cents, 'max_cents', s.gift_card_max_cents,
           'presets_cents', to_jsonb(s.gift_card_presets_cents), 'rental_max_days', s.gift_rental_max_days,
           'cars', coalesce((select jsonb_agg(jsonb_build_object('vehicle_id', l.vehicle_id, 'slug', l.slug, 'name', format('%s %s %s', l.year, l.make, l.model),
                        'daily_rate_cents', l.daily_rate_cents) order by l.make, l.model, l.year desc) from public_vehicle_listings l), '[]'::jsonb))
    from app.settings() s
$$;
create function public.server_gift_rental_price(p_vehicle uuid, p_days integer) returns jsonb
language sql stable security definer set search_path = public, app, pg_temp as $$ select app.gift_rental_price(p_vehicle, p_days) $$;
create function public.server_gift_order_create(p_by uuid, p jsonb) returns jsonb
language sql security definer set search_path = public, app, pg_temp as $$ select app.gift_order_create(p_by, p) $$;
create function public.server_gift_order_intent(p_id uuid, p_intent text) returns void
language sql security definer set search_path = public, app, pg_temp as $$ select app.gift_order_intent(p_id, p_intent) $$;
create function public.server_gift_order_paid(p_id uuid, p jsonb) returns jsonb
language sql security definer set search_path = public, app, pg_temp as $$ select app.gift_order_paid(p_id, p) $$;
create function public.server_gift_order_of(p_id uuid, p_by uuid) returns jsonb
language sql stable security definer set search_path = public, app, pg_temp as $$
  select app.gift_card_row(g) || jsonb_build_object('stripe_intent_id', g.stripe_intent_id, 'view_token', case when g.status = 'active' then g.view_token end)
    from gift_cards g where g.id = p_id and g.buyer_user_id = p_by
$$;
create function public.server_gift_card_view(p_token text) returns jsonb
language sql stable security definer set search_path = public, app, pg_temp as $$ select app.gift_card_view(p_token) $$;
create function public.server_my_gift_cards(p_user uuid) returns jsonb
language sql stable security definer set search_path = public, app, pg_temp as $$ select app.my_gift_cards(p_user) $$;
create function public.server_gift_card_claim(p_user uuid, p_code text) returns jsonb
language sql security definer set search_path = public, app, pg_temp as $$ select app.gift_card_claim(p_user, p_code) $$;
create function public.server_booking_gift_state(p_booking uuid, p_user uuid) returns jsonb
language sql stable security definer set search_path = public, app, pg_temp as $$ select app.gift_booking_state(p_booking, p_user) $$;
create function public.server_booking_gift_apply(p_booking uuid, p_user uuid, p_card uuid, p_amount bigint default null) returns jsonb
language sql security definer set search_path = public, app, pg_temp as $$ select app.gift_booking_apply(p_booking, p_user, p_card, p_amount) $$;
create function public.server_booking_gift_remove(p_booking uuid, p_user uuid, p_application uuid default null) returns jsonb
language sql security definer set search_path = public, app, pg_temp as $$ select app.gift_booking_remove(p_booking, p_user, p_application) $$;
create function public.server_booking_gift_pay(p_booking uuid, p_user uuid) returns jsonb
language sql security definer set search_path = public, app, pg_temp as $$ select app.gift_booking_pay(p_booking, p_user) $$;

-- ================================================================ 12. emails, preferences, the job
-- CATALOGUE 3600 START (generated by supabase/seed/3600_gen_catalogue.mjs; do not edit by hand)
insert into notification_catalogue (code, audience, also_sent_to, category, is_digest, digest_slot, from_address, reply_to,
    subject, preheader, timing, trigger_text, replaces_template, link_path, variables, template_html, template_text) values
  ('renter_gift_card_receipt', 'renter', '{}'::text[], 'transactional', false, null, 'CarmaCars <billing@carmacars.ca>', 'billing@carmacars.ca', 'Your CarmaCars gift card receipt, {{gift_amount}}', 'For {{recipient_name}}. {{delivery_text}}', 'Immediate', 'Gift cards (migration 3600): a gift card or a gifted rental is paid by card on carmacars.ca/gift-cards. Sent to the buyer once per gift card. No HST is charged on a gift card: it is charged when the card pays for a rental.', null, '/account/gift-cards', '[{"name":"card_text","type":"string"},{"name":"company_address","type":"string","global":true},{"name":"contact_email","type":"string","global":true},{"name":"delivery_text","type":"string"},{"name":"first_name","type":"string"},{"name":"gift_amount","type":"string"},{"name":"gift_code_last4","type":"string"},{"name":"instagram_url","type":"url","global":true},{"name":"is_rental","type":"boolean"},{"name":"opening_hours","type":"string","global":true},{"name":"payment_date","type":"string"},{"name":"recipient_email","type":"string"},{"name":"recipient_name","type":"string"},{"name":"rental_text","type":"string"},{"name":"reply_time","type":"string","global":true},{"name":"support_phone","type":"string","global":true},{"name":"tiktok_url","type":"url","global":true}]'::jsonb, 'templates/renter_gift_card_receipt.html', 'templates/renter_gift_card_receipt.txt'),
  ('renter_gift_card_delivered', 'renter', '{}'::text[], 'transactional', false, null, 'CarmaCars <hello@carmacars.ca>', 'contact@carmacars.ca', '{{from_name}} sent you a CarmaCars gift card', '{{gift_amount}} toward your next rental.', 'On the send date chosen by the buyer, else immediate', 'Gift cards (migration 3600): a paid gift card or gifted rental reaches its send date (at once when no date was chosen), or an Admin issues a voucher credit to someone by email, or an Admin resends it. Sent to the recipient''s email, once per gift card and send.', null, null, '[{"name":"card_url","type":"url"},{"name":"company_address","type":"string","global":true},{"name":"contact_email","type":"string","global":true},{"name":"expiry_text","type":"string"},{"name":"first_name","type":"string"},{"name":"from_name","type":"string"},{"name":"gift_amount","type":"string"},{"name":"gift_code","type":"string"},{"name":"gift_code_last4","type":"string"},{"name":"gift_message","type":"string"},{"name":"has_message","type":"boolean"},{"name":"instagram_url","type":"url","global":true},{"name":"is_rental","type":"boolean"},{"name":"opening_hours","type":"string","global":true},{"name":"redeem_url","type":"url"},{"name":"rental_text","type":"string"},{"name":"reply_time","type":"string","global":true},{"name":"support_phone","type":"string","global":true},{"name":"tiktok_url","type":"url","global":true}]'::jsonb, 'templates/renter_gift_card_delivered.html', 'templates/renter_gift_card_delivered.txt'),
  ('renter_gift_card_sent', 'renter', '{}'::text[], 'transactional', false, null, 'CarmaCars <hello@carmacars.ca>', 'contact@carmacars.ca', 'Your gift card reached {{recipient_name}}', 'We emailed {{gift_amount}} to {{recipient_email}} today.', 'On the send date', 'Gift cards (migration 3600): a gift card the buyer scheduled for a later date was emailed to the recipient on that date. Sent to the buyer once. Not sent when the gift went at once (the receipt says so).', null, '/account/gift-cards', '[{"name":"company_address","type":"string","global":true},{"name":"contact_email","type":"string","global":true},{"name":"first_name","type":"string"},{"name":"gift_amount","type":"string"},{"name":"gift_code_last4","type":"string"},{"name":"instagram_url","type":"url","global":true},{"name":"opening_hours","type":"string","global":true},{"name":"recipient_email","type":"string"},{"name":"recipient_name","type":"string"},{"name":"reply_time","type":"string","global":true},{"name":"support_phone","type":"string","global":true},{"name":"tiktok_url","type":"url","global":true}]'::jsonb, 'templates/renter_gift_card_sent.html', 'templates/renter_gift_card_sent.txt'),
  ('renter_gift_card_used', 'renter', '{}'::text[], 'transactional', false, null, 'CarmaCars <billing@carmacars.ca>', 'billing@carmacars.ca', '{{amount_used}} of your gift card paid booking {{booking_number}}', '{{balance_left}} is left on the card.', 'Immediate', 'Gift cards (migration 3600): a booking paid with a gift card balance is confirmed. Sent to the card holder once per booking and card.', null, '/account/gift-cards', '[{"name":"amount_used","type":"string"},{"name":"balance_left","type":"string"},{"name":"booking_number","type":"string"},{"name":"company_address","type":"string","global":true},{"name":"contact_email","type":"string","global":true},{"name":"first_name","type":"string"},{"name":"gift_code_last4","type":"string"},{"name":"instagram_url","type":"url","global":true},{"name":"opening_hours","type":"string","global":true},{"name":"reply_time","type":"string","global":true},{"name":"support_phone","type":"string","global":true},{"name":"tiktok_url","type":"url","global":true}]'::jsonb, 'templates/renter_gift_card_used.html', 'templates/renter_gift_card_used.txt'),
  ('renter_gift_card_refunded', 'renter', '{}'::text[], 'transactional', false, null, 'CarmaCars <billing@carmacars.ca>', 'billing@carmacars.ca', '{{amount_returned}} is back on your gift card', 'From booking {{booking_number}}. Your balance is {{balance_left}}.', 'Immediate', 'Gift cards (migration 3600): an approved refund of a booking paid with a gift card returned the amount to the card balance. Sent to the card holder once per refund.', null, '/account/gift-cards', '[{"name":"amount_returned","type":"string"},{"name":"balance_left","type":"string"},{"name":"booking_number","type":"string"},{"name":"company_address","type":"string","global":true},{"name":"contact_email","type":"string","global":true},{"name":"first_name","type":"string"},{"name":"gift_code_last4","type":"string"},{"name":"instagram_url","type":"url","global":true},{"name":"opening_hours","type":"string","global":true},{"name":"reply_time","type":"string","global":true},{"name":"support_phone","type":"string","global":true},{"name":"tiktok_url","type":"url","global":true}]'::jsonb, 'templates/renter_gift_card_refunded.html', 'templates/renter_gift_card_refunded.txt'),
  ('staff_gift_card_sold', 'staff_va_finance', '{}'::text[], 'transactional', true, 'next', 'CarmaCars <billing@carmacars.ca>', 'contact@carmacars.ca', 'Gift card {{gift_kind}}: {{gift_amount}}', '{{buyer_name}} for {{recipient_name}}. Gift cards outstanding: {{outstanding_total}}.', 'Next digest', 'Gift cards (migration 3600): a gift card or gifted rental was paid online, or an Admin issued a voucher credit. Queued for the next Finance and Admin digest.', null, '/staff/money?tab=gift', '[{"name":"buyer_name","type":"string"},{"name":"company_address","type":"string","global":true},{"name":"gift_amount","type":"string"},{"name":"gift_code_last4","type":"string"},{"name":"gift_kind","type":"string"},{"name":"gift_type","type":"string"},{"name":"outstanding_total","type":"string"},{"name":"recipient_name","type":"string"}]'::jsonb, 'templates/staff_gift_card_sold.html', 'templates/staff_gift_card_sold.txt'),
  ('staff_gift_card_voided', 'staff_admin', '{}'::text[], 'transactional', false, null, 'CarmaCars <billing@carmacars.ca>', 'contact@carmacars.ca', 'Gift card ending {{gift_code_last4}} voided', '{{amount_voided}} taken off by {{actor_name}}: {{void_reason}}', 'Immediate', 'Gift cards (migration 3600): an Admin voided a gift card or voucher, with the reason. Sent at once to Admins and Finance.', null, '/admin/money?tab=gift', '[{"name":"actor_name","type":"string"},{"name":"amount_voided","type":"string"},{"name":"company_address","type":"string","global":true},{"name":"gift_code_last4","type":"string"},{"name":"gift_type","type":"string"},{"name":"void_reason","type":"string"}]'::jsonb, 'templates/staff_gift_card_voided.html', 'templates/staff_gift_card_voided.txt')
on conflict (code) do update set
  audience = excluded.audience, also_sent_to = excluded.also_sent_to, category = excluded.category,
  is_digest = excluded.is_digest, digest_slot = excluded.digest_slot, from_address = excluded.from_address,
  reply_to = excluded.reply_to, subject = excluded.subject, preheader = excluded.preheader, timing = excluded.timing,
  trigger_text = excluded.trigger_text, replaces_template = excluded.replaces_template, link_path = excluded.link_path,
  variables = excluded.variables, template_html = excluded.template_html, template_text = excluded.template_text,
  in_catalogue = true, updated_at = now();
select app.notification_catalogue_refresh();
-- CATALOGUE 3600 END

update notification_catalogue set emitted_by = case code
    when 'renter_gift_card_receipt' then 'app.gift_order_paid (3600): the gift card is paid'
    when 'renter_gift_card_delivered' then 'app.gift_deliver (3600): paid with no send date, the send date (hourly job), a voucher issued, a resend'
    when 'renter_gift_card_sent' then 'app.job_gift_cards_send (3600): a scheduled gift card went out'
    when 'renter_gift_card_used' then 'app.gift_capture, app.gift_booking_pay (3600): a booking paid with a gift card is confirmed'
    when 'renter_gift_card_refunded' then 'app.gift_refunds_after (3600): the gift card part of a refund is back on the card'
    when 'staff_gift_card_sold' then 'app.gift_order_paid, app.gift_card_issue (3600)'
    when 'staff_gift_card_voided' then 'app.gift_card_void (3600)' end,
  pref_type = case when code like 'renter_%' then 'receipts' else 'staff_money' end,
  push_topic = 'payments', no_text = true, updated_at = now()
 where code = any (app.gift_notice_codes());
select app.notification_catalogue_refresh();

do $$
begin
  if to_regclass('cron.job') is not null then
    perform cron.schedule('carmacars-gift-cards-send', '7 * * * *', $q$select app.job_gift_cards_send()$q$);
  end if;
end $$;

-- ================================================================ 13. the academy: gift cards (Finance, customer service, Sales, Admins)
insert into academy_sections (slug, title, blurb, guide_refs) values ('r49-gift-cards', 'Gift cards and vouchers', 'What a gift card and a gifted rental are, how a renter uses one on Sign and pay, refunds, and vouchers.', array['renter/sign-and-pay', 'renter/rewards', 'va/finance']::text[]) on conflict (slug) do update set title = excluded.title, blurb = excluded.blurb, guide_refs = excluded.guide_refs, updated_at = now();
insert into academy_lessons (section_id, sort, title, scenes) values ((select id from academy_sections where slug = 'r49-gift-cards'), 1, 'What a gift card is', '[{"caption": "Gift cards and gifted rentals", "say": "Anyone can buy a CarmaCars gift card on carmacars.ca/gift-cards: an amount, or a car for a number of days as a gifted rental. It is emailed to the person with a message, on the day the buyer picks.", "visual": {"kind": "title", "heading": "Gift cards", "text": "carmacars.ca/gift-cards"}}, {"caption": "The rules", "say": "A gift card sold for money never expires. It pays the rental, its fees and the HST, never the refundable deposit. No HST is charged when it is bought: the HST is in the rental it pays for.", "visual": {"kind": "list", "heading": "Always true", "items": ["Never expires when it was paid for", "Pays the rental, fees and HST", "Never the deposit", "No HST on the sale itself"]}}, {"caption": "A gifted rental", "say": "A gifted rental is a credit for the price of that car and those days. Only the account with the email it was sent to can use it, on that car or any other.", "visual": {"kind": "rule", "heading": "Tied to the recipient", "text": "Only the account with the email it was sent to can use a gifted rental.", "tone": "warn"}}]'::jsonb) on conflict (section_id, sort) do update set title = excluded.title, scenes = excluded.scenes, updated_at = now();
insert into academy_lessons (section_id, sort, title, scenes) values ((select id from academy_sections where slug = 'r49-gift-cards'), 2, 'Helping a renter use it', '[{"caption": "Adding the code", "say": "The renter adds the code under Rewards, Gift cards, or on Sign and pay with Have a gift card code. Spaces, dashes and lower case are fine.", "visual": {"kind": "chat", "lines": [{"who": "renter", "text": "Where do I put my gift card?"}, {"who": "you", "text": "On Sign and pay, tap Have a gift card code, type it and tap Add and use. The rest goes on your card."}]}}, {"caption": "Balance first", "say": "On Sign and pay the balance is used before the card. What is not used stays on the gift card. Without a saved card, at least one dollar is paid by card so the card for the deposit is saved.", "visual": {"kind": "list", "heading": "On Sign and pay", "items": ["Use: the balance pays first", "Remove: the balance goes back", "The rest by card", "All of it: Confirm with gift cards"]}}, {"caption": "Refunds", "say": "If a booking paid with a gift card is refunded, the gift card part goes back to the gift card balance as soon as the refund is approved. The card part goes back to the card as usual.", "visual": {"kind": "rule", "heading": "Refunds", "text": "The gift card part goes back to the gift card, the rest to the card.", "tone": "info"}}, {"caption": "Vouchers and voids", "say": "Only an Admin issues a voucher or voids a gift card, always with the reason. Finance sees every card and what is owed on them under Money, Gift cards.", "visual": {"kind": "list", "heading": "Money > Gift cards", "items": ["What is owed on gift cards", "Every card and its history", "Admin: issue a voucher", "Admin: void with a reason, resend"]}}]'::jsonb) on conflict (section_id, sort) do update set title = excluded.title, scenes = excluded.scenes, updated_at = now();
insert into academy_questions (section_id, sort, prompt, options, answer, explain) values ((select id from academy_sections where slug = 'r49-gift-cards'), 1, 'Does a gift card someone paid for expire?', '["After one year", "Never", "After 90 days", "At the end of the year"]'::jsonb, 1, 'A gift card sold for money never expires (Ontario). Only a voucher given free may have an end date.') on conflict (section_id, sort) do update set prompt = excluded.prompt, options = excluded.options, answer = excluded.answer, explain = excluded.explain, updated_at = now();
insert into academy_questions (section_id, sort, prompt, options, answer, explain) values ((select id from academy_sections where slug = 'r49-gift-cards'), 2, 'A renter wants their gift card to pay the deposit. What do you say?', '["It pays the deposit first", "A gift card never pays the deposit: the deposit is held on their card at pickup", "Call an Admin", "It pays half"]'::jsonb, 1, 'A gift card pays the rental, its fees and the HST, never the refundable deposit.') on conflict (section_id, sort) do update set prompt = excluded.prompt, options = excluded.options, answer = excluded.answer, explain = excluded.explain, updated_at = now();
insert into academy_questions (section_id, sort, prompt, options, answer, explain) values ((select id from academy_sections where slug = 'r49-gift-cards'), 3, 'A friend forwarded a gifted rental to another person. Can that person use it?', '["Yes, anyone with the code", "Only the account with the email it was sent to", "Only staff", "Only on weekends"]'::jsonb, 1, 'A gifted rental belongs to the email it was sent to.') on conflict (section_id, sort) do update set prompt = excluded.prompt, options = excluded.options, answer = excluded.answer, explain = excluded.explain, updated_at = now();
insert into academy_questions (section_id, sort, prompt, options, answer, explain) values ((select id from academy_sections where slug = 'r49-gift-cards'), 4, 'A booking paid with a $50 gift card and $150 by card is refunded in full. Where does the money go?', '["All to the card", "$50 back to the gift card, $150 to the card", "All to the gift card", "Nowhere until an Admin decides"]'::jsonb, 1, 'The gift card part goes back to the gift card balance, the rest to the card it was paid with.') on conflict (section_id, sort) do update set prompt = excluded.prompt, options = excluded.options, answer = excluded.answer, explain = excluded.explain, updated_at = now();
insert into academy_questions (section_id, sort, prompt, options, answer, explain) values ((select id from academy_sections where slug = 'r49-gift-cards'), 5, 'Who can issue a voucher or void a gift card?', '["Anyone in customer service", "Only an Admin, with the reason", "Finance, without a reason", "The renter"]'::jsonb, 1, 'Only an Admin issues vouchers and voids gift cards, and each one keeps the reason and who did it.') on conflict (section_id, sort) do update set prompt = excluded.prompt, options = excluded.options, answer = excluded.answer, explain = excluded.explain, updated_at = now();
insert into academy_path_sections (path_code, section_id, sort) select 'cs', (select id from academy_sections where slug = 'r49-gift-cards'), coalesce(max(sort), 0) + 1 from academy_path_sections where path_code = 'cs' on conflict (path_code, section_id) do nothing;
insert into academy_path_sections (path_code, section_id, sort) select 'finance', (select id from academy_sections where slug = 'r49-gift-cards'), coalesce(max(sort), 0) + 1 from academy_path_sections where path_code = 'finance' on conflict (path_code, section_id) do nothing;
insert into academy_path_sections (path_code, section_id, sort) select 'sales_in_person', (select id from academy_sections where slug = 'r49-gift-cards'), coalesce(max(sort), 0) + 1 from academy_path_sections where path_code = 'sales_in_person' on conflict (path_code, section_id) do nothing;
insert into academy_path_sections (path_code, section_id, sort) select 'sales_remote', (select id from academy_sections where slug = 'r49-gift-cards'), coalesce(max(sort), 0) + 1 from academy_path_sections where path_code = 'sales_remote' on conflict (path_code, section_id) do nothing;
insert into academy_path_sections (path_code, section_id, sort) select 'admin', (select id from academy_sections where slug = 'r49-gift-cards'), coalesce(max(sort), 0) + 1 from academy_path_sections where path_code = 'admin' on conflict (path_code, section_id) do nothing;

-- ================================================================ 14. privileges
do $$
declare f text;
begin
  foreach f in array array[
    'app.gift_ledger_before()', 'app.gift_ledger_frozen()', 'app.gift_cards_balance_guard()', 'app.gift_code_new()', 'app.gift_code_norm(text)',
    'app.gift_kind_label(text)', 'app.gift_base_url()', 'app.gift_liability_cents()', 'app.gift_card_mine(gift_cards, uuid)', 'app.gift_card_usable(gift_cards)',
    'app.gift_card_row(gift_cards, boolean)', 'app.gift_notice_codes()', 'app.gift_first_name(text)',
    'app.gift_emit(text, gift_cards, text, text, text, uuid, jsonb)', 'app.notification_recipients_pre3600(app_events, notification_catalogue)',
    'app.ntf_payload_pre3600(text, app_events, jsonb)', 'app.gift_deliver(uuid, uuid, boolean)', 'app.job_gift_cards_send(timestamptz)',
    'app.gift_order_create(uuid, jsonb)', 'app.gift_rental_price(uuid, integer)', 'app.gift_order_intent(uuid, text)', 'app.gift_order_paid(uuid, jsonb)',
    'app.gift_card_view(text)', 'app.my_gift_cards(uuid)', 'app.gift_card_claim(uuid, text)', 'app.gift_booking_applied(uuid)',
    'app.gift_booking_state(uuid, uuid)', 'app.gift_booking_apply(uuid, uuid, uuid, bigint)', 'app.gift_release(uuid, uuid, text)',
    'app.gift_booking_remove(uuid, uuid, uuid)', 'app.gift_booking_release_all(uuid, text)', 'app.gift_bookings_after()',
    'app.gift_capture(uuid, uuid, uuid)', 'app.finalize_booking_pre3600(uuid, text, jsonb, bigint, integer, jsonb, uuid)',
    'app.gift_booking_pay(uuid, uuid)', 'app.gift_refundable(uuid)', 'app.gift_refunds_before()', 'app.gift_refunds_after()',
    'app.ntf_refunds_after()', 'app.guard_refund_approval()', 'app.allocate_refund(uuid)', 'app.gift_cards_admin(uuid, jsonb)', 'app.gift_card_history(uuid, jsonb)',
    'app.gift_card_issue(uuid, jsonb)', 'app.gift_card_void(uuid, jsonb)', 'app.gift_card_resend(uuid, jsonb)', 'app.door_pre3600(uuid, text, text, text, jsonb)',
    'public.server_gift_cards_facts()', 'public.server_gift_rental_price(uuid, integer)', 'public.server_gift_order_create(uuid, jsonb)',
    'public.server_gift_order_intent(uuid, text)', 'public.server_gift_order_paid(uuid, jsonb)', 'public.server_gift_order_of(uuid, uuid)',
    'public.server_gift_card_view(text)', 'public.server_my_gift_cards(uuid)', 'public.server_gift_card_claim(uuid, text)',
    'public.server_booking_gift_state(uuid, uuid)', 'public.server_booking_gift_apply(uuid, uuid, uuid, bigint)',
    'public.server_booking_gift_remove(uuid, uuid, uuid)', 'public.server_booking_gift_pay(uuid, uuid)'] loop
    execute format('revoke all on function %s from public, anon, authenticated', f);
    execute format('grant execute on function %s to service_role', f);
  end loop;
end $$;
