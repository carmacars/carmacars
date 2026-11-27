-- 5136 (R50 hotfix 2, Sales; docs/changes/2026-11-27-r50-sales-fixes.md). The owner, Nov 27: "sales shift claims need Admin
-- approval before assignment (claim, pending, approved or denied, notices both ways)".
--
-- A salesperson who works field shifts (field staff with Sales, 0931) claimed a shift on My shifts and held it at once. Now
-- a claim by a person with the Sales function waits for an Admin:
--   1. Claim: field_do shift_take (an open shift) or offer_claim (a shift someone gave up) from a salesperson makes a
--      shift_claims row, pending, after the same checks the shift itself makes (it exists, has not started, has room or is
--      still offered, the person is not on it, no claim of theirs waits on it). Nothing is held yet. The Admins are told
--      (shift_claim_pending); My shifts lists it as "Waiting for an Admin".
--   2. Decide: admin_do shift_claim_decide {claim, approve, note}. Approve books the shift exactly as the claim would have
--      (0880's field_shift_book, or 0931's offer claim, so the full, overlap, academy and last-day rules still decide; a
--      claim the shift no longer allows is refused with the reason and stays pending for a Deny). Deny needs the reason.
--      The person is told either way (shift_claim_decided), with the reason.
--   3. A claim not decided before the shift starts lapses: it reads as lapsed, and is stored so at the next decision.
--   Fleet and Admin putting a person on a shift, swaps and standing shifts are unchanged; field staff without Sales are
--   unchanged.
-- SCHEMA_MARKER is not changed. New table: row-level security, admin_all, the audit trigger. No applied migration is
-- edited: app.door is wrapped (_pre5136).
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

create table shift_claims (
  id            uuid primary key default gen_random_uuid(),
  slot_id       uuid not null references field_shift_slots (id),
  offer_id      uuid references field_shift_offers (id),
  staff_id      uuid not null references users (id),
  status        text not null default 'pending' check (status in ('pending', 'approved', 'denied', 'lapsed')),
  decided_by    uuid references users (id),
  decided_at    timestamptz,
  decided_note  text check (decided_note is null or length(decided_note) <= 300),
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now(),
  check (status <> 'denied' or decided_note is not null)
);
comment on table shift_claims is 'A salesperson''s claim of a field shift waiting for an Admin (5136): approved books it, denied tells them why.';
create unique index shift_claims_one_pending on shift_claims (slot_id, staff_id) where status = 'pending';
create index shift_claims_slot_idx on shift_claims (slot_id);
create index shift_claims_offer_idx on shift_claims (offer_id) where offer_id is not null;
create index shift_claims_staff_idx on shift_claims (staff_id, created_at);
create trigger shift_claims_updated before update on shift_claims for each row execute function app.set_updated_at();
create trigger audit_shift_claims after insert or update or delete on shift_claims for each row execute function app.audit_row();
alter table shift_claims enable row level security;
create policy admin_all on shift_claims for all to authenticated using (app.is_admin()) with check (app.is_admin());
revoke all on shift_claims from public, anon, authenticated;
grant all on shift_claims to service_role;

insert into staff_alert_rules (rule, label, grp, who, tier, topic, wired, fixed, hint, sort, pref_type) values
  ('shift_claim_pending', 'A salesperson claimed a shift: approve or deny', 'Field work', '{admin}', 'normal', 'alerts', true, false,
   '5136: a salesperson''s shift claim waits for an Admin (Shift claims).', 57, 'staff_fleet'),
  ('shift_claim_decided', 'Your shift claim was approved or denied', 'Field work', '{assigned}', 'normal', 'alerts', true, false,
   '5136: an Admin decided your shift claim.', 58, 'staff_fleet')
on conflict (rule) do nothing;

-- claims waiting past their shift's start lapse
create function app.shift_claims_lapse() returns void
language sql security definer set search_path = public, app, pg_temp as $$
  update shift_claims c set status = 'lapsed', decided_at = now()
    from field_shift_slots s where s.id = c.slot_id and c.status = 'pending' and (s.starts_at <= now() or s.cancelled_at is not null)
$$;

create function app.shift_claim_words(s field_shift_slots) returns text
language sql stable security definer set search_path = public, app, pg_temp as $$
  select app.fmt_day(app.local_date(s.starts_at)) || ', ' || to_char(s.starts_at at time zone 'America/Toronto', 'FMHH12:MI am') || ' to '
      || to_char(s.ends_at at time zone 'America/Toronto', 'FMHH12:MI am')
$$;

