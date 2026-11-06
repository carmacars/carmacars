-- 0560_vin_reader.sql
-- Release 28 (docs/changes/2026-11-06-r28-platform.md, B2): VIN by photo or camera on every VIN field. The barcode is read
-- in the browser (nothing reaches the server); a photo without a readable barcode goes to the vision model through
-- /api/vin/read, which asks this gate first and records the call after. Like the permit reader (0290), only who asked,
-- when and whether a VIN came back are kept: never the VIN, never the photo.
--
--   program_settings.ai_vision_vin_enabled            the photo reader on or off (on)
--   program_settings.ai_vision_vin_daily_per_person   photos a signed-in person who is not staff may have read per day (20)
--   program_settings.ai_vision_vin_daily_per_visitor  photos one visitor (the application, the earnings calculator) may
--                                                     have read per day, counted by a hash of the address and day (5)
--   program_settings.ai_vision_vin_daily_visitors     photos all visitors together may have read per day (100)
-- Staff are limited only by the day's AI allowance (the live share of app.ai_allow), as for permits.

alter table program_settings
  add column if not exists ai_vision_vin_enabled boolean not null default true,
  add column if not exists ai_vision_vin_daily_per_person integer not null default 20 check (ai_vision_vin_daily_per_person between 0 and 500),
  add column if not exists ai_vision_vin_daily_per_visitor integer not null default 5 check (ai_vision_vin_daily_per_visitor between 0 and 100),
  add column if not exists ai_vision_vin_daily_visitors integer not null default 100 check (ai_vision_vin_daily_visitors between 0 and 5000);
comment on column program_settings.ai_vision_vin_enabled is 'Read a VIN from a photo with the vision model when the photo has no readable barcode (0560). The live barcode scan runs in the browser and needs no setting.';
comment on column program_settings.ai_vision_vin_daily_per_person is 'VIN photos a signed-in person who is not staff may have read per day (0560); staff are limited only by the day''s AI allowance.';
comment on column program_settings.ai_vision_vin_daily_per_visitor is 'VIN photos one visitor who is not signed in may have read per day (0560), counted by a hash of the address and the day.';
comment on column program_settings.ai_vision_vin_daily_visitors is 'VIN photos all visitors who are not signed in may have read per day together (0560).';

create table if not exists vin_reads (
  id          uuid primary key default gen_random_uuid(),
  user_id     uuid references users (id) on delete cascade,
  client_hash text not null check (client_hash ~ '^[0-9a-f]{16,64}$'),
  staff       boolean not null default false,
  ok          boolean not null,
  check_ok    boolean,
  corrected   boolean,
  model       text,
  error       text,
  created_at  timestamptz not null default now()
);
create index if not exists vin_reads_user_day_idx on vin_reads (user_id, created_at);
create index if not exists vin_reads_client_day_idx on vin_reads (client_hash, created_at);
create index if not exists vin_reads_day_idx on vin_reads (created_at);
comment on table vin_reads is 'VIN photos read by the vision model (0560): who asked (a person, or a visitor by a hash of the address and the day), when, whether a VIN came back and whether its check digit added up. The VIN and the photo are never stored.';
alter table vin_reads enable row level security;
revoke all on vin_reads from public, anon, authenticated;
grant select on vin_reads to authenticated;
grant select, insert, update, delete on vin_reads to service_role;
drop policy if exists admin_all on vin_reads;
create policy admin_all on vin_reads for select to authenticated using (app.is_admin());
drop trigger if exists audit_vin_reads on vin_reads;
create trigger audit_vin_reads after insert or update or delete on vin_reads for each row execute function app.audit_row();

-- ================================================================ the AI tier and label of the new purpose
create or replace function app.ai_tier(p_purpose text) returns text
language sql immutable as $$
  select case when p_purpose = 'staff_assistant' then 'assistant'
              when p_purpose in ('chat', 'phone_draft', 'phone_summary', 'toll_read', 'plate_detect', 'guide_review', 'permit_read',
                                 'interview_transcribe', 'interview_followup', 'vin_read') then 'live'
              else 'background' end
$$;

do $$ begin
  if not exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace where n.nspname = 'app' and p.proname = 'ai_feature_label_pre0560') then
    alter function app.ai_feature_label(text) rename to ai_feature_label_pre0560;
  end if;
end $$;
create or replace function app.ai_feature_label(p_purpose text) returns text
language sql immutable as $$
  select case p_purpose when 'vin_read' then 'VIN photo reader' else app.ai_feature_label_pre0560(p_purpose) end
$$;

-- ================================================================ the gate and the record
create or replace function app.vin_read_gate(p_by uuid, p_client text, p_now timestamptz default now()) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare
  s program_settings := app.settings(app.local_date(p_now));
  b jsonb := app.ai_vision_budget(p_now);
  v_t0 timestamptz := app.local_midnight(app.local_date(p_now));
  v_staff boolean := false;
  v_n integer;
  a jsonb;
