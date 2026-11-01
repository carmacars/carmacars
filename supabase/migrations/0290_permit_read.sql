-- 0290: the ownership permit read from a photo (Release 25b, docs/changes/2026-11-05-permit-photo-read.md). The owner sent
-- photos of Ontario vehicle permits and the details were typed into the car forms by hand: plate, VIN, year, make and
-- model code, colour, body, permit number and the plate sticker expiry (YYMMDD). Now, when staff or an owner add a car,
-- they take or choose a photo of the permit and the form fills itself; they review every field before saving.
--
-- 1. The vision model reads it (Cloudflare Workers AI, the model of Settings > Vision model, as the toll reader does):
--    program_settings.ai_vision_permit_enabled (on by default) and ai_vision_permit_daily_per_person (10 reads a day for
--    an owner; staff are not capped beyond the day's AI allowance). app.permit_read_gate(user) says whether this person
--    may read one now: Admins, fleet and customer service, or a signed-in owner (an owner record, or a person applying
--    with an account). The call is recorded in provider_calls (its neurons count in the day's allowance) and in
--    permit_reads (who, when, how many fields were read; never the values read).
-- 2. The live tier: the permit reader shares the readers' share of the free allowance (app.ai_tier), with its own label.
-- 3. The permit number and the sticker expiry are saved with a car added for an owner (Add a car for an owner, the
--    owner's own application): app.submit_owner_application takes vehicles[].permit_number and
--    vehicles[].sticker_expires_on, checked as the car's registration checks them (0237), and sets them on the new car.
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

-- ================================================================ 1. settings and the record
alter table program_settings
  add column if not exists ai_vision_permit_enabled boolean not null default true,
  add column if not exists ai_vision_permit_daily_per_person integer not null default 10 check (ai_vision_permit_daily_per_person between 0 and 500);
comment on column program_settings.ai_vision_permit_enabled is 'Read an ownership permit photo with the vision model when a car is added (0290): staff and owners review the details before saving.';
comment on column program_settings.ai_vision_permit_daily_per_person is 'Permit photos an owner may have read per day (0290); staff are limited only by the day''s AI allowance.';

create table if not exists permit_reads (
  id          uuid primary key default gen_random_uuid(),
  user_id     uuid not null references users (id) on delete cascade,
  staff       boolean not null,
  ok          boolean not null,
  model       text,
  fields_read smallint not null default 0 check (fields_read between 0 and 9),
  error       text,
  created_at  timestamptz not null default now()
);
create index if not exists permit_reads_user_day_idx on permit_reads (user_id, created_at);
comment on table permit_reads is 'Ownership permit photos read by the vision model (0290): who asked, when, whether it answered and how many of the nine fields it read. The values read are never stored here; the photo is kept only when the person attaches it to the car.';
alter table permit_reads enable row level security;
revoke all on permit_reads from public, anon, authenticated;
grant select on permit_reads to authenticated;
grant select, insert, update, delete on permit_reads to service_role;
drop policy if exists admin_all on permit_reads;
create policy admin_all on permit_reads for select to authenticated using (app.is_admin());
create trigger audit_permit_reads after insert or update or delete on permit_reads for each row execute function app.audit_row();

-- ================================================================ 2. the tier and the label
create or replace function app.ai_tier(p_purpose text) returns text
language sql immutable as $$
  select case when p_purpose = 'staff_assistant' then 'assistant'
              when p_purpose in ('chat', 'phone_draft', 'phone_summary', 'toll_read', 'plate_detect', 'guide_review', 'permit_read') then 'live'
              else 'background' end
$$;

create or replace function app.ai_feature_label(p_purpose text) returns text
language sql immutable as $$
  select case p_purpose
    when 'staff_assistant' then 'Staff assistant'
    when 'chat' then 'Visitor live chat'
    when 'phone_draft' then 'Phone line: reply drafts'
    when 'phone_summary' then 'Phone line: call summaries'
    when 'toll_read' then 'Toll and ticket reader'
    when 'plate_detect' then 'Plate finder on photos'
    when 'guide_review' then 'Guide suggestions'
    when 'seo_car' then 'Search copy: car pages'
    when 'seo_page' then 'Search copy: landing pages'
    when 'seo_article' then 'Search copy: articles'
    when 'draft_copy' then 'Listing copy of new cars'
    when 'guide_rewrite' then 'Guide upkeep after a deploy'
    when 'turo_email' then 'Turo email reading'
    when 'colour_read' then 'Car colour reader'
    when 'permit_read' then 'Ownership permit reader'
    else initcap(replace(coalesce(p_purpose, 'other'), '_', ' ')) end
$$;

-- ================================================================ 1. the gate and the record
create or replace function app.permit_read_gate(p_by uuid, p_now timestamptz default now()) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare
  s program_settings := app.settings(app.local_date(p_now));
  b jsonb := app.ai_vision_budget(p_now);
  v_staff boolean;
  v_owner boolean;
  v_today integer;
  a jsonb;
begin
  if p_by is null or not exists (select 1 from users u where u.id = p_by and u.status = 'active') then
    raise exception 'Sign in to read a permit photo' using errcode = '42501';
  end if;
  v_staff := app.user_is_admin(p_by) or app.user_va_has(p_by, 'fleet', 'cs');
  v_owner := exists (select 1 from owners o where o.user_id = p_by);
  b := b || jsonb_build_object('staff', v_staff, 'owner', v_owner);
  if not s.ai_vision_permit_enabled then
    return b || jsonb_build_object('allowed', false, 'reason', 'Reading a permit photo is off in Program settings. Type the details from the permit.');
  end if;
  if not coalesce((b ->> 'enabled')::boolean, false) then
    return b || jsonb_build_object('allowed', false, 'reason', 'The vision model is off in Program settings. Type the details from the permit.');
  end if;
  if not v_staff then
    select count(*) into v_today from permit_reads r
     where r.user_id = p_by and r.created_at >= app.local_midnight(app.local_date(p_now)) and r.created_at < p_now + interval '1 second';
    if v_today >= s.ai_vision_permit_daily_per_person then
      return b || jsonb_build_object('allowed', false, 'reason', 'You have read the permits you can for today. Type the details from the permit, or try again tomorrow.');
    end if;
  end if;
  if (b ->> 'all_used')::bigint >= (b ->> 'all_limit')::bigint then
    return b || jsonb_build_object('allowed', false, 'reason', 'Today''s allowance for the vision model is used up; it starts again at midnight, Toronto time. Type the details from the permit.');
  end if;
  a := app.ai_allow('permit_read', 300, p_now);
  if not (a ->> 'ok')::boolean then return b || jsonb_build_object('allowed', false, 'reason', a ->> 'message'); end if;
  return b || jsonb_build_object('allowed', true);
end $$;
comment on function app.permit_read_gate(uuid, timestamptz) is 'May this person have an ownership permit photo read now (0290): staff, or a signed-in owner within the daily count; the model to use.';

create or replace function app.permit_read_record(p_by uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  v_staff boolean := app.user_is_admin(p_by) or app.user_va_has(p_by, 'fleet', 'cs');
  v_id uuid;
begin
  if p_by is null or not exists (select 1 from users u where u.id = p_by and u.status = 'active') then
    raise exception 'Not permitted' using errcode = '42501';
  end if;
  insert into provider_calls (provider, purpose, ok, error, duration_ms, cost_microusd, units, unit)
  values (left(coalesce(p ->> 'model', 'workers-ai'), 120), 'permit_read', coalesce((p ->> 'ok')::boolean, false), left(p ->> 'error', 500),
          greatest(coalesce((p ->> 'duration_ms')::integer, 0), 0), 0, greatest(coalesce((p ->> 'neurons')::integer, 0), 0), 'neurons');
  insert into permit_reads (user_id, staff, ok, model, fields_read, error)
  values (p_by, v_staff, coalesce((p ->> 'ok')::boolean, false), left(p ->> 'model', 120),
          least(greatest(coalesce((p ->> 'fields_read')::integer, 0), 0), 9), left(p ->> 'error', 300))
  returning id into v_id;
  return jsonb_build_object('id', v_id);
end $$;
comment on function app.permit_read_record(uuid, jsonb) is 'Records one permit photo read (0290): the neurons in provider_calls, who and how many fields in permit_reads (never the values).';

create or replace function public.server_permit_read_gate(p_by uuid) returns jsonb
language sql stable security definer set search_path = public, app as $$ select app.permit_read_gate(p_by) $$;
create or replace function public.server_permit_read_record(p_by uuid, p jsonb) returns jsonb
language sql security definer set search_path = public, app as $$ select app.permit_read_record(p_by, p) $$;

-- ================================================================ 3. the permit number and sticker on a new car
create or replace function app.permit_fields_check(p jsonb) returns void
language plpgsql immutable as $$
begin
  if nullif(btrim(coalesce(p ->> 'permit_number', '')), '') is not null and btrim(p ->> 'permit_number') !~ '^[A-Za-z0-9 -]{4,20}$' then
    raise exception 'The permit number is 4 to 20 letters and digits' using errcode = '22023';
  end if;
  if nullif(p ->> 'sticker_expires_on', '') is not null and (p ->> 'sticker_expires_on') !~ '^\d{4}-\d{2}-\d{2}$' then
    raise exception 'The plate sticker expiry is a date' using errcode = '22023';
  end if;
end $$;

alter function app.submit_owner_application(jsonb, uuid) rename to submit_owner_application_pre0290;
create function app.submit_owner_application(p jsonb, p_by uuid default null) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  v_in jsonb := case when jsonb_typeof(p -> 'vehicles') = 'array' then p -> 'vehicles' else '[]'::jsonb end;
  v_out jsonb;
  v jsonb;
  i integer;
  v_id uuid;
  v_sticker date;
begin
  for v in select x from jsonb_array_elements(v_in) x loop
    if jsonb_typeof(v) = 'object' then
      perform app.permit_fields_check(v);
      if nullif(v ->> 'sticker_expires_on', '') is not null then
        v_sticker := (v ->> 'sticker_expires_on')::date;
        if v_sticker < current_date - 365 then raise exception 'The plate sticker expiry is more than a year ago: check it' using errcode = '22023'; end if;
      end if;
    end if;
  end loop;
  v_out := app.submit_owner_application_pre0290(
    case when jsonb_typeof(p -> 'vehicles') = 'array'
         then jsonb_set(p, '{vehicles}', coalesce((select jsonb_agg(case when jsonb_typeof(x) = 'object' then x - 'permit_number' - 'sticker_expires_on' else x end order by n)
                                                   from jsonb_array_elements(p -> 'vehicles') with ordinality e(x, n)), '[]'::jsonb))
         else p end, p_by);
  if jsonb_typeof(v_out -> 'vehicles') = 'array' then
    for i in 0 .. jsonb_array_length(v_in) - 1 loop
      v := v_in -> i;
      v_id := nullif(v_out #>> array['vehicles', i::text, 'vehicle_id'], '')::uuid;
      continue when v_id is null or jsonb_typeof(v) <> 'object';
      continue when nullif(btrim(coalesce(v ->> 'permit_number', '')), '') is null and nullif(v ->> 'sticker_expires_on', '') is null;
      update vehicles set
        permit_number = coalesce(permit_number, nullif(upper(btrim(coalesce(v ->> 'permit_number', ''))), '')),
        sticker_expires_on = coalesce(sticker_expires_on, nullif(v ->> 'sticker_expires_on', '')::date)
       where id = v_id;
    end loop;
  end if;
  return v_out;
end $$;
select pg_temp.copy_grants('app.submit_owner_application(jsonb, uuid)'::regprocedure, 'app.submit_owner_application_pre0290(jsonb, uuid)'::regprocedure);

do $$
declare f record;
begin
  for f in select p.oid::regprocedure as sig from pg_proc p join pg_namespace n on n.oid = p.pronamespace
            where (n.nspname = 'app' and p.proname in ('permit_read_gate', 'permit_read_record', 'permit_fields_check', 'submit_owner_application_pre0290'))
               or (n.nspname = 'public' and p.proname in ('server_permit_read_gate', 'server_permit_read_record')) loop
    execute format('revoke all on function %s from public, anon, authenticated', f.sig);
    execute format('grant execute on function %s to service_role', f.sig);
  end loop;
end $$;
