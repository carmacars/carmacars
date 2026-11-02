-- 0520: one model name per car family (docs/changes/2026-11-07-r27-leftovers.md, section 2). SCHEMA_MARKER 0529.
--
-- The owner: the /cars filters showed "C-Class" and "C300", "CLA-Class" and "CLA250" as separate models. VIN decode
-- names the family (C-Class, trim C300 4MATIC), a permit scan or a partner sheet the code (C300), and manual entry
-- either. Now every save of a car goes through one rule, app.car_model_family (the same rule as
-- web/src/features/vin/model-family.ts; the unit test and 99_model_family.sql check the same cases):
--   the model is the family as the maker names it (Mercedes-Benz: A-Class, C-Class, CLA-Class, GLA-Class, GLB, GLC,
--   GLE, GLS, AMG GT ...; BMW: 3 Series, X5 ...), the model code and the words after it are the trim (C300 4MATIC,
--   CLA250 4MATIC, 330i xDrive). A value it cannot read with certainty is left exactly as typed; other makes are
--   left as they are.
-- 1. app.car_model_family(make, model, trim) -> {model, trim, known}; the trigger vehicles_a1_model_family runs after
--    0087's name case on every insert or update of make, model or trim (VIN decode, permit scan, partner sheets, the
--    Admin and owner forms all save through vehicles).
-- 2. Every car on file now: renamed by the rule, each change in the audit log (model_family, with the names before and
--    after), and its plain copy written again (the public address, the listing slug, never changes).
-- 3. Data health: a Mercedes-Benz or BMW car whose model is not a family we know ("Model family not recognized"),
--    with a link to the car, so a typo or a new family is fixed by a person instead of splitting the filters.
-- No applied migration is edited.

-- ================================================================ 1. the rule
create or replace function app.mf_join(p_parts text[]) returns text
language plpgsql immutable as $$
declare
  w text;
  p text;
  seen text[] := '{}';
begin
  foreach p in array coalesce(p_parts, '{}') loop
    continue when p is null;
    foreach w in array regexp_split_to_array(btrim(regexp_replace(p, '\s+', ' ', 'g')), ' ') loop
      continue when w = '' or upper(w) = any (select upper(x) from unnest(seen) x);
      seen := seen || case when w ~* '^4matic\+?$' then upper(w) else w end;
    end loop;
  end loop;
  return nullif(array_to_string(seen, ' '), '');
end $$;

-- a Mercedes-Benz model code: {family, code, rest}; null when it is not one, or other words follow it
create or replace function app.mf_mb_code(p text) returns jsonb
language plpgsql immutable as $$
declare
  w text[];
  n integer;
  i integer := 1;
  pre text[] := '{}';
  head text;
  m text[];
  used integer := 1;
  fam text;
  rest text[];
  x text;
begin
  if p is null or btrim(p) = '' then return null; end if;
  w := regexp_split_to_array(btrim(regexp_replace(p, '\s+', ' ', 'g')), ' ');
  n := array_length(w, 1);
  while i <= n and w[i] ~* '^(maybach|amg|mercedes-amg)$' loop
    if w[i] !~* '^mercedes-amg$' then pre := pre || w[i]; end if;
    i := i + 1;
  end loop;
  head := coalesce(w[i], '');
  m := regexp_match(head, '^([A-Za-z]{1,3})-?(\d{2,3})([A-Za-z]?)$');
  if m is null and head ~ '^[A-Za-z]{1,3}$' and coalesce(w[i + 1], '') ~ '^\d{2,3}[A-Za-z]?$' then
    m := regexp_match(head || w[i + 1], '^([A-Za-z]{1,3})(\d{2,3})([A-Za-z]?)$');
    used := 2;
  end if;
  if m is null then return null; end if;
  fam := case upper(m[1]) when 'A' then 'A-Class' when 'B' then 'B-Class' when 'C' then 'C-Class' when 'E' then 'E-Class' when 'S' then 'S-Class'
    when 'G' then 'G-Class' when 'CLA' then 'CLA-Class' when 'CLS' then 'CLS-Class' when 'CLE' then 'CLE' when 'GLA' then 'GLA-Class' when 'GLB' then 'GLB'
    when 'GLC' then 'GLC' when 'GLE' then 'GLE' when 'GLS' then 'GLS' when 'GLK' then 'GLK-Class' when 'ML' then 'M-Class' when 'GL' then 'GL-Class'
    when 'SL' then 'SL' when 'SLC' then 'SLC' when 'SLK' then 'SLK-Class' when 'EQB' then 'EQB' when 'EQE' then 'EQE' when 'EQS' then 'EQS' end;
  if fam is null then return null; end if;
  rest := coalesce(w[i + used:n], '{}');
  foreach x in array rest loop
    -- an AMG car's "S" (C63 S) is part of the trim; after a three digit code a lone letter is not a trim word
    if not (upper(x) = any (array['4MATIC', '4MATIC+', 'AMG', 'COUPE', 'COUPÉ', 'CABRIOLET', 'CABRIO', 'CONVERTIBLE', 'SEDAN', 'WAGON', 'ESTATE', 'SUV',
              '4-DOOR', '4DR', '2DR', 'ROADSTER', 'HYBRID', 'PLUG-IN', 'SPORT', 'PREMIUM', 'NIGHT', 'EDITION', 'FINAL', 'MAYBACH', 'PULLMAN', 'LWB',
              'AVANTGARDE', 'EXCLUSIVE', 'PROGRESSIVE', 'LUXURY', 'PACKAGE'])
            or (length(m[2]) = 2 and x = 'S')) then
      return null;
    end if;
  end loop;
  return jsonb_build_object('family', fam, 'code', upper(m[1]) || m[2] || coalesce(m[3], ''), 'rest', to_jsonb(pre || rest));