begin
  if p_client is null or p_client !~ '^[0-9a-f]{16,64}$' then raise exception 'A client key is needed' using errcode = '22023'; end if;
  if p_by is not null then
    if not exists (select 1 from users u where u.id = p_by and u.status = 'active') then
      raise exception 'Not permitted' using errcode = '42501';
    end if;
    v_staff := app.user_is_admin(p_by) or app.user_is_staff(p_by) or app.user_is_field(p_by);
  end if;
  b := b || jsonb_build_object('staff', v_staff, 'signed_in', p_by is not null);
  if not s.ai_vision_vin_enabled then
    return b || jsonb_build_object('allowed', false, 'reason', 'Reading a VIN from a photo is off in Program settings. Scan the barcode or type the VIN.');
  end if;
  if not coalesce((b ->> 'enabled')::boolean, false) then
    return b || jsonb_build_object('allowed', false, 'reason', 'The vision model is off in Program settings. Scan the barcode or type the VIN.');
  end if;
  if p_by is not null and not v_staff then
    select count(*) into v_n from vin_reads r where r.user_id = p_by and r.created_at >= v_t0 and r.created_at <= p_now;
    if v_n >= s.ai_vision_vin_daily_per_person then
      return b || jsonb_build_object('allowed', false, 'reason', 'You have read the VIN photos you can for today. Scan the barcode or type the VIN.');
    end if;
  elsif p_by is null then
    select count(*) into v_n from vin_reads r where r.user_id is null and r.client_hash = p_client and r.created_at >= v_t0 and r.created_at <= p_now;
    if v_n >= s.ai_vision_vin_daily_per_visitor then
      return b || jsonb_build_object('allowed', false, 'reason', 'You have read the VIN photos you can for today. Scan the barcode or type the VIN.');
    end if;
    select count(*) into v_n from vin_reads r where r.user_id is null and r.created_at >= v_t0 and r.created_at <= p_now;
    if v_n >= s.ai_vision_vin_daily_visitors then
      return b || jsonb_build_object('allowed', false, 'reason', 'Reading VIN photos is busy today. Scan the barcode or type the VIN.');
    end if;
  end if;
  if (b ->> 'all_used')::bigint >= (b ->> 'all_limit')::bigint then
    return b || jsonb_build_object('allowed', false, 'reason', 'Today''s allowance for the vision model is used up; it starts again at midnight, Toronto time. Scan the barcode or type the VIN.');
  end if;
  a := app.ai_allow('vin_read', 150, p_now);
  if not (a ->> 'ok')::boolean then return b || jsonb_build_object('allowed', false, 'reason', a ->> 'message'); end if;
  return b || jsonb_build_object('allowed', true);
end $$;

create or replace function app.vin_read_record(p_by uuid, p_client text, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  v_staff boolean := p_by is not null and (app.user_is_admin(p_by) or app.user_is_staff(p_by) or app.user_is_field(p_by));
  v_id uuid;
begin
  if p_by is not null and not exists (select 1 from users u where u.id = p_by and u.status = 'active') then
    raise exception 'Not permitted' using errcode = '42501';
  end if;
  if p_client is null or p_client !~ '^[0-9a-f]{16,64}$' then raise exception 'A client key is needed' using errcode = '22023'; end if;
  insert into provider_calls (provider, purpose, ok, error, duration_ms, cost_microusd, units, unit)
  values (left(coalesce(p ->> 'model', 'workers-ai'), 120), 'vin_read', coalesce((p ->> 'ok')::boolean, false), left(p ->> 'error', 500),
          greatest(coalesce((p ->> 'duration_ms')::integer, 0), 0), 0, greatest(coalesce((p ->> 'neurons')::integer, 0), 0), 'neurons');
  insert into vin_reads (user_id, client_hash, staff, ok, check_ok, corrected, model, error)
  values (p_by, p_client, v_staff, coalesce((p ->> 'ok')::boolean, false), (p ->> 'check_ok')::boolean, (p ->> 'corrected')::boolean,
          left(p ->> 'model', 120), left(p ->> 'error', 300))
  returning id into v_id;
  return jsonb_build_object('id', v_id);
end $$;

-- the server's doors (service role only); p_by null: a visitor who is not signed in
create or replace function public.server_vin_read_gate(p_client text, p_by uuid default null) returns jsonb
language sql stable security definer set search_path = public, app as $$ select app.vin_read_gate(p_by, p_client) $$;
create or replace function public.server_vin_read_record(p_client text, p jsonb, p_by uuid default null) returns jsonb
language sql security definer set search_path = public, app as $$ select app.vin_read_record(p_by, p_client, p) $$;
revoke all on function app.vin_read_gate(uuid, text, timestamptz), app.vin_read_record(uuid, text, jsonb),
  public.server_vin_read_gate(text, uuid), public.server_vin_read_record(text, jsonb, uuid) from public, anon, authenticated;
grant execute on function public.server_vin_read_gate(text, uuid), public.server_vin_read_record(text, jsonb, uuid) to service_role;

-- the server may run every function of the app schema (suites 06, 08 and 09)
do $g$
declare f regprocedure;
begin
  for f in select p.oid::regprocedure from pg_proc p join pg_namespace n on n.oid = p.pronamespace
            where n.nspname = 'app' and not has_function_privilege('service_role', p.oid, 'execute') loop
    execute format('grant execute on function %s to service_role', f);
  end loop;
end $g$;
