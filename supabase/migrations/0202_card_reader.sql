-- 0202: the card reader, a Stripe Terminal S700 (Release 21, item 3). SCHEMA_MARKER 0202.
-- docs/changes/2026-10-31-card-reader.md.
--   Admin > Settings > Card reader: Pair reader takes the pairing code the S700 shows and registers it at Stripe to a
--   Terminal location made from CarmaCars' mailing address (Site settings). Server-driven: the website hands a
--   card_present PaymentIntent to the reader and the booking screen waits for the card. From a booking: Charge on reader
--   (the rental, the fees, everything open or a later charge) and Hold deposit on reader (manual capture, captured or
--   released from Settle the deposit like any hold; a card-present hold lapses after 2 days). A charge on the reader is
--   authorized, checked (0203: the same card on a card-coverage rental) and then captured.
--   A reader request is a payment request (0129) of channel reader: it settles through server_payreq_settle like the
--   pay page, so a payment, its receipt and a hold are recorded the same way.
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

-- ================================================================ 1. locations and readers
create table terminal_locations (
  id             uuid primary key default gen_random_uuid(),
  stripe_location_id text not null unique,
  display_name   text not null,
  address        text not null,
  created_by     uuid references users (id),
  created_at     timestamptz not null default now()
);
comment on table terminal_locations is 'Stripe Terminal locations (0202), made from the mailing address; the newest is the one readers are paired to.';

create table terminal_readers (
  id               uuid primary key default gen_random_uuid(),
  stripe_reader_id text not null unique,
  label            text not null check (length(btrim(label)) between 1 and 60),
  device_type      text,
  serial_number    text,
  location_id      uuid references terminal_locations (id),
  paired_by        uuid references users (id),
  paired_at        timestamptz not null default now(),
  removed_at       timestamptz,
  removed_by       uuid references users (id)
);
comment on table terminal_readers is 'Card readers paired to Stripe Terminal (0202); removed ones are kept.';
alter table terminal_locations enable row level security;
alter table terminal_readers enable row level security;
create policy admin_all on terminal_locations to authenticated using (app.is_admin()) with check (app.is_admin());
create policy admin_all on terminal_readers to authenticated using (app.is_admin()) with check (app.is_admin());
create trigger audit_terminal_readers after insert or update or delete on terminal_readers for each row execute function app.audit_row();

-- ================================================================ 2. a payment request on the reader
alter table payment_requests drop constraint if exists payment_requests_channel_check;
alter table payment_requests add constraint payment_requests_channel_check check (channel = any (array['device', 'text', 'email', 'link', 'reader']));
alter table payment_requests add column if not exists reader_id uuid references terminal_readers (id);
alter table payment_requests add constraint payment_requests_reader_check check ((channel = 'reader') = (reader_id is not null)) not valid;
alter table payment_requests validate constraint payment_requests_reader_check;

-- ================================================================ 3. Admin: the state, the location, pairing, removing
create function app.terminal_state(p_by uuid) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare
  ss site_settings;
begin
  perform app.assert_admin(p_by);
  select * into ss from site_settings limit 1;
  return jsonb_build_object(
    'mailing_address', coalesce(nullif(btrim(ss.mailing_address), ''), nullif(btrim((app.settings()).company_address), '')),
    'location', (select jsonb_build_object('id', l.id, 'stripe_location_id', l.stripe_location_id, 'display_name', l.display_name, 'address', l.address, 'created_at', l.created_at)
                   from terminal_locations l order by l.created_at desc limit 1),
    'readers', coalesce((select jsonb_agg(jsonb_build_object('id', r.id, 'stripe_reader_id', r.stripe_reader_id, 'label', r.label, 'device_type', r.device_type,
                 'serial_number', r.serial_number, 'paired_at', r.paired_at, 'paired_by', (select u.full_name from users u where u.id = r.paired_by)) order by r.paired_at)
                 from terminal_readers r where r.removed_at is null), '[]'::jsonb),
    'legal_name', (app.settings()).company_legal_name);
end $$;

