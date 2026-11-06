-- 0544: Blind Spot's rental agreement filled in full, and typed corrections (docs/changes/2026-11-07-r28-operations.md, A11).
--
-- The form's facts (app.blindspot_extra) also carry:
--   readings        the booking's own km and fuel out and in (a pickup or return recorded now, details later, has no
--                   report readings yet): the form fills K/M out and in and fuel out and in from them;
--   late_fee_cents  the booking's late fee per started hour: box 34's per-hour late charge on every copy;
--   overrides       what staff typed over the filled form (Type into the agreement), box by box.
-- blindspot_box_overrides keeps the typed values (audited). Saving writes back to the booking what has a home there
-- (the insured vehicle, the claim number, the adjuster; K/M and fuel out or in while the booking has none) and keeps the
-- rest as the form's own correction; the agreement job then makes the corrected version.
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

create table if not exists blindspot_box_overrides (
  id         uuid primary key default gen_random_uuid(),
  booking_id uuid not null references bookings (id) on delete cascade,
  box        text not null check (box ~ '^[a-z0-9-]{1,24}$'),
  value      text not null check (char_length(value) <= 200),
  set_by     uuid references users (id) on delete set null,
  set_at     timestamptz not null default now(),
  unique (booking_id, box)
);
alter table blindspot_box_overrides enable row level security;
create policy admin_all on blindspot_box_overrides for all to authenticated using (app.is_admin()) with check (app.is_admin());
create trigger audit_blindspot_box_overrides after insert or update or delete on blindspot_box_overrides for each row execute function app.audit_row();
comment on table blindspot_box_overrides is 'Values staff typed over the filled Blind Spot form (0544), by box; drawn in place of what the booking gives.';

alter function app.blindspot_extra(uuid) rename to blindspot_extra_pre0544;
create function app.blindspot_extra(p_booking uuid) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare
  b bookings;
  t record;
begin
  select * into b from bookings where id = p_booking;
  select * into t from app.booking_fee_term(p_booking, 'late_return_fee');
  return app.blindspot_extra_pre0544(p_booking) || jsonb_build_object(
    'readings', jsonb_build_object('odometer_out_km', b.odometer_out_km, 'fuel_out_pct', b.fuel_out_pct, 'odometer_in_km', b.odometer_in_km, 'fuel_in_pct', b.fuel_in_pct),
    'late_fee_cents', nullif(coalesce(t.amount_cents, 0), 0),
    'overrides', coalesce((select jsonb_object_agg(o.box, o.value) from blindspot_box_overrides o where o.booking_id = p_booking), '{}'::jsonb));
end $$;
select pg_temp.copy_grants('app.blindspot_extra(uuid)'::regprocedure, 'app.blindspot_extra_pre0544(uuid)'::regprocedure);

create or replace function app.blindspot_boxes_save(p_by uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  b bookings;
  k text;
  v text;
  v_n integer := 0;
  v_back text[] := '{}';
  v_int integer;
begin
  if not (app.user_is_admin(p_by) or app.user_may_handover(p_by) or app.offer_role(p_by) is not null) then
    raise exception 'Staff who handle bookings correct the agreement' using errcode = '42501';
  end if;
  select * into b from bookings where id::text = p ->> 'booking' or booking_number = upper(btrim(coalesce(p ->> 'booking', ''))) for update;
  if b.id is null then raise exception 'Booking not found' using errcode = 'P0002'; end if;
  if jsonb_typeof(p -> 'boxes') <> 'object' then raise exception 'Nothing to save' using errcode = '22023'; end if;
  for k, v in select key, nullif(btrim(value), '') from jsonb_each_text(p -> 'boxes') loop
    if k !~ '^[a-z0-9-]{1,24}$' then raise exception 'Unknown box %', k using errcode = '22023'; end if;
    if v is not null and char_length(v) > 200 then raise exception 'Box % is too long (200 characters at most)', k using errcode = '22023'; end if;
    if v is null then
      delete from blindspot_box_overrides where booking_id = b.id and box = k;
    else
      insert into blindspot_box_overrides (booking_id, box, value, set_by) values (b.id, k, v, p_by)
      on conflict (booking_id, box) do update set value = excluded.value, set_by = excluded.set_by, set_at = now();
      -- what has a home on the booking goes back there too
      begin
        if k = 'insured' then update bookings set insured_vehicle = v where id = b.id; v_back := v_back || k;
        elsif k = 'claim' then update bookings set insurer_claim_number = v where id = b.id; v_back := v_back || k;
        elsif k = 'adjuster' then update bookings set insurer_adjuster_name = v where id = b.id; v_back := v_back || k;
        elsif k in ('28', '27', 'fuel-out', 'fuel-in') then
          v_int := nullif(regexp_replace(v, '[^0-9]', '', 'g'), '')::integer;
          if v_int is not null then
            if k = '28' and b.odometer_out_km is null then update bookings set odometer_out_km = v_int where id = b.id; v_back := v_back || k;
            elsif k = '27' and b.odometer_in_km is null then update bookings set odometer_in_km = v_int where id = b.id; v_back := v_back || k;
            elsif k = 'fuel-out' and b.fuel_out_pct is null and v_int between 0 and 100 then update bookings set fuel_out_pct = v_int where id = b.id; v_back := v_back || k;
            elsif k = 'fuel-in' and b.fuel_in_pct is null and v_int between 0 and 100 then update bookings set fuel_in_pct = v_int where id = b.id; v_back := v_back || k;
            end if;
          end if;
        end if;
      exception when others then
        raise warning '0544 write-back of box % on %: %', k, b.booking_number, sqlerrm;
      end;
    end if;
    v_n := v_n + 1;
  end loop;
  perform app.log_booking_event(b.id, 'adjusted', b.status::text, b.status::text, null,
    format('Blind Spot agreement corrected by hand (%s box%s)', v_n, case when v_n = 1 then '' else 'es' end), p_by, 'staff',
    jsonb_build_object('boxes', p -> 'boxes', 'written_back', to_jsonb(v_back)));
  return jsonb_build_object('ok', true, 'saved', v_n, 'written_back', to_jsonb(v_back), 'booking_id', b.id);
end $$;
revoke all on function app.blindspot_boxes_save(uuid, jsonb) from public, anon, authenticated;

alter function app.door(uuid, text, text, text, jsonb) rename to door_pre0544;
create function app.door(p_user uuid, p_aal text, p_call text, p_name text, p jsonb default '{}'::jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
begin
  if p_call in ('ops_do', 'admin_do') and p_name = 'blindspot_boxes_save' then
    if coalesce(p, '{}'::jsonb) ? '_va' then perform set_config('app.va_active', coalesce(p ->> '_va', ''), true); end if;
    perform app.door_begin(p_user, p_aal);
    return app.blindspot_boxes_save(p_user, coalesce(p, '{}'::jsonb) - '_va');
  end if;
  return app.door_pre0544(p_user, p_aal, p_call, p_name, p);
end $$;
select pg_temp.copy_grants('app.door(uuid, text, text, text, jsonb)'::regprocedure, 'app.door_pre0544(uuid, text, text, text, jsonb)'::regprocedure);