end $$;

-- "C300 4MATIC": the code, then the words after it, then what the trim adds ("Maybach S580" keeps the badge first)
create or replace function app.mf_code_trim(c jsonb, p_trim text) returns text
language plpgsql immutable as $$
declare
  rest text[] := array(select jsonb_array_elements_text(c -> 'rest'));
  t jsonb;
  extra text := p_trim;
begin
  if p_trim is not null then
    t := app.mf_mb_code(p_trim);
    if t is not null and upper(t ->> 'code') = upper(c ->> 'code') then extra := array_to_string(array(select jsonb_array_elements_text(t -> 'rest')), ' '); end if;
  end if;
  return app.mf_join(array[case when exists (select 1 from unnest(rest) r where r ~* '^maybach$') then 'Maybach' end, c ->> 'code',
                           array_to_string(array(select r from unnest(rest) r where r !~* '^maybach$'), ' '), extra]);
end $$;

create or replace function app.car_model_family(p_make text, p_model text, p_trim text) returns jsonb
language plpgsql immutable as $$
declare
  mo text := btrim(regexp_replace(coalesce(p_model, ''), '\s+', ' ', 'g'));
  tr text := nullif(btrim(regexp_replace(coalesce(p_trim, ''), '\s+', ' ', 'g')), '');
  mk text := upper(btrim(coalesce(p_make, '')));
  key text := btrim(regexp_replace(regexp_replace(upper(mo), '[-_/]+', ' ', 'g'), '\s+', ' ', 'g'));
  alias text;
  c jsonb;
  t jsonb;
  gt text[];
  s text[];
  x text[];
  fam text;
  bmw text[] := array['1 Series', '2 Series', '3 Series', '4 Series', '5 Series', '6 Series', '7 Series', '8 Series', 'X1', 'X2', 'X3', 'X3 M', 'X4', 'X4 M',
    'X5', 'X5 M', 'X6', 'X6 M', 'X7', 'XM', 'Z4', 'M2', 'M3', 'M4', 'M5', 'M8', 'i3', 'i4', 'i5', 'i7', 'i8', 'iX', 'iX3'];
  bmw_words text[] := array['XDRIVE', 'SDRIVE', 'M', 'SPORT', 'GRAN', 'COUPE', 'TOURING', 'COMPETITION', 'CONVERTIBLE', 'SEDAN', 'PACKAGE', 'PREMIUM', 'EDITION'];
  mb_families text[] := array['A-Class', 'B-Class', 'C-Class', 'E-Class', 'S-Class', 'G-Class', 'CLA-Class', 'CLS-Class', 'CLE', 'GLA-Class', 'GLB', 'GLC', 'GLE',
    'GLS', 'GLK-Class', 'M-Class', 'GL-Class', 'SL', 'SLC', 'SLK-Class', 'EQB', 'EQE', 'EQS', 'AMG GT', 'Sprinter', 'Metris'];