-- p: {slot} (shift_take) or {id} (offer_claim)
create function app.shift_claim_make(p_user uuid, p_name text, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app, pg_temp as $$
declare
  s field_shift_slots;
  o field_shift_offers;
  v_id uuid;
begin
  if app.academy_locked(p_user) then raise exception 'Pass the academy first, then claim shifts' using errcode = '23514'; end if;
  if p_name = 'offer_claim' then
    select * into o from field_shift_offers where id = nullif(p ->> 'id', '')::uuid;
    if o.id is null or o.kind <> 'giveaway' then raise exception 'That shift is not offered' using errcode = 'P0002'; end if;
    if o.status <> 'open' then raise exception 'Someone already claimed this shift' using errcode = '23514'; end if;
    if o.from_staff = p_user then raise exception 'You gave this shift up' using errcode = '23514'; end if;
    select * into s from field_shift_slots where id = o.slot_id;
  else
    select * into s from field_shift_slots where id = nullif(p ->> 'slot', '')::uuid;
    if s.id is not null and (select count(*) from field_shift_plans x where x.slot_id = s.id and x.cancelled_at is null) >= s.capacity then
      raise exception 'This shift is full' using errcode = '23514';
    end if;
  end if;
  if s.id is null or s.cancelled_at is not null then raise exception 'That shift is not there any more' using errcode = 'P0002'; end if;
  if s.starts_at <= now() then raise exception 'That shift has started' using errcode = '23514'; end if;
  if exists (select 1 from field_shift_plans x where x.slot_id = s.id and x.staff_id = p_user and x.cancelled_at is null) then
    raise exception 'Already on this shift' using errcode = '23505';
  end if;
  select id into v_id from shift_claims where slot_id = s.id and staff_id = p_user and status = 'pending';
  if v_id is null then
    insert into shift_claims (slot_id, offer_id, staff_id) values (s.id, o.id, p_user) returning id into v_id;
    begin
      perform app.staff_alert('shift_claim_pending', 'shift_claim', v_id, 'pending',
        left(format('%s claimed a shift: %s', coalesce((select u.full_name from users u where u.id = p_user), 'A salesperson'), app.shift_claim_words(s)), 140),
        'Approve or deny it on Shift claims.', jsonb_build_object('path_admin', '/admin/shift-claims'));
    exception when others then raise warning 'shift claim alert not sent for %: %', v_id, sqlerrm;
    end;
  end if;
  return jsonb_build_object('pending', true, 'claim', v_id,
    'message', 'Claimed: an Admin approves sales shift claims. You hold the shift once it is approved; you are told either way.');
end $$;

-- p: {claim, approve, note}
create function app.shift_claim_decide(p_by uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app, pg_temp as $$
declare
  c shift_claims;
  s field_shift_slots;
  v_ok boolean := coalesce((p ->> 'approve')::boolean, false);
  v_note text := nullif(left(btrim(coalesce(p ->> 'note', '')), 300), '');
  v jsonb;
begin
  perform app.assert_admin(p_by);
  perform app.shift_claims_lapse();
  select * into c from shift_claims where id = nullif(p ->> 'claim', '')::uuid for update;
  if c.id is null then raise exception 'Claim not found' using errcode = 'P0002'; end if;
  if c.status <> 'pending' then raise exception 'This claim is %', c.status using errcode = '23514'; end if;
  select * into s from field_shift_slots where id = c.slot_id;
  if v_ok then
    if c.offer_id is not null then v := app.fx_offer_claim(c.staff_id, jsonb_build_object('id', c.offer_id));
    else v := app.field_shift_book(c.staff_id, c.slot_id, c.staff_id); end if;
    update shift_claims set status = 'approved', decided_by = p_by, decided_at = now(), decided_note = v_note where id = c.id;
  else
    if v_note is null then raise exception 'Say why the claim is denied' using errcode = '22023'; end if;
    update shift_claims set status = 'denied', decided_by = p_by, decided_at = now(), decided_note = v_note where id = c.id;
  end if;
  begin
    perform app.staff_alert('shift_claim_decided', 'shift_claim', c.id, case when v_ok then 'approved' else 'denied' end,
      left(format('Your shift claim was %s: %s', case when v_ok then 'approved' else 'denied' end, app.shift_claim_words(s)), 140),
      left(case when v_ok then 'The shift is yours. ' else '' end || coalesce(v_note, ''), 240),
      jsonb_build_object('assigned_to', c.staff_id, 'path_staff', '/staff/field/shifts'));
  exception when others then raise warning 'shift claim decision alert not sent for %: %', c.id, sqlerrm;
  end;
  insert into audit_log (actor_user_id, action, entity_table, entity_id, after)
  values (p_by, 'shift_claim_decide', 'shift_claims', c.id::text, jsonb_build_object('approve', v_ok, 'note', v_note, 'plan', v -> 'id'));
  return jsonb_build_object('ok', true, 'claim', c.id, 'status', case when v_ok then 'approved' else 'denied' end);
end $$;

create function app.shift_claims_admin(p_by uuid, p jsonb) returns jsonb
language plpgsql stable security definer set search_path = public, app, pg_temp as $$
declare v_status text := coalesce(nullif(p ->> 'status', ''), 'pending');
begin
  perform app.assert_admin(p_by);
  return jsonb_build_object('status', v_status, 'pending', (select count(*) from shift_claims c join field_shift_slots s on s.id = c.slot_id where c.status = 'pending' and s.starts_at > now()),
    'rows', coalesce((select jsonb_agg(jsonb_build_object('id', c.id, 'staff', coalesce(u.full_name, u.email), 'staff_id', c.staff_id, 'starts_at', s.starts_at, 'ends_at', s.ends_at,
               'when', app.shift_claim_words(s), 'given_up', c.offer_id is not null, 'status', case when c.status = 'pending' and s.starts_at <= now() then 'lapsed' else c.status end, 'note', c.decided_note, 'claimed_at', c.created_at,
               'decided_at', c.decided_at, 'taken', (select count(*) from field_shift_plans x where x.slot_id = s.id and x.cancelled_at is null), 'capacity', s.capacity)
             order by s.starts_at)
             from shift_claims c join field_shift_slots s on s.id = c.slot_id join users u on u.id = c.staff_id
            where v_status = 'all' or (case when c.status = 'pending' and s.starts_at <= now() then 'lapsed' else c.status end) = v_status), '[]'::jsonb));
end $$;

create function app.my_shift_claims(p_user uuid) returns jsonb
language sql stable security definer set search_path = public, app, pg_temp as $$
  select coalesce(jsonb_agg(jsonb_build_object('id', c.id, 'slot_id', c.slot_id, 'starts_at', s.starts_at, 'ends_at', s.ends_at, 'status', c.status, 'note', c.decided_note)
                  order by s.starts_at), '[]'::jsonb)
    from shift_claims c join field_shift_slots s on s.id = c.slot_id
   where c.staff_id = p_user and (c.status = 'pending' or (c.status in ('approved', 'denied') and c.decided_at > now() - interval '7 days'))
     and s.ends_at > now()
$$;

alter function app.door(uuid, text, text, text, jsonb) rename to door_pre5136;
create function app.door(p_user uuid, p_aal text, p_call text, p_name text, p jsonb default '{}'::jsonb) returns jsonb
language plpgsql security definer set search_path = public, app, pg_temp as $$
declare
  p_ jsonb := coalesce(p, '{}'::jsonb) - '_va';
  v jsonb;
begin
  if p_call = 'field_do' and p_name in ('shift_take', 'offer_claim') and app.user_va_has_sales(p_user) and not app.user_is_admin(p_user) then
    perform app.door_begin(p_user, p_aal);
    if not app.is_field_person(p_user) then raise exception 'Not permitted' using errcode = '42501'; end if;
    return app.shift_claim_make(p_user, p_name, p_);
  end if;
  if p_call = 'admin_read' and p_name = 'shift_claims' then
    perform app.door_begin(p_user, p_aal);
    return app.shift_claims_admin(p_user, p_);
  end if;
  if p_call = 'admin_do' and p_name = 'shift_claim_decide' then
    perform app.door_begin(p_user, p_aal);
    return app.shift_claim_decide(p_user, p_);
  end if;
  v := app.door_pre5136(p_user, p_aal, p_call, p_name, p);
  if p_call = 'field_read' and p_name = 'my_shifts' and jsonb_typeof(v) = 'object' then
    v := v || jsonb_build_object('claims', app.my_shift_claims(p_user));
  end if;
  return v;
end $$;
select pg_temp.copy_grants('app.door(uuid, text, text, text, jsonb)'::regprocedure, 'app.door_pre5136(uuid, text, text, text, jsonb)'::regprocedure);

revoke all on function app.shift_claims_lapse(), app.shift_claim_words(field_shift_slots), app.shift_claim_make(uuid, text, jsonb), app.shift_claim_decide(uuid, jsonb),
  app.shift_claims_admin(uuid, jsonb), app.my_shift_claims(uuid) from public, anon, authenticated;
grant execute on function app.shift_claims_lapse(), app.shift_claim_words(field_shift_slots), app.shift_claim_make(uuid, text, jsonb), app.shift_claim_decide(uuid, jsonb),
  app.shift_claims_admin(uuid, jsonb), app.my_shift_claims(uuid) to service_role;
