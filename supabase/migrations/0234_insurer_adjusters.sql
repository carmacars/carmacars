-- 0234: insurers' adjusters, and what was billed to each insurer by class, by car and by adjuster
-- (docs/changes/2026-11-03-insurer-adjusters.md). The owner: "it'll be a different contact for each adjuster, insurance
-- companies usually have a few different adjusters so you should be giving an option to add an adjuster and insurance
-- company and they get added to our database and that helps build a ratesheet of everything we've billed to each
-- insurance company by class and by car".
--
-- 1. insurer_adjusters: an insurer's adjusters (name, email, phone, notes). A booking keeps its adjuster
--    (bookings.insurer_adjuster_id) and, as before, the name, email and phone it was billed under (0016's columns, read by
--    the agreements, the invoices and the conversation). Every way a booking gets an adjuster adds or finds them: a
--    trigger matches the typed adjuster within the insurer by email, else by name, adds them when new, and keeps their
--    latest email and phone; an adjuster picked by id fills the booking's columns.
-- 2. The booking's Insurance claim card and Add a rental: pick the insurer or add it by name; pick a saved adjuster of
--    that insurer or add one (booking_insurer_save takes insurer_name and adjuster_id).
-- 3. Existing bookings: their adjusters are added (deduplicated by email, else name, per insurer; the latest booking's
--    details win). The bookings keep their text as it was.
-- 4. Billing contact per adjuster: an insurer invoice goes to the booking's adjuster (email and name), else the insurer's
--    billing email; an insurer no longer needs a billing contact of its own.
-- 5. The billing history (app.insurer_billing) adds, per booking, the adjuster, the car and the charges to the insurer
--    (VLF, LDW, T&LDW, PAP/PEC, Waiver Saver) with the rental and HST; and three summaries: by class, by car and by
--    adjuster (bookings, days, average daily rate, each charge, the insurer's share, billed, paid, outstanding). The rate
--    sheet (app.insurer_rate_sheet) adds the same by insurer and class for every insurer.
-- 6. Doors: admin_read/va_read insurer_adjusters (an insurer's, or all), admin_do/va_do insurer_adjuster_save (an Admin,
--    customer service or finance).
-- No applied migration is edited.

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
    raise exception '0234: the text to change was not found in %: %', p_sig, left(p_old, 120);
  end if;
  execute replace(d, p_old, p_new);
end $$;

-- ================================================================ 1. the adjusters
create table if not exists insurer_adjusters (
  id          uuid primary key default gen_random_uuid(),
  insurer_id  uuid not null references insurers (id) on delete cascade,
  name        text check (name is null or length(name) between 1 and 200),
  email       text check (email is null or email ~ '^[^@\s]+@[^@\s]+\.[^@\s]+$'),
  phone       text check (phone is null or length(phone) <= 40),
  notes       text check (notes is null or length(notes) <= 1000),
  is_active   boolean not null default true,
  created_by  uuid references users (id),
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now(),
  check (name is not null or email is not null)
);
create unique index if not exists insurer_adjusters_email_key on insurer_adjusters (insurer_id, lower(email)) where email is not null;
create index if not exists insurer_adjusters_name_idx on insurer_adjusters (insurer_id, lower(name));
comment on table insurer_adjusters is 'An insurer''s adjusters (0234): the contact each insurance replacement is billed to. Added from bookings (matched by email, else name, within the insurer) and in Admin > Insurer rates.';
alter table insurer_adjusters enable row level security;
revoke all on insurer_adjusters from anon, authenticated;
grant select on insurer_adjusters to authenticated;
grant all on insurer_adjusters to service_role;
drop policy if exists admin_all on insurer_adjusters;
create policy admin_all on insurer_adjusters for select to authenticated using (app.is_admin());
drop policy if exists staff_read on insurer_adjusters;
create policy staff_read on insurer_adjusters for select to authenticated using (app.is_staff());
drop trigger if exists audit_insurer_adjusters on insurer_adjusters;
create trigger audit_insurer_adjusters after insert or update or delete on insurer_adjusters for each row execute function app.audit_row();

alter table bookings add column if not exists insurer_adjuster_id uuid references insurer_adjusters (id) on delete set null;
create index if not exists bookings_insurer_adjuster_idx on bookings (insurer_adjuster_id) where insurer_adjuster_id is not null;
comment on column bookings.insurer_adjuster_id is 'The insurer''s adjuster this booking is billed to (0234); insurer_adjuster_name, _email and _phone keep the details used.';

-- an adjuster of the insurer by email, else by name; added when new; their latest email and phone kept
create or replace function app.insurer_adjuster_find_or_add(p_insurer uuid, p_name text, p_email text, p_phone text, p_by uuid default null) returns uuid
language plpgsql security definer set search_path = public, app as $$
declare
  v_name text := nullif(btrim(coalesce(p_name, '')), '');
  v_email text := lower(nullif(btrim(coalesce(p_email, '')), ''));
  v_phone text := nullif(btrim(coalesce(p_phone, '')), '');
  a insurer_adjusters;
begin
  if p_insurer is null or (v_name is null and v_email is null) then return null; end if;
  if v_email is not null and v_email !~ '^[^@\s]+@[^@\s]+\.[^@\s]+$' then v_email := null; end if;
  if v_name is null and v_email is null then return null; end if;
  if v_email is not null then
    select * into a from insurer_adjusters x where x.insurer_id = p_insurer and lower(x.email) = v_email;
  end if;
  if a.id is null and v_name is not null then
    select * into a from insurer_adjusters x where x.insurer_id = p_insurer and lower(x.name) = lower(v_name)
       and (v_email is null or x.email is null) order by x.created_at limit 1;
  end if;
  if a.id is null then
    insert into insurer_adjusters (insurer_id, name, email, phone, created_by) values (p_insurer, v_name, v_email, left(v_phone, 40), p_by) returning * into a;
  else
    update insurer_adjusters set name = coalesce(v_name, name), email = coalesce(email, v_email), phone = coalesce(left(v_phone, 40), phone), is_active = true, updated_at = now()
     where id = a.id and (name is distinct from coalesce(v_name, name) or email is distinct from coalesce(email, v_email) or phone is distinct from coalesce(left(v_phone, 40), phone) or not is_active);
  end if;
  return a.id;
end $$;

-- every way a booking gets an adjuster adds or finds them (set app.adjuster_sync = 'off' to leave a booking's text alone)
create or replace function app.booking_adjuster_sync() returns trigger
language plpgsql security definer set search_path = public, app as $$
declare
  a insurer_adjusters;
  v_text_changed boolean;
begin
  if current_setting('app.adjuster_sync', true) = 'off' then return new; end if;
  v_text_changed := tg_op = 'INSERT' or new.insurer_adjuster_name is distinct from old.insurer_adjuster_name
                    or new.insurer_adjuster_email is distinct from old.insurer_adjuster_email or new.insurer_adjuster_phone is distinct from old.insurer_adjuster_phone
                    or new.insurer_id is distinct from old.insurer_id;
  if new.insurer_adjuster_id is not null and (tg_op = 'INSERT' or new.insurer_adjuster_id is distinct from old.insurer_adjuster_id) then
    -- picked by id: the booking takes their details
    select * into a from insurer_adjusters where id = new.insurer_adjuster_id;
    if a.id is null then raise exception 'Adjuster not found' using errcode = 'P0002'; end if;
    if new.insurer_id is null then new.insurer_id := a.insurer_id;
    elsif new.insurer_id <> a.insurer_id then raise exception 'That adjuster works for another insurer' using errcode = '23514';
    end if;
    new.insurer_adjuster_name := a.name; new.insurer_adjuster_email := a.email; new.insurer_adjuster_phone := a.phone;
  elsif v_text_changed then
    if nullif(btrim(coalesce(new.insurer_adjuster_name, '')), '') is null and nullif(btrim(coalesce(new.insurer_adjuster_email, '')), '') is null then
      new.insurer_adjuster_id := null;
    elsif new.insurer_id is not null then
      new.insurer_adjuster_id := app.insurer_adjuster_find_or_add(new.insurer_id, new.insurer_adjuster_name, new.insurer_adjuster_email, new.insurer_adjuster_phone,
                                                                  nullif(current_setting('app.user_id', true), '')::uuid);
    end if;
  end if;
  return new;
exception when invalid_text_representation then
  -- app.user_id not a uuid: no author
  new.insurer_adjuster_id := app.insurer_adjuster_find_or_add(new.insurer_id, new.insurer_adjuster_name, new.insurer_adjuster_email, new.insurer_adjuster_phone);
  return new;
end $$;
drop trigger if exists bookings_adjuster_sync on bookings;
create trigger bookings_adjuster_sync before insert or update of insurer_id, insurer_adjuster_id, insurer_adjuster_name, insurer_adjuster_email, insurer_adjuster_phone
  on bookings for each row execute function app.booking_adjuster_sync();

-- ================================================================ 3. the existing bookings' adjusters
do $$
declare r record;
begin
  perform set_config('app.adjuster_sync', 'off', true);
  for r in select b.id, b.insurer_id, b.insurer_adjuster_name, b.insurer_adjuster_email, b.insurer_adjuster_phone from bookings b
            where b.insurer_id is not null and b.insurer_adjuster_id is null
              and (nullif(btrim(coalesce(b.insurer_adjuster_name, '')), '') is not null or nullif(btrim(coalesce(b.insurer_adjuster_email, '')), '') is not null)
            order by b.created_at loop
    update bookings set insurer_adjuster_id = app.insurer_adjuster_find_or_add(r.insurer_id, r.insurer_adjuster_name, r.insurer_adjuster_email, r.insurer_adjuster_phone)
     where id = r.id;
  end loop;
  perform set_config('app.adjuster_sync', '', true);
end $$;

-- ================================================================ 2. the booking's insurer and adjuster, picked or added
create or replace function app.insurer_find_or_add(p_name text, p_by uuid default null) returns uuid
language plpgsql security definer set search_path = public, app as $$
declare
  v_name text := nullif(btrim(coalesce(p_name, '')), '');
  v uuid;
begin
  if v_name is null then return null; end if;
  select id into v from insurers where lower(name) = lower(v_name);
  if v is null then insert into insurers (name, created_by) values (left(v_name, 200), p_by) returning id into v; end if;
  update insurers set is_active = true, updated_at = now() where id = v and not is_active;
  return v;
end $$;

alter function app.booking_insurer_save(uuid, jsonb) rename to booking_insurer_save_pre0234;
create function app.booking_insurer_save(p_by uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  q jsonb := coalesce(p, '{}'::jsonb);
  b bookings;
  a insurer_adjusters;
  v_ins uuid;
  r jsonb;
begin
  if not (app.user_is_admin(p_by) or app.user_va_has(p_by, 'cs', 'finance')) then
    raise exception 'An Admin, customer service or finance records the insurer' using errcode = '42501';
  end if;
  select * into b from bookings where id::text = q ->> 'booking' or booking_number = q ->> 'booking';
  -- an insurer not on the list yet, by name
  if nullif(btrim(coalesce(q ->> 'insurer_name', '')), '') is not null and coalesce(q ->> 'insurer_id', '') in ('', 'new') then
    q := (q - 'insurer_name') || jsonb_build_object('insurer_id', app.insurer_find_or_add(q ->> 'insurer_name', p_by));
  else
    q := q - 'insurer_name';
    if q ->> 'insurer_id' = 'new' then raise exception 'Type the insurer''s name' using errcode = '23514'; end if;
  end if;
  -- a saved adjuster: their details go with the save
  if nullif(q ->> 'adjuster_id', '') is not null and q ->> 'adjuster_id' <> 'new' then
    select * into a from insurer_adjusters where id::text = q ->> 'adjuster_id';
    if a.id is null then raise exception 'Adjuster not found' using errcode = 'P0002'; end if;
    v_ins := coalesce(nullif(q ->> 'insurer_id', '')::uuid, b.insurer_id);
    if v_ins is not null and v_ins <> a.insurer_id then raise exception 'That adjuster works for another insurer' using errcode = '23514'; end if;
    q := q || jsonb_build_object('insurer_id', a.insurer_id, 'adjuster_name', coalesce(a.name, ''), 'adjuster_email', coalesce(a.email, ''), 'adjuster_phone', coalesce(a.phone, ''));
  elsif q ? 'adjuster_id' and coalesce(q ->> 'adjuster_id', '') = '' then
    q := q || jsonb_build_object('adjuster_name', '', 'adjuster_email', '', 'adjuster_phone', '');
  end if;
  perform set_config('app.user_id', p_by::text, true);
  r := app.booking_insurer_save_pre0234(p_by, q - 'adjuster_id');
  if a.id is not null then
    update bookings set insurer_adjuster_id = a.id where id = b.id and insurer_adjuster_id is distinct from a.id;
  end if;
  return r || jsonb_build_object('adjuster_id', (select insurer_adjuster_id from bookings where id = b.id));
end $$;
select pg_temp.copy_grants('app.booking_insurer_save(uuid, jsonb)'::regprocedure, 'app.booking_insurer_save_pre0234(uuid, jsonb)'::regprocedure);

-- ================================================================ 6. the adjusters through the door
create or replace function app.insurer_adjusters_read(p_by uuid, p jsonb) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
begin
  if not (app.user_is_admin(p_by) or app.user_va_has(p_by, 'cs', 'finance')) then
    raise exception 'An Admin, customer service or finance sees the adjusters' using errcode = '42501';
  end if;
  return coalesce((select jsonb_agg(jsonb_build_object('id', a.id, 'insurer_id', a.insurer_id, 'insurer', i.name, 'name', a.name, 'email', a.email, 'phone', a.phone,
                     'notes', a.notes, 'is_active', a.is_active,
                     'bookings', (select count(*) from bookings b where b.insurer_adjuster_id = a.id))
                   order by i.name, coalesce(a.name, a.email))
                    from insurer_adjusters a join insurers i on i.id = a.insurer_id
                   where (nullif(p ->> 'insurer', '') is null or a.insurer_id::text = p ->> 'insurer')
                     and (coalesce((p ->> 'all')::boolean, false) or a.is_active)), '[]'::jsonb);
end $$;

create or replace function app.insurer_adjuster_save(p_by uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  a insurer_adjusters;
  v_email text := lower(nullif(btrim(coalesce(p ->> 'email', '')), ''));
  v_name text := nullif(btrim(coalesce(p ->> 'name', '')), '');
begin
  if not (app.user_is_admin(p_by) or app.user_va_has(p_by, 'cs', 'finance')) then
    raise exception 'An Admin, customer service or finance keeps the adjusters' using errcode = '42501';
  end if;
  if v_name is null and v_email is null then raise exception 'Type the adjuster''s name or email' using errcode = '23514'; end if;
  if v_email is not null and v_email !~ '^[^@\s]+@[^@\s]+\.[^@\s]+$' then raise exception 'The adjuster''s email' using errcode = '22023'; end if;
  if nullif(p ->> 'id', '') is not null then
    update insurer_adjusters set name = v_name, email = v_email, phone = nullif(btrim(coalesce(p ->> 'phone', '')), ''),
           notes = nullif(btrim(coalesce(p ->> 'notes', '')), ''), is_active = coalesce((p ->> 'is_active')::boolean, is_active), updated_at = now()
     where id::text = p ->> 'id' returning * into a;
    if a.id is null then raise exception 'Adjuster not found' using errcode = 'P0002'; end if;
  else
    if not exists (select 1 from insurers where id::text = p ->> 'insurer_id') then raise exception 'Choose the insurer' using errcode = '23514'; end if;
    if v_email is not null and exists (select 1 from insurer_adjusters x where x.insurer_id::text = p ->> 'insurer_id' and lower(x.email) = v_email) then
      raise exception 'This insurer already has an adjuster with that email' using errcode = '23505';
    end if;
    insert into insurer_adjusters (insurer_id, name, email, phone, notes, created_by)
    values ((p ->> 'insurer_id')::uuid, v_name, v_email, nullif(btrim(coalesce(p ->> 'phone', '')), ''), nullif(btrim(coalesce(p ->> 'notes', '')), ''), p_by)
    returning * into a;
  end if;
  return to_jsonb(a);
end $$;

alter function app.door(uuid, text, text, text, jsonb) rename to door_pre0234;
create function app.door(p_user uuid, p_aal text, p_call text, p_name text, p jsonb default '{}'::jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
begin
  if p_call in ('admin_read', 'va_read') and p_name = 'insurer_adjusters' then
    perform app.door_begin(p_user, p_aal);
    return app.insurer_adjusters_read(p_user, coalesce(p, '{}'::jsonb) - '_va');
  end if;
  if p_call in ('admin_do', 'va_do', 'ops_do') and p_name = 'insurer_adjuster_save' then
    if coalesce(p, '{}'::jsonb) ? '_va' then perform set_config('app.va_active', coalesce(p ->> '_va', ''), true); end if;
    perform app.door_begin(p_user, p_aal);
    return app.insurer_adjuster_save(p_user, coalesce(p, '{}'::jsonb) - '_va');
  end if;
  return app.door_pre0234(p_user, p_aal, p_call, p_name, p);
end $$;
select pg_temp.copy_grants('app.door(uuid, text, text, text, jsonb)'::regprocedure, 'app.door_pre0234(uuid, text, text, text, jsonb)'::regprocedure);

-- ================================================================ 4. the invoice goes to the booking's adjuster
select pg_temp.patch_fn('app.send_insurer_invoice_email(uuid, uuid)'::regprocedure,
  $o$  select nullif(btrim(billing_email), '') into v_email from insurers where id = ii.insurer_id;
  if v_email is null then
    raise exception 'The insurer has no billing email: add it in Settings, Insurers' using errcode = '23514';
  end if;$o$,
  $n$  -- 0234: the booking's adjuster first, else the insurer's billing email
  select coalesce(nullif(btrim(b.insurer_adjuster_email), ''), nullif(btrim(x.billing_email), '')) into v_email
    from insurers x left join bookings b on b.id = ii.booking_id where x.id = ii.insurer_id;
  if v_email is null then
    raise exception 'The booking has no adjuster email and the insurer has no billing email: add the adjuster''s email on the booking (Insurance claim)' using errcode = '23514';
  end if;$n$);
select pg_temp.patch_fn('app.send_insurer_invoice_email(uuid, uuid)'::regprocedure,
  $o$jsonb_build_object('insurer_id', ii.insurer_id),$o$,
  $n$jsonb_build_object('insurer_id', ii.insurer_id, 'to_email', v_email,
                            'to_name', (select coalesce(nullif(btrim(b.insurer_adjuster_name), ''), nullif(btrim(x.billing_contact_name), ''), x.name)
                                          from insurers x left join bookings b on b.id = ii.booking_id where x.id = ii.insurer_id)),$n$);
select pg_temp.patch_fn('app.notification_recipients_0032(app_events, notification_catalogue)'::regprocedure,
  $o$    return query select 'insurer'::text, null::uuid, btrim(x.billing_email), coalesce(nullif(btrim(x.billing_contact_name), ''), x.name),
                        null::uuid, null::uuid, true
                   from insurers x where x.id = (p ->> 'insurer_id')::uuid and nullif(btrim(x.billing_email), '') is not null;$o$,
  $n$    -- 0234: to the adjuster the sender named (to_email), else the insurer's billing email
    return query select 'insurer'::text, null::uuid, coalesce(nullif(btrim(p ->> 'to_email'), ''), btrim(x.billing_email)),
                        coalesce(nullif(btrim(p ->> 'to_name'), ''), nullif(btrim(x.billing_contact_name), ''), x.name),
                        null::uuid, null::uuid, true
                   from insurers x where x.id = (p ->> 'insurer_id')::uuid
                    and coalesce(nullif(btrim(p ->> 'to_email'), ''), nullif(btrim(x.billing_email), '')) is not null;$n$);
select pg_temp.patch_fn('app.pdf_facts_0032(text, text, uuid)'::regprocedure,
  $o$'insurer', (select jsonb_build_object('name', x.name, 'contact', x.billing_contact_name, 'email', x.billing_email, 'address', x.billing_address)$o$,
  $n$'insurer', (select jsonb_build_object('name', x.name, 'contact', coalesce(nullif(btrim(b.insurer_adjuster_name), ''), x.billing_contact_name),
                                           'email', coalesce(nullif(btrim(b.insurer_adjuster_email), ''), x.billing_email), 'address', x.billing_address)$n$);

-- ================================================================ 5. billed by class, by car and by adjuster
-- one row per booking billed to an insurer: the car, the adjuster, the days, the rate, each charge to the insurer, the share
create or replace function app.insurer_billed_rows(p_insurer uuid, p_from date default null, p_to date default null)
returns table (booking_id uuid, insurer_id uuid, class_code text, vehicle_id uuid, vehicle text, adjuster_id uuid, adjuster text,
               days integer, daily_rate_cents bigint, rental_cents bigint, fees jsonb, fees_cents bigint, hst_cents bigint, share_cents bigint,
               billed_cents bigint, paid_cents bigint, outstanding_cents bigint)
language sql stable security definer set search_path = public, app as $$
  select b.id, b.insurer_id, coalesce((x.rate).class_code, v.class::text), b.vehicle_id, app.vehicle_name(b.vehicle_id),
         b.insurer_adjuster_id, coalesce(nullif(btrim(b.insurer_adjuster_name), ''), b.insurer_adjuster_email),
         s.covered_days, x.daily_rate_cents, s.rental_share_cents,
         coalesce((select jsonb_object_agg(f.code, f.cents) from (select li.charge_type as code, sum(li.amount_cents)::bigint as cents from booking_line_items li
                     where li.booking_id = b.id and li.voided_at is null and li.stage in ('booking', 'extension') and li.charge_type = any (app.insurer_fee_codes())
                     group by li.charge_type) f), '{}'::jsonb),
         s.fees_share_cents, s.hst_cents, s.share_cents + s.hst_cents,
         coalesce((select sum(ii.total_cents) filter (where ii.status <> 'draft') from insurer_invoices ii where ii.booking_id = b.id and ii.insurer_id = b.insurer_id), 0)::bigint,
         coalesce((select sum(ii.paid_cents) from insurer_invoices ii where ii.booking_id = b.id and ii.insurer_id = b.insurer_id), 0)::bigint,
         coalesce((select sum(ii.balance_cents) filter (where ii.status in ('sent', 'part_paid')) from insurer_invoices ii where ii.booking_id = b.id and ii.insurer_id = b.insurer_id), 0)::bigint
    from bookings b join vehicles v on v.id = b.vehicle_id
    cross join lateral app.booking_insurer_rate(b) x
    cross join lateral app.booking_insurer_share(b.id) s
   where (p_insurer is null or b.insurer_id = p_insurer) and b.insurer_id is not null and b.bill_to <> 'renter'
     and b.status in ('confirmed', 'on_rent', 'returned', 'closed')
     and (p_from is null or app.local_date(b.pickup_at) >= p_from) and (p_to is null or app.local_date(b.pickup_at) <= p_to)
$$;

-- a group of those rows in figures: bookings, days, the average daily rate, each charge, the share, billed, paid, owed
create or replace function app.insurer_billed_sum(p_rows jsonb) returns jsonb
language sql immutable as $$
  select jsonb_build_object('bookings', count(*), 'days', coalesce(sum((r ->> 'days')::integer), 0),
    'average_rate_cents', case when sum((r ->> 'days')::integer) filter (where r ->> 'daily_rate_cents' is not null) > 0
                               then round(sum((r ->> 'daily_rate_cents')::numeric * (r ->> 'days')::integer) filter (where r ->> 'daily_rate_cents' is not null)
                                          / sum((r ->> 'days')::integer) filter (where r ->> 'daily_rate_cents' is not null))::bigint end,
    'rental_cents', coalesce(sum((r ->> 'rental_cents')::bigint), 0), 'fees_cents', coalesce(sum((r ->> 'fees_cents')::bigint), 0),
    'fees', coalesce((select jsonb_object_agg(k, t) from (select f.key as k, sum(f.value::bigint) as t from jsonb_array_elements(p_rows) y, jsonb_each_text(y -> 'fees') f group by f.key) z), '{}'::jsonb),
    'hst_cents', coalesce(sum((r ->> 'hst_cents')::bigint), 0), 'share_cents', coalesce(sum((r ->> 'share_cents')::bigint), 0),
    'billed_cents', coalesce(sum((r ->> 'billed_cents')::bigint), 0), 'paid_cents', coalesce(sum((r ->> 'paid_cents')::bigint), 0),
    'outstanding_cents', coalesce(sum((r ->> 'outstanding_cents')::bigint), 0))
    from jsonb_array_elements(p_rows) r
$$;

alter function app.insurer_billing(uuid, jsonb) rename to insurer_billing_pre0234;
create function app.insurer_billing(p_by uuid, p jsonb) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare
  v jsonb := app.insurer_billing_pre0234(p_by, p);
  rows jsonb;
begin
  if v is null then return null; end if;
  select coalesce(jsonb_agg(to_jsonb(r)), '[]'::jsonb) into rows
    from app.insurer_billed_rows((v #>> '{insurer,id}')::uuid, nullif(v ->> 'from', '')::date, nullif(v ->> 'to', '')::date) r;
  return v || jsonb_build_object(
    'fee_codes', (select coalesce(jsonb_agg(jsonb_build_object('code', f.code, 'label', f.label) order by f.sort_order), '[]'::jsonb) from fee_types f where f.code = any (app.insurer_fee_codes())),
    'by_car', coalesce((select jsonb_agg(app.insurer_billed_sum(g.rs) || jsonb_build_object('vehicle_id', g.k, 'vehicle', g.rs -> 0 ->> 'vehicle', 'class_code', g.rs -> 0 ->> 'class_code')
                          order by g.rs -> 0 ->> 'vehicle')
                          from (select r ->> 'vehicle_id' as k, jsonb_agg(r) as rs from jsonb_array_elements(rows) r group by r ->> 'vehicle_id') g), '[]'::jsonb),
    'by_adjuster', coalesce((select jsonb_agg(app.insurer_billed_sum(g.rs) || jsonb_build_object('adjuster_id', g.k, 'adjuster', coalesce(g.rs -> 0 ->> 'adjuster', 'No adjuster recorded'))
                          order by g.rs -> 0 ->> 'adjuster' nulls last)
                          from (select r ->> 'adjuster_id' as k, jsonb_agg(r) as rs from jsonb_array_elements(rows) r group by r ->> 'adjuster_id') g), '[]'::jsonb),
    'class_charges', coalesce((select jsonb_object_agg(g.k, app.insurer_billed_sum(g.rs))
                          from (select r ->> 'class_code' as k, jsonb_agg(r) as rs from jsonb_array_elements(rows) r group by r ->> 'class_code') g), '{}'::jsonb),
    'booking_charges', coalesce((select jsonb_object_agg(r ->> 'booking_id', jsonb_build_object('adjuster', r ->> 'adjuster', 'adjuster_id', r ->> 'adjuster_id',
                          'vehicle', r ->> 'vehicle', 'fees', r -> 'fees', 'rental_cents', r -> 'rental_cents', 'hst_cents', r -> 'hst_cents', 'share_cents', r -> 'share_cents'))
                          from jsonb_array_elements(rows) r), '{}'::jsonb),
    'adjusters', app.insurer_adjusters_read(p_by, jsonb_build_object('insurer', v #>> '{insurer,id}', 'all', true)));
end $$;
select pg_temp.copy_grants('app.insurer_billing(uuid, jsonb)'::regprocedure, 'app.insurer_billing_pre0234(uuid, jsonb)'::regprocedure);

alter function app.insurer_rate_sheet(uuid, jsonb) rename to insurer_rate_sheet_pre0234;
create function app.insurer_rate_sheet(p_by uuid, p jsonb) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare
  v jsonb := app.insurer_rate_sheet_pre0234(p_by, p);
  rows jsonb;
begin
  select coalesce(jsonb_agg(to_jsonb(r)), '[]'::jsonb) into rows from app.insurer_billed_rows(null) r;
  return v || jsonb_build_object('billed', coalesce((select jsonb_agg(app.insurer_billed_sum(g.rs) || jsonb_build_object('insurer_id', g.i, 'insurer', (select name from insurers where id::text = g.i),
                    'class_code', g.c, 'class_label', (select label from vehicle_classes where code = g.c)) order by (select name from insurers where id::text = g.i), g.c)
                    from (select r ->> 'insurer_id' as i, r ->> 'class_code' as c, jsonb_agg(r) as rs from jsonb_array_elements(rows) r group by 1, 2) g), '[]'::jsonb));
end $$;
select pg_temp.copy_grants('app.insurer_rate_sheet(uuid, jsonb)'::regprocedure, 'app.insurer_rate_sheet_pre0234(uuid, jsonb)'::regprocedure);

do $$
declare f record;
begin
  for f in select p.oid::regprocedure as sig from pg_proc p join pg_namespace n on n.oid = p.pronamespace
            where n.nspname = 'app' and p.proname in ('insurer_adjuster_find_or_add', 'booking_adjuster_sync', 'insurer_find_or_add', 'booking_insurer_save_pre0234',
                                                     'insurer_adjusters_read', 'insurer_adjuster_save', 'door_pre0234', 'insurer_billed_rows', 'insurer_billed_sum',
                                                     'insurer_billing_pre0234', 'insurer_rate_sheet_pre0234') loop
    execute format('revoke all on function %s from public, anon, authenticated', f.sig);
    execute format('grant execute on function %s to service_role', f.sig);
  end loop;
end $$;