begin
  if mo = '' then return jsonb_build_object('model', p_model, 'trim', p_trim, 'known', null); end if;
  if mk in ('MERCEDES-BENZ', 'MERCEDES BENZ', 'MERCEDES', 'MERCEDES-AMG', 'MERCEDES-MAYBACH', 'MERCE', 'MB') then
    alias := case key
      when 'A CLASS' then 'A-Class' when 'B CLASS' then 'B-Class' when 'C CLASS' then 'C-Class' when 'E CLASS' then 'E-Class' when 'S CLASS' then 'S-Class'
      when 'G CLASS' then 'G-Class' when 'CLA CLASS' then 'CLA-Class' when 'CLA' then 'CLA-Class' when 'CLS CLASS' then 'CLS-Class' when 'CLS' then 'CLS-Class'
      when 'CLE CLASS' then 'CLE' when 'CLE' then 'CLE' when 'GLA CLASS' then 'GLA-Class' when 'GLA' then 'GLA-Class' when 'GLB CLASS' then 'GLB' when 'GLB' then 'GLB'
      when 'GLC CLASS' then 'GLC' when 'GLC' then 'GLC' when 'GLC COUPE' then 'GLC' when 'GLE CLASS' then 'GLE' when 'GLE' then 'GLE' when 'GLE COUPE' then 'GLE'
      when 'GLS CLASS' then 'GLS' when 'GLS' then 'GLS' when 'GLK CLASS' then 'GLK-Class' when 'M CLASS' then 'M-Class' when 'GL CLASS' then 'GL-Class'
      when 'SL CLASS' then 'SL' when 'SL' then 'SL' when 'SLC CLASS' then 'SLC' when 'SLC' then 'SLC' when 'SLK CLASS' then 'SLK-Class'
      when 'AMG GT' then 'AMG GT' when 'MERCEDES AMG GT' then 'AMG GT' when 'GT' then 'AMG GT' when 'AMG GT 4 DOOR COUPE' then 'AMG GT'
      when 'EQB' then 'EQB' when 'EQE' then 'EQE' when 'EQE SUV' then 'EQE' when 'EQS' then 'EQS' when 'EQS SUV' then 'EQS'
      when 'SPRINTER' then 'Sprinter' when 'METRIS' then 'Metris' when 'MAYBACH S CLASS' then 'S-Class' when 'MAYBACH GLS' then 'GLS' end;
    if alias is not null then
      t := app.mf_mb_code(tr);
      return jsonb_build_object('model', alias, 'trim', case when t is not null and t ->> 'family' = alias then app.mf_code_trim(t, null) else tr end, 'known', true);
    end if;
    c := app.mf_mb_code(mo);
    if c is not null then return jsonb_build_object('model', c ->> 'family', 'trim', app.mf_code_trim(c, tr), 'known', true); end if;
    gt := regexp_match(mo, '^(?:[Mm][Ee][Rr][Cc][Ee][Dd][Ee][Ss]-)?[Aa][Mm][Gg] [Gg][Tt] ?(\d{2})?(?: (.*))?$');
    if gt is not null and (gt[2] is null or not exists (select 1 from unnest(string_to_array(gt[2], ' ')) w
                                                          where not (upper(w) = any (array['4MATIC', '4MATIC+', 'AMG', 'COUPE', '4-DOOR', 'ROADSTER', 'EDITION']) or w = 'S'))) then
      return jsonb_build_object('model', 'AMG GT', 'trim', app.mf_join(array[case when gt[1] is not null then 'GT' || gt[1] end, gt[2], tr]), 'known', true);
    end if;
    return jsonb_build_object('model', mo, 'trim', tr, 'known', mo = any (mb_families));
  end if;
  if mk = 'BMW' then
    s := regexp_match(mo, '^([Mm]?)(\d)(\d{2})([IiDdEe]|[Xx][Ii])(?: (.*))?$');
    if s is not null and (s[5] is null or not exists (select 1 from unnest(string_to_array(s[5], ' ')) w where not upper(w) = any (bmw_words))) then
      return jsonb_build_object('model', s[2] || ' Series', 'trim', app.mf_join(array[upper(s[1]) || s[2] || s[3] || lower(s[4]), s[5], tr]), 'known', true);
    end if;
    x := regexp_match(mo, '^([Xx]\d|[Zz]4|[Ii]\d|[Ii][Xx]) (.+)$');
    if x is not null and x[2] !~ '^M( |$)' then
      fam := case when x[1] ~* '^x\d$' then upper(x[1]) else x[1] end;
      if fam = any (bmw) then return jsonb_build_object('model', fam, 'trim', app.mf_join(array[x[2], tr]), 'known', true); end if;
    end if;
    return jsonb_build_object('model', mo, 'trim', tr, 'known', mo = any (bmw));
  end if;
  return jsonb_build_object('model', mo, 'trim', tr, 'known', null);
end $$;
comment on function app.car_model_family(text, text, text) is 'One model per car family (0520): {model: the family as the maker names it, trim: the code and its words, known: true, false (a Mercedes-Benz or BMW model we do not know) or null (another make)}. The same rule as web/src/features/vin/model-family.ts.';

