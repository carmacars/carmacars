-- 0192_owner_preview_form_fixes.sql
-- Two jobs (docs/changes/2026-10-27-owner-preview-form-fixes.md).
--
-- 1. The owner reads their agreements right after sign-up. Until now /owner/sign said "We are preparing the terms for
--    your vehicles" until an Admin approved the application and set each car's terms: app.owner_agreement_facts (0029)
--    reads the agreements and the Vehicle Schedule entries, and a car still in intake has neither. A preview mode is
--    added beside it, app.owner_agreement_preview_facts: the same facts plus one entry for each car still in intake,
--    filled from the application (the car, how it is held, the management mode and onboarding method proposed), with
--    every fee, the Revenue Share and the agreement numbers left empty ("pending") and the flag preview = true. The page
--    shows the two agreements read only, marked "Terms pending approval". Nothing in the signing gate changes: the
--    documents open for signature only through app.owner_open_agreements, which still needs the agreements an Admin's
--    terms create. The owner's checklist says where to read them.
--
-- 2. The ServiceOntario forms, as previewed on the live site for real owners' cars:
--    a. "Street Number and Name" printed a district ("Scarborough") and lost the street. The owner's street line went to
--       the form as stored, and app.split_ca_address (0122) took the first comma part as the street and the last as the
--       city, read "Toronto ON M5V1A1" as a province, kept "Unit 5" inside the street line and took "University Ave" or
--       "Steeles Ave" for a unit. Now: app.address_parts reads the owner's separate columns first (street line, unit,
--       city, province, postal code), takes the unit out of the street line ("Unit 5", "#5", "5-123 Main St"), reads a
--       second line that is a unit as the unit and one that is a district as nothing, and parses a whole address typed
--       in the street line; app.split_ca_address finds the street by its civic number, the city after it, a district in
--       between dropped, and splits an address with no commas at its street type.
--    b. The name boxes were empty for owners whose first and last names were never stored (an owner added by staff,
--       a corporation whose legal name is the corporation's): the registry context took the parts as stored. Now the
--       parts come from the legal name when they are missing (an individual always gets "LAST, FIRST M"), a corporation
--       owner's person is its signing officer, and the corporation's name is its own, else a corporation owner's legal
--       name, else the name proposed for a new corporation on the application. CarmaCars' registry name falls back to
--       its trade name when no legal name is set.
--    c. No registrant box filled at all: a car whose onboarding method was not on its schedule, its onboarding or the
--       vehicle (only its ownership situation said it) fell to "no method", and every registrant field was empty. Now
--       the method is also read from the situation, and with no method at all the owner (or the owner's corporation) is
--       the vehicle's registrant, so Section 1 is never empty.
--    d. 013-1155 (and every registry form) is the owner's to do only when the car's method needs it: app.
--       vehicle_registry_forms gives the list by the current method and situation (013-1155 and 013-0169 for a Lease
--       through a new Owner Corporation only); filling a car's forms keeps to it, an open form the method does not need
--       is superseded (a signed or filed one stays on record), so the owner's checklist and Documents no longer list it.
--    The mapping of each official form is put back where no Admin has saved one (0122's rule), every form in use and not
--    signed or filed is filled again, and no template is marked checked: an Admin checks each one in the UI.
--
-- 3. The guides say so: the Owner's "Apply and get your car listed" and "Documents and forms", the Admin's "Settings".
-- No applied migration is edited.

-- ================================================================ 1. the owner's agreements, before approval
-- The facts of 0029 (with 0053's other Owners and 0122's company name) and, for each car still in intake, an entry
-- filled from the application. The fees, the Revenue Share, the Install Fee, the schedule and agreement numbers and the
-- dates stay empty: only an Admin sets them. Owner or staff, like the facts.
create or replace function app.owner_agreement_preview_facts(p_owner uuid, p_by uuid) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare
  f jsonb := app.owner_agreement_facts(p_owner, p_by);   -- the same reader, the same access check
  o owners;
  v_pending jsonb;
  v_next integer;
  v_ea_signed boolean;
  v_agreements jsonb;
begin
  select * into o from owners where id = p_owner;
  v_next := coalesce((select max((s ->> 'vehicle_number')::integer) from jsonb_array_elements(f -> 'schedules') s), 0);
  v_ea_signed := exists (select 1 from jsonb_array_elements(f -> 'agreements') a where a ->> 'kind' = 'enrollment' and a ->> 'status' = 'signed');
  select coalesce(jsonb_agg(x.entry order by x.n), '[]'::jsonb) into v_pending
    from (select row_number() over (order by v.created_at, v.id) as n,
                 jsonb_build_object('id', null, 'vehicle_id', v.id, 'schedule_number', null,
                   'vehicle_number', v_next + row_number() over (order by v.created_at, v.id), 'is_additional', v_ea_signed,
                   'year', v.year, 'make', v.make, 'model', v.model, 'trim', v.trim, 'colour', v.colour, 'vin', upper(v.vin), 'plate', v.plate,
                   'odometer_km', v.odometer_km, 'held_by', coalesce(ob.held_by, o.owner_type), 'title_status', ob.title_status,
                   'finance_party_name', ob.finance_party_name,
                   'finance_permission', coalesce(ob.finance_permission::text, case when ob.title_status = 'owned_outright' then 'not_applicable' end),
                   'management_mode', coalesce(ob.proposed_management_mode, v.management_mode),
                   'onboarding_method', case when coalesce(ob.proposed_management_mode, v.management_mode) = 'turo_only' then 'none'
                                             else coalesce(ob.proposed_onboarding_method::text, v.onboarding_method::text, sit.method::text) end,
                   'insurance_fee_cents', null, 'tracker_fee_cents', null, 'install_fee_cents', null, 'revenue_share_bps', null,
                   'enrollment_date', null, 'special_terms', null,
                   'owners_lien', case when ob.owners_lien_elected then 'elected' else 'not_available' end,
                   'signed_at', null, 'signature_request_id', null, 'title_agreement_id', null, 'onboarding_status', ob.status, 'pending', true) as entry
            from vehicles v join vehicle_onboardings ob on ob.vehicle_id = v.id
            left join onboarding_situations sit on sit.situation = ob.situation
           where v.owner_id = p_owner and ob.status = 'intake' and not coalesce(v.is_sample, false)
             and not exists (select 1 from vehicle_schedules s where s.vehicle_id = v.id and s.superseded_by is null)) x;
  if jsonb_array_length(v_pending) = 0 then
    return f || jsonb_build_object('preview', false, 'pending_vehicles', 0);
  end if;
  -- an agreement not made yet is shown with no number and no date
  v_agreements := f -> 'agreements';
  if not exists (select 1 from jsonb_array_elements(v_agreements) a where a ->> 'kind' = 'enrollment') then
    v_agreements := v_agreements || jsonb_build_array(jsonb_build_object('id', null, 'kind', 'enrollment', 'agreement_number', null, 'status', 'preview',
      'agreement_date', null, 'signature_request_id', null, 'document_sha256', null));
  end if;
  if not exists (select 1 from jsonb_array_elements(v_agreements) a where a ->> 'kind' = 'title_holding')
     and exists (select 1 from jsonb_array_elements(v_pending) s where s ->> 'management_mode' <> 'turo_only') then
    v_agreements := v_agreements || jsonb_build_array(jsonb_build_object('id', null, 'kind', 'title_holding', 'agreement_number', null, 'status', 'preview',
      'agreement_date', null, 'signature_request_id', null, 'document_sha256', null));
  end if;
  return f || jsonb_build_object('agreements', v_agreements, 'schedules', (f -> 'schedules') || v_pending,
                                 'preview', true, 'pending_vehicles', jsonb_array_length(v_pending));
end $$;

create or replace function public.server_owner_agreement_preview_facts(p_owner uuid, p_by uuid) returns jsonb
language sql stable security invoker set search_path = public, app as $$ select app.owner_agreement_preview_facts(p_owner, p_by) $$;

-- The owner's checklist (0049): an agreement not prepared yet is there to read now, signed once the terms are approved.
alter function app.my_signing_checklist(uuid) rename to my_signing_checklist_pre0192;
create or replace function app.my_signing_checklist(p_by uuid) returns jsonb
language sql stable security definer set search_path = public, app as $$
  select c || jsonb_build_object('items', coalesce((select jsonb_agg(case
             when i ->> 'code' in ('enrollment', 'title_holding') and i ->> 'status' = 'open' and i ->> 'detail' like 'Not prepared yet%'
             then i || jsonb_build_object('preview', true, 'detail', 'Filled in for you to read now. You sign once CarmaCars approves your terms.')
             else i end order by n) from jsonb_array_elements(c -> 'items') with ordinality t(i, n)), '[]'::jsonb))
    from app.my_signing_checklist_pre0192(p_by) c
$$;

-- ================================================================ 2. the ServiceOntario forms
-- ---------------------------------------------------------------- 2a. addresses
-- A province as its two letters ("Ontario" and "Ont." read "ON").
create or replace function app.ca_province_code(p text) returns text
language sql immutable as $$
  select case lower(btrim(regexp_replace(coalesce(p, ''), '\.$', '')))
    when '' then null
    when 'ontario' then 'ON' when 'ont' then 'ON' when 'quebec' then 'QC' when 'québec' then 'QC' when 'pq' then 'QC'
    when 'british columbia' then 'BC' when 'alberta' then 'AB' when 'manitoba' then 'MB' when 'saskatchewan' then 'SK'
    when 'nova scotia' then 'NS' when 'new brunswick' then 'NB' when 'newfoundland and labrador' then 'NL' when 'newfoundland' then 'NL'
    when 'prince edward island' then 'PE' when 'pei' then 'PE' when 'yukon' then 'YT' when 'northwest territories' then 'NT' when 'nunavut' then 'NU'
    else upper(btrim(regexp_replace(p, '\.$', ''))) end
$$;

-- A postal code written "A1A 1A1"; anything else as it is.
create or replace function app.ca_postal_code(p text) returns text
language sql immutable as $$
  select case when upper(regexp_replace(coalesce(p, ''), '[\s-]', '', 'g')) ~ '^[A-Z][0-9][A-Z][0-9][A-Z][0-9]$'
              then substr(upper(regexp_replace(p, '[\s-]', '', 'g')), 1, 3) || ' ' || substr(upper(regexp_replace(p, '[\s-]', '', 'g')), 4, 3)
              else nullif(btrim(coalesce(p, '')), '') end
$$;

-- A unit written on its own ("Unit 5", "Apt. 12B", "Suite 300", "#1807", "PH2", or "1807" alone) as the unit alone
-- ("5", "12B", "300", "1807", "PH2"); null for anything else ("Scarborough", "Rear building").
create or replace function app.unit_only(p text) returns text
language sql immutable as $$
  select case
    when btrim(coalesce(p, '')) ~* '^(unit|apt|apartment|suite|ste|no|number|#)\.?\s*#?\s*([A-Za-z]?[0-9][0-9A-Za-z-]*|[A-Za-z])$'
      then upper((regexp_match(btrim(p), '^(unit|apt|apartment|suite|ste|no|number|#)\.?\s*#?\s*([A-Za-z]?[0-9][0-9A-Za-z-]*|[A-Za-z])$', 'i'))[2])
    when btrim(coalesce(p, '')) ~* '^(ph|lph|uph)\s*[0-9]+$' then upper(regexp_replace(btrim(p), '\s', '', 'g'))
    when btrim(coalesce(p, '')) ~ '^[A-Za-z]?[0-9]{1,5}[A-Za-z]?$' then upper(btrim(p))
    else null end
$$;

-- A street line and the unit written in it: "123 Main St Unit 5", "123 Main St #5", "Unit 5 123 Main St", "#5 123 Main St"
-- and "5-123 Main St" (the unit, then the civic number) give the street "123 Main St" and the unit "5".
create or replace function app.street_and_unit(p text) returns jsonb
language plpgsql immutable as $$
declare
  s text := btrim(regexp_replace(coalesce(p, ''), '\s+', ' ', 'g'), ' ,');
  T constant text := '([A-Za-z]?[0-9][0-9A-Za-z-]*|[A-Za-z])';
  m text[];
begin
  if s = '' then return jsonb_build_object('street', null, 'unit', null); end if;
  m := regexp_match(s, '^(?:unit|apt|apartment|suite|ste)\.?\s*#?\s*' || T || '[\s,-]+([0-9].*)$', 'i');
  if m is not null then return jsonb_build_object('street', btrim(m[2]), 'unit', upper(m[1])); end if;
  m := regexp_match(s, '^#\s*' || T || '[\s,-]+([0-9].*)$');
  if m is not null then return jsonb_build_object('street', btrim(m[2]), 'unit', upper(m[1])); end if;
  m := regexp_match(s, '^(.*?\S)[\s,]+(?:unit|apt|apartment|suite|ste)\.?\s*#?\s*' || T || '\M(.*)$', 'i');
  if m is not null then return jsonb_build_object('street', btrim(btrim(m[1]) || ' ' || btrim(m[3]), ' ,'), 'unit', upper(m[2])); end if;
  m := regexp_match(s, '^(.*?\S)[\s,]*#\s*' || T || '\M(.*)$');
  if m is not null then return jsonb_build_object('street', btrim(btrim(m[1]) || ' ' || btrim(m[3]), ' ,'), 'unit', upper(m[2])); end if;
  m := regexp_match(s, '^([A-Za-z]?[0-9]+[A-Za-z]?)\s*-\s*([0-9]+[A-Za-z]?\s+\S.*)$');
  if m is not null then return jsonb_build_object('street', btrim(m[2]), 'unit', upper(m[1])); end if;
  return jsonb_build_object('street', s, 'unit', null);
end $$;

-- A one-line address in its parts (0122's function, made robust): "123 Example St, Scarborough, Toronto, ON M1J 1W6",
-- "123 Example St Unit 5, Toronto ON M5V1A1", "123 Example St Toronto ON M5V 1A1" (no commas), "Unit 5, 123 Example St,
-- Toronto, Ontario". The postal code and the province come off the end; the street is the first part with a civic number
-- (a building or place name before it is dropped), the city the last part after it (a district between them, like
-- Scarborough, is dropped); a unit word anywhere is the unit; with no commas the city follows the street type.
create or replace function app.split_ca_address(p text) returns jsonb
language plpgsql immutable as $$
declare
  s text := btrim(regexp_replace(coalesce(p, ''), '\s+', ' ', 'g'), ' ,');
  PROV constant text := '(ON|ONT|Ontario|QC|PQ|Quebec|Québec|BC|British Columbia|AB|Alberta|MB|Manitoba|SK|Saskatchewan|NS|Nova Scotia|NB|New Brunswick|NL|Newfoundland and Labrador|Newfoundland|PE|PEI|Prince Edward Island|YT|Yukon|NT|Northwest Territories|NU|Nunavut)';
  TYPES constant text := '(?:St|Street|Ave|Av|Avenue|Rd|Road|Dr|Drive|Blvd|Boulevard|Cres|Crescent|Crt|Ct|Court|Way|Lane|Ln|Pl|Place|Trail|Trl|Terr|Terrace|Pkwy|Parkway|Hwy|Highway|Circle|Cir|Sq|Square|Gate|Grove|Gdns|Gardens|Line|Sideroad|Path|Row|Walk|Hts|Heights|Mews|Close|Quay|Loop|Crossing|Cove)';
  v_postal text;
  v_prov text;
  v_unit text;
  v_city text;
  v_line1 text;
  parts text[];
  rest text[] := '{}';
  x text;
  m text[];
  su jsonb;
  i integer;
begin
  s := btrim(regexp_replace(s, '[,\s]*\mCanada\.?$', '', 'i'), ' ,');
  if s = '' then return jsonb_build_object('address_line1', null, 'unit', null, 'city', null, 'province', null, 'postal_code', null); end if;
  m := regexp_match(s, '^(.*?)[,\s]*\m([A-Za-z][0-9][A-Za-z])\s?-?([0-9][A-Za-z][0-9])$');
  if m is not null then v_postal := upper(m[2] || ' ' || m[3]); s := btrim(m[1], ' ,'); end if;
  m := regexp_match(s, '^(.*?)[,\s]*\m' || PROV || '\.?$', 'i');
  if m is not null then v_prov := app.ca_province_code(m[2]); s := btrim(m[1], ' ,'); end if;
  parts := array(select btrim(y) from unnest(string_to_array(s, ',')) y where btrim(y) <> '');
  foreach x in array parts loop
    if v_unit is null and x ~* '^(unit|apt|apartment|suite|ste|no\.?\s|#|ph)' and app.unit_only(x) is not null then v_unit := app.unit_only(x);
    else rest := rest || x; end if;
  end loop;
  if cardinality(rest) > 0 then
    i := coalesce((select min(k) from generate_subscripts(rest, 1) k where rest[k] ~ '^(#\s*)?[A-Za-z]?[0-9]'), 1);
    v_line1 := rest[i];
    if cardinality(rest) > i then v_city := rest[cardinality(rest)]; end if;
    su := app.street_and_unit(v_line1);
    v_line1 := su ->> 'street';
    v_unit := coalesce(v_unit, su ->> 'unit');
    -- no commas: the city after the street type ("45 Example Rd W Toronto")
    if v_city is null and v_line1 is not null then
      m := regexp_match(v_line1, '^([0-9].*\m' || TYPES || '\.?(?:\s+(?:N|S|E|W|NE|NW|SE|SW|North|South|East|West)\.?)?)\s+([A-Za-z][A-Za-z .''-]*)$', 'i');
      if m is not null and m[2] !~* ('^(N|S|E|W|NE|NW|SE|SW|North|South|East|West)\.?$') then v_line1 := btrim(m[1]); v_city := btrim(m[2]); end if;
    end if;
  end if;
  return jsonb_build_object('address_line1', v_line1, 'unit', v_unit, 'city', v_city, 'province', v_prov, 'postal_code', v_postal);
end $$;

-- An address kept in separate columns, in the boxes the forms have: the columns first; a whole address typed in the
-- street line is parsed (its city, province and postal code only where the columns have none); the unit comes out of
-- the street line; a second line that is a unit is the unit, one that is the street (the first line a building or a
-- district) is the street, and anything else (a district such as "Scarborough") goes in no box.
create or replace function app.address_parts(p_line1 text, p_line2 text, p_city text, p_province text, p_postal text) returns jsonb
language plpgsql immutable as $$
declare
  l1 text := nullif(btrim(regexp_replace(coalesce(p_line1, ''), '\s+', ' ', 'g'), ' ,'), '');
  l2 text := nullif(btrim(regexp_replace(coalesce(p_line2, ''), '\s+', ' ', 'g'), ' ,'), '');
  v_city text := nullif(btrim(coalesce(p_city, '')), '');
  v_prov text := app.ca_province_code(p_province);
  v_postal text := app.ca_postal_code(p_postal);
  v_street text;
  v_unit text;
  one jsonb;
  su jsonb;
begin
  if l1 ~ ',' or l1 ~* '\m[A-Za-z][0-9][A-Za-z]\s?[0-9][A-Za-z][0-9]$' then
    one := app.split_ca_address(l1);
    v_street := one ->> 'address_line1'; v_unit := one ->> 'unit';
    v_city := coalesce(v_city, one ->> 'city'); v_prov := coalesce(v_prov, one ->> 'province'); v_postal := coalesce(v_postal, one ->> 'postal_code');
  elsif l1 is not null then
    su := app.street_and_unit(l1); v_street := su ->> 'street'; v_unit := su ->> 'unit';
  end if;
  if l2 is not null then
    if app.unit_only(l2) is not null then
      v_unit := app.unit_only(l2);
    elsif l2 ~ '^(#\s*)?[A-Za-z]?[0-9]' and coalesce(v_street, '') !~ '[0-9]' then
      su := app.street_and_unit(l2); v_street := su ->> 'street'; v_unit := coalesce(v_unit, su ->> 'unit');
    end if;
  end if;
  return jsonb_build_object('address_line1', v_street, 'unit', v_unit, 'city', v_city, 'province', v_prov, 'postal_code', v_postal);
end $$;

-- ---------------------------------------------------------------- 2b. names
-- A corporation's name rather than a person's ("Northshore Auto Holdings Ltd.", "1001234 Ontario Inc.").
create or replace function app.looks_like_company(p text) returns boolean
language sql immutable as $$
  select coalesce(p, '') ~* '\m(inc|incorporated|ltd|limited|corp|corporation|co|company|llc|llp|lp|ltee|ltée|ulc|holdings|enterprises|group|ventures|investments|capital|leasing|rentals|motors|automotive|services|solutions|trust)\M'
      or coalesce(p, '') ~ '^\s*[0-9]{5,}\s'
$$;

-- A person's name in its parts: "Olivia Margaret Tremblay", "Tremblay, Olivia M", "Ana de Souza", "John Smith Jr".
create or replace function app.person_name_parts(p text) returns jsonb
language plpgsql immutable as $$
declare
  s text := btrim(regexp_replace(coalesce(p, ''), '\s+', ' ', 'g'), ' ,');
  w text[];
  n integer;
  i integer;
  v_last text;
  v_suffix text;
begin
  if s = '' then return jsonb_build_object('first', null, 'middle', null, 'last', null); end if;
  if s ~ ',' then
    w := string_to_array(btrim(substr(s, strpos(s, ',') + 1)), ' ');
    return jsonb_build_object('first', nullif(w[1], ''), 'middle', nullif(array_to_string(w[2:], ' '), ''), 'last', nullif(btrim(split_part(s, ',', 1)), ''));
  end if;
  w := string_to_array(s, ' ');
  n := cardinality(w);
  if n > 2 and w[n] ~* '^(jr|sr|ii|iii|iv)\.?$' then v_suffix := w[n]; n := n - 1; end if;
  if n = 1 then return jsonb_build_object('first', null, 'middle', null, 'last', w[1]); end if;
  v_last := w[n];
  i := n - 1;
  while i > 1 and lower(w[i]) in ('van', 'von', 'der', 'den', 'de', 'del', 'della', 'da', 'di', 'du', 'la', 'le', 'st', 'st.', 'dos', 'das', 'bin', 'ibn', 'el') loop
    v_last := w[i] || ' ' || v_last; i := i - 1;
  end loop;
  return jsonb_build_object('first', w[1], 'middle', nullif(array_to_string(w[2:i], ' '), ''), 'last', v_last || coalesce(' ' || v_suffix, ''));
end $$;

-- ---------------------------------------------------------------- 2c. the registry context (0122's, with the fixes above)
alter function app.registry_context(uuid) rename to registry_context_pre0192;
create or replace function app.registry_context(p_vehicle uuid) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare
  c jsonb := app.registry_context_0047(p_vehicle);
  o jsonb;
  reg jsonb;
  corp jsonb;
  co jsonb;
  st jsonb;
  ap jsonb;
  np jsonb;
  m text;
  v_leased boolean;
  v_corp_owner boolean;
  vr jsonb;
  po jsonb;
  v_person text;
  v_first text;
  v_middle text;
  v_last text;
  v_person_reg text;
  v_corp_name text;
  v_corp_signer text;
  v_proposed text;
  v_situation_method text;
  v_held text;
begin
  if c is null then return null; end if;
  o := c -> 'owner'; corp := c -> 'corporation'; m := c #>> '{method,code}';
  select x.method::text, nullif(btrim(ob.new_corporation ->> 'proposed_name'), '')
    into v_situation_method, v_proposed
    from vehicle_onboardings ob left join onboarding_situations x on x.situation = ob.situation where ob.vehicle_id = p_vehicle;
  -- the method: the schedule, the onboarding, the vehicle, else the ownership situation (0192)
  m := coalesce(m, v_situation_method);
  v_held := c #>> '{title,held_by}';
  v_leased := c #>> '{title,status}' = 'leased';
  v_corp_owner := o ->> 'owner_type' = 'corporation';

  -- CarmaCars, the company: its one-line address in its parts; its legal name, else its trade name
  co := app.split_ca_address(c #>> '{registrant,address}');
  st := app.street_parts(co ->> 'address_line1');
  reg := (c -> 'registrant') || co || jsonb_build_object('street_number', st ->> 'number', 'street_name', st ->> 'name',
           'registry_name', upper(coalesce(nullif(btrim(c #>> '{registrant,legal_name}'), ''), nullif(btrim(c #>> '{registrant,trade_name}'), ''))));

  -- the owner's person: an individual's legal name; a corporation's signing officer (or its legal name when that is a
  -- person's). The parts stored win; missing ones come from that name.
  v_person := case when v_corp_owner then coalesce(nullif(btrim(c #>> '{corporation,signing_officer_name}'), ''),
                                                   case when not app.looks_like_company(o ->> 'legal_name') then o ->> 'legal_name' end)
                   else o ->> 'legal_name' end;
  np := app.person_name_parts(v_person);
  if nullif(btrim(coalesce(o ->> 'first_name', '')), '') is null and nullif(btrim(coalesce(o ->> 'last_name', '')), '') is null then
    v_first := np ->> 'first'; v_middle := coalesce(nullif(btrim(coalesce(o ->> 'middle_name', '')), ''), np ->> 'middle'); v_last := np ->> 'last';
  else
    v_first := coalesce(nullif(btrim(coalesce(o ->> 'first_name', '')), ''), np ->> 'first');
    v_middle := nullif(btrim(coalesce(o ->> 'middle_name', '')), '');
    v_last := coalesce(nullif(btrim(coalesce(o ->> 'last_name', '')), ''), np ->> 'last');
  end if;
  v_person_reg := app.registry_person_name(v_last, v_first, v_middle, v_person);

  -- the owner's address in the forms' boxes: the separate columns first (0192)
  ap := app.address_parts(o ->> 'address_line1', o ->> 'address_line2', o ->> 'city', o ->> 'province', o ->> 'postal_code');
  st := app.street_parts(ap ->> 'address_line1');
  o := o || jsonb_build_object('first_name', v_first, 'middle_name', v_middle, 'last_name', v_last,
         'address_line1', ap ->> 'address_line1', 'unit', ap ->> 'unit', 'city', ap ->> 'city', 'province', ap ->> 'province', 'postal_code', ap ->> 'postal_code',
         'street_number', st ->> 'number', 'street_name', st ->> 'name', 'person_registry_name', v_person_reg,
         'registry_name', case when v_corp_owner and app.looks_like_company(o ->> 'legal_name') then upper(btrim(o ->> 'legal_name')) else v_person_reg end);

  -- the corporation: its own name, else a corporation owner's legal name, else the name proposed for a new one
  v_corp_name := coalesce(nullif(btrim(coalesce(corp ->> 'name', '')), ''),
                          case when v_corp_owner and app.looks_like_company(o ->> 'legal_name') then btrim(o ->> 'legal_name') end,
                          case when m = 'lease_new_owner_corporation' and v_proposed !~* '^\s*(a\s+)?numbered' then v_proposed end);
  v_corp_signer := coalesce(nullif(btrim(coalesce(corp ->> 'signing_officer_name', '')), ''), v_person, o ->> 'legal_name');
  corp := corp || jsonb_build_object('name', v_corp_name, 'signer_name', v_corp_signer, 'registry_name', upper(v_corp_name), 'proposed_name', v_proposed,
            'applies', v_corp_owner or v_held = 'corporation' or m in ('lease_existing_corporation', 'lease_new_owner_corporation'),
            'rin_needed', m = 'lease_existing_corporation', 'is_new_owner_corporation', m = 'lease_new_owner_corporation');

  -- who is the vehicle's registrant on SR-LV-006 section 1, and who signs the application, by method
  vr := case
    when m in ('lease_existing_corporation', 'lease_new_owner_corporation') then jsonb_build_object(
      'name', corp ->> 'registry_name', 'rin', corp ->> 'rin', 'date_of_birth', null,
      'address_line1', o ->> 'address_line1', 'unit', o ->> 'unit', 'city', o ->> 'city', 'province', o ->> 'province', 'postal_code', o ->> 'postal_code',
      'signer_name', v_corp_signer, 'owner_signs', true, 'is_individual', false)
    when m = 'co_registrant' then jsonb_build_object(
      'name', v_person_reg, 'rin', o ->> 'licence_number', 'date_of_birth', o ->> 'date_of_birth',
      'address_line1', o ->> 'address_line1', 'unit', o ->> 'unit', 'city', o ->> 'city', 'province', o ->> 'province', 'postal_code', o ->> 'postal_code',
      'signer_name', coalesce(v_person, o ->> 'legal_name'), 'owner_signs', true, 'is_individual', true)
    when m = 'transfer' and v_leased then jsonb_build_object(
      -- the lessor keeps the vehicle; its RIN and address are on the lease and the permit, written at the counter
      'name', upper(nullif(btrim(coalesce(c #>> '{lender,name}', '')), '')), 'rin', null, 'date_of_birth', null,
      'address_line1', null, 'unit', null, 'city', null, 'province', null, 'postal_code', null,
      'signer_name', reg ->> 'signing_officer_name', 'owner_signs', false, 'is_individual', false)
    when m = 'transfer' then jsonb_build_object(
      'name', reg ->> 'registry_name', 'rin', reg ->> 'rin', 'date_of_birth', null,
      'address_line1', reg ->> 'address_line1', 'unit', reg ->> 'unit', 'city', reg ->> 'city', 'province', reg ->> 'province', 'postal_code', reg ->> 'postal_code',
      'signer_name', reg ->> 'signing_officer_name', 'owner_signs', false, 'is_individual', false)
    -- no method on record: the owner (or the owner's corporation) is the vehicle's registrant, as it is today
    when v_corp_owner or v_held = 'corporation' then jsonb_build_object(
      'name', coalesce(corp ->> 'registry_name', o ->> 'registry_name'), 'rin', corp ->> 'rin', 'date_of_birth', null,
      'address_line1', o ->> 'address_line1', 'unit', o ->> 'unit', 'city', o ->> 'city', 'province', o ->> 'province', 'postal_code', o ->> 'postal_code',
      'signer_name', v_corp_signer, 'owner_signs', true, 'is_individual', false)
    else jsonb_build_object(
      'name', v_person_reg, 'rin', o ->> 'licence_number', 'date_of_birth', o ->> 'date_of_birth',
      'address_line1', o ->> 'address_line1', 'unit', o ->> 'unit', 'city', o ->> 'city', 'province', o ->> 'province', 'postal_code', o ->> 'postal_code',
      'signer_name', coalesce(v_person, o ->> 'legal_name'), 'owner_signs', true, 'is_individual', true) end;
  -- the plates are CarmaCars' (the lessee) under a Lease, and under a Transfer of a leased car
  po := case when m in ('lease_existing_corporation', 'lease_new_owner_corporation') or (m = 'transfer' and v_leased)
             then jsonb_build_object('name', reg ->> 'registry_name', 'rin', reg ->> 'rin', 'address_line1', reg ->> 'address_line1', 'unit', reg ->> 'unit',
                    'city', reg ->> 'city', 'province', reg ->> 'province', 'postal_code', reg ->> 'postal_code', 'signer_name', reg ->> 'signing_officer_name')
             else '{}'::jsonb end;
  return c || jsonb_build_object('owner', o, 'registrant', reg, 'corporation', corp, 'vehicle_registrant', vr, 'plate_owner', po,
    'method', (c -> 'method') || jsonb_build_object('code', m,
                 'is_lease', m in ('lease_existing_corporation', 'lease_new_owner_corporation'), 'is_co_registrant', m = 'co_registrant', 'is_transfer', m = 'transfer',
                 'plates_other', po <> '{}'::jsonb, 'two_registrants', m = 'co_registrant',
                 'owner_signs_application', coalesce((vr ->> 'owner_signs')::boolean, false)));
end $$;

-- ---------------------------------------------------------------- 2d. the forms each car's method needs
-- By the car's current method (its schedule, else its onboarding, the vehicle, the situation): the situation's own list
-- (an Admin may edit it), else the method's (onboarding_method_info). A Transfer of a car owned outright or financed needs
-- none (the sign-back on the permit); 013-1155 and 013-0169 only a Lease through a new Owner Corporation. A car with no
-- method yet keeps the list its onboarding has.
create or replace function app.vehicle_registry_forms(p_vehicle uuid) returns text[]
language plpgsql stable security definer set search_path = public, app as $$
declare
  ob vehicle_onboardings;
  v_m text;
  v_held text;
  v_title text;
  v_forms text[];
begin
  select * into ob from vehicle_onboardings where vehicle_id = p_vehicle;
  select coalesce(s.onboarding_method::text, ob.proposed_onboarding_method::text, v.onboarding_method::text, x.method::text),
         coalesce(s.held_by, ob.held_by)::text, coalesce(s.title_status, ob.title_status)::text
    into v_m, v_held, v_title
    from vehicles v
    left join vehicle_schedules s on s.vehicle_id = v.id and s.superseded_by is null
    left join onboarding_situations x on x.situation = ob.situation
   where v.id = p_vehicle
   order by s.created_at desc nulls last limit 1;
  if v_m is null then return coalesce(ob.government_forms, '{}'::text[]); end if;
  select coalesce((select x.government_forms from onboarding_situations x
                    where x.method = i.method
                      and (x.situation = ob.situation
                           or ((x.held_by is null or x.held_by::text = v_held) and (v_title is null or v_title::title_status = any (x.title_statuses))))
                    order by (x.situation is not distinct from ob.situation) desc, x.sort_order limit 1),
                  i.government_forms)
    into v_forms
    from onboarding_method_info i where i.method::text = v_m;
  return coalesce(v_forms, '{}'::text[]);
end $$;

-- Pre-fill every registry form the car's method needs (0022's, by the list above): the onboarding keeps the list, and a
-- form the method no longer needs is superseded unless it is signed or filed.
create or replace function app.fill_vehicle_government_forms(p_vehicle uuid, p_by uuid default null)
returns table (form_code text, fill_id uuid, status text, mode text, missing text[])
language plpgsql security definer set search_path = public, app as $$
declare
  v_forms text[];
  f text;
  v_id uuid;
begin
  if not exists (select 1 from vehicle_onboardings ob where ob.vehicle_id = p_vehicle) then
    raise exception 'This vehicle has no onboarding record' using errcode = 'P0002';
  end if;
  v_forms := app.vehicle_registry_forms(p_vehicle);
  update vehicle_onboardings ob set government_forms = v_forms where ob.vehicle_id = p_vehicle and ob.government_forms is distinct from v_forms;
  update government_form_fills g set superseded_at = now()
   where g.vehicle_id = p_vehicle and g.superseded_at is null and g.status not in ('signed', 'filed') and not (g.form_code = any (v_forms));
  foreach f in array v_forms loop
    v_id := app.fill_government_form(p_vehicle, f, p_by);
    return query select g.form_code, g.id, g.status, g.mode, g.missing from government_form_fills g where g.id = v_id;
  end loop;
end $$;

-- ================================================================ 3. the mappings, and the forms in use filled again
-- The checked mapping of each official form (0122's, from the publisher's download) goes back on the current template
-- where no Admin has saved one and the template has every mapped field; a template an Admin mapped is left as it is,
-- and none is marked checked here. Then, for every car: the onboarding keeps the forms its method needs, an open form it
-- does not need is superseded, and every open form (not signed or filed) is filled again from the fixed context.
do $$
declare
  t record;
  r record;
  v_forms text[];
begin
  for t in
    select p.id, o.field_map, o.notes from pdf_templates p join official_form_originals o on o.form_code = p.form_code
     where p.is_current and p.mapped_by is null and p.field_map is distinct from o.field_map
       and not exists (select 1 from jsonb_object_keys(o.field_map) k
                        where not exists (select 1 from jsonb_array_elements(p.field_names) x where x ->> 'name' = k))
  loop
    update pdf_templates set field_map = t.field_map, notes = coalesce(t.notes, notes), mapped_at = now() where id = t.id;
  end loop;
  for r in select ob.vehicle_id from vehicle_onboardings ob loop
    v_forms := app.vehicle_registry_forms(r.vehicle_id);
    update vehicle_onboardings set government_forms = v_forms where vehicle_id = r.vehicle_id and government_forms is distinct from v_forms;
    update government_form_fills g set superseded_at = now()
     where g.vehicle_id = r.vehicle_id and g.superseded_at is null and g.status not in ('signed', 'filed') and not (g.form_code = any (v_forms));
  end loop;
  for r in select g.vehicle_id, g.form_code from government_form_fills g
            where g.superseded_at is null and g.status not in ('signed', 'filed')
              and exists (select 1 from pdf_templates p where p.form_code = g.form_code and p.is_current) loop
    perform app.fill_government_form(r.vehicle_id, r.form_code, null);
  end loop;
end $$;

-- ================================================================ 4. the guides
-- The Owner's chapters "Apply and get your car listed" and "Documents and forms" (the agreements to read before approval,
-- the registry forms each method needs) and the Admin's "Settings" (the forms a car gets by its method).
-- GUIDES 0192 START (generated by supabase/seed/0192_gen_guides.mjs from docs/guides/content; do not edit by hand)
select app.guide_release_section('owner', 'apply-and-get-your-car-listed', 'chapter', 'start-here', 'You apply online in about ten minutes. We reply within one business day, set your terms, and walk you through the rest.

## Apply to list your car

1. Go to `carmacars.ca/list-your-car` and press **Apply to list your car**.
2. About you: individual or corporation, your address, licence and date of birth. Press **Continue to vehicles**.
3. For each car, type the VIN: your car is found as you type the last character (Edit if anything is wrong), then tap its colour and answer the rest. Use **Add another vehicle** for more cars.
4. Read how it will work, press **Continue**, then **Review**.
5. Press **Submit application**, then **Go to your owner portal**.

![](/guides/img/public-13-list-your-car-desktop-48bf4cb0.jpg "desktop; size: 1440 800; address: carmacars.ca/list-your-car; pins: 1 20.1 74.9")

> Tip: Need a break? **Email me a link** saves your application and sends you a link to finish later.

> Good to know: No car to add yet? On the vehicle step press **I''ll add my car later**, choose your password and press **Open my owner account**. Your owner portal opens with **Add your first car**: press it when you are ready, starting with the VIN.

## What happens next

Five steps take your car from your driveway to its first rental.

:::flow
Tell us about the car | We confirm fees and set your terms
Sign the agreements | Online, one for all your cars
One registry visit | We fill in the forms and come with you
Tracker and insurance | We install it and add the car
Photos and listing | Live within 1 business day
:::

1. When your terms are ready, Home shows **Check and sign**. Everything is filled in from your application: check the short list of key values (each has a **Fix** link) and open any document to read it in full.
2. Tap **All of these** for the three confirmations (your initials are filled in), then press **Sign all**. Your name on file is your signature; prefer to draw it? Press **Draw instead**. One signature covers every document, in about a minute.
3. Pay the upfront invoice: the first and last month''s insurance fee for each car (see chapter 4).
4. Upload what each car''s checklist asks for: the ownership permit, the lender''s permission if it is financed or leased, and insurance.
5. Sign Forms C and D (filled in for you) with witnesses: Form C on screen with your witness beside you, or on paper; Form D on paper, with a photo of each page from your phone (see chapter 5).

## If we need a little more

Sometimes we need one more document before we can approve your application, for example the ownership permit or the insurance slip.

1. You get an email, and Home shows "We need a little more" with the list and any note from our team.
2. Upload what is asked, or write Your answer, and press **Send my answer**.
3. We review it within 1 business day. Once we approve your application, you get an email and Home shows Check and sign.
', 'Apply and get your car listed', 'Apply online, sign, pay the upfront invoice and get your car on the site.',
  'You apply online in about ten minutes. We reply within one business day, set your terms, and walk you through the rest.

## Apply to list your car

1. Go to `carmacars.ca/list-your-car` and press **Apply to list your car**.
2. About you: individual or corporation, your address, licence and date of birth. Press **Continue to vehicles**.
3. For each car, type the VIN: your car is found as you type the last character (Edit if anything is wrong), then tap its colour and answer the rest. Use **Add another vehicle** for more cars.
4. Read how it will work, press **Continue**, then **Review**.
5. Press **Submit application**, then **Go to your owner portal**.

![](/guides/img/public-13-list-your-car-desktop-48bf4cb0.jpg "desktop; size: 1440 800; address: carmacars.ca/list-your-car; pins: 1 20.1 74.9")

> Tip: Need a break? **Email me a link** saves your application and sends you a link to finish later.

> Good to know: No car to add yet? On the vehicle step press **I''ll add my car later**, choose your password and press **Open my owner account**. Your owner portal opens with **Add your first car**: press it when you are ready, starting with the VIN.

## What happens next

Five steps take your car from your driveway to its first rental.

:::flow
Tell us about the car | We confirm fees and set your terms
Sign the agreements | Online, one for all your cars
One registry visit | We fill in the forms and come with you
Tracker and insurance | We install it and add the car
Photos and listing | Live within 1 business day
:::

1. Right after you apply, Home shows **Read your agreements**: both agreements, filled in from your application, marked "Terms pending approval". The fees and the Revenue Share read Pending approval until we set them, and the Sign button stays off.
2. When your terms are ready, Home shows **Check and sign**. Everything is filled in from your application: check the short list of key values (each has a **Fix** link) and open any document to read it in full.
3. Tap **All of these** for the three confirmations (your initials are filled in), then press **Sign all**. Your name on file is your signature; prefer to draw it? Press **Draw instead**. One signature covers every document, in about a minute.
4. Pay the upfront invoice: the first and last month''s insurance fee for each car (see chapter 4).
5. Upload what each car''s checklist asks for: the ownership permit, the lender''s permission if it is financed or leased, and insurance.
6. Sign Forms C and D (filled in for you) with witnesses: Form C on screen with your witness beside you, or on paper; Form D on paper, with a photo of each page from your phone (see chapter 5).

## If we need a little more

Sometimes we need one more document before we can approve your application, for example the ownership permit or the insurance slip.

1. You get an email, and Home shows "We need a little more" with the list and any note from our team.
2. Upload what is asked, or write Your answer, and press **Send my answer**.
3. We review it within 1 business day. Once we approve your application, you get an email and Home shows Check and sign.
',
  '<p class="gd-p">You apply online in about ten minutes. We reply within one business day, set your terms, and walk you through the rest.</p><section class="gd-task" id="apply-and-get-your-car-listed-apply-to-list-your-car" data-gd-task><h2 class="gd-h2">Apply to list your car</h2><div class="gd-stepblock gd-stepblock--below"><div class="gd-stepcol"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Go to <span class="gd-url">carmacars.ca/list-your-car</span> and press <b class="gd-ui">Apply to list your car</b>.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">About you: individual or corporation, your address, licence and date of birth. Press <b class="gd-ui">Continue to vehicles</b>.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">For each car, type the VIN: your car is found as you type the last character (Edit if anything is wrong), then tap its colour and answer the rest. Use <b class="gd-ui">Add another vehicle</b> for more cars.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">Read how it will work, press <b class="gd-ui">Continue</b>, then <b class="gd-ui">Review</b>.</div></li><li><span class="gd-n" aria-hidden="true">5</span><div class="gd-t">Press <b class="gd-ui">Submit application</b>, then <b class="gd-ui">Go to your owner portal</b>.</div></li></ol></div><figure class="gd-fig gd-fig--desk"><div class="gd-browser"><div class="gd-bar" aria-hidden="true"><i></i><i></i><i></i><span class="gd-addr">carmacars.ca/list-your-car</span></div><div class="gd-imgwrap" style="aspect-ratio:1440/800"><img src="/guides/img/public-13-list-your-car-desktop-48bf4cb0.jpg" alt="" loading="lazy" decoding="async" width="1440" height="800"><span class="gd-pin" style="left:20.1%;top:74.9%" aria-hidden="true">1</span></div></div></figure></div><aside class="gd-box"><span class="gd-lbl">Tip</span><div>Need a break? <b class="gd-ui">Email me a link</b> saves your application and sends you a link to finish later.</div></aside><aside class="gd-box"><span class="gd-lbl">Good to know</span><div>No car to add yet? On the vehicle step press <b class="gd-ui">I&#39;ll add my car later</b>, choose your password and press <b class="gd-ui">Open my owner account</b>. Your owner portal opens with <b class="gd-ui">Add your first car</b>: press it when you are ready, starting with the VIN.</div></aside></section><section class="gd-task" id="apply-and-get-your-car-listed-what-happens-next" data-gd-task><h2 class="gd-h2">What happens next</h2><p class="gd-p">Five steps take your car from your driveway to its first rental.</p><ol class="gd-flow"><li><b>1</b><span>Tell us about the car</span><em>We confirm fees and set your terms</em></li><li><b>2</b><span>Sign the agreements</span><em>Online, one for all your cars</em></li><li><b>3</b><span>One registry visit</span><em>We fill in the forms and come with you</em></li><li><b>4</b><span>Tracker and insurance</span><em>We install it and add the car</em></li><li><b>5</b><span>Photos and listing</span><em>Live within 1 business day</em></li></ol><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Right after you apply, Home shows <b class="gd-ui">Read your agreements</b>: both agreements, filled in from your application, marked &quot;Terms pending approval&quot;. The fees and the Revenue Share read Pending approval until we set them, and the Sign button stays off.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">When your terms are ready, Home shows <b class="gd-ui">Check and sign</b>. Everything is filled in from your application: check the short list of key values (each has a <b class="gd-ui">Fix</b> link) and open any document to read it in full.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Tap <b class="gd-ui">All of these</b> for the three confirmations (your initials are filled in), then press <b class="gd-ui">Sign all</b>. Your name on file is your signature; prefer to draw it? Press <b class="gd-ui">Draw instead</b>. One signature covers every document, in about a minute.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">Pay the upfront invoice: the first and last month&#39;s insurance fee for each car (see chapter 4).</div></li><li><span class="gd-n" aria-hidden="true">5</span><div class="gd-t">Upload what each car&#39;s checklist asks for: the ownership permit, the lender&#39;s permission if it is financed or leased, and insurance.</div></li><li><span class="gd-n" aria-hidden="true">6</span><div class="gd-t">Sign Forms C and D (filled in for you) with witnesses: Form C on screen with your witness beside you, or on paper; Form D on paper, with a photo of each page from your phone (see chapter 5).</div></li></ol></div></section><section class="gd-task" id="apply-and-get-your-car-listed-if-we-need-a-little-more" data-gd-task><h2 class="gd-h2">If we need a little more</h2><p class="gd-p">Sometimes we need one more document before we can approve your application, for example the ownership permit or the insurance slip.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">You get an email, and Home shows &quot;We need a little more&quot; with the list and any note from our team.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Upload what is asked, or write Your answer, and press <b class="gd-ui">Send my answer</b>.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">We review it within 1 business day. Once we approve your application, you get an email and Home shows Check and sign.</div></li></ol></div></section>');
select app.guide_release_section('owner', 'documents-and-forms', 'chapter', 'fees-payments-and-payouts', 'Your signed agreements, uploads and government forms are under Documents. Some forms are filled for you; Forms C and D are signed with witnesses.

## Sign everything at once

Everything you sign on screen is in one place: Home shows how many are signed ("2 of 5 signed") and opens it with Check and sign.

1. Press **Check and sign** on Home (or open `carmacars.ca/owner/sign`). The list at the top shows each document: signed, in this package, or done elsewhere (Forms C and D, the bank debit).
2. Check the key values: your name, address, each car with its VIN and plate, your fees and Revenue Share. Something wrong? Press **Fix** next to it, change it, and come back.
3. Open any document to read it word for word: the agreements, the schedules and Forms A and B. The official registry forms are not in it: they are printed and signed in ink.
4. Tap **All of these** for the statements the agreement asks you to initial (your initials are filled in), then press **Sign all**.
5. Your name on file is your signature. One signature is applied to each document; CarmaCars countersigns at the same moment and every signed copy is in Documents.

> Two owners: A car with a second owner on its ownership? Each owner named in the Title Schedule signs. The other owner gets their own link by email and signs the same documents on their phone or computer. The agreements take effect when the last owner signs; CarmaCars countersigns then.

> Good to know: Form A (the trust declaration) is for cars under the Co-Registrant or Transfer method; Form B (the lease summary) for cars under a Lease method. No witness is needed: they are in the same package. You can also sign one on its own page from Documents.

> Tip: Signed one of your documents on paper instead? Send us the scan. Once we record it, Documents shows it as Signed on paper and we do not ask again.

## We set up your car for you

When our team enters your car for you, you get one email: review the details and sign.

1. No sign-in yet? The email has a link to choose your password. It works once, for 24 hours; after that use Forgot password on the sign-in page.
2. Open `carmacars.ca/owner/review` (Home has **Review or correct your details**). Check your phone and address, and each car: plate, colour, odometer, your insurer and your lender. The terms we agreed are shown too.
3. Something wrong? Correct it and press **Save corrections**. Your documents are filled in again and we are told. A term you did not agree to: message us before you sign.
4. Everything right? Press **Everything is right: sign** and sign once.

## Sign an updated Vehicle Schedule

When we agree new terms for a car you already signed for, you sign an updated Vehicle Schedule. Home shows it first.

1. Open it from Home or the email. It shows what changes (now and updated) and the date it applies from.
2. Read the text, tick that you agree, type your full legal name and press **Sign**.
3. Your current terms stay until you sign. After that, your invoices and statements use the new ones from the date.

## Form C on screen, with your witness beside you

Form C is the lender or lessor permission for a financed or leased car. It needs one witness, and you can sign it on screen when your witness is with you.

1. Open Documents. Under Forms to sign with witnesses, press Sign Form C on screen instead.
2. Initial each of the three acknowledgments, and type Your initials.
3. Sign: draw your signature in the box, or use your name.
4. Hand the device to your witness, another adult. They type their full name and tick the statement "I witnessed (your name) sign in my presence." Press **Sign Form C**.

![](/guides/img/owner-16-form-c-screen-desktop-faa92983.jpg "desktop; size: 790 980; address: carmacars.ca/owner/documents/form-c/4898eb96-0cce-4efc-9fdd-740b4b4e9ad3; pins: 2 5.7 13.6, 3 32.9 55.1, 4 6.3 82.2")

## Forms C and D on paper, signed with witnesses

Form D is a limited power of attorney (two witnesses), signed on paper. Form C can be signed on paper too, with one witness.

1. Open Documents. Under Forms to sign with witnesses, press **Print the form**. It is filled in, and every spot to sign or initial is marked SIGN HERE or INITIAL HERE.
2. Sign it in front of your witnesses. They sign and print their names in their spots.
3. Type each witness''s full name in the boxes.
4. On your phone, press **Take a photo of the signed page**: one photo of each page. A PDF scan works too (**Or choose a file**).

![](/guides/img/owner-12-forms-c-d-desktop-21fbbe79.jpg "desktop; size: 1440 742; address: carmacars.ca/owner/documents; pins: 1 21.5 32.5, 3 69.4 50.7, 4 69.4 60.4")

> Tip: We check the photo and approve it, or send it back with what to fix. You get an email either way, and the page shows the status.

> Good to know: Why paper for Form D? It is a power of attorney, which cannot be signed electronically in Ontario, and its two witnesses sign in person.

## Government forms filled for you

Each car''s registry forms are prepared from your records. Until we load the official PDF, you get a data sheet with the values.

1. Open Documents and choose a form marked "Official form, filled for you".
2. Press **Download the filled form** and check each value.
3. Print it and sign it in ink. It is the official ServiceOntario form exactly as ServiceOntario publishes it, with only its empty text boxes filled in. Its boxes to tick and its signatures are done by hand, at the registry office or before you go, as we tell you.

![](/guides/img/owner-13-official-form-desktop-48614913.jpg "desktop; size: 1440 732; address: carmacars.ca/owner/documents/forms/4d54a524-c28d-4bc4-8ad3-dd9558100a81/official; pins: 2 22.2 29.5")

> Good to know: ON00453 (a company''s registrant number) is an Adobe form: open it in Adobe Acrobat Reader (free) to see and print it. Other PDF viewers show a blank page, as they do with the form downloaded from ServiceOntario.

> Watch out: Official registry forms are never signed on screen. You pay ServiceOntario, the inspection station and the appraiser directly.
', 'Documents and forms', 'Agreements, government forms, Forms C and D, and official forms filled for you.',
  'Your signed agreements, uploads and government forms are under Documents. Some forms are filled for you; Forms C and D are signed with witnesses.

## Sign everything at once

Everything you sign on screen is in one place: Home shows how many are signed ("2 of 5 signed") and opens it with Check and sign.

1. Press **Check and sign** on Home (or open `carmacars.ca/owner/sign`). The list at the top shows each document: signed, in this package, or done elsewhere (Forms C and D, the bank debit).
2. Check the key values: your name, address, each car with its VIN and plate, your fees and Revenue Share. Something wrong? Press **Fix** next to it, change it, and come back.
3. Open any document to read it word for word: the agreements, the schedules and Forms A and B. The official registry forms are not in it: they are printed and signed in ink.
4. Tap **All of these** for the statements the agreement asks you to initial (your initials are filled in), then press **Sign all**.
5. Your name on file is your signature. One signature is applied to each document; CarmaCars countersigns at the same moment and every signed copy is in Documents.

## Read your agreements before approval

You can read both agreements as soon as you apply, before we approve your terms.

1. Press **Read your agreements** on Home (Documents and each car''s Onboarding checklist link to it too).
2. Each document is filled in from your application: your name, address and cars. It is marked "Terms pending approval": the fees, the Revenue Share and the agreement numbers read Pending approval until we set them.
3. Something wrong? Press **Fix** next to it. The Sign button stays off until we approve your terms; then Home shows **Check and sign** and we email you.

> Two owners: A car with a second owner on its ownership? Each owner named in the Title Schedule signs. The other owner gets their own link by email and signs the same documents on their phone or computer. The agreements take effect when the last owner signs; CarmaCars countersigns then.

> Good to know: Form A (the trust declaration) is for cars under the Co-Registrant or Transfer method; Form B (the lease summary) for cars under a Lease method. No witness is needed: they are in the same package. You can also sign one on its own page from Documents.

> Tip: Signed one of your documents on paper instead? Send us the scan. Once we record it, Documents shows it as Signed on paper and we do not ask again.

## We set up your car for you

When our team enters your car for you, you get one email: review the details and sign.

1. No sign-in yet? The email has a link to choose your password. It works once, for 24 hours; after that use Forgot password on the sign-in page.
2. Open `carmacars.ca/owner/review` (Home has **Review or correct your details**). Check your phone and address, and each car: plate, colour, odometer, your insurer and your lender. The terms we agreed are shown too.
3. Something wrong? Correct it and press **Save corrections**. Your documents are filled in again and we are told. A term you did not agree to: message us before you sign.
4. Everything right? Press **Everything is right: sign** and sign once.

## Sign an updated Vehicle Schedule

When we agree new terms for a car you already signed for, you sign an updated Vehicle Schedule. Home shows it first.

1. Open it from Home or the email. It shows what changes (now and updated) and the date it applies from.
2. Read the text, tick that you agree, type your full legal name and press **Sign**.
3. Your current terms stay until you sign. After that, your invoices and statements use the new ones from the date.

## Form C on screen, with your witness beside you

Form C is the lender or lessor permission for a financed or leased car. It needs one witness, and you can sign it on screen when your witness is with you.

1. Open Documents. Under Forms to sign with witnesses, press Sign Form C on screen instead.
2. Initial each of the three acknowledgments, and type Your initials.
3. Sign: draw your signature in the box, or use your name.
4. Hand the device to your witness, another adult. They type their full name and tick the statement "I witnessed (your name) sign in my presence." Press **Sign Form C**.

![](/guides/img/owner-16-form-c-screen-desktop-faa92983.jpg "desktop; size: 790 980; address: carmacars.ca/owner/documents/form-c/4898eb96-0cce-4efc-9fdd-740b4b4e9ad3; pins: 2 5.7 13.6, 3 32.9 55.1, 4 6.3 82.2")

## Forms C and D on paper, signed with witnesses

Form D is a limited power of attorney (two witnesses), signed on paper. Form C can be signed on paper too, with one witness.

1. Open Documents. Under Forms to sign with witnesses, press **Print the form**. It is filled in, and every spot to sign or initial is marked SIGN HERE or INITIAL HERE.
2. Sign it in front of your witnesses. They sign and print their names in their spots.
3. Type each witness''s full name in the boxes.
4. On your phone, press **Take a photo of the signed page**: one photo of each page. A PDF scan works too (**Or choose a file**).

![](/guides/img/owner-12-forms-c-d-desktop-21fbbe79.jpg "desktop; size: 1440 742; address: carmacars.ca/owner/documents; pins: 1 21.5 32.5, 3 69.4 50.7, 4 69.4 60.4")

> Tip: We check the photo and approve it, or send it back with what to fix. You get an email either way, and the page shows the status.

> Good to know: Why paper for Form D? It is a power of attorney, which cannot be signed electronically in Ontario, and its two witnesses sign in person.

## Government forms filled for you

Each car''s registry forms are prepared from your records, only the ones its onboarding method needs (013-1155 and 013-0169, for example, only for a Lease through a new corporation). Until we load the official PDF, you get a data sheet with the values.

1. Open Documents and choose a form marked "Official form, filled for you".
2. Press **Download the filled form** and check each value.
3. Print it and sign it in ink. It is the official ServiceOntario form exactly as ServiceOntario publishes it, with only its empty text boxes filled in. Its boxes to tick and its signatures are done by hand, at the registry office or before you go, as we tell you.

![](/guides/img/owner-13-official-form-desktop-48614913.jpg "desktop; size: 1440 732; address: carmacars.ca/owner/documents/forms/4d54a524-c28d-4bc4-8ad3-dd9558100a81/official; pins: 2 22.2 29.5")

> Good to know: ON00453 (a company''s registrant number) is an Adobe form: open it in Adobe Acrobat Reader (free) to see and print it. Other PDF viewers show a blank page, as they do with the form downloaded from ServiceOntario.

> Watch out: Official registry forms are never signed on screen. You pay ServiceOntario, the inspection station and the appraiser directly.
',
  '<p class="gd-p">Your signed agreements, uploads and government forms are under Documents. Some forms are filled for you; Forms C and D are signed with witnesses.</p><section class="gd-task" id="documents-and-forms-sign-everything-at-once" data-gd-task><h2 class="gd-h2">Sign everything at once</h2><p class="gd-p">Everything you sign on screen is in one place: Home shows how many are signed (&quot;2 of 5 signed&quot;) and opens it with Check and sign.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Press <b class="gd-ui">Check and sign</b> on Home (or open <span class="gd-url">carmacars.ca/owner/sign</span>). The list at the top shows each document: signed, in this package, or done elsewhere (Forms C and D, the bank debit).</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Check the key values: your name, address, each car with its VIN and plate, your fees and Revenue Share. Something wrong? Press <b class="gd-ui">Fix</b> next to it, change it, and come back.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Open any document to read it word for word: the agreements, the schedules and Forms A and B. The official registry forms are not in it: they are printed and signed in ink.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">Tap <b class="gd-ui">All of these</b> for the statements the agreement asks you to initial (your initials are filled in), then press <b class="gd-ui">Sign all</b>.</div></li><li><span class="gd-n" aria-hidden="true">5</span><div class="gd-t">Your name on file is your signature. One signature is applied to each document; CarmaCars countersigns at the same moment and every signed copy is in Documents.</div></li></ol></div></section><section class="gd-task" id="documents-and-forms-read-your-agreements-before-approval" data-gd-task><h2 class="gd-h2">Read your agreements before approval</h2><p class="gd-p">You can read both agreements as soon as you apply, before we approve your terms.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Press <b class="gd-ui">Read your agreements</b> on Home (Documents and each car&#39;s Onboarding checklist link to it too).</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Each document is filled in from your application: your name, address and cars. It is marked &quot;Terms pending approval&quot;: the fees, the Revenue Share and the agreement numbers read Pending approval until we set them.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Something wrong? Press <b class="gd-ui">Fix</b> next to it. The Sign button stays off until we approve your terms; then Home shows <b class="gd-ui">Check and sign</b> and we email you.</div></li></ol></div><aside class="gd-box"><div>Two owners: A car with a second owner on its ownership? Each owner named in the Title Schedule signs. The other owner gets their own link by email and signs the same documents on their phone or computer. The agreements take effect when the last owner signs; CarmaCars countersigns then.</div></aside><aside class="gd-box"><span class="gd-lbl">Good to know</span><div>Form A (the trust declaration) is for cars under the Co-Registrant or Transfer method; Form B (the lease summary) for cars under a Lease method. No witness is needed: they are in the same package. You can also sign one on its own page from Documents.</div></aside><aside class="gd-box"><span class="gd-lbl">Tip</span><div>Signed one of your documents on paper instead? Send us the scan. Once we record it, Documents shows it as Signed on paper and we do not ask again.</div></aside></section><section class="gd-task" id="documents-and-forms-we-set-up-your-car-for-you" data-gd-task><h2 class="gd-h2">We set up your car for you</h2><p class="gd-p">When our team enters your car for you, you get one email: review the details and sign.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">No sign-in yet? The email has a link to choose your password. It works once, for 24 hours; after that use Forgot password on the sign-in page.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Open <span class="gd-url">carmacars.ca/owner/review</span> (Home has <b class="gd-ui">Review or correct your details</b>). Check your phone and address, and each car: plate, colour, odometer, your insurer and your lender. The terms we agreed are shown too.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Something wrong? Correct it and press <b class="gd-ui">Save corrections</b>. Your documents are filled in again and we are told. A term you did not agree to: message us before you sign.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">Everything right? Press <b class="gd-ui">Everything is right: sign</b> and sign once.</div></li></ol></div></section><section class="gd-task" id="documents-and-forms-sign-an-updated-vehicle-schedule" data-gd-task><h2 class="gd-h2">Sign an updated Vehicle Schedule</h2><p class="gd-p">When we agree new terms for a car you already signed for, you sign an updated Vehicle Schedule. Home shows it first.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Open it from Home or the email. It shows what changes (now and updated) and the date it applies from.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Read the text, tick that you agree, type your full legal name and press <b class="gd-ui">Sign</b>.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Your current terms stay until you sign. After that, your invoices and statements use the new ones from the date.</div></li></ol></div></section><section class="gd-task" id="documents-and-forms-form-c-on-screen-with-your-witness-beside-you" data-gd-task><h2 class="gd-h2">Form C on screen, with your witness beside you</h2><p class="gd-p">Form C is the lender or lessor permission for a financed or leased car. It needs one witness, and you can sign it on screen when your witness is with you.</p><div class="gd-stepblock gd-stepblock--below"><div class="gd-stepcol"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Open Documents. Under Forms to sign with witnesses, press Sign Form C on screen instead.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Initial each of the three acknowledgments, and type Your initials.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Sign: draw your signature in the box, or use your name.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">Hand the device to your witness, another adult. They type their full name and tick the statement &quot;I witnessed (your name) sign in my presence.&quot; Press <b class="gd-ui">Sign Form C</b>.</div></li></ol></div><figure class="gd-fig gd-fig--desk"><div class="gd-browser"><div class="gd-bar" aria-hidden="true"><i></i><i></i><i></i><span class="gd-addr">carmacars.ca/owner/documents/form-c/4898eb96-0cce-4efc-9fdd-740b4b4e9ad3</span></div><div class="gd-imgwrap" style="aspect-ratio:790/980"><img src="/guides/img/owner-16-form-c-screen-desktop-faa92983.jpg" alt="" loading="lazy" decoding="async" width="790" height="980"><span class="gd-pin" style="left:5.7%;top:13.6%" aria-hidden="true">2</span><span class="gd-pin" style="left:32.9%;top:55.1%" aria-hidden="true">3</span><span class="gd-pin" style="left:6.3%;top:82.2%" aria-hidden="true">4</span></div></div></figure></div></section><section class="gd-task" id="documents-and-forms-forms-c-and-d-on-paper-signed-with-witnesses" data-gd-task><h2 class="gd-h2">Forms C and D on paper, signed with witnesses</h2><p class="gd-p">Form D is a limited power of attorney (two witnesses), signed on paper. Form C can be signed on paper too, with one witness.</p><div class="gd-stepblock gd-stepblock--below"><div class="gd-stepcol"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Open Documents. Under Forms to sign with witnesses, press <b class="gd-ui">Print the form</b>. It is filled in, and every spot to sign or initial is marked SIGN HERE or INITIAL HERE.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Sign it in front of your witnesses. They sign and print their names in their spots.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Type each witness&#39;s full name in the boxes.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">On your phone, press <b class="gd-ui">Take a photo of the signed page</b>: one photo of each page. A PDF scan works too (<b class="gd-ui">Or choose a file</b>).</div></li></ol></div><figure class="gd-fig gd-fig--desk"><div class="gd-browser"><div class="gd-bar" aria-hidden="true"><i></i><i></i><i></i><span class="gd-addr">carmacars.ca/owner/documents</span></div><div class="gd-imgwrap" style="aspect-ratio:1440/742"><img src="/guides/img/owner-12-forms-c-d-desktop-21fbbe79.jpg" alt="" loading="lazy" decoding="async" width="1440" height="742"><span class="gd-pin" style="left:21.5%;top:32.5%" aria-hidden="true">1</span><span class="gd-pin" style="left:69.4%;top:50.7%" aria-hidden="true">3</span><span class="gd-pin" style="left:69.4%;top:60.4%" aria-hidden="true">4</span></div></div></figure></div><aside class="gd-box"><span class="gd-lbl">Tip</span><div>We check the photo and approve it, or send it back with what to fix. You get an email either way, and the page shows the status.</div></aside><aside class="gd-box"><span class="gd-lbl">Good to know</span><div>Why paper for Form D? It is a power of attorney, which cannot be signed electronically in Ontario, and its two witnesses sign in person.</div></aside></section><section class="gd-task" id="documents-and-forms-government-forms-filled-for-you" data-gd-task><h2 class="gd-h2">Government forms filled for you</h2><p class="gd-p">Each car&#39;s registry forms are prepared from your records, only the ones its onboarding method needs (013-1155 and 013-0169, for example, only for a Lease through a new corporation). Until we load the official PDF, you get a data sheet with the values.</p><div class="gd-stepblock gd-stepblock--below"><div class="gd-stepcol"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Open Documents and choose a form marked &quot;Official form, filled for you&quot;.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Press <b class="gd-ui">Download the filled form</b> and check each value.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Print it and sign it in ink. It is the official ServiceOntario form exactly as ServiceOntario publishes it, with only its empty text boxes filled in. Its boxes to tick and its signatures are done by hand, at the registry office or before you go, as we tell you.</div></li></ol></div><figure class="gd-fig gd-fig--desk"><div class="gd-browser"><div class="gd-bar" aria-hidden="true"><i></i><i></i><i></i><span class="gd-addr">carmacars.ca/owner/documents/forms/4d54a524-c28d-4bc4-8ad3-dd9558100a81/official</span></div><div class="gd-imgwrap" style="aspect-ratio:1440/732"><img src="/guides/img/owner-13-official-form-desktop-48614913.jpg" alt="" loading="lazy" decoding="async" width="1440" height="732"><span class="gd-pin" style="left:22.2%;top:29.5%" aria-hidden="true">2</span></div></div></figure></div><aside class="gd-box"><span class="gd-lbl">Good to know</span><div>ON00453 (a company&#39;s registrant number) is an Adobe form: open it in Adobe Acrobat Reader (free) to see and print it. Other PDF viewers show a blank page, as they do with the form downloaded from ServiceOntario.</div></aside><aside class="gd-box gd-box--warn"><span class="gd-lbl">Watch out</span><div>Official registry forms are never signed on screen. You pay ServiceOntario, the inspection station and the appraiser directly.</div></aside></section>');
select app.guide_release_section('admin', 'settings', 'chapter', 'search-car-pages-landing-pages-and-guides', 'Settings change the public site and the rules of the program at once. Program settings are kept as dated rows, so earlier values stay on record.

## The Settings page

1. Site setup lists what is still missing on the public site, with **Open site settings**.
2. Site settings: contact details, hours, tagline, logo, socials, Google place id and featured cars.
3. Program settings: every timing and policy value.
4. Forms: Blind Spot''s rental agreement for every booking, and the official ServiceOntario PDFs and what goes in each field.
5. Insurers: insurance companies billed for bookings.

![](/guides/img/admin-24-settings-desktop-89b31691.jpg "desktop; size: 1440 900; address: carmacars.ca/admin/settings; pins: 1 32.6 33.0, 2 25.8 40.2, 3 77.4 40.2, 4 25.8 73.2, 5 25.8 84.9")

The other tiles: Site content (headings, FAQs, legal text), Fee defaults, Deposit tiers, Kilometre choices, Vehicle classes, Vehicle class rules, Airports and delivery, Protection Plan prices, Card coverage, Reviews, Text alerts, Partners (each partner company''s CRM link: see Partners, company cars and rentals added by hand), Email aliases and reply-to, Staff and roles, Promo codes and Quick replies.

## Program settings

1. Turnaround between trips: the time held between two trips. The cleaning block after a trip is this time.
2. Settings come in groups such as Company, Booking requests and offers, Owner debits and statement emails, Deposits, Delivery, Owners and fleet, and Tolls and damage. Open one to see its fields.
3. First reply target for customer service and sales (minutes), under Booking requests and offers: 5 by default. New booking requests, enquiries, changes renters ask for and renter messages are due that many minutes after they come in; the scorecard and the staff screens use it. What renters are told (Reply wording, in Site settings) is separate.
4. Staff commissions and prices typed by hand: the commission outside Sales (10%), the three Sales tiers and their days (10%, 15% from 50 days, 20% from 100 days, the month''s target), the price floor a day (empty: none) and the discount from the rate sheet that flags a price (20%). The owner confirmed these values in October 2026. The remote Sales values follow: the three remote tiers (5%, 10%, 15%), the touches a month (400), the drop under it (one tier) and its floor (2.5%), the peak hours a week (20), the reply target (15 minutes) and the peak hours (noon to 6 pm, Thursday to Sunday).
5. Staff agreement defaults by function, at the bottom: pay (a month, an hour or commission only), the rate, the schedule (full time, part time or flexible), days a week and hours a day for Customer service, Fleet, Finance and Sales, the values every assistant shares, and the field staff wage. Sales is commission only: no rate and a flexible schedule. Press **Save the defaults**.
6. Live visitors and live chat: recording visits, the signal thresholds, follow-up tasks, the chat and its assistant, and how long visits and chats are kept.
7. Discount games: the same values as Settings, Discount games (the prize table and the games are easier to change there).
8. Deposits: the toll and ticket window after the return (7 days: settling sooner suggests a hold-back), the longest hold-back (30 days after the return), how long before a card hold lapses it is collected (36 hours), and collecting what is owed after the deposit by itself (the card on file, then a pay link, then a Finance task). A deposit is never released by itself.
9. Field jobs and handovers: field jobs made from each confirmed booking (on) and who gets them (the least busy field staff member, or nobody so Fleet assigns), how field staff may take a deposit at the check-out besides a card (e-Transfer and cash), and whether they may release a car whose tracker is not reporting, with a reason (on; you get an urgent task). Field pay: the first day of a pay period (every period is two weeks), the default hourly rate (CA$18.00), whether overtime is paid (off), after how many hours in a week (44) and at what share of the rate (150%), vacation pay added to each statement (off; Ontario 4%) and the longest shift (16 hours).
10. Sign-in by phone: codes by text from the CarmaCars number (on), US numbers (off until the Quo number is registered for US texting, A2P 10DLC), codes per number and per connection an hour, and whether a verified phone confirms an account like a confirmed email. Accepting an offer, signing and paying need a confirmed account; an account made by phone gives its email on the pay page before its first payment.
11. Calendar sync, Turo by email, Booking recovery emails and Site check: how often calendar links are read, the Turo inbound address and who may forward to it, the reminder delays and sending hours, and the site check with the address its alerts go to (rent@carmacars.ca), the minutes before an email, the daily limit and the quiet hours.
12. Change a value and press **Save**. It is saved as a new row from today; the rows before stay as they were.

![](/guides/img/admin-25-program-settings-desktop-d16b066c.jpg "desktop; size: 1440 1000; address: carmacars.ca/admin/settings/program; pins: 1 25.8 22.0, 2 27.8 49.0")

## Vehicle class rules

Open **Settings**, then **Vehicle class rules**. How a new car''s class is decided from its VIN: the first rule that matches wins.

1. The table lists each rule: its rank, what the car must be (a make, and patterns for the model, the trim and the body), the class it gets, the class once the car is old enough, a note and whether it is on. The lowest rank that matches is used; a car that matches no rule is Standard.
2. Press **Add a rule** or **Change**: a rank, at least one condition, the class, optionally the years old after which an older class applies, and a note (it is shown as the reason for the class). A pattern is not case sensitive: ^911 matches models that start with 911. A rule with no condition, a pattern that does not compile and an older class equal to the class are refused.
3. **Try a car** gives the class the rules decide for a year, make, model, trim and body, and why.
4. **Delete** removes a rule; switch it off instead to keep it. Every add, change and delete is in the audit log, with before and after.

> Tip: A rule changes the cars entered from then on. A car already listed keeps its class until you change it on the car.

## Official ServiceOntario forms

The five official forms are loaded with a mapping to the owner, car, company and lender details. Each is the form exactly as ServiceOntario publishes it: only its empty text boxes are filled. Its checkboxes, drop-downs and signatures are done by hand at the counter, in ink. Until you check a form, owners get a data sheet with the values.

1. Open **Settings** > **Forms**. Each form shows "Mapping to check" (a draft is ready) or "Official PDF in use". Its notes say what the form is for and which boxes are left blank on purpose.
2. Press **Download a filled preview** for one car and check each value against the form.
3. Change a field if needed: What goes in it (or "Signed here by hand, in ink"), a Format (for example YYYY/MM/DD) and Only when. Press Save the mapping.
4. Press **Checked: use for owners**. Every owner''s form of that kind is filled again, except ones already signed or filed. Owners download it, print it and sign it in ink; record it with **Record paper signature**. Each form not checked yet is also a line on To do with the same button and Preview it.
5. A new version from ServiceOntario? Press **Upload the official fillable PDF**: the fields of the same name keep their mapping.

> Good to know: SR-LV-006 (registration), SR-LV-012 (two registrants), ON00453 (a company''s RIN), 013-1155 and 013-0169 (the tax-exempt transfer into an owner''s corporation). 013-1155 is sworn before a commissioner, so it is printed and signed in person. ON00453 is an Adobe form: it opens in Adobe Acrobat Reader. Each form''s notes list what to tick or choose at the counter.

## Blind Spot rental agreement

We rent under Blind Spot Car Rental''s insurance, so every booking has two agreements: CarmaCars'' rental agreement and Blind Spot''s own. Blind Spot''s is filled in from the booking, the renter and the car, and the renter signs both with one signature. Its PDF is stored privately, never on the website.

1. Open **Settings** > **Forms**. The Blind Spot Car Rental agreement card is first. Press **Upload Blind Spot''s PDF** and choose Blind Spot''s blank form (2 pages, A4).
2. Press **Download the filled sample**: a made-up booking on the form. **Sample billed to an insurer** also fills the claim number, the adjuster and the insurance company. Check every box.
3. On the form the old address (top left and twice in box 15) is replaced by the mailing address of Site settings, box 1 by CarmaCars'' HST number (Program settings, Company HST number; blank until it is entered), and box 21 has the representative''s signature instead of Sam''s.
4. Press **Checked: use for bookings**. From then on each booking gets it when its rental agreement is made; a renter whose agreement is already open gets it the next time they open the signing page.
5. Box 21: Ahmad is written in a script hand, as Blind Spot asked. To use a real signature instead, upload a PNG under Authorized company representative; Remove the image goes back to the written name. Full name is for the signature record page.
6. A new version of Blind Spot''s form? Upload it the same way: it waits for **Checked: use for bookings**, and bookings keep the version in use until then.

> Good to know: Each box is filled only when the booking has the value: the renter and their licence, the additional drivers, the car (plate, make and model, the fleet number as vehicle number), the pickup as time and date out, the due-back date and time, the kilometres allowed, the daily rate and the rental charge, the underage fee, the Protection Plan as CDW, winter tires, the subtotal, HST, total and deposit, and for a booking billed to an insurer the insurer, claim number and adjuster. Other charges, such as delivery, are listed in box 14. Initials, fuel and the boxes filled at return stay blank.

The renter''s signature goes in boxes 16, 17 and 20 of the signed copy, with a signature record page. Both agreements are in the booking''s Drivers and documents tab, in the renter''s Documents, and the signed Blind Spot agreement is attached to the "Your signed rental agreement" email. Admin > Today lists the HST number, the upload and the check until they are done.

## Agreements to sign: investors and staff

Investment agreements and staff agreements are made from the person''s record and signed in their own portal, or on paper.

1. Investor: open **People** > **Investors** and the investor. Under Investment agreement, press **Send the agreement to sign**. Check the values it is filled with (amount, yearly percentage, dates, exemption) and press **Send to sign**.
2. Once the investor signs, the agreement shows **Awaiting countersignature** on the investor''s page and on To do. It is not countersigned automatically: check it and press **Countersign**. CarmaCars is bound once it has countersigned and the funds clear.
3. Staff: open **People** > **Staff**. Under Staff agreements, press **Send the agreement to sign** beside the person. Pay, schedule, hours and the other values start from the staff profile and the defaults of their function in Program settings; change any before sending. For Sales the Pay is Commission only: the agreement then has no rate, schedule or hours, and pays the commission of section 3.4.
4. A field staff member''s agreement prints the home address they entered themselves. Staff enter their home address at their first sign-in, before they sign, or in their profile.
5. They get a notice, check the key values and sign in their portal in a few taps (their name is the signature, or they draw it). The signed copy is filed with their documents.
6. Your own PDF instead? **Send a PDF to sign** still works.
7. Signed on paper instead? Press **Record paper signature** in the same place and upload the scan.
8. Sent by mistake? Press **Withdraw** and give the reason.

## The user guides

**Settings** > **Guides**. The guide of each portal, as people read it under Guide.

1. Each guide shows its version, when it was published and whether there are unpublished changes.
2. Open a guide and press a section. Change its text and press **Show the preview** to see it as people will. Press **Save the draft**; each save is kept in the section''s history.
3. Move a section with the arrows, hide it, or press **Add a chapter**. Upload a screenshot under Screenshots and paste the line it gives you.
4. Press **Publish version** (the next number). The portals show the new version at once.
5. The stored PDF is printed again by the guides-pdf workflow. Until then the guide says the web guide has newer edits.

## The guides keep up by themselves

After every update of the site that changes the portals, the guides are checked without anyone asking.

1. Every screenshot is taken again on the new version of the site. One whose screen changed replaces the old one in the guide.
2. The text of each section whose screen changed, or that names a button the portals no longer show, is rewritten from the portal''s own labels and menu, checked, and published. The PDFs of those guides are printed again.
3. Such a section says **Changed automatically on** and the date, in the list of guides and in the guide''s editor. Not right? Open the section and press **Revert**: the text it replaced comes back, published at once.
4. This includes sections you edited: the newest automatic text is published, and every earlier version stays in the section''s history. There is nothing to review.
5. A rewrite that does not pass the checks is asked again, more strictly. If it still does not pass, the screenshots and button names are updated, the rest of the text stays as it was, and the next run tries again.

> Tip: The card "The guides keep up by themselves" at the top of Guides lists the last runs: when, how many screenshots were replaced, how many sections were rewritten, and how many PDFs were printed.

## Insurers and the other lists

1. Open Insurers. Each insurer on file opens to edit its billing contact, email, phone, address and notes. Its rates by car class are in **Money** > **Insurer rates**.
2. To add one, fill in the Add form (Name, Billing contact, Billing email and the rest) and press **Add**.
3. Deposit tiers, Kilometre choices, Vehicle classes, Airports, Promo codes and Quick replies work the same way.

## Promo codes: end dates and reminders

**Settings** > **All settings**, **Promo codes**.

- Every code made for a person has an end date: a game prize 7 days, a come-back offer 30, a Live visitors code 3 and a code made for one renter 30 unless you set another. The first card of Promo codes holds the 30 days and the two reminders.
- A code for everyone may have no end date: empty Valid until. The Add form starts with an end date 30 days ahead.
- A code that ended is refused wherever it is typed (the request form, an offer, Add a rental, a booking edit) with "This code has expired".
- A person who has not used a code is reminded 3 days before its last day and the day before, by email and by text as they chose, never once they used it, unsubscribed or the code ended, and never twice. A game code reminder always goes; a reminder of any other code needs their consent to offers.
- The list shows each code''s end date and the reminders sent. The card Codes sent to people lists game prizes, come-back offers and Live visitors codes the same way.

## Card coverage: which credit cards include rental car coverage

**Settings** > **Card coverage** is the list renters see at `carmacars.ca/credit-card-rental-coverage` and staff see under Card coverage in their portal. It starts filled in with 48 Canadian and US cards, each checked on October 23, 2026.

1. The table shows each card: who pays first (Primary, Secondary, or not stated), the car value limit (MSRP), the longest rental, whether the numbers were read in the issuer''s own document, and when it was last checked.
2. Open a card under Change a card, open its official guide, correct what changed and press **Save**. Changing the facts without a date marks the card checked today; type a Last checked date to record another day.
3. A card whose numbers come from a published summary has Read in the issuer''s own document unticked and the summary''s link under Where the numbers came from. The page shows it as Unverified. Tick it once you have read the issuer''s guide.
4. Add a card with the Add form; untick Shown to hide one. Changes reach the public page at once.

> Tip: A card not checked for 6 months shows on Today until it is checked again. The page tells renters to confirm with their card issuer and says CarmaCars decides no claims: keep the list to facts from the issuer''s guide.

## Reviews: review requests and Google

**Settings** > **Reviews**: when review requests go, the Google review link and the Google Business Profile connection. Review requests are on from the start.

1. When review requests go: the check-in (on or off, the shortest rental, hours after the pickup), the request (minutes after the check-in), the reminder (hours) and the final follow-up (days), the sending hours (9 am to 9 pm), and the hold while charges are open.
2. The Google review link: the Google place id (Site settings) makes it, or paste the Business Profile''s own review link.
3. Google Business Profile: press **Connect Google** and sign in with rent@carmacars.ca, then allow access. Reviews are read every 6 hours and matched to renters by name within 30 days after their return.
4. A clear match stops that renter''s reminders at once. A possible match waits in Reviews: press **Confirm**, **Not this renter** or **Match to a booking**.

> Tip: Until Google approves the Business Profile API for the project, the status says so and nothing else changes: renters still get the review link, and "I already left a review", Mark reviewed and on-site reviews still stop the messages.
', 'Settings', 'Site, program settings, official forms mapping, insurers and the other lists.',
  'Settings change the public site and the rules of the program at once. Program settings are kept as dated rows, so earlier values stay on record.

## The Settings page

1. Site setup lists what is still missing on the public site, with **Open site settings**.
2. Site settings: contact details, hours, tagline, logo, socials, Google place id and featured cars.
3. Program settings: every timing and policy value.
4. Forms: Blind Spot''s rental agreement for every booking, and the official ServiceOntario PDFs and what goes in each field.
5. Insurers: insurance companies billed for bookings.

![](/guides/img/admin-24-settings-desktop-89b31691.jpg "desktop; size: 1440 900; address: carmacars.ca/admin/settings; pins: 1 32.6 33.0, 2 25.8 40.2, 3 77.4 40.2, 4 25.8 73.2, 5 25.8 84.9")

The other tiles: Site content (headings, FAQs, legal text), Fee defaults, Deposit tiers, Kilometre choices, Vehicle classes, Vehicle class rules, Airports and delivery, Protection Plan prices, Card coverage, Reviews, Text alerts, Partners (each partner company''s CRM link: see Partners, company cars and rentals added by hand), Email aliases and reply-to, Staff and roles, Promo codes and Quick replies.

## Program settings

1. Turnaround between trips: the time held between two trips. The cleaning block after a trip is this time.
2. Settings come in groups such as Company, Booking requests and offers, Owner debits and statement emails, Deposits, Delivery, Owners and fleet, and Tolls and damage. Open one to see its fields.
3. First reply target for customer service and sales (minutes), under Booking requests and offers: 5 by default. New booking requests, enquiries, changes renters ask for and renter messages are due that many minutes after they come in; the scorecard and the staff screens use it. What renters are told (Reply wording, in Site settings) is separate.
4. Staff commissions and prices typed by hand: the commission outside Sales (10%), the three Sales tiers and their days (10%, 15% from 50 days, 20% from 100 days, the month''s target), the price floor a day (empty: none) and the discount from the rate sheet that flags a price (20%). The owner confirmed these values in October 2026. The remote Sales values follow: the three remote tiers (5%, 10%, 15%), the touches a month (400), the drop under it (one tier) and its floor (2.5%), the peak hours a week (20), the reply target (15 minutes) and the peak hours (noon to 6 pm, Thursday to Sunday).
5. Staff agreement defaults by function, at the bottom: pay (a month, an hour or commission only), the rate, the schedule (full time, part time or flexible), days a week and hours a day for Customer service, Fleet, Finance and Sales, the values every assistant shares, and the field staff wage. Sales is commission only: no rate and a flexible schedule. Press **Save the defaults**.
6. Live visitors and live chat: recording visits, the signal thresholds, follow-up tasks, the chat and its assistant, and how long visits and chats are kept.
7. Discount games: the same values as Settings, Discount games (the prize table and the games are easier to change there).
8. Deposits: the toll and ticket window after the return (7 days: settling sooner suggests a hold-back), the longest hold-back (30 days after the return), how long before a card hold lapses it is collected (36 hours), and collecting what is owed after the deposit by itself (the card on file, then a pay link, then a Finance task). A deposit is never released by itself.
9. Field jobs and handovers: field jobs made from each confirmed booking (on) and who gets them (the least busy field staff member, or nobody so Fleet assigns), how field staff may take a deposit at the check-out besides a card (e-Transfer and cash), and whether they may release a car whose tracker is not reporting, with a reason (on; you get an urgent task). Field pay: the first day of a pay period (every period is two weeks), the default hourly rate (CA$18.00), whether overtime is paid (off), after how many hours in a week (44) and at what share of the rate (150%), vacation pay added to each statement (off; Ontario 4%) and the longest shift (16 hours).
10. Sign-in by phone: codes by text from the CarmaCars number (on), US numbers (off until the Quo number is registered for US texting, A2P 10DLC), codes per number and per connection an hour, and whether a verified phone confirms an account like a confirmed email. Accepting an offer, signing and paying need a confirmed account; an account made by phone gives its email on the pay page before its first payment.
11. Calendar sync, Turo by email, Booking recovery emails and Site check: how often calendar links are read, the Turo inbound address and who may forward to it, the reminder delays and sending hours, and the site check with the address its alerts go to (rent@carmacars.ca), the minutes before an email, the daily limit and the quiet hours.
12. Change a value and press **Save**. It is saved as a new row from today; the rows before stay as they were.

![](/guides/img/admin-25-program-settings-desktop-d16b066c.jpg "desktop; size: 1440 1000; address: carmacars.ca/admin/settings/program; pins: 1 25.8 22.0, 2 27.8 49.0")

## Vehicle class rules

Open **Settings**, then **Vehicle class rules**. How a new car''s class is decided from its VIN: the first rule that matches wins.

1. The table lists each rule: its rank, what the car must be (a make, and patterns for the model, the trim and the body), the class it gets, the class once the car is old enough, a note and whether it is on. The lowest rank that matches is used; a car that matches no rule is Standard.
2. Press **Add a rule** or **Change**: a rank, at least one condition, the class, optionally the years old after which an older class applies, and a note (it is shown as the reason for the class). A pattern is not case sensitive: ^911 matches models that start with 911. A rule with no condition, a pattern that does not compile and an older class equal to the class are refused.
3. **Try a car** gives the class the rules decide for a year, make, model, trim and body, and why.
4. **Delete** removes a rule; switch it off instead to keep it. Every add, change and delete is in the audit log, with before and after.

> Tip: A rule changes the cars entered from then on. A car already listed keeps its class until you change it on the car.

## Official ServiceOntario forms

The five official forms are loaded with a mapping to the owner, car, company and lender details. Each is the form exactly as ServiceOntario publishes it: only its empty text boxes are filled. Its checkboxes, drop-downs and signatures are done by hand at the counter, in ink. Until you check a form, owners get a data sheet with the values.

1. Open **Settings** > **Forms**. Each form shows "Mapping to check" (a draft is ready) or "Official PDF in use". Its notes say what the form is for and which boxes are left blank on purpose.
2. Press **Download a filled preview** for one car and check each value against the form.
3. Change a field if needed: What goes in it (or "Signed here by hand, in ink"), a Format (for example YYYY/MM/DD) and Only when. Press Save the mapping.
4. Press **Checked: use for owners**. Every owner''s form of that kind is filled again, except ones already signed or filed. Owners download it, print it and sign it in ink; record it with **Record paper signature**. Each form not checked yet is also a line on To do with the same button and Preview it.
5. A new version from ServiceOntario? Press **Upload the official fillable PDF**: the fields of the same name keep their mapping.

> Good to know: SR-LV-006 (registration), SR-LV-012 (two registrants), ON00453 (a company''s RIN), 013-1155 and 013-0169 (the tax-exempt transfer into an owner''s corporation). 013-1155 is sworn before a commissioner, so it is printed and signed in person. ON00453 is an Adobe form: it opens in Adobe Acrobat Reader. Each form''s notes list what to tick or choose at the counter. A car gets only the forms its onboarding method needs: no form for a Transfer of a car owned outright or financed (the sign-back on the permit), 013-1155 and 013-0169 only for a Lease through a new Owner Corporation.

## Blind Spot rental agreement

We rent under Blind Spot Car Rental''s insurance, so every booking has two agreements: CarmaCars'' rental agreement and Blind Spot''s own. Blind Spot''s is filled in from the booking, the renter and the car, and the renter signs both with one signature. Its PDF is stored privately, never on the website.

1. Open **Settings** > **Forms**. The Blind Spot Car Rental agreement card is first. Press **Upload Blind Spot''s PDF** and choose Blind Spot''s blank form (2 pages, A4).
2. Press **Download the filled sample**: a made-up booking on the form. **Sample billed to an insurer** also fills the claim number, the adjuster and the insurance company. Check every box.
3. On the form the old address (top left and twice in box 15) is replaced by the mailing address of Site settings, box 1 by CarmaCars'' HST number (Program settings, Company HST number; blank until it is entered), and box 21 has the representative''s signature instead of Sam''s.
4. Press **Checked: use for bookings**. From then on each booking gets it when its rental agreement is made; a renter whose agreement is already open gets it the next time they open the signing page.
5. Box 21: Ahmad is written in a script hand, as Blind Spot asked. To use a real signature instead, upload a PNG under Authorized company representative; Remove the image goes back to the written name. Full name is for the signature record page.
6. A new version of Blind Spot''s form? Upload it the same way: it waits for **Checked: use for bookings**, and bookings keep the version in use until then.

> Good to know: Each box is filled only when the booking has the value: the renter and their licence, the additional drivers, the car (plate, make and model, the fleet number as vehicle number), the pickup as time and date out, the due-back date and time, the kilometres allowed, the daily rate and the rental charge, the underage fee, the Protection Plan as CDW, winter tires, the subtotal, HST, total and deposit, and for a booking billed to an insurer the insurer, claim number and adjuster. Other charges, such as delivery, are listed in box 14. Initials, fuel and the boxes filled at return stay blank.

The renter''s signature goes in boxes 16, 17 and 20 of the signed copy, with a signature record page. Both agreements are in the booking''s Drivers and documents tab, in the renter''s Documents, and the signed Blind Spot agreement is attached to the "Your signed rental agreement" email. Admin > Today lists the HST number, the upload and the check until they are done.

## Agreements to sign: investors and staff

Investment agreements and staff agreements are made from the person''s record and signed in their own portal, or on paper.

1. Investor: open **People** > **Investors** and the investor. Under Investment agreement, press **Send the agreement to sign**. Check the values it is filled with (amount, yearly percentage, dates, exemption) and press **Send to sign**.
2. Once the investor signs, the agreement shows **Awaiting countersignature** on the investor''s page and on To do. It is not countersigned automatically: check it and press **Countersign**. CarmaCars is bound once it has countersigned and the funds clear.
3. Staff: open **People** > **Staff**. Under Staff agreements, press **Send the agreement to sign** beside the person. Pay, schedule, hours and the other values start from the staff profile and the defaults of their function in Program settings; change any before sending. For Sales the Pay is Commission only: the agreement then has no rate, schedule or hours, and pays the commission of section 3.4.
4. A field staff member''s agreement prints the home address they entered themselves. Staff enter their home address at their first sign-in, before they sign, or in their profile.
5. They get a notice, check the key values and sign in their portal in a few taps (their name is the signature, or they draw it). The signed copy is filed with their documents.
6. Your own PDF instead? **Send a PDF to sign** still works.
7. Signed on paper instead? Press **Record paper signature** in the same place and upload the scan.
8. Sent by mistake? Press **Withdraw** and give the reason.

## The user guides

**Settings** > **Guides**. The guide of each portal, as people read it under Guide.

1. Each guide shows its version, when it was published and whether there are unpublished changes.
2. Open a guide and press a section. Change its text and press **Show the preview** to see it as people will. Press **Save the draft**; each save is kept in the section''s history.
3. Move a section with the arrows, hide it, or press **Add a chapter**. Upload a screenshot under Screenshots and paste the line it gives you.
4. Press **Publish version** (the next number). The portals show the new version at once.
5. The stored PDF is printed again by the guides-pdf workflow. Until then the guide says the web guide has newer edits.

## The guides keep up by themselves

After every update of the site that changes the portals, the guides are checked without anyone asking.

1. Every screenshot is taken again on the new version of the site. One whose screen changed replaces the old one in the guide.
2. The text of each section whose screen changed, or that names a button the portals no longer show, is rewritten from the portal''s own labels and menu, checked, and published. The PDFs of those guides are printed again.
3. Such a section says **Changed automatically on** and the date, in the list of guides and in the guide''s editor. Not right? Open the section and press **Revert**: the text it replaced comes back, published at once.
4. This includes sections you edited: the newest automatic text is published, and every earlier version stays in the section''s history. There is nothing to review.
5. A rewrite that does not pass the checks is asked again, more strictly. If it still does not pass, the screenshots and button names are updated, the rest of the text stays as it was, and the next run tries again.

> Tip: The card "The guides keep up by themselves" at the top of Guides lists the last runs: when, how many screenshots were replaced, how many sections were rewritten, and how many PDFs were printed.

## Insurers and the other lists

1. Open Insurers. Each insurer on file opens to edit its billing contact, email, phone, address and notes. Its rates by car class are in **Money** > **Insurer rates**.
2. To add one, fill in the Add form (Name, Billing contact, Billing email and the rest) and press **Add**.
3. Deposit tiers, Kilometre choices, Vehicle classes, Airports, Promo codes and Quick replies work the same way.

## Promo codes: end dates and reminders

**Settings** > **All settings**, **Promo codes**.

- Every code made for a person has an end date: a game prize 7 days, a come-back offer 30, a Live visitors code 3 and a code made for one renter 30 unless you set another. The first card of Promo codes holds the 30 days and the two reminders.
- A code for everyone may have no end date: empty Valid until. The Add form starts with an end date 30 days ahead.
- A code that ended is refused wherever it is typed (the request form, an offer, Add a rental, a booking edit) with "This code has expired".
- A person who has not used a code is reminded 3 days before its last day and the day before, by email and by text as they chose, never once they used it, unsubscribed or the code ended, and never twice. A game code reminder always goes; a reminder of any other code needs their consent to offers.
- The list shows each code''s end date and the reminders sent. The card Codes sent to people lists game prizes, come-back offers and Live visitors codes the same way.

## Card coverage: which credit cards include rental car coverage

**Settings** > **Card coverage** is the list renters see at `carmacars.ca/credit-card-rental-coverage` and staff see under Card coverage in their portal. It starts filled in with 48 Canadian and US cards, each checked on October 23, 2026.

1. The table shows each card: who pays first (Primary, Secondary, or not stated), the car value limit (MSRP), the longest rental, whether the numbers were read in the issuer''s own document, and when it was last checked.
2. Open a card under Change a card, open its official guide, correct what changed and press **Save**. Changing the facts without a date marks the card checked today; type a Last checked date to record another day.
3. A card whose numbers come from a published summary has Read in the issuer''s own document unticked and the summary''s link under Where the numbers came from. The page shows it as Unverified. Tick it once you have read the issuer''s guide.
4. Add a card with the Add form; untick Shown to hide one. Changes reach the public page at once.

> Tip: A card not checked for 6 months shows on Today until it is checked again. The page tells renters to confirm with their card issuer and says CarmaCars decides no claims: keep the list to facts from the issuer''s guide.

## Reviews: review requests and Google

**Settings** > **Reviews**: when review requests go, the Google review link and the Google Business Profile connection. Review requests are on from the start.

1. When review requests go: the check-in (on or off, the shortest rental, hours after the pickup), the request (minutes after the check-in), the reminder (hours) and the final follow-up (days), the sending hours (9 am to 9 pm), and the hold while charges are open.
2. The Google review link: the Google place id (Site settings) makes it, or paste the Business Profile''s own review link.
3. Google Business Profile: press **Connect Google** and sign in with rent@carmacars.ca, then allow access. Reviews are read every 6 hours and matched to renters by name within 30 days after their return.
4. A clear match stops that renter''s reminders at once. A possible match waits in Reviews: press **Confirm**, **Not this renter** or **Match to a booking**.

> Tip: Until Google approves the Business Profile API for the project, the status says so and nothing else changes: renters still get the review link, and "I already left a review", Mark reviewed and on-site reviews still stop the messages.
',
  '<p class="gd-p">Settings change the public site and the rules of the program at once. Program settings are kept as dated rows, so earlier values stay on record.</p><section class="gd-task" id="settings-the-settings-page" data-gd-task><h2 class="gd-h2">The Settings page</h2><div class="gd-stepblock gd-stepblock--below"><div class="gd-stepcol"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Site setup lists what is still missing on the public site, with <b class="gd-ui">Open site settings</b>.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Site settings: contact details, hours, tagline, logo, socials, Google place id and featured cars.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Program settings: every timing and policy value.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">Forms: Blind Spot&#39;s rental agreement for every booking, and the official ServiceOntario PDFs and what goes in each field.</div></li><li><span class="gd-n" aria-hidden="true">5</span><div class="gd-t">Insurers: insurance companies billed for bookings.</div></li></ol></div><figure class="gd-fig gd-fig--desk"><div class="gd-browser"><div class="gd-bar" aria-hidden="true"><i></i><i></i><i></i><span class="gd-addr">carmacars.ca/admin/settings</span></div><div class="gd-imgwrap" style="aspect-ratio:1440/900"><img src="/guides/img/admin-24-settings-desktop-89b31691.jpg" alt="" loading="lazy" decoding="async" width="1440" height="900"><span class="gd-pin" style="left:32.6%;top:33%" aria-hidden="true">1</span><span class="gd-pin" style="left:25.8%;top:40.2%" aria-hidden="true">2</span><span class="gd-pin" style="left:77.4%;top:40.2%" aria-hidden="true">3</span><span class="gd-pin" style="left:25.8%;top:73.2%" aria-hidden="true">4</span><span class="gd-pin" style="left:25.8%;top:84.9%" aria-hidden="true">5</span></div></div></figure></div><p class="gd-p">The other tiles: Site content (headings, FAQs, legal text), Fee defaults, Deposit tiers, Kilometre choices, Vehicle classes, Vehicle class rules, Airports and delivery, Protection Plan prices, Card coverage, Reviews, Text alerts, Partners (each partner company&#39;s CRM link: see Partners, company cars and rentals added by hand), Email aliases and reply-to, Staff and roles, Promo codes and Quick replies.</p></section><section class="gd-task" id="settings-program-settings" data-gd-task><h2 class="gd-h2">Program settings</h2><div class="gd-stepblock gd-stepblock--below"><div class="gd-stepcol"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Turnaround between trips: the time held between two trips. The cleaning block after a trip is this time.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Settings come in groups such as Company, Booking requests and offers, Owner debits and statement emails, Deposits, Delivery, Owners and fleet, and Tolls and damage. Open one to see its fields.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">First reply target for customer service and sales (minutes), under Booking requests and offers: 5 by default. New booking requests, enquiries, changes renters ask for and renter messages are due that many minutes after they come in; the scorecard and the staff screens use it. What renters are told (Reply wording, in Site settings) is separate.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">Staff commissions and prices typed by hand: the commission outside Sales (10%), the three Sales tiers and their days (10%, 15% from 50 days, 20% from 100 days, the month&#39;s target), the price floor a day (empty: none) and the discount from the rate sheet that flags a price (20%). The owner confirmed these values in October 2026. The remote Sales values follow: the three remote tiers (5%, 10%, 15%), the touches a month (400), the drop under it (one tier) and its floor (2.5%), the peak hours a week (20), the reply target (15 minutes) and the peak hours (noon to 6 pm, Thursday to Sunday).</div></li><li><span class="gd-n" aria-hidden="true">5</span><div class="gd-t">Staff agreement defaults by function, at the bottom: pay (a month, an hour or commission only), the rate, the schedule (full time, part time or flexible), days a week and hours a day for Customer service, Fleet, Finance and Sales, the values every assistant shares, and the field staff wage. Sales is commission only: no rate and a flexible schedule. Press <b class="gd-ui">Save the defaults</b>.</div></li><li><span class="gd-n" aria-hidden="true">6</span><div class="gd-t">Live visitors and live chat: recording visits, the signal thresholds, follow-up tasks, the chat and its assistant, and how long visits and chats are kept.</div></li><li><span class="gd-n" aria-hidden="true">7</span><div class="gd-t">Discount games: the same values as Settings, Discount games (the prize table and the games are easier to change there).</div></li><li><span class="gd-n" aria-hidden="true">8</span><div class="gd-t">Deposits: the toll and ticket window after the return (7 days: settling sooner suggests a hold-back), the longest hold-back (30 days after the return), how long before a card hold lapses it is collected (36 hours), and collecting what is owed after the deposit by itself (the card on file, then a pay link, then a Finance task). A deposit is never released by itself.</div></li><li><span class="gd-n" aria-hidden="true">9</span><div class="gd-t">Field jobs and handovers: field jobs made from each confirmed booking (on) and who gets them (the least busy field staff member, or nobody so Fleet assigns), how field staff may take a deposit at the check-out besides a card (e-Transfer and cash), and whether they may release a car whose tracker is not reporting, with a reason (on; you get an urgent task). Field pay: the first day of a pay period (every period is two weeks), the default hourly rate (CA$18.00), whether overtime is paid (off), after how many hours in a week (44) and at what share of the rate (150%), vacation pay added to each statement (off; Ontario 4%) and the longest shift (16 hours).</div></li><li><span class="gd-n" aria-hidden="true">10</span><div class="gd-t">Sign-in by phone: codes by text from the CarmaCars number (on), US numbers (off until the Quo number is registered for US texting, A2P 10DLC), codes per number and per connection an hour, and whether a verified phone confirms an account like a confirmed email. Accepting an offer, signing and paying need a confirmed account; an account made by phone gives its email on the pay page before its first payment.</div></li><li><span class="gd-n" aria-hidden="true">11</span><div class="gd-t">Calendar sync, Turo by email, Booking recovery emails and Site check: how often calendar links are read, the Turo inbound address and who may forward to it, the reminder delays and sending hours, and the site check with the address its alerts go to (rent@carmacars.ca), the minutes before an email, the daily limit and the quiet hours.</div></li><li><span class="gd-n" aria-hidden="true">12</span><div class="gd-t">Change a value and press <b class="gd-ui">Save</b>. It is saved as a new row from today; the rows before stay as they were.</div></li></ol></div><figure class="gd-fig gd-fig--desk"><div class="gd-browser"><div class="gd-bar" aria-hidden="true"><i></i><i></i><i></i><span class="gd-addr">carmacars.ca/admin/settings/program</span></div><div class="gd-imgwrap" style="aspect-ratio:1440/1000"><img src="/guides/img/admin-25-program-settings-desktop-d16b066c.jpg" alt="" loading="lazy" decoding="async" width="1440" height="1000"><span class="gd-pin" style="left:25.8%;top:22%" aria-hidden="true">1</span><span class="gd-pin" style="left:27.8%;top:49%" aria-hidden="true">2</span></div></div></figure></div></section><section class="gd-task" id="settings-vehicle-class-rules" data-gd-task><h2 class="gd-h2">Vehicle class rules</h2><p class="gd-p">Open <b class="gd-ui">Settings</b>, then <b class="gd-ui">Vehicle class rules</b>. How a new car&#39;s class is decided from its VIN: the first rule that matches wins.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">The table lists each rule: its rank, what the car must be (a make, and patterns for the model, the trim and the body), the class it gets, the class once the car is old enough, a note and whether it is on. The lowest rank that matches is used; a car that matches no rule is Standard.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Press <b class="gd-ui">Add a rule</b> or <b class="gd-ui">Change</b>: a rank, at least one condition, the class, optionally the years old after which an older class applies, and a note (it is shown as the reason for the class). A pattern is not case sensitive: ^911 matches models that start with 911. A rule with no condition, a pattern that does not compile and an older class equal to the class are refused.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t"><b class="gd-ui">Try a car</b> gives the class the rules decide for a year, make, model, trim and body, and why.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t"><b class="gd-ui">Delete</b> removes a rule; switch it off instead to keep it. Every add, change and delete is in the audit log, with before and after.</div></li></ol></div><aside class="gd-box"><span class="gd-lbl">Tip</span><div>A rule changes the cars entered from then on. A car already listed keeps its class until you change it on the car.</div></aside></section><section class="gd-task" id="settings-official-serviceontario-forms" data-gd-task><h2 class="gd-h2">Official ServiceOntario forms</h2><p class="gd-p">The five official forms are loaded with a mapping to the owner, car, company and lender details. Each is the form exactly as ServiceOntario publishes it: only its empty text boxes are filled. Its checkboxes, drop-downs and signatures are done by hand at the counter, in ink. Until you check a form, owners get a data sheet with the values.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Open <b class="gd-ui">Settings</b> &gt; <b class="gd-ui">Forms</b>. Each form shows &quot;Mapping to check&quot; (a draft is ready) or &quot;Official PDF in use&quot;. Its notes say what the form is for and which boxes are left blank on purpose.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Press <b class="gd-ui">Download a filled preview</b> for one car and check each value against the form.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Change a field if needed: What goes in it (or &quot;Signed here by hand, in ink&quot;), a Format (for example YYYY/MM/DD) and Only when. Press Save the mapping.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">Press <b class="gd-ui">Checked: use for owners</b>. Every owner&#39;s form of that kind is filled again, except ones already signed or filed. Owners download it, print it and sign it in ink; record it with <b class="gd-ui">Record paper signature</b>. Each form not checked yet is also a line on To do with the same button and Preview it.</div></li><li><span class="gd-n" aria-hidden="true">5</span><div class="gd-t">A new version from ServiceOntario? Press <b class="gd-ui">Upload the official fillable PDF</b>: the fields of the same name keep their mapping.</div></li></ol></div><aside class="gd-box"><span class="gd-lbl">Good to know</span><div>SR-LV-006 (registration), SR-LV-012 (two registrants), ON00453 (a company&#39;s RIN), 013-1155 and 013-0169 (the tax-exempt transfer into an owner&#39;s corporation). 013-1155 is sworn before a commissioner, so it is printed and signed in person. ON00453 is an Adobe form: it opens in Adobe Acrobat Reader. Each form&#39;s notes list what to tick or choose at the counter. A car gets only the forms its onboarding method needs: no form for a Transfer of a car owned outright or financed (the sign-back on the permit), 013-1155 and 013-0169 only for a Lease through a new Owner Corporation.</div></aside></section><section class="gd-task" id="settings-blind-spot-rental-agreement" data-gd-task><h2 class="gd-h2">Blind Spot rental agreement</h2><p class="gd-p">We rent under Blind Spot Car Rental&#39;s insurance, so every booking has two agreements: CarmaCars&#39; rental agreement and Blind Spot&#39;s own. Blind Spot&#39;s is filled in from the booking, the renter and the car, and the renter signs both with one signature. Its PDF is stored privately, never on the website.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Open <b class="gd-ui">Settings</b> &gt; <b class="gd-ui">Forms</b>. The Blind Spot Car Rental agreement card is first. Press <b class="gd-ui">Upload Blind Spot&#39;s PDF</b> and choose Blind Spot&#39;s blank form (2 pages, A4).</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Press <b class="gd-ui">Download the filled sample</b>: a made-up booking on the form. <b class="gd-ui">Sample billed to an insurer</b> also fills the claim number, the adjuster and the insurance company. Check every box.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">On the form the old address (top left and twice in box 15) is replaced by the mailing address of Site settings, box 1 by CarmaCars&#39; HST number (Program settings, Company HST number; blank until it is entered), and box 21 has the representative&#39;s signature instead of Sam&#39;s.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">Press <b class="gd-ui">Checked: use for bookings</b>. From then on each booking gets it when its rental agreement is made; a renter whose agreement is already open gets it the next time they open the signing page.</div></li><li><span class="gd-n" aria-hidden="true">5</span><div class="gd-t">Box 21: Ahmad is written in a script hand, as Blind Spot asked. To use a real signature instead, upload a PNG under Authorized company representative; Remove the image goes back to the written name. Full name is for the signature record page.</div></li><li><span class="gd-n" aria-hidden="true">6</span><div class="gd-t">A new version of Blind Spot&#39;s form? Upload it the same way: it waits for <b class="gd-ui">Checked: use for bookings</b>, and bookings keep the version in use until then.</div></li></ol></div><aside class="gd-box"><span class="gd-lbl">Good to know</span><div>Each box is filled only when the booking has the value: the renter and their licence, the additional drivers, the car (plate, make and model, the fleet number as vehicle number), the pickup as time and date out, the due-back date and time, the kilometres allowed, the daily rate and the rental charge, the underage fee, the Protection Plan as CDW, winter tires, the subtotal, HST, total and deposit, and for a booking billed to an insurer the insurer, claim number and adjuster. Other charges, such as delivery, are listed in box 14. Initials, fuel and the boxes filled at return stay blank.</div></aside><p class="gd-p">The renter&#39;s signature goes in boxes 16, 17 and 20 of the signed copy, with a signature record page. Both agreements are in the booking&#39;s Drivers and documents tab, in the renter&#39;s Documents, and the signed Blind Spot agreement is attached to the &quot;Your signed rental agreement&quot; email. Admin &gt; Today lists the HST number, the upload and the check until they are done.</p></section><section class="gd-task" id="settings-agreements-to-sign-investors-and-staff" data-gd-task><h2 class="gd-h2">Agreements to sign: investors and staff</h2><p class="gd-p">Investment agreements and staff agreements are made from the person&#39;s record and signed in their own portal, or on paper.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Investor: open <b class="gd-ui">People</b> &gt; <b class="gd-ui">Investors</b> and the investor. Under Investment agreement, press <b class="gd-ui">Send the agreement to sign</b>. Check the values it is filled with (amount, yearly percentage, dates, exemption) and press <b class="gd-ui">Send to sign</b>.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Once the investor signs, the agreement shows <b class="gd-ui">Awaiting countersignature</b> on the investor&#39;s page and on To do. It is not countersigned automatically: check it and press <b class="gd-ui">Countersign</b>. CarmaCars is bound once it has countersigned and the funds clear.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Staff: open <b class="gd-ui">People</b> &gt; <b class="gd-ui">Staff</b>. Under Staff agreements, press <b class="gd-ui">Send the agreement to sign</b> beside the person. Pay, schedule, hours and the other values start from the staff profile and the defaults of their function in Program settings; change any before sending. For Sales the Pay is Commission only: the agreement then has no rate, schedule or hours, and pays the commission of section 3.4.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">A field staff member&#39;s agreement prints the home address they entered themselves. Staff enter their home address at their first sign-in, before they sign, or in their profile.</div></li><li><span class="gd-n" aria-hidden="true">5</span><div class="gd-t">They get a notice, check the key values and sign in their portal in a few taps (their name is the signature, or they draw it). The signed copy is filed with their documents.</div></li><li><span class="gd-n" aria-hidden="true">6</span><div class="gd-t">Your own PDF instead? <b class="gd-ui">Send a PDF to sign</b> still works.</div></li><li><span class="gd-n" aria-hidden="true">7</span><div class="gd-t">Signed on paper instead? Press <b class="gd-ui">Record paper signature</b> in the same place and upload the scan.</div></li><li><span class="gd-n" aria-hidden="true">8</span><div class="gd-t">Sent by mistake? Press <b class="gd-ui">Withdraw</b> and give the reason.</div></li></ol></div></section><section class="gd-task" id="settings-the-user-guides" data-gd-task><h2 class="gd-h2">The user guides</h2><p class="gd-p"><b class="gd-ui">Settings</b> &gt; <b class="gd-ui">Guides</b>. The guide of each portal, as people read it under Guide.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Each guide shows its version, when it was published and whether there are unpublished changes.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Open a guide and press a section. Change its text and press <b class="gd-ui">Show the preview</b> to see it as people will. Press <b class="gd-ui">Save the draft</b>; each save is kept in the section&#39;s history.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Move a section with the arrows, hide it, or press <b class="gd-ui">Add a chapter</b>. Upload a screenshot under Screenshots and paste the line it gives you.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">Press <b class="gd-ui">Publish version</b> (the next number). The portals show the new version at once.</div></li><li><span class="gd-n" aria-hidden="true">5</span><div class="gd-t">The stored PDF is printed again by the guides-pdf workflow. Until then the guide says the web guide has newer edits.</div></li></ol></div></section><section class="gd-task" id="settings-the-guides-keep-up-by-themselves" data-gd-task><h2 class="gd-h2">The guides keep up by themselves</h2><p class="gd-p">After every update of the site that changes the portals, the guides are checked without anyone asking.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Every screenshot is taken again on the new version of the site. One whose screen changed replaces the old one in the guide.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">The text of each section whose screen changed, or that names a button the portals no longer show, is rewritten from the portal&#39;s own labels and menu, checked, and published. The PDFs of those guides are printed again.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Such a section says <b class="gd-ui">Changed automatically on</b> and the date, in the list of guides and in the guide&#39;s editor. Not right? Open the section and press <b class="gd-ui">Revert</b>: the text it replaced comes back, published at once.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">This includes sections you edited: the newest automatic text is published, and every earlier version stays in the section&#39;s history. There is nothing to review.</div></li><li><span class="gd-n" aria-hidden="true">5</span><div class="gd-t">A rewrite that does not pass the checks is asked again, more strictly. If it still does not pass, the screenshots and button names are updated, the rest of the text stays as it was, and the next run tries again.</div></li></ol></div><aside class="gd-box"><span class="gd-lbl">Tip</span><div>The card &quot;The guides keep up by themselves&quot; at the top of Guides lists the last runs: when, how many screenshots were replaced, how many sections were rewritten, and how many PDFs were printed.</div></aside></section><section class="gd-task" id="settings-insurers-and-the-other-lists" data-gd-task><h2 class="gd-h2">Insurers and the other lists</h2><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Open Insurers. Each insurer on file opens to edit its billing contact, email, phone, address and notes. Its rates by car class are in <b class="gd-ui">Money</b> &gt; <b class="gd-ui">Insurer rates</b>.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">To add one, fill in the Add form (Name, Billing contact, Billing email and the rest) and press <b class="gd-ui">Add</b>.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Deposit tiers, Kilometre choices, Vehicle classes, Airports, Promo codes and Quick replies work the same way.</div></li></ol></div></section><section class="gd-task" id="settings-promo-codes-end-dates-and-reminders" data-gd-task><h2 class="gd-h2">Promo codes: end dates and reminders</h2><p class="gd-p"><b class="gd-ui">Settings</b> &gt; <b class="gd-ui">All settings</b>, <b class="gd-ui">Promo codes</b>.</p><ul class="gd-ul"><li>Every code made for a person has an end date: a game prize 7 days, a come-back offer 30, a Live visitors code 3 and a code made for one renter 30 unless you set another. The first card of Promo codes holds the 30 days and the two reminders.</li><li>A code for everyone may have no end date: empty Valid until. The Add form starts with an end date 30 days ahead.</li><li>A code that ended is refused wherever it is typed (the request form, an offer, Add a rental, a booking edit) with &quot;This code has expired&quot;.</li><li>A person who has not used a code is reminded 3 days before its last day and the day before, by email and by text as they chose, never once they used it, unsubscribed or the code ended, and never twice. A game code reminder always goes; a reminder of any other code needs their consent to offers.</li><li>The list shows each code&#39;s end date and the reminders sent. The card Codes sent to people lists game prizes, come-back offers and Live visitors codes the same way.</li></ul></section><section class="gd-task" id="settings-card-coverage-which-credit-cards-include-rental-car-coverage" data-gd-task><h2 class="gd-h2">Card coverage: which credit cards include rental car coverage</h2><p class="gd-p"><b class="gd-ui">Settings</b> &gt; <b class="gd-ui">Card coverage</b> is the list renters see at <span class="gd-url">carmacars.ca/credit-card-rental-coverage</span> and staff see under Card coverage in their portal. It starts filled in with 48 Canadian and US cards, each checked on October 23, 2026.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">The table shows each card: who pays first (Primary, Secondary, or not stated), the car value limit (MSRP), the longest rental, whether the numbers were read in the issuer&#39;s own document, and when it was last checked.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Open a card under Change a card, open its official guide, correct what changed and press <b class="gd-ui">Save</b>. Changing the facts without a date marks the card checked today; type a Last checked date to record another day.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">A card whose numbers come from a published summary has Read in the issuer&#39;s own document unticked and the summary&#39;s link under Where the numbers came from. The page shows it as Unverified. Tick it once you have read the issuer&#39;s guide.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">Add a card with the Add form; untick Shown to hide one. Changes reach the public page at once.</div></li></ol></div><aside class="gd-box"><span class="gd-lbl">Tip</span><div>A card not checked for 6 months shows on Today until it is checked again. The page tells renters to confirm with their card issuer and says CarmaCars decides no claims: keep the list to facts from the issuer&#39;s guide.</div></aside></section><section class="gd-task" id="settings-reviews-review-requests-and-google" data-gd-task><h2 class="gd-h2">Reviews: review requests and Google</h2><p class="gd-p"><b class="gd-ui">Settings</b> &gt; <b class="gd-ui">Reviews</b>: when review requests go, the Google review link and the Google Business Profile connection. Review requests are on from the start.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">When review requests go: the check-in (on or off, the shortest rental, hours after the pickup), the request (minutes after the check-in), the reminder (hours) and the final follow-up (days), the sending hours (9 am to 9 pm), and the hold while charges are open.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">The Google review link: the Google place id (Site settings) makes it, or paste the Business Profile&#39;s own review link.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Google Business Profile: press <b class="gd-ui">Connect Google</b> and sign in with rent@carmacars.ca, then allow access. Reviews are read every 6 hours and matched to renters by name within 30 days after their return.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">A clear match stops that renter&#39;s reminders at once. A possible match waits in Reviews: press <b class="gd-ui">Confirm</b>, <b class="gd-ui">Not this renter</b> or <b class="gd-ui">Match to a booking</b>.</div></li></ol></div><aside class="gd-box"><span class="gd-lbl">Tip</span><div>Until Google approves the Business Profile API for the project, the status says so and nothing else changes: renters still get the review link, and &quot;I already left a review&quot;, Mark reviewed and on-site reviews still stop the messages.</div></aside></section>');
-- GUIDES 0192 END

-- ================================================================ 5. privileges
do $$
declare
  f record;
begin
  for f in
    select p.oid::regprocedure as sig from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where (n.nspname = 'app' and p.proname = any (array['owner_agreement_preview_facts', 'my_signing_checklist', 'my_signing_checklist_pre0192',
              'registry_context', 'registry_context_pre0192', 'vehicle_registry_forms', 'fill_vehicle_government_forms',
              'ca_province_code', 'ca_postal_code', 'unit_only', 'street_and_unit', 'address_parts', 'looks_like_company', 'person_name_parts']))
        or (n.nspname = 'public' and p.proname = 'server_owner_agreement_preview_facts')
  loop
    execute format('revoke all on function %s from public, anon, authenticated', f.sig);
    execute format('grant execute on function %s to service_role', f.sig);
  end loop;
end $$;
