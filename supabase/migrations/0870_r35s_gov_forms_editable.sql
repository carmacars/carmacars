-- 0870: the government (ServiceOntario) registration forms are as editable as the rental agreements (Release 35, part S;
-- docs/changes/2026-11-08-r35-gov-forms-editable.md). No applied migration is edited.
--
-- The rental agreement's pattern (0198, 0154): an Admin corrects one generated agreement before it is signed, always with a
-- reason, the change is audited and the agreement is made again as a new version; the template's text is edited with a
-- preview and its versions are kept. The government forms get the same, on the official form itself (the owner's rule of
-- October 23, 2026, again on November 8: the forms are the publisher's PDFs byte for byte, only their boxes are filled;
-- their own text and layout are never edited or set again):
--   1. a box's value on one generated form (government_form_overrides): an Admin or fleet changes the value of a text box of
--      the official form (or a row of the data sheet while the form is not in use as a PDF), with a reason; the form is made
--      again as a new version (government_form_fills keeps every version, each downloadable by staff), audited; "Back to
--      the records" ends the change. A form signed in ink or filed is never changed.
--   2. the field mapping of a form (which platform value fills which box): fleet maps the forms too; every saved mapping is
--      kept (pdf_template_map_history), audited, and an earlier one can be loaded again; the preview fills the official
--      form with the mapping on screen, for a real car or for a sample car (made-up values).
--   3. Make again keeps the changed values unless the Admin or fleet chooses to discard them.
--   4. owners see only the current version (their reads already take the current fill alone).
--   5. the official form is filled only from the publisher's PDF: a template that is not the publisher's download (the
--      0047 copies opened with qpdf, the laid-out copy of ON00453) or an Admin's upload of the official PDF gives the data
--      sheet, never a look-alike.
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

-- ================================================================ the tables
create table government_form_overrides (
  id          uuid primary key default gen_random_uuid(),
  vehicle_id  uuid not null references vehicles (id),
  form_code   text not null,
  target      text not null check (target in ('pdf', 'sheet')),   -- pdf: a box of the official form (its field name); sheet: a row of the data sheet (its label)
  field       text not null check (length(field) between 1 and 300),
  value       text check (value is null or length(value) <= 500),  -- null: the box left empty
  reason      text not null check (length(btrim(reason)) >= 3),
  created_by  uuid references users (id),
  created_at  timestamptz not null default now(),
  ended_at    timestamptz,                                          -- replaced by a later change, back to the records, or discarded at Make again
  ended_by    uuid references users (id),
  end_reason  text
);
comment on table government_form_overrides is 'A value changed by hand on one car''s government form (0870), kept through every new version until it is ended.';
create unique index government_form_overrides_one on government_form_overrides (vehicle_id, form_code, target, field) where ended_at is null;
create index government_form_overrides_vehicle on government_form_overrides (vehicle_id, form_code);
alter table government_form_overrides enable row level security;
create policy admin_all on government_form_overrides for all to authenticated using (app.is_admin()) with check (app.is_admin());
revoke all on government_form_overrides from anon, authenticated;
grant select on government_form_overrides to authenticated;
grant all on government_form_overrides to service_role;
create trigger audit_government_form_overrides after insert or update or delete on government_form_overrides for each row execute function app.audit_row();

alter table government_form_fills add column if not exists overrides jsonb not null default '[]'::jsonb check (jsonb_typeof(overrides) = 'array');
comment on column government_form_fills.overrides is 'The values changed by hand that this version carries (0870): [{id, target, field}].';

create table pdf_template_map_history (
  id          uuid primary key default gen_random_uuid(),
  template_id uuid not null references pdf_templates (id),
  form_code   text not null,
  field_map   jsonb not null,
  verified    boolean not null,
  saved_by    uuid references users (id),
  saved_at    timestamptz not null default now(),
  note        text
);
comment on table pdf_template_map_history is 'Every mapping saved for an official form (0870): which platform value fills which box, by whom and when.';
create index pdf_template_map_history_template on pdf_template_map_history (template_id, saved_at desc);
alter table pdf_template_map_history enable row level security;
create policy admin_all on pdf_template_map_history for all to authenticated using (app.is_admin()) with check (app.is_admin());
revoke all on pdf_template_map_history from anon, authenticated;
grant select on pdf_template_map_history to authenticated;
grant all on pdf_template_map_history to service_role;
create trigger audit_pdf_template_map_history after insert or update or delete on pdf_template_map_history for each row execute function app.audit_row();