create or replace function app.vehicle_model_family() returns trigger
language plpgsql security definer set search_path = public, app as $$
declare f jsonb;
begin
  if new.model is null or btrim(new.model) = '' then return new; end if;
  f := app.car_model_family(new.make, new.model, new.trim);
  new.model := f ->> 'model';
  new.trim := f ->> 'trim';
  return new;
end $$;
drop trigger if exists vehicles_a1_model_family on vehicles;
create trigger vehicles_a1_model_family before insert or update of make, model, trim on vehicles for each row execute function app.vehicle_model_family();

-- ================================================================ 2. every car on file
create or replace function app.car_model_family_backfill() returns integer
language plpgsql security definer set search_path = public, app as $$
declare
  r record;
  f jsonb;
  n integer := 0;
begin
  for r in select v.id, v.make, v.model, v.trim, v.is_sample from vehicles v where v.model is not null and btrim(v.model) <> '' order by v.id loop
    f := app.car_model_family(r.make, r.model, r.trim);
    continue when f ->> 'model' is not distinct from r.model and f ->> 'trim' is not distinct from r.trim;
    update vehicles set model = model, trim = trim where id = r.id;   -- the trigger writes the family
    insert into audit_log (actor_user_id, action, entity_table, entity_id, before, after)
    values (null, 'model_family', 'vehicles', r.id::text, jsonb_build_object('model', r.model, 'trim', r.trim),
            jsonb_build_object('model', f ->> 'model', 'trim', f ->> 'trim', 'note', 'One model per family, the code in the trim (0520); the public address is unchanged'));
    if not coalesce(r.is_sample, false) then
      begin
        perform app.listing_template_copy(r.id);
        perform app.car_copy_queue(r.id);
      exception when others then
        insert into audit_log (actor_user_id, action, entity_table, entity_id, after)
        values (null, 'model_family_copy_failed', 'vehicles', r.id::text, jsonb_build_object('error', sqlerrm));
      end;
    end if;
    n := n + 1;
  end loop;
  return n;
end $$;
select app.car_model_family_backfill();

-- ================================================================ 3. Data health: a family we do not know
alter function app.data_health(timestamptz) rename to data_health_pre0520;
create function app.data_health(p_now timestamptz default now()) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare
  r jsonb := app.data_health_pre0520(p_now);
  x jsonb;
  c jsonb;
begin
  select coalesce(jsonb_agg(app.dh_item(v.id, format('%s %s%s: "%s" is not a %s model family we know', v.make, v.model, coalesce(' ' || v.trim, ''), v.model, v.make),
                                        '/admin/vehicles/' || v.id) order by v.make, v.model), '[]'::jsonb) into x
    from vehicles v
   where not coalesce(v.is_sample, false) and v.status not in ('exited', 'total_loss', 'declined')
     and (app.car_model_family(v.make, v.model, v.trim) ->> 'known') = 'false';
  c := app.dh_check('model_family', 'Model family not recognized', 'Mercedes-Benz or BMW cars whose model is not a family we know: the /cars filters list them apart', x, '/admin/vehicles');
  return jsonb_set(jsonb_set(r, '{checks}', (r -> 'checks') || c), '{issues}', to_jsonb((r ->> 'issues')::integer + (c ->> 'count')::integer));
end $$;

-- ================================================================ privileges
revoke all on function app.mf_join(text[]) from public, anon, authenticated;
revoke all on function app.mf_mb_code(text) from public, anon, authenticated;
revoke all on function app.mf_code_trim(jsonb, text) from public, anon, authenticated;
grant execute on function app.mf_join(text[]), app.mf_mb_code(text), app.mf_code_trim(jsonb, text) to authenticated, service_role;
grant execute on function app.car_model_family(text, text, text) to authenticated, service_role;
revoke all on function app.vehicle_model_family() from public, anon, authenticated;
grant execute on function app.vehicle_model_family() to service_role;
revoke all on function app.car_model_family_backfill() from public, anon, authenticated;
grant execute on function app.car_model_family_backfill() to service_role;
do $$
declare g text;
begin
  execute 'revoke all on function app.data_health(timestamptz) from public, anon, authenticated';
  foreach g in array array['anon', 'authenticated', 'service_role'] loop
    if has_function_privilege(g, 'app.data_health_pre0520(timestamptz)'::regprocedure, 'execute') then
      execute format('grant execute on function app.data_health(timestamptz) to %I', g);
    end if;
  end loop;
  execute 'revoke all on function app.data_health_pre0520(timestamptz) from public, anon, authenticated';
end $$;