create function app.terminal_location_save(p_by uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  v_id uuid;
begin
  perform app.assert_admin(p_by);
  if coalesce(p ->> 'stripe_location_id', '') !~ '^tml_[A-Za-z0-9_]+$' then raise exception 'A Stripe Terminal location id starts with tml_' using errcode = '22023'; end if;
  insert into terminal_locations (stripe_location_id, display_name, address, created_by)
  values (p ->> 'stripe_location_id', coalesce(nullif(btrim(p ->> 'display_name'), ''), 'CarmaCars'), coalesce(nullif(btrim(p ->> 'address'), ''), 'unknown'), p_by)
  on conflict (stripe_location_id) do update set address = excluded.address
  returning id into v_id;
  insert into audit_log (actor_user_id, action, entity_table, entity_id, after)
  values (p_by, 'terminal_location_save', 'terminal_locations', v_id::text, p);
  return jsonb_build_object('id', v_id, 'stripe_location_id', p ->> 'stripe_location_id');
end $$;

create function app.terminal_reader_save(p_by uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  v_id uuid;
  v_loc uuid := (select id from terminal_locations l where l.stripe_location_id = p ->> 'stripe_location_id');
begin
  perform app.assert_admin(p_by);
  if coalesce(p ->> 'stripe_reader_id', '') !~ '^tmr_[A-Za-z0-9_]+$' then raise exception 'A Stripe reader id starts with tmr_' using errcode = '22023'; end if;
  if nullif(btrim(coalesce(p ->> 'label', '')), '') is null then raise exception 'Name the reader (Front desk, Car lot)' using errcode = '22023'; end if;
  insert into terminal_readers (stripe_reader_id, label, device_type, serial_number, location_id, paired_by)
  values (p ->> 'stripe_reader_id', left(btrim(p ->> 'label'), 60), nullif(p ->> 'device_type', ''), nullif(p ->> 'serial_number', ''), v_loc, p_by)
  on conflict (stripe_reader_id) do update set label = excluded.label, device_type = excluded.device_type, serial_number = excluded.serial_number,
         location_id = excluded.location_id, paired_by = excluded.paired_by, paired_at = now(), removed_at = null, removed_by = null
  returning id into v_id;
  return jsonb_build_object('id', v_id, 'label', btrim(p ->> 'label'));
end $$;

create function app.terminal_reader_remove(p_by uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  v_n integer;
begin
  perform app.assert_admin(p_by);
  update terminal_readers set removed_at = now(), removed_by = p_by where id::text = p ->> 'id' and removed_at is null;
  get diagnostics v_n = row_count;
  if v_n = 0 then raise exception 'Reader not found' using errcode = 'P0002'; end if;
  return jsonb_build_object('ok', true);
end $$;

-- the readers a booking screen offers (staff who take a card)
create function app.terminal_readers(p_by uuid) returns jsonb
language sql stable security definer set search_path = public, app as $$
  select coalesce(jsonb_agg(jsonb_build_object('id', r.id, 'label', r.label) order by r.paired_at), '[]'::jsonb)
    from terminal_readers r where r.removed_at is null and (app.user_is_admin(p_by) or app.card_collect_allowed(p_by))
$$;

-- ================================================================ 4. a card request on the reader
-- payreq_create with channel reader (and p.reader, or the only reader paired): the request expires in 30 minutes.
alter function app.payreq_create(uuid, jsonb) rename to payreq_create_pre0202;
create function app.payreq_create(p_by uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  v_out jsonb;
  v_reader terminal_readers;
begin
  if coalesce(p ->> 'channel', '') <> 'reader' then return app.payreq_create_pre0202(p_by, p); end if;
  if coalesce(p ->> 'kind', 'charge') = 'setup' then raise exception 'A card is saved on the pay page, not on the reader' using errcode = '22023'; end if;
  select * into v_reader from terminal_readers r
   where r.removed_at is null and (r.id::text = p ->> 'reader' or (nullif(p ->> 'reader', '') is null and (select count(*) from terminal_readers x where x.removed_at is null) = 1))
   limit 1;
  if v_reader.id is null then
    raise exception '%', case when exists (select 1 from terminal_readers where removed_at is null) then 'Choose the reader' else 'No card reader is paired: an Admin pairs it in Settings, Card reader' end
      using errcode = '23514';
  end if;
  v_out := app.payreq_create_pre0202(p_by, p || jsonb_build_object('channel', 'device'));
  update payment_requests set channel = 'reader', reader_id = v_reader.id, expires_at = now() + interval '30 minutes' where id = (v_out ->> 'id')::uuid;
  return v_out || jsonb_build_object('channel', 'reader', 'reader', jsonb_build_object('id', v_reader.id, 'stripe_reader_id', v_reader.stripe_reader_id, 'label', v_reader.label));
end $$;
select pg_temp.copy_grants('app.payreq_create(uuid, jsonb)'::regprocedure, 'app.payreq_create_pre0202(uuid, jsonb)'::regprocedure);

-- the reader request as the website polls it
create function public.server_payreq_reader(p_id uuid) returns jsonb
language sql stable security definer set search_path = public, app as $$
  select jsonb_build_object('id', q.id, 'kind', q.kind, 'covers', q.covers, 'amount_cents', q.amount_cents, 'status', q.status, 'last_error', q.last_error,
           'intent_id', q.processor_intent_id, 'reader', r.stripe_reader_id, 'reader_label', r.label, 'booking_id', b.id, 'booking_number', b.booking_number,
           'created_by', q.created_by, 'expires_at', q.expires_at, 'payment_id', q.payment_id)
    from payment_requests q join bookings b on b.id = q.booking_id left join terminal_readers r on r.id = q.reader_id
   where q.id = p_id and q.channel = 'reader'
$$;

-- a reader request that did not go through: the reason, shown on the booking
create function public.server_payreq_reader_fail(p_id uuid, p_reason text) returns jsonb
language plpgsql security definer set search_path = public, app as $$
begin
  update payment_requests set status = 'failed', last_error = left(coalesce(nullif(btrim(p_reason), ''), 'Not paid'), 300), completed_at = now()
   where id = p_id and channel = 'reader' and status = 'open';
  return jsonb_build_object('ok', true);
end $$;

-- before a reader charge is captured: is this card allowed on this booking? 0203 (the same card on a card-coverage
-- rental) gives the answer; here every card is.
create function public.server_payreq_card_check(p_id uuid, p_card jsonb) returns jsonb
language sql stable security definer set search_path = public, app as $$
  select jsonb_build_object('ok', true)
$$;

-- a hold placed on the reader lapses after 2 days (card present), not the online hold's days
alter function public.server_payreq_settle(uuid, jsonb) rename to server_payreq_settle_pre0202;
create function public.server_payreq_settle(p_id uuid, p_intent jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  q payment_requests;
  v_out jsonb;
begin
  select * into q from payment_requests where id = p_id;
  -- a card read on the reader is card_present: it is never saved as the Card on File (it cannot be charged later)
  v_out := public.server_payreq_settle_pre0202(p_id, case when q.channel = 'reader' then p_intent || jsonb_build_object('method_id', null) else p_intent end);
  if q.channel = 'reader' and q.kind = 'hold' and coalesce((v_out ->> 'ok')::boolean, false) and (v_out ->> 'payment_id') is not null then
    update deposits set hold_expires_at = least(hold_expires_at, now() + interval '2 days') where hold_payment_id = (v_out ->> 'payment_id')::uuid;
    update deposit_events set note = 'card hold, on the card reader' where payment_id = (v_out ->> 'payment_id')::uuid and kind = 'taken';
  end if;
  return v_out;
end $$;
select pg_temp.copy_grants('public.server_payreq_settle(uuid, jsonb)'::regprocedure, 'public.server_payreq_settle_pre0202(uuid, jsonb)'::regprocedure);

-- ================================================================ 5. the door
alter function app.door(uuid, text, text, text, jsonb) rename to door_pre0202;
create function app.door(p_user uuid, p_aal text, p_call text, p_name text, p jsonb default '{}'::jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  p_ jsonb := coalesce(p, '{}'::jsonb) - '_va';
begin
  if (p_call = 'admin_do' and p_name in ('terminal_location_save', 'terminal_reader_save', 'terminal_reader_remove'))
     or (p_call = 'ops_read' and p_name in ('terminal_state', 'terminal_readers')) then
    if coalesce(p, '{}'::jsonb) ? '_va' then perform set_config('app.va_active', coalesce(p ->> '_va', ''), true); end if;
    perform app.door_begin(p_user, p_aal);
    return case p_name
      when 'terminal_location_save' then app.terminal_location_save(p_user, p_)
      when 'terminal_reader_save' then app.terminal_reader_save(p_user, p_)
      when 'terminal_reader_remove' then app.terminal_reader_remove(p_user, p_)
      when 'terminal_state' then app.terminal_state(p_user)
      else app.terminal_readers(p_user) end;
  end if;
  return app.door_pre0202(p_user, p_aal, p_call, p_name, p);
end $$;
select pg_temp.copy_grants('app.door(uuid, text, text, text, jsonb)'::regprocedure, 'app.door_pre0202(uuid, text, text, text, jsonb)'::regprocedure);

-- ================================================================ 6. privileges
do $$
declare
  f record;
begin
  for f in
    select p.oid::regprocedure as sig from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where (n.nspname = 'app' and p.proname = any (array['terminal_state', 'terminal_location_save', 'terminal_reader_save', 'terminal_reader_remove', 'terminal_readers',
              'payreq_create_pre0202', 'door_pre0202']))
        or (n.nspname = 'public' and p.proname = any (array['server_payreq_reader', 'server_payreq_reader_fail', 'server_payreq_card_check', 'server_payreq_settle_pre0202']))
  loop
    execute format('revoke all on function %s from public, anon, authenticated', f.sig);
    execute format('grant execute on function %s to service_role', f.sig);
  end loop;
end $$;
grant select, insert, update on terminal_locations, terminal_readers to service_role;