-- the mapping as it stands today, so the first change has something to go back to
insert into pdf_template_map_history (template_id, form_code, field_map, verified, saved_by, saved_at, note)
select t.id, t.form_code, t.field_map, t.verified, t.mapped_by, coalesce(t.mapped_at, t.created_at), 'The mapping before release 35'
  from pdf_templates t where t.kind is distinct from 'booking_overlay' and t.field_map <> '{}'::jsonb;

create function app.pdf_template_map_record() returns trigger
language plpgsql security definer set search_path = public, app as $$
begin
  if new.kind = 'booking_overlay' then return null; end if;
  if tg_op = 'UPDATE' and new.field_map is not distinct from old.field_map and new.verified is not distinct from old.verified then return null; end if;
  insert into pdf_template_map_history (template_id, form_code, field_map, verified, saved_by, note)
  values (new.id, new.form_code, new.field_map, new.verified, coalesce(new.mapped_by, new.uploaded_by), nullif(left(btrim(coalesce(current_setting('app.map_note', true), '')), 300), ''));
  return null;
end $$;
create trigger pdf_templates_map_history after insert or update of field_map, verified on pdf_templates
  for each row execute function app.pdf_template_map_record();

-- ================================================================ who may change them
-- An Admin, and fleet (the staff who handle owners' cars and their registration); customer service reads them.
create function app.government_forms_editor(p_by uuid) returns boolean
language sql stable security definer set search_path = public, app as $$
  select p_by is not null and (app.user_is_admin(p_by) or app.user_va_has(p_by, 'fleet')) $$;

-- the publisher's PDF: the stored download of the form (official_form_originals) or an Admin's upload of it; never the
-- copies opened and saved again (0047) or a laid-out copy (kind overlay)
create function app.official_form_is_publisher(p_template uuid) returns boolean
language sql stable security definer set search_path = public, app as $$
  select exists (select 1 from pdf_templates t
                  where t.id = p_template and t.file_key is not null and t.kind not in ('overlay', 'booking_overlay', 'generated')
                    and (exists (select 1 from official_form_originals o where o.form_code = t.form_code and o.sha256 = t.sha256)
                         or t.uploaded_by is not null)) $$;

-- the version number of a fill: its place among the fills of the same form of the same car
create function app.government_form_version(p_fill uuid) returns integer
language sql stable security definer set search_path = public, app as $$
  select (select count(*) from government_form_fills x
           where x.vehicle_id = g.vehicle_id and x.form_code = g.form_code and (x.generated_at, x.id) <= (g.generated_at, g.id))::integer
    from government_form_fills g where g.id = p_fill $$;

-- ================================================================ 1. the changed values go into every new version
create function app.government_form_apply_overrides(p_fill uuid) returns void
language plpgsql security definer set search_path = public, app as $$
declare
  g government_form_fills;
  o government_form_overrides;
  v_vals jsonb;
  v_sheet jsonb;
  v_missing text[];
  v_applied jsonb := '[]'::jsonb;
  v_required boolean;
begin
  select * into g from government_form_fills where id = p_fill for update;
  if g.id is null then return; end if;
  v_vals := g.field_values; v_sheet := g.data_sheet; v_missing := g.missing;
  for o in select * from government_form_overrides x where x.vehicle_id = g.vehicle_id and x.form_code = g.form_code and x.ended_at is null order by x.created_at loop
    if o.target = 'pdf' then
      v_vals := v_vals || jsonb_build_object(o.field, o.value);
      if o.value is not null then v_missing := array_remove(v_missing, 'PDF field ' || o.field);
      elsif coalesce((select (t.field_map -> o.field ->> 'required')::boolean from pdf_templates t where t.id = g.pdf_template_id), false)
            and not (('PDF field ' || o.field) = any (v_missing)) then v_missing := v_missing || ('PDF field ' || o.field); end if;
    else
      if not exists (select 1 from jsonb_array_elements(v_sheet) r where r ->> 'label' = o.field) then continue; end if;
      select coalesce(bool_or(coalesce((r ->> 'required')::boolean, false)), false) into v_required from jsonb_array_elements(v_sheet) r where r ->> 'label' = o.field;
      select coalesce(jsonb_agg(case when r ->> 'label' = o.field then r || jsonb_build_object('value', o.value, 'missing', v_required and o.value is null) else r end order by n), '[]'::jsonb)
        into v_sheet from jsonb_array_elements(v_sheet) with ordinality e(r, n);
      if o.value is not null then v_missing := array_remove(v_missing, o.field);
      elsif v_required and not (o.field = any (v_missing)) then v_missing := v_missing || o.field; end if;
    end if;
    v_applied := v_applied || jsonb_build_array(jsonb_build_object('id', o.id, 'target', o.target, 'field', o.field));
  end loop;
  if v_applied = '[]'::jsonb then return; end if;
  update government_form_fills
     set field_values = v_vals, data_sheet = v_sheet, missing = v_missing, overrides = v_applied,
         status = case when status in ('draft', 'ready') then case when cardinality(v_missing) = 0 then 'ready' else 'draft' end else status end
   where id = g.id;
end $$;

alter function app.fill_government_form(uuid, text, uuid) rename to fill_government_form_pre0870;
create function app.fill_government_form(p_vehicle uuid, p_form_code text, p_by uuid default null) returns uuid
language plpgsql security definer set search_path = public, app as $$
declare
  v_id uuid := app.fill_government_form_pre0870(p_vehicle, p_form_code, p_by);
begin
  -- 5. only the publisher's PDF is filled; any other template gives the data sheet
  update government_form_fills g set mode = 'data_sheet'
   where g.id = v_id and g.mode = 'pdf' and not app.official_form_is_publisher(g.pdf_template_id);
  perform app.government_form_apply_overrides(v_id);
  return v_id;
end $$;
select pg_temp.copy_grants('app.fill_government_form(uuid, text, uuid)'::regprocedure, 'app.fill_government_form_pre0870(uuid, text, uuid)'::regprocedure);

-- p: fill (the current version), field, target (pdf | sheet; by the form's mode when not given), value (empty: the box left
-- empty), reason; restore true: back to the value from the records. Returns the new version.
create function app.government_form_edit(p_by uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  g government_form_fills;
  t pdf_templates;
  v_field text := btrim(coalesce(p ->> 'field', ''));
  v_target text;
  v_value text := nullif(btrim(coalesce(p ->> 'value', '')), '');
  v_reason text := btrim(coalesce(p ->> 'reason', ''));
  v_restore boolean := coalesce((p ->> 'restore')::boolean, false);
  v_spec jsonb;
  v_before text;
  v_new uuid;
  v_ended integer;
begin
  if not app.government_forms_editor(p_by) then raise exception 'Not permitted' using errcode = '42501'; end if;
  select * into g from government_form_fills where id = nullif(p ->> 'fill', '')::uuid for update;
  if g.id is null then raise exception 'Form not found' using errcode = 'P0002'; end if;
  if g.superseded_at is not null then raise exception 'This is an earlier version: change the current one' using errcode = '23514'; end if;
  if g.status in ('signed', 'filed') then
    raise exception 'This form is % already: it is kept as it is. Make again after the change at the registry, or record a new one', case g.status when 'signed' then 'signed in ink' else 'filed' end using errcode = '23514';
  end if;
  if length(v_reason) < 3 then raise exception 'Give the reason for the change' using errcode = '22023'; end if;
  select * into t from pdf_templates where id = g.pdf_template_id;
  v_target := coalesce(nullif(p ->> 'target', ''), case when g.mode = 'pdf' then 'pdf' else 'sheet' end);
  if v_target = 'pdf' then
    select f into v_spec from jsonb_array_elements(t.field_names) f where f ->> 'name' = v_field limit 1;
    if v_spec is null then raise exception 'The official form has no box "%"', v_field using errcode = '22023'; end if;
    if coalesce(v_spec ->> 'type', 'text') <> 'text' then
      raise exception 'Only the text boxes are filled: checkboxes, choices and signatures are done by hand at the counter' using errcode = '22023';
    end if;
    if v_value is not null and nullif(v_spec ->> 'max_length', '')::integer is not null and length(v_value) > (v_spec ->> 'max_length')::integer then
      raise exception 'At most % characters fit in this box', v_spec ->> 'max_length' using errcode = '22023';
    end if;
    v_before := g.field_values ->> v_field;
  elsif v_target = 'sheet' then
    if not exists (select 1 from jsonb_array_elements(g.data_sheet) r where r ->> 'label' = v_field) then
      raise exception 'The data sheet has no row "%"', v_field using errcode = '22023';
    end if;
    select r ->> 'value' into v_before from jsonb_array_elements(g.data_sheet) r where r ->> 'label' = v_field limit 1;
  else
    raise exception 'Choose a box of the form or a row of the data sheet' using errcode = '22023';
  end if;
  if not v_restore and v_value is not distinct from v_before then raise exception 'That is the value already on the form' using errcode = '22023'; end if;

  update government_form_overrides set ended_at = now(), ended_by = p_by, end_reason = case when v_restore then 'Back to the records: ' || v_reason else 'Changed again' end
   where vehicle_id = g.vehicle_id and form_code = g.form_code and target = v_target and field = v_field and ended_at is null;
  get diagnostics v_ended = row_count;
  if v_restore and v_ended = 0 then raise exception 'This box has no changed value: it already comes from the records' using errcode = '22023'; end if;
  if not v_restore then
    insert into government_form_overrides (vehicle_id, form_code, target, field, value, reason, created_by)
    values (g.vehicle_id, g.form_code, v_target, v_field, v_value, v_reason, p_by);
  end if;
  v_new := app.fill_government_form(g.vehicle_id, g.form_code, p_by);
  insert into audit_log (actor_user_id, action, entity_table, entity_id, before, after)
  values (p_by, case when v_restore then 'government_form_restore' else 'government_form_edit' end, 'government_form_fills', v_new::text,
          jsonb_build_object('fill', g.id, 'version', app.government_form_version(g.id), 'target', v_target, 'field', v_field, 'value', v_before),
          jsonb_build_object('fill', v_new, 'version', app.government_form_version(v_new), 'value', case when v_restore then null else v_value end, 'reason', v_reason,
                             'form_code', g.form_code, 'vehicle_id', g.vehicle_id));
  return (select jsonb_build_object('fill', x.id, 'version', app.government_form_version(x.id), 'status', x.status, 'missing', to_jsonb(x.missing))
            from government_form_fills x where x.id = v_new);
end $$;

-- ================================================================ 3. Make again: an Admin or fleet; the changed values kept unless discarded
create or replace function app.government_forms_make_again(p_by uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  v vehicles;
  r jsonb;
  v_discard boolean := coalesce((p ->> 'discard_edits')::boolean, false);
  v_n integer := 0;
begin
  if not app.government_forms_editor(p_by) then raise exception 'Not permitted' using errcode = '42501'; end if;
  select * into v from vehicles where id = nullif(p ->> 'vehicle_id', '')::uuid;
  if v.id is null then raise exception 'Car not found' using errcode = 'P0002'; end if;
  if not app.registry_forms_due(v.id) then
    raise exception 'This car''s government forms are made once its terms are set (Approve on the application)' using errcode = '23514';
  end if;
  if v_discard then
    -- a form signed or filed keeps its values: only the changes of forms still open are discarded
    update government_form_overrides o set ended_at = now(), ended_by = p_by, end_reason = 'Discarded at Make again'
     where o.vehicle_id = v.id and o.ended_at is null
       and not exists (select 1 from government_form_fills g where g.vehicle_id = v.id and g.form_code = o.form_code and g.superseded_at is null and g.status in ('signed', 'filed'));
    get diagnostics v_n = row_count;
  end if;
  r := app.registry_forms_refresh(v.id, p_by, true)
       || jsonb_build_object('discarded', v_n, 'kept', (select count(*) from government_form_overrides o where o.vehicle_id = v.id and o.ended_at is null));
  insert into audit_log (actor_user_id, action, entity_table, entity_id, after)
  values (p_by, 'government_forms_make_again', 'vehicles', v.id::text, r);
  return r;
end $$;

-- ================================================================ the reads
alter function app.government_form_fill_read(uuid, jsonb) rename to government_form_fill_read_pre0870;
create function app.government_form_fill_read(p_by uuid, p jsonb) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare
  v jsonb := app.government_form_fill_read_pre0870(p_by, p);
  g government_form_fills;
  t pdf_templates;
  v_platform jsonb;
begin
  if v is null then return v; end if;
  select * into g from government_form_fills where id = (v ->> 'id')::uuid;
  select * into t from pdf_templates where id = g.pdf_template_id;
  v_platform := case when g.mode = 'pdf' then app.form_field_values(t.id, g.vehicle_id) else '{}'::jsonb end;
  return v || jsonb_build_object(
    'version', app.government_form_version(g.id),
    'can_edit', app.government_forms_editor(p_by) and g.superseded_at is null and g.status not in ('signed', 'filed'),
    'versions', (select coalesce(jsonb_agg(jsonb_build_object('id', x.id, 'version', app.government_form_version(x.id), 'generated_at', x.generated_at, 'status', x.status,
                   'current', x.superseded_at is null, 'edits', jsonb_array_length(x.overrides), 'official', x.mode = 'pdf',
                   'by', case when x.generated_by is null then 'automatic' else (select coalesce(u.full_name, 'CarmaCars') from users u where u.id = x.generated_by) end)
                   order by x.generated_at desc, x.id desc), '[]'::jsonb)
                   from government_form_fills x where x.vehicle_id = g.vehicle_id and x.form_code = g.form_code),
    'fields', case when g.mode = 'pdf' then
        (select coalesce(jsonb_agg(jsonb_build_object('target', 'pdf', 'name', f ->> 'name', 'label', coalesce(f ->> 'label', f ->> 'name'), 'page', f -> 'page',
                   'max_length', f -> 'max_length', 'value', g.field_values ->> (f ->> 'name'), 'records', v_platform ->> (f ->> 'name'),
                   'edited', exists (select 1 from jsonb_array_elements(g.overrides) o where o ->> 'target' = 'pdf' and o ->> 'field' = f ->> 'name'))
                   order by n), '[]'::jsonb)
           from jsonb_array_elements(t.field_names) with ordinality e(f, n) where coalesce(f ->> 'type', 'text') = 'text')
      else
        (select coalesce(jsonb_agg(jsonb_build_object('target', 'sheet', 'name', r ->> 'label', 'label', r ->> 'label', 'value', r ->> 'value',
                   'edited', exists (select 1 from jsonb_array_elements(g.overrides) o where o ->> 'target' = 'sheet' and o ->> 'field' = r ->> 'label'))
                   order by n), '[]'::jsonb)
           from jsonb_array_elements(g.data_sheet) with ordinality e(r, n)) end,
    'edits', (select coalesce(jsonb_agg(jsonb_build_object('id', o.id, 'target', o.target, 'field', o.field, 'value', o.value, 'reason', o.reason, 'at', o.created_at,
                'by', (select u.full_name from users u where u.id = o.created_by), 'ended_at', o.ended_at, 'end_reason', o.end_reason,
                'label', case when o.target = 'pdf' then coalesce((select f ->> 'label' from jsonb_array_elements(t.field_names) f where f ->> 'name' = o.field limit 1), o.field) else o.field end)
                order by o.created_at desc), '[]'::jsonb)
                from government_form_overrides o where o.vehicle_id = g.vehicle_id and o.form_code = g.form_code));
end $$;
select pg_temp.copy_grants('app.government_form_fill_read(uuid, jsonb)'::regprocedure, 'app.government_form_fill_read_pre0870(uuid, jsonb)'::regprocedure);

-- the list: staff see each form's version and how many values were changed by hand (owners see the forms as they are)
alter function app.government_forms_list(uuid, jsonb) rename to government_forms_list_pre0870;
create function app.government_forms_list(p_by uuid, p jsonb) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare
  v jsonb := app.government_forms_list_pre0870(p_by, p);
begin
  if v is null or not (app.user_is_admin(p_by) or app.user_va_has(p_by, 'cs', 'fleet')) then return v; end if;
  return v || jsonb_build_object('can_edit', app.government_forms_editor(p_by),
    'cars', (select coalesce(jsonb_agg(c || jsonb_build_object('forms', (select coalesce(jsonb_agg(f || jsonb_build_object(
                'version', app.government_form_version((f ->> 'id')::uuid),
                'edits', (select jsonb_array_length(x.overrides) from government_form_fills x where x.id = (f ->> 'id')::uuid)) order by m), '[]'::jsonb)
              from jsonb_array_elements(c -> 'forms') with ordinality e2(f, m))) order by n), '[]'::jsonb)
             from jsonb_array_elements(v -> 'cars') with ordinality e(c, n)));
end $$;
select pg_temp.copy_grants('app.government_forms_list(uuid, jsonb)'::regprocedure, 'app.government_forms_list_pre0870(uuid, jsonb)'::regprocedure);

-- ================================================================ 2. the mapping: fleet too, kept, previewed with the mapping on screen
-- A sample car with made-up values for every source, so a mapping is checked without a real owner's data.
create function app.registry_sample_context() returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare
  ctx jsonb := jsonb_build_object('always', 'true');
  s jsonb;
  v_path text[];
  v_val text;
  l text;
begin
  for s in select * from jsonb_array_elements(app.registry_sources()) loop
    v_path := string_to_array(s ->> 'path', '.');
    l := lower(s ->> 'label');
    v_val := case
      when l like '%(yes or no)%' then case when s ->> 'path' like '%lease%' or s ->> 'path' like '%transfer%' then 'false' else 'true' end
      when s ->> 'path' = 'today' then to_char(app.today(), 'YYYY-MM-DD')
      when l like '%date of birth%' then '1985-04-12'
      when l like '%postal%' then 'M5V 1A1'
      when l like '%phone%' then '+14165550100'
      when l like '%email%' then 'sample.owner@example.test'
      when l like '%province%' then 'ON'
      when l like '%vin%' then '2HGFC2F59MH000001'
      when s ->> 'path' like '%.year' then '2021'
      when s ->> 'path' like '%.make' then 'Honda'
      when s ->> 'path' like '%.model' then 'Civic'
      when s ->> 'path' like '%.plate' then 'SMPL 001'
      when l like '%odometer%' then '20000'
      when l like '%city%' then 'Toronto'
      when l like '%unit%' or l like '%apartment%' then '12'
      when l like '%street number%' then '1'
      when l like '%rin%' or l like '%licence number%' or l like '%corporation: number%' then 'SAMPLE000'
      when l like '%address%' or l like '%street%' then '1 Example Street'
      else 'SAMPLE ' || upper(regexp_replace(s ->> 'label', '^[^:]*:\s*', '')) end;
    if array_length(v_path, 1) = 1 then ctx := ctx || jsonb_build_object(v_path[1], v_val);
    elsif array_length(v_path, 1) = 2 then ctx := ctx || jsonb_build_object(v_path[1], coalesce(ctx -> v_path[1], '{}'::jsonb) || jsonb_build_object(v_path[2], v_val));
    end if;
  end loop;
  return ctx;
end $$;

-- the values of a mapping for a context (app.form_field_values, for any mapping)
create function app.form_values_for(p_map jsonb, p_ctx jsonb) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare
  r record;
  v_spec jsonb;
  v_val text;
  v_values jsonb := '{}'::jsonb;
begin
  for r in select key, value from jsonb_each(coalesce(p_map, '{}'::jsonb)) loop
    v_spec := case when jsonb_typeof(r.value) = 'string' then jsonb_build_object('source', r.value #>> '{}') else r.value end;
    if v_spec ? 'when' and not coalesce(app.context_value(p_ctx, v_spec ->> 'when')::boolean, false) then continue; end if;
    v_val := app.apply_transform(app.context_value(p_ctx, v_spec ->> 'source'), v_spec ->> 'transform');
    if v_spec ->> 'type' = 'checkbox' then v_val := case when lower(coalesce(v_val, 'false')) in ('true', 't', 'yes') then 'Yes' else 'Off' end; end if;
    v_values := v_values || jsonb_build_object(r.key, v_val);
  end loop;
  return v_values;
end $$;

-- p: template, vehicle (a car's id, or 'sample'), field_map (the mapping on screen; the saved one when not given)
create or replace function app.form_template_preview(p_by uuid, p jsonb) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare
  t pdf_templates;
  v_map jsonb;
  v_sample boolean := coalesce(p ->> 'vehicle', '') = 'sample';
begin
  if not app.government_forms_editor(p_by) then perform app.assert_admin(p_by); end if;
  select * into t from pdf_templates where id = nullif(p ->> 'template', '')::uuid;
  if t.id is null or t.file_key is null then raise exception 'That template has no file' using errcode = 'P0002'; end if;
  v_map := case when jsonb_typeof(p -> 'field_map') = 'object' then p -> 'field_map' else t.field_map end;
  return jsonb_build_object('file_key', t.file_key, 'form_code', t.form_code, 'field_map', v_map, 'sample', v_sample,
    'values', case when v_sample then app.form_values_for(v_map, app.registry_sample_context())
                   when nullif(p ->> 'vehicle', '') is not null then app.form_values_for(v_map, app.registry_context((p ->> 'vehicle')::uuid))
                   else '{}'::jsonb end);
end $$;

-- the mapping saved by an Admin or fleet, with a note for the history; otherwise as 0042
create or replace function app.form_template_map(p_by uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  t pdf_templates;
  v_map jsonb := coalesce(p -> 'field_map', '{}'::jsonb);
  r record;
  v_names text[];
  v_paths text[] := (select array_agg(x ->> 'path') from jsonb_array_elements(app.registry_sources()) x) || array['always'];
  n integer := 0;
  g record;
  v_verify boolean := coalesce((p ->> 'verify')::boolean, false);
begin
  if not app.government_forms_editor(p_by) then perform app.assert_admin(p_by); end if;
  select * into t from pdf_templates where id = (p ->> 'template')::uuid for update;
  if t.id is null then raise exception 'That template is not there' using errcode = 'P0002'; end if;
  if not t.is_current then raise exception 'Only the current version of a form is mapped' using errcode = '23514'; end if;
  if jsonb_typeof(v_map) <> 'object' then raise exception 'The mapping is not readable' using errcode = '22023'; end if;
  select array_agg(x ->> 'name') into v_names from jsonb_array_elements(t.field_names) x;
  for r in select key, value from jsonb_each(v_map) loop
    if not (r.key = any (coalesce(v_names, '{}'))) then raise exception 'The PDF has no field "%"', r.key using errcode = '22023'; end if;
    if jsonb_typeof(r.value) <> 'object' then raise exception 'Field "%": the mapping is not readable', r.key using errcode = '22023'; end if;
    if coalesce(r.value ->> 'type', 'text') not in ('text', 'checkbox', 'signature', 'dropdown', 'radio') then
      raise exception 'Field "%": unknown type', r.key using errcode = '22023';
    end if;
    if r.value ->> 'type' is distinct from 'signature' and not ((r.value ->> 'source') = any (v_paths)) then
      raise exception 'Field "%": choose what goes in it', r.key using errcode = '22023';
    end if;
    if r.value ? 'when' and not ((r.value ->> 'when') = any (v_paths)) then raise exception 'Field "%": unknown condition', r.key using errcode = '22023'; end if;
    if nullif(r.value ->> 'transform', '') is not null and (r.value ->> 'transform') not in ('upper', 'lower', 'postal', 'phone', 'yesno', 'money')
       and (r.value ->> 'transform') !~ '^date:[YMD/ -]+$' then
      raise exception 'Field "%": unknown format', r.key using errcode = '22023';
    end if;
  end loop;
  if v_verify and not exists (select 1 from jsonb_each(v_map) e where e.value ->> 'type' is distinct from 'signature') then
    raise exception 'Map at least one field before the form is used for owners' using errcode = '23514';
  end if;
  perform set_config('app.map_note', coalesce(p ->> 'note', ''), true);
  update pdf_templates set field_map = v_map, mapped_by = p_by, mapped_at = now(),
         verified = v_verify and file_key is not null,
         verified_by = case when v_verify then p_by end,
         verified_at = case when v_verify then now() end
   where id = t.id;
  perform set_config('app.map_note', '', true);
  insert into audit_log (actor_user_id, action, entity_table, entity_id, before, after)
  values (p_by, 'form_template_map', 'pdf_templates', t.id::text, jsonb_build_object('field_map', t.field_map, 'verified', t.verified),
          jsonb_build_object('field_map', v_map, 'verified', v_verify, 'note', nullif(p ->> 'note', '')));
  if v_verify then
    for g in select f.vehicle_id from government_form_fills f where f.form_code = t.form_code and f.superseded_at is null and f.status not in ('signed', 'filed') loop
      perform app.fill_government_form(g.vehicle_id, t.form_code, p_by);
      n := n + 1;
    end loop;
  end if;
  return (select to_jsonb(x) from pdf_templates x where x.id = t.id) || jsonb_build_object('refilled', n);
end $$;

-- Settings > Forms for an Admin (as before) and for fleet (the registry forms alone, without the per-booking ones and
-- without uploading); each form with its saved mappings, and the sample car first in the preview's list
alter function app.form_templates(uuid) rename to form_templates_pre0870;
create function app.form_templates(p_by uuid) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare
  v jsonb;
  v_admin boolean := app.user_is_admin(p_by);
begin
  if v_admin then v := app.form_templates_pre0870(p_by);
  elsif app.government_forms_editor(p_by) then
    v := jsonb_build_object(
      'forms', coalesce((select jsonb_agg(jsonb_build_object('form_code', c.form_code,
                 'current', (select to_jsonb(t) - 'field_map' || jsonb_build_object('field_map', t.field_map, 'mapped_by_name', (select u.full_name from users u where u.id = t.mapped_by),
                                                                                    'verified_by_name', (select u.full_name from users u where u.id = t.verified_by))
                               from pdf_templates t where t.form_code = c.form_code and t.is_current),
                 'versions', (select count(*) from pdf_templates t where t.form_code = c.form_code),
                 'fills', (select jsonb_build_object('pdf', count(*) filter (where g.mode = 'pdf'), 'data_sheet', count(*) filter (where g.mode = 'data_sheet'))
                             from government_form_fills g where g.form_code = c.form_code and g.superseded_at is null)) order by c.form_code)
                 from (select distinct form_code from pdf_templates x where x.kind is distinct from 'booking_overlay') c), '[]'::jsonb),
      'sources', app.registry_sources(),
      'transforms', jsonb_build_array('upper', 'lower', 'postal', 'phone', 'yesno', 'date:YYYY-MM-DD', 'date:DD/MM/YYYY', 'date:MM/DD/YYYY', 'date:YYYY', 'date:MM', 'date:DD', 'date:YYYY/MM/DD'),
      'vehicles', coalesce((select jsonb_agg(jsonb_build_object('id', v.id, 'name', app.vehicle_name(v.id), 'owner', o.legal_name) order by o.legal_name, v.plate)
                             from vehicles v join owners o on o.id = v.owner_id where not coalesce(v.is_sample, false)), '[]'::jsonb));
  else
    perform app.assert_admin(p_by);
  end if;
  return v || jsonb_build_object('can_upload', v_admin,
    'vehicles', jsonb_build_array(jsonb_build_object('id', 'sample', 'name', 'A sample car (made-up values)', 'owner', 'Sample')) || coalesce(v -> 'vehicles', '[]'::jsonb),
    'forms', (select coalesce(jsonb_agg(f || jsonb_build_object('official', coalesce(app.official_form_is_publisher((f #>> '{current,id}')::uuid), false),
                'history', (select coalesce(jsonb_agg(jsonb_build_object('id', h.id, 'saved_at', h.saved_at, 'verified', h.verified, 'note', h.note,
                              'by', (select u.full_name from users u where u.id = h.saved_by), 'fields', (select count(*) from jsonb_object_keys(h.field_map)), 'field_map', h.field_map)
                              order by h.saved_at desc), '[]'::jsonb)
                              from (select * from pdf_template_map_history x where x.template_id = (f #>> '{current,id}')::uuid order by x.saved_at desc limit 20) h)) order by n), '[]'::jsonb)
                from jsonb_array_elements(v -> 'forms') with ordinality e(f, n)));
end $$;
select pg_temp.copy_grants('app.form_templates(uuid)'::regprocedure, 'app.form_templates_pre0870(uuid)'::regprocedure);

-- ================================================================ the door: one change
alter function app.door(uuid, text, text, text, jsonb) rename to door_pre0870;
create function app.door(p_user uuid, p_aal text, p_call text, p_name text, p jsonb default '{}'::jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
begin
  if p_call in ('ops_do', 'va_do') and p_name = 'government_form_edit' then
    if coalesce(p, '{}'::jsonb) ? '_va' then perform set_config('app.va_active', coalesce(p ->> '_va', ''), true); end if;
    perform app.door_begin(p_user, p_aal);
    return app.government_form_edit(p_user, coalesce(p, '{}'::jsonb) - '_va');
  end if;
  return app.door_pre0870(p_user, p_aal, p_call, p_name, p);
end $$;
select pg_temp.copy_grants('app.door(uuid, text, text, text, jsonb)'::regprocedure, 'app.door_pre0870(uuid, text, text, text, jsonb)'::regprocedure);

-- ================================================================ 5. the forms in use as a PDF that are not the publisher's: the data sheet
do $$
declare r record;
begin
  for r in select g.vehicle_id, g.form_code from government_form_fills g
            where g.superseded_at is null and g.mode = 'pdf' and g.status in ('draft', 'ready', 'printed')
              and not app.official_form_is_publisher(g.pdf_template_id) loop
    begin
      perform app.fill_government_form(r.vehicle_id, r.form_code, null);
    exception when others then
      insert into audit_log (action, entity_table, entity_id, after) values ('registry_forms_refresh_failed', 'vehicles', r.vehicle_id::text, jsonb_build_object('error', sqlerrm, 'form_code', r.form_code));
    end;
  end loop;
end $$;

do $$
declare f record;
begin
  for f in select p.oid::regprocedure as sig from pg_proc p join pg_namespace n on n.oid = p.pronamespace
            where n.nspname = 'app' and p.proname = any (array['pdf_template_map_record', 'government_forms_editor', 'official_form_is_publisher', 'government_form_version',
              'government_form_apply_overrides', 'fill_government_form_pre0870', 'government_form_edit', 'government_form_fill_read_pre0870',
              'government_forms_list_pre0870', 'registry_sample_context', 'form_values_for', 'form_templates_pre0870', 'door_pre0870'])
  loop
    execute format('revoke all on function %s from public, anon, authenticated', f.sig);
    execute format('grant execute on function %s to service_role', f.sig);
  end loop;
end $$;
