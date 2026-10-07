-- 0009_tolls_tickets.sql
-- Tolls, tickets, fines, towing and impound notices: logged, matched to whoever had the car,
-- then charged, billed at cost or forwarded (procedure 11; renter spec section 1).

create table toll_tickets (
  id              uuid primary key default gen_random_uuid(),
  kind            text not null check (kind in ('toll_invoice', 'ticket', 'camera_offence', 'parking', 'fine', 'tow', 'impound')),
  notice_number   text,
  authority       text,                                -- who issued it
  plate           text not null,
  vehicle_id      uuid references vehicles (id),
  occurred_at     timestamptz not null,                -- date and time on the notice
  place           text,
  amount_cents    bigint not null check (amount_cents >= 0),   -- the amount itself: pass-through, no HST added
  due_on          date,
  received_on     date not null default app.today(),
  charge_by       date,                                -- matched and charged in 3 business days
  document_id     uuid references documents (id),      -- the notice
  -- who had the car
  matched_to      text not null default 'unmatched' check (matched_to in (
                    'unmatched', 'renter', 'owner_booking', 'owner_outside_program', 'turo_only', 'staff')),
  booking_id      uuid references bookings (id),
  owner_id        uuid references owners (id),
  staff_user_id   uuid references users (id),
  tracker_proof_document_id uuid references documents (id),  -- Tracker data is the proof
  matched_by      uuid references users (id),
  matched_at      timestamptz,
  admin_fee_cents bigint not null default 0 check (admin_fee_cents >= 0),  -- $15 per toll invoice, $40 per other item; none for an Owner
  paid_by_company_at timestamptz,                      -- "Pay it"
  status          text not null default 'logged' check (status in (
                    'logged', 'matched', 'charged', 'billed_to_owner', 'forwarded_to_owner', 'company_paid',
                    'disputed', 'named_to_authority', 'closed')),
  amount_line_item_id uuid references booking_line_items (id),
  fee_line_item_id    uuid references booking_line_items (id),
  owner_deduction_id  uuid references owner_deductions (id),
  charged_from    text check (charged_from in ('deposit', 'card_on_file')),
  notified_at     timestamptz,                         -- T19 with the notice
  created_by      uuid references users (id),
  created_at      timestamptz not null default now(),
  updated_at      timestamptz not null default now(),
  check (matched_to not in ('renter', 'owner_booking') or booking_id is not null),
  check (matched_to <> 'staff' or staff_user_id is not null),
  check (matched_to not in ('owner_booking', 'owner_outside_program', 'turo_only', 'staff') or admin_fee_cents = 0)
);
create unique index toll_tickets_notice_key on toll_tickets (authority, notice_number) where notice_number is not null;
create index toll_tickets_booking_idx on toll_tickets (booking_id);
create index toll_tickets_plate_idx on toll_tickets (upper(plate), occurred_at);
create index toll_tickets_open_idx on toll_tickets (status) where status in ('logged', 'matched', 'disputed');
create trigger toll_tickets_updated before update on toll_tickets for each row execute function app.set_updated_at();

alter table booking_line_items add constraint booking_line_items_toll_ticket_fk
  foreign key (toll_ticket_id) references toll_tickets (id);

-- Who had the car at that moment. The Rental Period runs from pickup (handover) to Check-in.
create or replace function app.match_toll_ticket(p_vehicle uuid, p_at timestamptz)
returns table (matched_to text, booking_id uuid, owner_id uuid)
language plpgsql stable security definer set search_path = public, app as $$
declare
  v vehicles;
  b bookings;
begin
  select * into v from vehicles where id = p_vehicle;
  if v.id is null then return query select 'unmatched'::text, null::uuid, null::uuid; return; end if;
  if v.management_mode = 'turo_only' then
    return query select 'turo_only'::text, null::uuid, v.owner_id; return;
  end if;
  select * into b from bookings x
   where x.vehicle_id = p_vehicle and x.status in ('on_rent', 'returned', 'closed')
     and coalesce(x.handed_over_at, x.pickup_at) <= p_at
     and p_at < coalesce(x.checked_in_at, 'infinity'::timestamptz)
   order by coalesce(x.handed_over_at, x.pickup_at) desc limit 1;
  if b.id is not null then
    return query select case when b.booking_type = 'owner' then 'owner_booking' else 'renter' end, b.id, b.owner_id;
    return;
  end if;
  if v.enrollment_date is null or app.local_date(p_at) < v.enrollment_date
     or (v.exit_date is not null and app.local_date(p_at) > v.exit_date) then
    return query select 'owner_outside_program'::text, null::uuid, v.owner_id; return;
  end if;
  return query select 'unmatched'::text, null::uuid, null::uuid;   -- no match: escalate to an admin
end $$;

-- The administration fee for one notice, from the fee terms on the booking (or the defaults).
create or replace function app.toll_ticket_admin_fee(p_kind text, p_matched_to text, p_booking uuid)
returns bigint language sql stable security definer set search_path = public, app as $$
  select case when p_matched_to <> 'renter' then 0::bigint
    else coalesce(
      (select t.amount_cents from booking_fee_terms t where t.booking_id = p_booking
          and t.fee_type_code = case when p_kind = 'toll_invoice' then 'toll_admin_fee' else 'ticket_admin_fee' end),
      (select d.amount_cents from fee_defaults d
        where d.fee_type_code = case when p_kind = 'toll_invoice' then 'toll_admin_fee' else 'ticket_admin_fee' end
          and d.vehicle_class is null and d.effective_from <= app.today() and (d.effective_to is null or d.effective_to > app.today())
        order by d.effective_from desc limit 1),
      0) end
$$;
