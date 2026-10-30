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
select app.guide_release_section('renter', 'sign-and-pay', 'chapter', 'your-offer', 'After you approve, you sign the rental agreement on screen and pay. It takes a few minutes on a phone or a computer; the signing itself is three taps.

## Sign the rental agreement

1. Fill in your home address and licence details. You do this once; we keep them for next time.
2. Press **Save details**. The agreement then shows your details.

![](/guides/img/renter-04-sign-details-desktop-bd193670.jpg "desktop; size: 1440 1052; address: carmacars.ca/account/bookings/CC-10003/sign; pins: 1 44.4 25.9, 2 16.3 96.4")

3. Check the key values at the top: the car, the dates, the deposit and the deductible. Open **Read the full rental agreement** to read it word for word, or press **Download PDF** to keep a copy. Below it is the Blind Spot Car Rental agreement, filled in with the same booking: we rent under Blind Spot''s insurance, so it is part of your rental too. Press its **Download PDF** to read it.
4. Under Sign, tap **All four**: it ticks the four statements, which stay on screen to read.
5. Confirm it is you: press **Send the code** and type the 6-digit code we text (or email) you. Tick that you read the agreements, initial each key term in its box, tick the three consents and draw your signature with your finger or the mouse.
6. Press **Sign and continue to payment**. Your one signature signs both agreements; the signed copies, with a certificate of each step, are in Documents and in the email that confirms your booking.

![](/guides/img/renter-06-sign-ready-desktop-1eee20a4.jpg "desktop; size: 1440 1212; address: carmacars.ca/account/bookings/CC-10003/sign; pins: 3 59.0 8.9, 4 69.4 18.2, 5 90.3 78.5, 6 96.9 87.1")

## Signing with our staff

At pickup or at our desk, you can sign on a CarmaCars phone or tablet.

1. Our staff member checks your name and your original licence, then hands you the device.
2. Read the agreements, confirm the code we text you, initial the key terms, tick the consents and sign with your finger. Then hand the device back.
3. It is the same signature as signing online. Prefer your own phone? Ask for the signing link by email or text.

## When your booking changes after you sign

Your agreements always match your booking.

1. If the dates, the price, the car, the drivers or your coverage change, you get an email and a text with a link to the new version: read what changed and sign it the same way. Until you sign, the earlier version applies.
2. A correction that changes nothing you agreed to (a typo in an address) comes as a corrected copy by email, with nothing to sign.
3. At pickup and at return you get your agreements as picked up and as returned: the time, kilometres and fuel, and at return the final charges.

## Pay to confirm

1. Check What you pay now. The refundable deposit is taken at pickup, not today.
2. Enter the Name on the card and the card details. Use a credit card in your own name.
3. Press **Pay $...** (the button shows the amount).

![](/guides/img/renter-07-pay-desktop-705896d6.jpg "desktop; size: 1440 1082; address: carmacars.ca/account/bookings/CC-10003/pay; pins: 7 70.5 21.9, 8 64.6 16.5, 9 64.6 96.4")

> Tip: Your card is authorized now and charged once the booking is confirmed. It becomes your Card on File for the deposit at pickup and any later charges you agreed to when you signed.

> Watch out: See "This car was just taken"? Someone confirmed the same car first. The authorization on your card is released, and we offer you another car or other dates.

## A rental we booked for you

Booked by phone, in person or through a partner? We add the rental and you sign it online.

1. You get an email: "Read and sign your rental agreement; your card is charged when you sign."
2. Open it. Check the car, the dates and the price, and read the agreement.
3. Press **Accept and sign**. If we have your card on file, it is charged at that moment, not before, and the agreement is countersigned by CarmaCars as soon as you sign.
', 'Sign and pay', 'Sign the rental agreement on screen and pay with your card.',
  'After you approve, you sign the rental agreement on screen and pay. It takes a few minutes on a phone or a computer; the signing itself is three taps.

## Sign the rental agreement

1. Fill in your home address and licence details. You do this once; we keep them for next time.
2. Press **Save details**. The agreement then shows your details.

![](/guides/img/renter-04-sign-details-desktop-bd193670.jpg "desktop; size: 1440 1052; address: carmacars.ca/account/bookings/CC-10003/sign; pins: 1 44.4 25.9, 2 16.3 96.4")

3. Check the key values at the top: the car, the dates, the deposit and the deductible. Open **Read the full rental agreement** to read it word for word, or press **Download PDF** to keep a copy. Below it is the Blind Spot Car Rental agreement, filled in with the same booking: we rent under Blind Spot''s insurance, so it is part of your rental too. Press its **Download PDF** to read it.
4. Under Sign, tap **All four**: it ticks the four statements, which stay on screen to read.
5. Tick that you read the agreements, initial each key term in its box and press **Save initials** (press **Clear** to draw them again), tick the three consents and draw your signature with your finger or the mouse.
6. Press **Sign and continue to payment**. Your one signature signs both agreements; the signed copies, with a certificate of each step, are in Documents and in the email that confirms your booking.

![](/guides/img/renter-06-sign-ready-desktop-1eee20a4.jpg "desktop; size: 1440 1212; address: carmacars.ca/account/bookings/CC-10003/sign; pins: 3 59.0 8.9, 4 69.4 18.2, 5 90.3 78.5, 6 96.9 87.1")

## Signing with our staff

At pickup or at our desk, you can sign on a CarmaCars phone or tablet.

1. Our staff member checks your name and your original licence, then hands you the device.
2. Read the agreements, confirm the code we text you, initial the key terms, tick the consents and sign with your finger. Then hand the device back.
3. It is the same signature as signing online. Prefer your own phone? Ask for the signing link by email or text.

## When your booking changes after you sign

Your agreements always match your booking.

1. If the dates, the price, the car, the drivers or your coverage change, you get an email and a text with a link to the new version: read what changed and sign it the same way. Until you sign, the earlier version applies.
2. A correction that changes nothing you agreed to (a typo in an address) comes as a corrected copy by email, with nothing to sign.
3. At pickup and at return you get your agreements as picked up and as returned: the time, kilometres and fuel, and at return the final charges.

## Pay to confirm

1. Check What you pay now. The refundable deposit is taken at pickup, not today.
2. Enter the Name on the card and the card details. Use a credit card in your own name.
3. Press **Pay $...** (the button shows the amount).

![](/guides/img/renter-07-pay-desktop-705896d6.jpg "desktop; size: 1440 1082; address: carmacars.ca/account/bookings/CC-10003/pay; pins: 7 70.5 21.9, 8 64.6 16.5, 9 64.6 96.4")

> Tip: Your card is authorized now and charged once the booking is confirmed. It becomes your Card on File for the deposit at pickup and any later charges you agreed to when you signed.

> Watch out: See "This car was just taken"? Someone confirmed the same car first. The authorization on your card is released, and we offer you another car or other dates.

## A rental we booked for you

Booked by phone, in person or through a partner? We add the rental and you sign it online.

1. You get an email: "Read and sign your rental agreement; your card is charged when you sign."
2. Open it. Check the car, the dates and the price, and read the agreement.
3. Press **Accept and sign**. If we have your card on file, it is charged at that moment, not before, and the agreement is countersigned by CarmaCars as soon as you sign.

### Complete your details
If your rental agreement is missing something only you can give (your date of birth, home address, mobile, licence number, issuer or expiry, or your insurance or card coverage details), your booking shows **Complete your details** at the top, and the signing and payment pages ask for it first. Fill in the form once and press **Save my details**: the agreement then shows them.',
  '<p class="gd-p">After you approve, you sign the rental agreement on screen and pay. It takes a few minutes on a phone or a computer; the signing itself is three taps.</p><section class="gd-task" id="sign-and-pay-sign-the-rental-agreement" data-gd-task><h2 class="gd-h2">Sign the rental agreement</h2><div class="gd-stepblock gd-stepblock--below"><div class="gd-stepcol"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Fill in your home address and licence details. You do this once; we keep them for next time.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Press <b class="gd-ui">Save details</b>. The agreement then shows your details.</div></li></ol></div><figure class="gd-fig gd-fig--desk"><div class="gd-browser"><div class="gd-bar" aria-hidden="true"><i></i><i></i><i></i><span class="gd-addr">carmacars.ca/account/bookings/CC-10003/sign</span></div><div class="gd-imgwrap" style="aspect-ratio:1440/1052"><img src="/guides/img/renter-04-sign-details-desktop-bd193670.jpg" alt="" loading="lazy" decoding="async" width="1440" height="1052"><span class="gd-pin" style="left:44.4%;top:25.9%" aria-hidden="true">1</span><span class="gd-pin" style="left:16.3%;top:96.4%" aria-hidden="true">2</span></div></div></figure></div><div class="gd-stepblock gd-stepblock--below"><div class="gd-stepcol"><ol class="gd-ol" start="3"><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Check the key values at the top: the car, the dates, the deposit and the deductible. Open <b class="gd-ui">Read the full rental agreement</b> to read it word for word, or press <b class="gd-ui">Download PDF</b> to keep a copy. Below it is the Blind Spot Car Rental agreement, filled in with the same booking: we rent under Blind Spot&#39;s insurance, so it is part of your rental too. Press its <b class="gd-ui">Download PDF</b> to read it.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">Under Sign, tap <b class="gd-ui">All four</b>: it ticks the four statements, which stay on screen to read.</div></li><li><span class="gd-n" aria-hidden="true">5</span><div class="gd-t">Tick that you read the agreements, initial each key term in its box and press <b class="gd-ui">Save initials</b> (press <b class="gd-ui">Clear</b> to draw them again), tick the three consents and draw your signature with your finger or the mouse.</div></li><li><span class="gd-n" aria-hidden="true">6</span><div class="gd-t">Press <b class="gd-ui">Sign and continue to payment</b>. Your one signature signs both agreements; the signed copies, with a certificate of each step, are in Documents and in the email that confirms your booking.</div></li></ol></div><figure class="gd-fig gd-fig--desk"><div class="gd-browser"><div class="gd-bar" aria-hidden="true"><i></i><i></i><i></i><span class="gd-addr">carmacars.ca/account/bookings/CC-10003/sign</span></div><div class="gd-imgwrap" style="aspect-ratio:1440/1212"><img src="/guides/img/renter-06-sign-ready-desktop-1eee20a4.jpg" alt="" loading="lazy" decoding="async" width="1440" height="1212"><span class="gd-pin" style="left:59%;top:8.9%" aria-hidden="true">3</span><span class="gd-pin" style="left:69.4%;top:18.2%" aria-hidden="true">4</span><span class="gd-pin" style="left:90.3%;top:78.5%" aria-hidden="true">5</span><span class="gd-pin" style="left:96.9%;top:87.1%" aria-hidden="true">6</span></div></div></figure></div></section><section class="gd-task" id="sign-and-pay-signing-with-our-staff" data-gd-task><h2 class="gd-h2">Signing with our staff</h2><p class="gd-p">At pickup or at our desk, you can sign on a CarmaCars phone or tablet.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Our staff member checks your name and your original licence, then hands you the device.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Read the agreements, confirm the code we text you, initial the key terms, tick the consents and sign with your finger. Then hand the device back.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">It is the same signature as signing online. Prefer your own phone? Ask for the signing link by email or text.</div></li></ol></div></section><section class="gd-task" id="sign-and-pay-when-your-booking-changes-after-you-sign" data-gd-task><h2 class="gd-h2">When your booking changes after you sign</h2><p class="gd-p">Your agreements always match your booking.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">If the dates, the price, the car, the drivers or your coverage change, you get an email and a text with a link to the new version: read what changed and sign it the same way. Until you sign, the earlier version applies.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">A correction that changes nothing you agreed to (a typo in an address) comes as a corrected copy by email, with nothing to sign.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">At pickup and at return you get your agreements as picked up and as returned: the time, kilometres and fuel, and at return the final charges.</div></li></ol></div></section><section class="gd-task" id="sign-and-pay-pay-to-confirm" data-gd-task><h2 class="gd-h2">Pay to confirm</h2><div class="gd-stepblock gd-stepblock--below"><div class="gd-stepcol"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Check What you pay now. The refundable deposit is taken at pickup, not today.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Enter the Name on the card and the card details. Use a credit card in your own name.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Press <b class="gd-ui">Pay $...</b> (the button shows the amount).</div></li></ol></div><figure class="gd-fig gd-fig--desk"><div class="gd-browser"><div class="gd-bar" aria-hidden="true"><i></i><i></i><i></i><span class="gd-addr">carmacars.ca/account/bookings/CC-10003/pay</span></div><div class="gd-imgwrap" style="aspect-ratio:1440/1082"><img src="/guides/img/renter-07-pay-desktop-705896d6.jpg" alt="" loading="lazy" decoding="async" width="1440" height="1082"><span class="gd-pin" style="left:70.5%;top:21.9%" aria-hidden="true">7</span><span class="gd-pin" style="left:64.6%;top:16.5%" aria-hidden="true">8</span><span class="gd-pin" style="left:64.6%;top:96.4%" aria-hidden="true">9</span></div></div></figure></div><aside class="gd-box"><span class="gd-lbl">Tip</span><div>Your card is authorized now and charged once the booking is confirmed. It becomes your Card on File for the deposit at pickup and any later charges you agreed to when you signed.</div></aside><aside class="gd-box gd-box--warn"><span class="gd-lbl">Watch out</span><div>See &quot;This car was just taken&quot;? Someone confirmed the same car first. The authorization on your card is released, and we offer you another car or other dates.</div></aside></section><section class="gd-task" id="sign-and-pay-a-rental-we-booked-for-you" data-gd-task><h2 class="gd-h2">A rental we booked for you</h2><p class="gd-p">Booked by phone, in person or through a partner? We add the rental and you sign it online.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">You get an email: &quot;Read and sign your rental agreement; your card is charged when you sign.&quot;</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Open it. Check the car, the dates and the price, and read the agreement.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Press <b class="gd-ui">Accept and sign</b>. If we have your card on file, it is charged at that moment, not before, and the agreement is countersigned by CarmaCars as soon as you sign.</div></li></ol></div><h3 class="gd-h3">Complete your details</h3><p class="gd-p">If your rental agreement is missing something only you can give (your date of birth, home address, mobile, licence number, issuer or expiry, or your insurance or card coverage details), your booking shows <b class="gd-ui">Complete your details</b> at the top, and the signing and payment pages ask for it first. Fill in the form once and press <b class="gd-ui">Save my details</b>: the agreement then shows them.</p></section>');
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

1. Right after you apply, Home shows **Read your agreements**: both agreements, filled in from your application, marked "Terms pending approval". The fees and the Revenue Share read Pending approval until we set them, and the Sign button stays off.
2. When your terms are ready, Home shows **Check and sign**. Everything is filled in from your application: check the short list of key values (each has a **Fix** link) and open any document to read it in full.
3. Sign in a few steps: confirm it is you with the 6-digit code we send to your phone or email, say you read the documents, initial the three confirmations, tick the two consents and draw your signature. Then press **Sign all**. One signature covers every document, in about two minutes.
4. Pay the upfront invoice: the first and last month''s insurance fee for each car (see chapter 4).
5. Upload what each car''s checklist asks for: the ownership permit, the lender''s permission if it is financed or leased, and insurance.
6. Sign Forms C and D (filled in for you) with witnesses: Form C on screen with your witness beside you, or on paper; Form D on paper, with a photo of each page from your phone (see chapter 5).

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
3. Sign in a few steps: say you read the documents, initial the three confirmations, tick the two consents and draw your signature. Then press **Sign all**. A code to your phone or email is optional (**Verify by code**); it is asked first only if CarmaCars turns it on. One signature covers every document, in about two minutes.
4. Pay the upfront invoice: the first and last month''s insurance fee for each car (see chapter 4).
5. Upload what each car''s checklist asks for: the ownership permit, the lender''s permission if it is financed or leased, and insurance.
6. Sign Forms C and D (filled in for you) with witnesses: Form C on screen with your witness beside you, or on paper; Form D on paper, with a photo of each page from your phone (see chapter 5).

## If we need a little more

Sometimes we need one more document before we can approve your application, for example the ownership permit or the insurance slip.

1. You get an email, and Home shows "We need a little more" with the list and any note from our team.
2. Upload what is asked, or write Your answer, and press **Send my answer**.
3. We review it within 1 business day. Once we approve your application, you get an email and Home shows Check and sign.
',
  '<p class="gd-p">You apply online in about ten minutes. We reply within one business day, set your terms, and walk you through the rest.</p><section class="gd-task" id="apply-and-get-your-car-listed-apply-to-list-your-car" data-gd-task><h2 class="gd-h2">Apply to list your car</h2><div class="gd-stepblock gd-stepblock--below"><div class="gd-stepcol"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Go to <span class="gd-url">carmacars.ca/list-your-car</span> and press <b class="gd-ui">Apply to list your car</b>.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">About you: individual or corporation, your address, licence and date of birth. Press <b class="gd-ui">Continue to vehicles</b>.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">For each car, type the VIN: your car is found as you type the last character (Edit if anything is wrong), then tap its colour and answer the rest. Use <b class="gd-ui">Add another vehicle</b> for more cars.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">Read how it will work, press <b class="gd-ui">Continue</b>, then <b class="gd-ui">Review</b>.</div></li><li><span class="gd-n" aria-hidden="true">5</span><div class="gd-t">Press <b class="gd-ui">Submit application</b>, then <b class="gd-ui">Go to your owner portal</b>.</div></li></ol></div><figure class="gd-fig gd-fig--desk"><div class="gd-browser"><div class="gd-bar" aria-hidden="true"><i></i><i></i><i></i><span class="gd-addr">carmacars.ca/list-your-car</span></div><div class="gd-imgwrap" style="aspect-ratio:1440/800"><img src="/guides/img/public-13-list-your-car-desktop-48bf4cb0.jpg" alt="" loading="lazy" decoding="async" width="1440" height="800"><span class="gd-pin" style="left:20.1%;top:74.9%" aria-hidden="true">1</span></div></div></figure></div><aside class="gd-box"><span class="gd-lbl">Tip</span><div>Need a break? <b class="gd-ui">Email me a link</b> saves your application and sends you a link to finish later.</div></aside><aside class="gd-box"><span class="gd-lbl">Good to know</span><div>No car to add yet? On the vehicle step press <b class="gd-ui">I&#39;ll add my car later</b>, choose your password and press <b class="gd-ui">Open my owner account</b>. Your owner portal opens with <b class="gd-ui">Add your first car</b>: press it when you are ready, starting with the VIN.</div></aside></section><section class="gd-task" id="apply-and-get-your-car-listed-what-happens-next" data-gd-task><h2 class="gd-h2">What happens next</h2><p class="gd-p">Five steps take your car from your driveway to its first rental.</p><ol class="gd-flow"><li><b>1</b><span>Tell us about the car</span><em>We confirm fees and set your terms</em></li><li><b>2</b><span>Sign the agreements</span><em>Online, one for all your cars</em></li><li><b>3</b><span>One registry visit</span><em>We fill in the forms and come with you</em></li><li><b>4</b><span>Tracker and insurance</span><em>We install it and add the car</em></li><li><b>5</b><span>Photos and listing</span><em>Live within 1 business day</em></li></ol><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Right after you apply, Home shows <b class="gd-ui">Read your agreements</b>: both agreements, filled in from your application, marked &quot;Terms pending approval&quot;. The fees and the Revenue Share read Pending approval until we set them, and the Sign button stays off.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">When your terms are ready, Home shows <b class="gd-ui">Check and sign</b>. Everything is filled in from your application: check the short list of key values (each has a <b class="gd-ui">Fix</b> link) and open any document to read it in full.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Sign in a few steps: say you read the documents, initial the three confirmations, tick the two consents and draw your signature. Then press <b class="gd-ui">Sign all</b>. A code to your phone or email is optional (<b class="gd-ui">Verify by code</b>); it is asked first only if CarmaCars turns it on. One signature covers every document, in about two minutes.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">Pay the upfront invoice: the first and last month&#39;s insurance fee for each car (see chapter 4).</div></li><li><span class="gd-n" aria-hidden="true">5</span><div class="gd-t">Upload what each car&#39;s checklist asks for: the ownership permit, the lender&#39;s permission if it is financed or leased, and insurance.</div></li><li><span class="gd-n" aria-hidden="true">6</span><div class="gd-t">Sign Forms C and D (filled in for you) with witnesses: Form C on screen with your witness beside you, or on paper; Form D on paper, with a photo of each page from your phone (see chapter 5).</div></li></ol></div></section><section class="gd-task" id="apply-and-get-your-car-listed-if-we-need-a-little-more" data-gd-task><h2 class="gd-h2">If we need a little more</h2><p class="gd-p">Sometimes we need one more document before we can approve your application, for example the ownership permit or the insurance slip.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">You get an email, and Home shows &quot;We need a little more&quot; with the list and any note from our team.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Upload what is asked, or write Your answer, and press <b class="gd-ui">Send my answer</b>.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">We review it within 1 business day. Once we approve your application, you get an email and Home shows Check and sign.</div></li></ol></div></section>');
select app.guide_release_section('owner', 'fees-payments-and-payouts', 'chapter', 'bookings-and-your-own-use', 'Your fees are debited from your bank account on the 15th, after a notice. Your payout for the month before arrives on the 10th, with a statement.

## How your fees work

- Each car has two monthly fees: an insurance fee and a tracker fee. They are due every month, rented or not.
- The tracker fee starts the day the car''s tracker is installed. The tracker install fee has its own invoice.
- Before a car goes live you pay the first and last month amount we agreed with you (usually two months of the insurance fee, or the exact amount we agreed).
- Your amounts are the ones we agreed for each car, to the cent. Any other fee we agreed, for example a registration fee, comes on its own invoice with each line, its quantity and whether HST applies.
- Vehicles shows each car''s terms: the insurance fee and tracker fee a month and the Revenue Share, since when they apply, and any change coming. Open a car for its History: every period of terms and every notice we sent (Download the notice).
- Lower amounts apply from the date in our notice. A higher fee comes with 30 days'' written notice; a higher Revenue Share applies only if you sign an updated Vehicle Schedule. A month whose fee changes part way is billed per day at each amount.
- One invoice per car. Registry, inspection and appraisal costs are not billed by us unless we agreed to pay them for you; then they are on an invoice of their own.

An invoice we cancel shows Void with the reason, and the invoice that replaces it. Nothing is debited for a void invoice. Every invoice has Download PDF.

## The monthly debit, step by step

:::flow
Notice day | 10 days before: your invoices and one email with the total
The 15th | Each invoice is debited from your account
Cleared | The invoice shows Paid and you get a receipt
Insufficient funds? | A $50.00 Late Fee once, and the same amount tried again within 30 days
:::

- A debit is never more than its notice said. Each invoice shows "will be debited on" with the date.
- If your bank returns a debit for insufficient funds, we add the $50.00 Late Fee to that invoice once and try the original amount again within 30 days, as section 4.4 of your Enrollment Agreement sets out. The Late Fee is collected with your next debit.
- Returned for another reason (for example a closed account)? We do not try again and add no Late Fee. We pause your debit and email you: pay the invoice from its page, or set up a new account under Account > Banking.
- Returned again after the retry? The invoice is in arrears and we contact you.
- You can always pay an invoice by card from its page before the debit day.
- On your bank statement the debit shows our company''s legal name, operating as CarmaCars.

## Set up the automatic debit

Do this once. Without it, we email you on each notice day to set it up.

1. Open **Account** > **Banking**. Under Automatic debit of your fees, press **Set up pre-authorized debit**.
2. Read the agreement and press **Continue to my bank details**.
3. Enter your bank details and press **Save the bank account**. Banking then shows the account and the next debit.

![](/guides/img/owner-07-banking-desktop-52316739.jpg "desktop; size: 1440 752; address: carmacars.ca/owner/banking; pins: 1 96.2 36.8")

## Pay an invoice now

1. Open Invoices, then the invoice. It lists what it covers and the balance.
2. Choose Card (paid at once) and press **Pay $...**.
3. Or choose Pre-authorized debit (from a Canadian bank account, clears in 3 to 5 business days) and press **Authorize debit of $...**.
4. Prefer Interac e-Transfer? Send the amount to billing@carmacars.ca with the invoice number in the message.

![](/guides/img/owner-06-invoice-desktop-bba2c020.jpg "desktop; size: 1440 742; address: carmacars.ca/owner/invoices/INV-1050; pins: 2 6.9 52.6, 3 38.2 52.6, 4 11.5 80.5")

> Tip: Paid us by e-Transfer, cheque, cash or bank transfer? Once we record it, the invoice says "Paid by e-Transfer on" the date, you get a receipt by email, and the automatic debit does not take that amount. Paid part of it? The invoice shows Partly paid and only the rest is debited.

## Tell us where to pay you

1. Open **Account** > **Banking**. Under Where we pay you, choose Bank transfer or e-Transfer.
2. Fill in Account holder, Institution number, Transit number and Account number (or your e-Transfer email).
3. Press **Submit payout details**. For your security we confirm new details by phone before we use them.

![](/guides/img/owner-07-banking-desktop-87b2ffe3.jpg "desktop; size: 990 642; address: carmacars.ca/owner/banking; pins: 1 50.5 25.7, 2 90.9 45.5, 3 30.3 89.7")

## Statements and payouts

1. This month so far, at the top of Statements: the rentals finished this month, your Owner Revenue, the Revenue Share, fees and deductions and the expected payout, worked out live and marked Provisional. Rentals still under way are listed below it.
2. Statements: one a month, once approved by CarmaCars; the approved statement is the final one. Open one to see every booking, the revenue share, deductions and the payout.
3. Press **Download PDF** to keep a copy. We also email it to you with the PDF attached.
4. Payouts shows what was paid to you and when. Payouts are made on the 10th for the month before.

![](/guides/img/owner-09-statement-desktop-fc5f9ea5.jpg "desktop; size: 1440 792; address: carmacars.ca/owner/statements/380cc1bb-bfd5-4e55-8022-93a3b998ca74; pins: 2 16.0 30.6, 1 66.0 40.9")
', 'Fees, payments and payouts', 'How fees are billed, the monthly debit, paying an invoice, statements and payouts.',
  'Your fees are debited from your bank account on the 15th, after a notice. Your payout for the month before arrives on the 10th, with a statement.

## How your fees work

- Each car has two monthly fees: an insurance fee and a tracker fee. They are due every month, rented or not.
- The tracker fee starts the day the car''s tracker is installed. The tracker install fee has its own invoice.
- Before a car goes live you pay the first and last month amount we agreed with you (usually two months of the insurance fee, or the exact amount we agreed).
- Your amounts are the ones we agreed for each car, to the cent. Any other fee we agreed, for example a registration fee, comes on its own invoice with each line, its quantity and whether HST applies.
- Vehicles shows each car''s terms: the insurance fee and tracker fee a month and the Revenue Share, since when they apply, and any change coming. Open a car for its History: every period of terms and every notice we sent (Download the notice).
- Lower amounts apply from the date in our notice. A higher fee comes with 30 days'' written notice; a higher Revenue Share applies only if you sign an updated Vehicle Schedule. A month whose fee changes part way is billed per day at each amount.
- One invoice per car. Registry, inspection and appraisal costs are not billed by us unless we agreed to pay them for you; then they are on an invoice of their own.

An invoice we cancel shows Void with the reason, and the invoice that replaces it. Nothing is debited for a void invoice. Every invoice has Download PDF.

## The monthly debit, step by step

:::flow
Notice day | 10 days before: your invoices and one email with the total
The 15th | Each invoice is debited from your account
Cleared | The invoice shows Paid and you get a receipt
Insufficient funds? | A $50.00 Late Fee once, and the same amount tried again within 30 days
:::

- A debit is never more than its notice said. Each invoice shows "will be debited on" with the date.
- If your bank returns a debit for insufficient funds, we add the $50.00 Late Fee to that invoice once and try the original amount again within 30 days, as section 4.4 of your Enrollment Agreement sets out. The Late Fee is collected with your next debit.
- Returned for another reason (for example a closed account)? We do not try again and add no Late Fee. We pause your debit and email you: pay the invoice from its page, or set up a new account under Account > Banking.
- Returned again after the retry? The invoice is in arrears and we contact you.
- You can always pay an invoice by card from its page before the debit day.
- On your bank statement the debit shows our company''s legal name, operating as CarmaCars.

## Set up the automatic debit

Do this once. Without it, we email you on each notice day to set it up.

1. Open **Account** > **Banking**. Under Automatic debit of your fees, press **Set up pre-authorized debit**.
2. Read the agreement and press **Continue to my bank details**.
3. Enter your bank details and press **Save the bank account**. Banking then shows the account and the next debit.

![](/guides/img/owner-07-banking-desktop-52316739.jpg "desktop; size: 1440 752; address: carmacars.ca/owner/banking; pins: 1 96.2 36.8")

## Pay an invoice now

1. Open Invoices, then the invoice. It lists what it covers and the balance.
2. Choose Card (paid at once) and press **Pay $...**.
3. Or choose Pre-authorized debit (from a Canadian bank account, clears in 3 to 5 business days) and press **Authorize debit of $...**.
4. Prefer Interac e-Transfer? Send the amount to billing@carmacars.ca with the invoice number in the message.

![](/guides/img/owner-06-invoice-desktop-bba2c020.jpg "desktop; size: 1440 742; address: carmacars.ca/owner/invoices/INV-1050; pins: 2 6.9 52.6, 3 38.2 52.6, 4 11.5 80.5")

> Tip: Paid us by e-Transfer, cheque, cash or bank transfer? Once we record it, the invoice says "Paid by e-Transfer on" the date, you get a receipt by email, and the automatic debit does not take that amount. Paid part of it? The invoice shows Partly paid and only the rest is debited.

## Tell us where to pay you

1. Open **Account** > **Banking**. Under Where we pay you, choose Bank transfer or e-Transfer.
2. Fill in Account holder, Institution number, Transit number and Account number (or your e-Transfer email).
3. Press **Submit payout details**. For your security we confirm new details by phone before we use them.

![](/guides/img/owner-07-banking-desktop-87b2ffe3.jpg "desktop; size: 990 642; address: carmacars.ca/owner/banking; pins: 1 50.5 25.7, 2 90.9 45.5, 3 30.3 89.7")

## Statements and payouts

1. This month so far, at the top of Statements: the rentals finished this month, your Owner Revenue, the Revenue Share, fees and deductions and the expected payout, worked out live and marked Provisional. Rentals still under way are listed below it.
2. Statements: one a month, once approved by CarmaCars; the approved statement is the final one. Open one to see every booking, the revenue share, deductions and the payout.
3. Press **Download PDF** to keep a copy. We also email it to you with the PDF attached.
4. Payouts shows what was paid to you and when. Payouts are made on the 10th for the month before.

![](/guides/img/owner-09-statement-desktop-fc5f9ea5.jpg "desktop; size: 1440 792; address: carmacars.ca/owner/statements/380cc1bb-bfd5-4e55-8022-93a3b998ca74; pins: 2 16.0 30.6, 1 66.0 40.9")

> Good to know: Paid a flat monthly payment for a car? Its statement shows a Flat monthly payment line for the month (a part month by the day) instead of the Revenue Share. The car''s rentals are listed without amounts paid to you, as CarmaCars keeps them, and there is no insurance or tracker fee for it. A booking expense is taken off only when we charge it to you; it then shows as an owner cost with its reason. Vehicles shows the amount and since when.
',
  '<p class="gd-p">Your fees are debited from your bank account on the 15th, after a notice. Your payout for the month before arrives on the 10th, with a statement.</p><section class="gd-task" id="fees-payments-and-payouts-how-your-fees-work" data-gd-task><h2 class="gd-h2">How your fees work</h2><ul class="gd-ul"><li>Each car has two monthly fees: an insurance fee and a tracker fee. They are due every month, rented or not.</li><li>The tracker fee starts the day the car&#39;s tracker is installed. The tracker install fee has its own invoice.</li><li>Before a car goes live you pay the first and last month amount we agreed with you (usually two months of the insurance fee, or the exact amount we agreed).</li><li>Your amounts are the ones we agreed for each car, to the cent. Any other fee we agreed, for example a registration fee, comes on its own invoice with each line, its quantity and whether HST applies.</li><li>Vehicles shows each car&#39;s terms: the insurance fee and tracker fee a month and the Revenue Share, since when they apply, and any change coming. Open a car for its History: every period of terms and every notice we sent (Download the notice).</li><li>Lower amounts apply from the date in our notice. A higher fee comes with 30 days&#39; written notice; a higher Revenue Share applies only if you sign an updated Vehicle Schedule. A month whose fee changes part way is billed per day at each amount.</li><li>One invoice per car. Registry, inspection and appraisal costs are not billed by us unless we agreed to pay them for you; then they are on an invoice of their own.</li></ul><p class="gd-p">An invoice we cancel shows Void with the reason, and the invoice that replaces it. Nothing is debited for a void invoice. Every invoice has Download PDF.</p></section><section class="gd-task" id="fees-payments-and-payouts-the-monthly-debit-step-by-step" data-gd-task><h2 class="gd-h2">The monthly debit, step by step</h2><ol class="gd-flow"><li><b>1</b><span>Notice day</span><em>10 days before: your invoices and one email with the total</em></li><li><b>2</b><span>The 15th</span><em>Each invoice is debited from your account</em></li><li><b>3</b><span>Cleared</span><em>The invoice shows Paid and you get a receipt</em></li><li><b>4</b><span>Insufficient funds?</span><em>A $50.00 Late Fee once, and the same amount tried again within 30 days</em></li></ol><ul class="gd-ul"><li>A debit is never more than its notice said. Each invoice shows &quot;will be debited on&quot; with the date.</li><li>If your bank returns a debit for insufficient funds, we add the $50.00 Late Fee to that invoice once and try the original amount again within 30 days, as section 4.4 of your Enrollment Agreement sets out. The Late Fee is collected with your next debit.</li><li>Returned for another reason (for example a closed account)? We do not try again and add no Late Fee. We pause your debit and email you: pay the invoice from its page, or set up a new account under Account &gt; Banking.</li><li>Returned again after the retry? The invoice is in arrears and we contact you.</li><li>You can always pay an invoice by card from its page before the debit day.</li><li>On your bank statement the debit shows our company&#39;s legal name, operating as CarmaCars.</li></ul></section><section class="gd-task" id="fees-payments-and-payouts-set-up-the-automatic-debit" data-gd-task><h2 class="gd-h2">Set up the automatic debit</h2><p class="gd-p">Do this once. Without it, we email you on each notice day to set it up.</p><div class="gd-stepblock gd-stepblock--below"><div class="gd-stepcol"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Open <b class="gd-ui">Account</b> &gt; <b class="gd-ui">Banking</b>. Under Automatic debit of your fees, press <b class="gd-ui">Set up pre-authorized debit</b>.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Read the agreement and press <b class="gd-ui">Continue to my bank details</b>.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Enter your bank details and press <b class="gd-ui">Save the bank account</b>. Banking then shows the account and the next debit.</div></li></ol></div><figure class="gd-fig gd-fig--desk"><div class="gd-browser"><div class="gd-bar" aria-hidden="true"><i></i><i></i><i></i><span class="gd-addr">carmacars.ca/owner/banking</span></div><div class="gd-imgwrap" style="aspect-ratio:1440/752"><img src="/guides/img/owner-07-banking-desktop-52316739.jpg" alt="" loading="lazy" decoding="async" width="1440" height="752"><span class="gd-pin" style="left:96.2%;top:36.8%" aria-hidden="true">1</span></div></div></figure></div></section><section class="gd-task" id="fees-payments-and-payouts-pay-an-invoice-now" data-gd-task><h2 class="gd-h2">Pay an invoice now</h2><div class="gd-stepblock gd-stepblock--below"><div class="gd-stepcol"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Open Invoices, then the invoice. It lists what it covers and the balance.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Choose Card (paid at once) and press <b class="gd-ui">Pay $...</b>.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Or choose Pre-authorized debit (from a Canadian bank account, clears in 3 to 5 business days) and press <b class="gd-ui">Authorize debit of $...</b>.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">Prefer Interac e-Transfer? Send the amount to billing@carmacars.ca with the invoice number in the message.</div></li></ol></div><figure class="gd-fig gd-fig--desk"><div class="gd-browser"><div class="gd-bar" aria-hidden="true"><i></i><i></i><i></i><span class="gd-addr">carmacars.ca/owner/invoices/INV-1050</span></div><div class="gd-imgwrap" style="aspect-ratio:1440/742"><img src="/guides/img/owner-06-invoice-desktop-bba2c020.jpg" alt="" loading="lazy" decoding="async" width="1440" height="742"><span class="gd-pin" style="left:6.9%;top:52.6%" aria-hidden="true">2</span><span class="gd-pin" style="left:38.2%;top:52.6%" aria-hidden="true">3</span><span class="gd-pin" style="left:11.5%;top:80.5%" aria-hidden="true">4</span></div></div></figure></div><aside class="gd-box"><span class="gd-lbl">Tip</span><div>Paid us by e-Transfer, cheque, cash or bank transfer? Once we record it, the invoice says &quot;Paid by e-Transfer on&quot; the date, you get a receipt by email, and the automatic debit does not take that amount. Paid part of it? The invoice shows Partly paid and only the rest is debited.</div></aside></section><section class="gd-task" id="fees-payments-and-payouts-tell-us-where-to-pay-you" data-gd-task><h2 class="gd-h2">Tell us where to pay you</h2><div class="gd-stepblock gd-stepblock--below"><div class="gd-stepcol"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Open <b class="gd-ui">Account</b> &gt; <b class="gd-ui">Banking</b>. Under Where we pay you, choose Bank transfer or e-Transfer.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Fill in Account holder, Institution number, Transit number and Account number (or your e-Transfer email).</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Press <b class="gd-ui">Submit payout details</b>. For your security we confirm new details by phone before we use them.</div></li></ol></div><figure class="gd-fig gd-fig--desk"><div class="gd-browser"><div class="gd-bar" aria-hidden="true"><i></i><i></i><i></i><span class="gd-addr">carmacars.ca/owner/banking</span></div><div class="gd-imgwrap" style="aspect-ratio:990/642"><img src="/guides/img/owner-07-banking-desktop-87b2ffe3.jpg" alt="" loading="lazy" decoding="async" width="990" height="642"><span class="gd-pin" style="left:50.5%;top:25.7%" aria-hidden="true">1</span><span class="gd-pin" style="left:90.9%;top:45.5%" aria-hidden="true">2</span><span class="gd-pin" style="left:30.3%;top:89.7%" aria-hidden="true">3</span></div></div></figure></div></section><section class="gd-task" id="fees-payments-and-payouts-statements-and-payouts" data-gd-task><h2 class="gd-h2">Statements and payouts</h2><div class="gd-stepblock gd-stepblock--below"><div class="gd-stepcol"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">This month so far, at the top of Statements: the rentals finished this month, your Owner Revenue, the Revenue Share, fees and deductions and the expected payout, worked out live and marked Provisional. Rentals still under way are listed below it.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Statements: one a month, once approved by CarmaCars; the approved statement is the final one. Open one to see every booking, the revenue share, deductions and the payout.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Press <b class="gd-ui">Download PDF</b> to keep a copy. We also email it to you with the PDF attached.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">Payouts shows what was paid to you and when. Payouts are made on the 10th for the month before.</div></li></ol></div><figure class="gd-fig gd-fig--desk"><div class="gd-browser"><div class="gd-bar" aria-hidden="true"><i></i><i></i><i></i><span class="gd-addr">carmacars.ca/owner/statements/380cc1bb-bfd5-4e55-8022-93a3b998ca74</span></div><div class="gd-imgwrap" style="aspect-ratio:1440/792"><img src="/guides/img/owner-09-statement-desktop-fc5f9ea5.jpg" alt="" loading="lazy" decoding="async" width="1440" height="792"><span class="gd-pin" style="left:16%;top:30.6%" aria-hidden="true">2</span><span class="gd-pin" style="left:66%;top:40.9%" aria-hidden="true">1</span></div></div></figure></div><aside class="gd-box"><span class="gd-lbl">Good to know</span><div>Paid a flat monthly payment for a car? Its statement shows a Flat monthly payment line for the month (a part month by the day) instead of the Revenue Share. The car&#39;s rentals are listed without amounts paid to you, as CarmaCars keeps them, and there is no insurance or tracker fee for it. A booking expense is taken off only when we charge it to you; it then shows as an owner cost with its reason. Vehicles shows the amount and since when.</div></aside></section>');
select app.guide_release_section('owner', 'documents-and-forms', 'chapter', 'fees-payments-and-payouts', 'Your signed agreements, uploads and government forms are under Documents. Some forms are filled for you; Forms C and D are signed with witnesses.

## Sign everything at once

Everything you sign on screen is in one place: Home shows how many are signed ("2 of 5 signed") and opens it with Check and sign.

1. Press **Check and sign** on Home (or open `carmacars.ca/owner/sign`). The list at the top shows each document: signed, in this package, or done elsewhere (Forms C and D, the bank debit).
2. Check the key values: your name, address, each car with its VIN and plate, your fees and Revenue Share. Something wrong? Press **Fix** next to it, change it, and come back.
3. Open any document to read it word for word: the agreements, the schedules and Forms A and B. The official registry forms are not in it: they are printed and signed in ink.
4. Press **Send the code**: a 6-digit code goes to your phone (or your email, if you choose it). Type it and press **Confirm**.
5. Tick that you read the documents, draw your initials in the box beside each confirmation the Enrollment Agreement asks for, and tick the two consents (to sign electronically, to get your records electronically).
6. Draw your signature in the box with your finger, a pen or the mouse, then press **Sign all**. One signature is applied to each document; CarmaCars countersigns at the same moment and every signed copy is in Documents.
7. Each signed copy ends with a certificate of completion: when and where each step was done, and the code that confirmed it was you. Anyone holding a copy can check it at carmacars.ca/verify.

## Read your agreements before approval

You can read both agreements as soon as you apply, before we approve your terms.

1. Press **Read your agreements** on Home (Documents and each car''s Onboarding checklist link to it too).
2. Each document is filled in from your application: your name, address and cars. It is marked "Terms pending approval": the fees, the Revenue Share and the agreement numbers read Pending approval until we set them.
3. Something wrong? Press **Fix** next to it. The Sign button stays off until we approve your terms; then Home shows **Check and sign** and we email you.

> Two owners: A car with a second owner on its ownership? Each owner named in the Title Schedule signs. The other owner gets their own link by email and signs the same documents on their phone or computer, the same way: the code (sent to their email), the confirmations initialled, the consents and their drawn signature. The agreements take effect when the last owner signs; CarmaCars countersigns then.

> Good to know: Cannot draw a signature (for example with a disability)? Call us: an Admin can let you type your name instead.

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
2. Read the text, then sign the same way as your agreements: the code to your phone or email, tick that you read it, initial the updated terms, tick the two consents, draw your signature and press **Sign**.
3. Your current terms stay until you sign. After that, your invoices and statements use the new ones from the date. The signed copy, with its certificate of completion, is in Documents.

## Form C on screen, with your witness beside you

Form C is the lender or lessor permission for a financed or leased car. It needs one witness, and you can sign it on screen when your witness is with you.

1. Open Documents. Under Forms to sign with witnesses, press Sign Form C on screen instead.
2. Confirm it is you with the code sent to your phone or email, and tick that you read the form.
3. Draw your initials beside each of the three acknowledgments, tick the two consents and draw your signature.
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
', 'Documents and forms', 'Agreements, government forms, Forms C and D, and official forms filled for you.',
  'Your signed agreements, uploads and government forms are under Documents. Some forms are filled for you; Forms C and D are signed with witnesses.

## Sign everything at once

Everything you sign on screen is in one place: Home shows how many are signed ("2 of 5 signed") and opens it with Check and sign.

1. Press **Check and sign** on Home (or open `carmacars.ca/owner/sign`). The list at the top shows each document: signed, in this package, or done elsewhere (Forms C and D, the bank debit).
2. Check the key values: your name, address, each car with its VIN and plate, your fees and Revenue Share. Something wrong? Press **Fix** next to it, change it, and come back.
3. Open any document to read it word for word: the agreements, the schedules and Forms A and B. The official registry forms are not in it: they are printed and signed in ink.
4. A code is optional: press **Verify by code** if you want the certificate to say a 6-digit code to your phone or email confirmed it was you (it is asked first only if CarmaCars turns it on).
5. Tick that you read the documents, draw your initials in the box beside each confirmation the Enrollment Agreement asks for, and tick the two consents (to sign electronically, to get your records electronically).
6. Draw your signature in the box with your finger, a pen or the mouse, then press **Sign all**. One signature is applied to each document; CarmaCars countersigns at the same moment and every signed copy is in Documents.
7. Each signed copy ends with a certificate of completion: when and where each step was done, and whether a code confirmed it was you. Anyone holding a copy can check it at carmacars.ca/verify.

## Read your agreements before approval

You can read both agreements as soon as you apply, before we approve your terms.

1. Press **Read your agreements** on Home (Documents and each car''s Onboarding checklist link to it too).
2. Each document is filled in from your application: your name, address and cars. It is marked "Terms pending approval": the fees, the Revenue Share and the agreement numbers read Pending approval until we set them.
3. Something wrong? Press **Fix** next to it. The Sign button stays off until we approve your terms; then Home shows **Check and sign** and we email you.

> Two owners: A car with a second owner on its ownership? Each owner named in the Title Schedule signs. The other owner gets their own link by email and signs the same documents on their phone or computer, the same way: the documents read, the confirmations initialled, the consents and their drawn signature (a code to their email only if they choose it or CarmaCars turns it on). The agreements take effect when the last owner signs; CarmaCars countersigns then.

> Good to know: Cannot draw a signature (for example with a disability)? Call us: an Admin can let you type your name instead.

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
2. Read the text, then sign the same way as your agreements: tick that you read it, initial the updated terms, tick the two consents, draw your signature and press **Sign** (a code to your phone or email is optional).
3. Your current terms stay until you sign. After that, your invoices and statements use the new ones from the date. The signed copy, with its certificate of completion, is in Documents.

## Form C on screen, with your witness beside you

Form C is the lender or lessor permission for a financed or leased car. It needs one witness, and you can sign it on screen when your witness is with you.

1. Open Documents. Under Forms to sign with witnesses, press Sign Form C on screen instead.
2. Tick that you read the form (a code to your phone or email is optional, unless CarmaCars turns it on).
3. Draw your initials beside each of the three acknowledgments, tick the two consents and draw your signature.
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
  '<p class="gd-p">Your signed agreements, uploads and government forms are under Documents. Some forms are filled for you; Forms C and D are signed with witnesses.</p><section class="gd-task" id="documents-and-forms-sign-everything-at-once" data-gd-task><h2 class="gd-h2">Sign everything at once</h2><p class="gd-p">Everything you sign on screen is in one place: Home shows how many are signed (&quot;2 of 5 signed&quot;) and opens it with Check and sign.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Press <b class="gd-ui">Check and sign</b> on Home (or open <span class="gd-url">carmacars.ca/owner/sign</span>). The list at the top shows each document: signed, in this package, or done elsewhere (Forms C and D, the bank debit).</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Check the key values: your name, address, each car with its VIN and plate, your fees and Revenue Share. Something wrong? Press <b class="gd-ui">Fix</b> next to it, change it, and come back.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Open any document to read it word for word: the agreements, the schedules and Forms A and B. The official registry forms are not in it: they are printed and signed in ink.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">A code is optional: press <b class="gd-ui">Verify by code</b> if you want the certificate to say a 6-digit code to your phone or email confirmed it was you (it is asked first only if CarmaCars turns it on).</div></li><li><span class="gd-n" aria-hidden="true">5</span><div class="gd-t">Tick that you read the documents, draw your initials in the box beside each confirmation the Enrollment Agreement asks for, and tick the two consents (to sign electronically, to get your records electronically).</div></li><li><span class="gd-n" aria-hidden="true">6</span><div class="gd-t">Draw your signature in the box with your finger, a pen or the mouse, then press <b class="gd-ui">Sign all</b>. One signature is applied to each document; CarmaCars countersigns at the same moment and every signed copy is in Documents.</div></li><li><span class="gd-n" aria-hidden="true">7</span><div class="gd-t">Each signed copy ends with a certificate of completion: when and where each step was done, and whether a code confirmed it was you. Anyone holding a copy can check it at carmacars.ca/verify.</div></li></ol></div></section><section class="gd-task" id="documents-and-forms-read-your-agreements-before-approval" data-gd-task><h2 class="gd-h2">Read your agreements before approval</h2><p class="gd-p">You can read both agreements as soon as you apply, before we approve your terms.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Press <b class="gd-ui">Read your agreements</b> on Home (Documents and each car&#39;s Onboarding checklist link to it too).</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Each document is filled in from your application: your name, address and cars. It is marked &quot;Terms pending approval&quot;: the fees, the Revenue Share and the agreement numbers read Pending approval until we set them.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Something wrong? Press <b class="gd-ui">Fix</b> next to it. The Sign button stays off until we approve your terms; then Home shows <b class="gd-ui">Check and sign</b> and we email you.</div></li></ol></div><aside class="gd-box"><div>Two owners: A car with a second owner on its ownership? Each owner named in the Title Schedule signs. The other owner gets their own link by email and signs the same documents on their phone or computer, the same way: the documents read, the confirmations initialled, the consents and their drawn signature (a code to their email only if they choose it or CarmaCars turns it on). The agreements take effect when the last owner signs; CarmaCars countersigns then.</div></aside><aside class="gd-box"><span class="gd-lbl">Good to know</span><div>Cannot draw a signature (for example with a disability)? Call us: an Admin can let you type your name instead.</div></aside><aside class="gd-box"><span class="gd-lbl">Good to know</span><div>Form A (the trust declaration) is for cars under the Co-Registrant or Transfer method; Form B (the lease summary) for cars under a Lease method. No witness is needed: they are in the same package. You can also sign one on its own page from Documents.</div></aside><aside class="gd-box"><span class="gd-lbl">Tip</span><div>Signed one of your documents on paper instead? Send us the scan. Once we record it, Documents shows it as Signed on paper and we do not ask again.</div></aside></section><section class="gd-task" id="documents-and-forms-we-set-up-your-car-for-you" data-gd-task><h2 class="gd-h2">We set up your car for you</h2><p class="gd-p">When our team enters your car for you, you get one email: review the details and sign.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">No sign-in yet? The email has a link to choose your password. It works once, for 24 hours; after that use Forgot password on the sign-in page.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Open <span class="gd-url">carmacars.ca/owner/review</span> (Home has <b class="gd-ui">Review or correct your details</b>). Check your phone and address, and each car: plate, colour, odometer, your insurer and your lender. The terms we agreed are shown too.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Something wrong? Correct it and press <b class="gd-ui">Save corrections</b>. Your documents are filled in again and we are told. A term you did not agree to: message us before you sign.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">Everything right? Press <b class="gd-ui">Everything is right: sign</b> and sign once.</div></li></ol></div></section><section class="gd-task" id="documents-and-forms-sign-an-updated-vehicle-schedule" data-gd-task><h2 class="gd-h2">Sign an updated Vehicle Schedule</h2><p class="gd-p">When we agree new terms for a car you already signed for, you sign an updated Vehicle Schedule. Home shows it first.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Open it from Home or the email. It shows what changes (now and updated) and the date it applies from.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Read the text, then sign the same way as your agreements: tick that you read it, initial the updated terms, tick the two consents, draw your signature and press <b class="gd-ui">Sign</b> (a code to your phone or email is optional).</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Your current terms stay until you sign. After that, your invoices and statements use the new ones from the date. The signed copy, with its certificate of completion, is in Documents.</div></li></ol></div></section><section class="gd-task" id="documents-and-forms-form-c-on-screen-with-your-witness-beside-you" data-gd-task><h2 class="gd-h2">Form C on screen, with your witness beside you</h2><p class="gd-p">Form C is the lender or lessor permission for a financed or leased car. It needs one witness, and you can sign it on screen when your witness is with you.</p><div class="gd-stepblock gd-stepblock--below"><div class="gd-stepcol"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Open Documents. Under Forms to sign with witnesses, press Sign Form C on screen instead.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Tick that you read the form (a code to your phone or email is optional, unless CarmaCars turns it on).</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Draw your initials beside each of the three acknowledgments, tick the two consents and draw your signature.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">Hand the device to your witness, another adult. They type their full name and tick the statement &quot;I witnessed (your name) sign in my presence.&quot; Press <b class="gd-ui">Sign Form C</b>.</div></li></ol></div><figure class="gd-fig gd-fig--desk"><div class="gd-browser"><div class="gd-bar" aria-hidden="true"><i></i><i></i><i></i><span class="gd-addr">carmacars.ca/owner/documents/form-c/4898eb96-0cce-4efc-9fdd-740b4b4e9ad3</span></div><div class="gd-imgwrap" style="aspect-ratio:790/980"><img src="/guides/img/owner-16-form-c-screen-desktop-faa92983.jpg" alt="" loading="lazy" decoding="async" width="790" height="980"><span class="gd-pin" style="left:5.7%;top:13.6%" aria-hidden="true">2</span><span class="gd-pin" style="left:32.9%;top:55.1%" aria-hidden="true">3</span><span class="gd-pin" style="left:6.3%;top:82.2%" aria-hidden="true">4</span></div></div></figure></div></section><section class="gd-task" id="documents-and-forms-forms-c-and-d-on-paper-signed-with-witnesses" data-gd-task><h2 class="gd-h2">Forms C and D on paper, signed with witnesses</h2><p class="gd-p">Form D is a limited power of attorney (two witnesses), signed on paper. Form C can be signed on paper too, with one witness.</p><div class="gd-stepblock gd-stepblock--below"><div class="gd-stepcol"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Open Documents. Under Forms to sign with witnesses, press <b class="gd-ui">Print the form</b>. It is filled in, and every spot to sign or initial is marked SIGN HERE or INITIAL HERE.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Sign it in front of your witnesses. They sign and print their names in their spots.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Type each witness&#39;s full name in the boxes.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">On your phone, press <b class="gd-ui">Take a photo of the signed page</b>: one photo of each page. A PDF scan works too (<b class="gd-ui">Or choose a file</b>).</div></li></ol></div><figure class="gd-fig gd-fig--desk"><div class="gd-browser"><div class="gd-bar" aria-hidden="true"><i></i><i></i><i></i><span class="gd-addr">carmacars.ca/owner/documents</span></div><div class="gd-imgwrap" style="aspect-ratio:1440/742"><img src="/guides/img/owner-12-forms-c-d-desktop-21fbbe79.jpg" alt="" loading="lazy" decoding="async" width="1440" height="742"><span class="gd-pin" style="left:21.5%;top:32.5%" aria-hidden="true">1</span><span class="gd-pin" style="left:69.4%;top:50.7%" aria-hidden="true">3</span><span class="gd-pin" style="left:69.4%;top:60.4%" aria-hidden="true">4</span></div></div></figure></div><aside class="gd-box"><span class="gd-lbl">Tip</span><div>We check the photo and approve it, or send it back with what to fix. You get an email either way, and the page shows the status.</div></aside><aside class="gd-box"><span class="gd-lbl">Good to know</span><div>Why paper for Form D? It is a power of attorney, which cannot be signed electronically in Ontario, and its two witnesses sign in person.</div></aside></section><section class="gd-task" id="documents-and-forms-government-forms-filled-for-you" data-gd-task><h2 class="gd-h2">Government forms filled for you</h2><p class="gd-p">Each car&#39;s registry forms are prepared from your records, only the ones its onboarding method needs (013-1155 and 013-0169, for example, only for a Lease through a new corporation). Until we load the official PDF, you get a data sheet with the values.</p><div class="gd-stepblock gd-stepblock--below"><div class="gd-stepcol"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Open Documents and choose a form marked &quot;Official form, filled for you&quot;.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Press <b class="gd-ui">Download the filled form</b> and check each value.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Print it and sign it in ink. It is the official ServiceOntario form exactly as ServiceOntario publishes it, with only its empty text boxes filled in. Its boxes to tick and its signatures are done by hand, at the registry office or before you go, as we tell you.</div></li></ol></div><figure class="gd-fig gd-fig--desk"><div class="gd-browser"><div class="gd-bar" aria-hidden="true"><i></i><i></i><i></i><span class="gd-addr">carmacars.ca/owner/documents/forms/4d54a524-c28d-4bc4-8ad3-dd9558100a81/official</span></div><div class="gd-imgwrap" style="aspect-ratio:1440/732"><img src="/guides/img/owner-13-official-form-desktop-48614913.jpg" alt="" loading="lazy" decoding="async" width="1440" height="732"><span class="gd-pin" style="left:22.2%;top:29.5%" aria-hidden="true">2</span></div></div></figure></div><aside class="gd-box"><span class="gd-lbl">Good to know</span><div>ON00453 (a company&#39;s registrant number) is an Adobe form: open it in Adobe Acrobat Reader (free) to see and print it. Other PDF viewers show a blank page, as they do with the form downloaded from ServiceOntario.</div></aside><aside class="gd-box gd-box--warn"><span class="gd-lbl">Watch out</span><div>Official registry forms are never signed on screen. You pay ServiceOntario, the inspection station and the appraiser directly.</div></aside></section>');
select app.guide_release_section('admin', 'requests-offers-and-bookings', 'chapter', 'people-and-access', 'A booking starts as a request from the website, or as an offer you send yourself to a customer on the phone. You check it, adjust it and send the offer; an offer that is out is changed in place. After that, the booking page holds the money, documents, changes and history.

## The request queue

Open **Bookings** > **Requests**. The oldest waiting request is at the top.

1. Filter by New, Waiting on the renter, Pushed back, Offer out, Signing and payment, or Offer expired.
2. Waiting shows how long the renter has waited; red means past the first reply target (5 minutes, set in Program settings). Open a booking number to answer it.

![](/guides/img/admin-02-requests-desktop-6521282d.jpg "desktop; size: 1440 820; address: carmacars.ca/admin/requests; pins: 1 38.9 29.9, 2 22.2 43.3")

> Good to know: A request whose pickup time passes without an offer expires by itself, with a note in its history. The renter is not emailed unless "Email the renter when their request expires that way" is on in Program settings.

## Answer a request with an offer

1. The Review and offer tab shows the request as the renter sent it.
2. Adjust the car, the dates, the rate type, the places, the rates and fees, the deposit and extras.
3. Price on the right updates as you change things.
4. Add a message, choose how long the offer stays open, then press **Send the offer**.

![](/guides/img/admin-03-booking-review-desktop-353f3707.jpg "desktop; size: 1200 1550; address: carmacars.ca/admin/bookings/CC-10069?tab=review; pins: 1 5.0 6.5, 2 7.5 45.8, 3 74.2 42.6, 4 76.7 98.1")

5. Changed fields but not ready to send? Press **Save changes**. The panel "The offer as the renter sees it" shows the result.
6. Can''t do it? Press **Decline** and fill in Reason and any alternative.
7. Need an answer first? Press **Ask the renter** to send a question.

![](/guides/img/admin-03-booking-review-desktop-4dd4ed06.jpg "desktop; size: 500 80; address: carmacars.ca/admin/bookings/CC-10069?tab=review; pins: 6 41.2 52.5, 7 18.0 52.5")

Opening a request takes it for you: everyone else sees "Being answered by" your name and since when, with Send the offer and Decline off, until you send, decline or leave (20 minutes, renewed while you work; Program settings). Press **Take over** to answer one someone else holds; it is noted in the history. A second answer is refused with who answered and when. A request from the website opens to Sales after 15 minutes (Program settings); until then Admins, customer service and fleet answer it.

## Send an offer without a request

**Bookings** > **Send an offer**, or **Send an offer** on Bookings and on Requests. For a customer on the phone, by text or at the counter: no request needed.

1. The customer: type a name, phone or email and choose them. Not on file? Press **Add a new customer**: full legal name, mobile, email (the offer link goes there) and date of birth. A customer already on file with the same email or phone is shown with Use: one person, one record.
2. The car and the dates: type the car code, plate or name, or choose from the list; each car says Free or Not free for the dates. Then the pickup and return places (our location, delivery with the address and distance, airport).
3. The price: the Rate sheet, A total for the whole rental, or A rate per day (times the days). A price typed by hand needs its reason. At the top of the price, Amounts I type: Before tax, or After tax (HST included) to type what the renter pays for each line, worked back to the amount before tax for you (a line without HST stays as typed; the choice is remembered on this device). Or type the Total the renter pays (after tax): the rental charge is worked out so the total comes to it exactly, the other lines kept. Set the kilometres, a promo code, the deposit, a discount and each fee (an Admin), and how damage is covered: with option 3 the Protection Plan price is the one the renter pays.
4. How it is paid: the rental by card online (the usual way), e-Transfer, cash, cheque, bank transfer, platform payout or the insurer; the deposit by card hold, cash, e-Transfer or no deposit (an Admin).
5. Who found this client, the message to the renter, how long the offer is open, and how the link goes: Email, Text, both or neither.
6. The right side is the offer as the renter will see it, priced by the database as you type. Press **Send the offer**. **Save without sending** keeps it as a request for later.

> Good to know: It makes the same request and offer the website makes: the renter approves, signs and pays (or you record the payment), and only then is the car on the calendar. No "request received" email goes to the renter for an offer you send. Staff commissions and statements count it like any other booking.

## Change an offer that is out

The renter has the offer (Offered), or approved it and has not paid (Signing and payment). Press **Edit the offer** on the booking.

1. Change anything: the car, the dates, the places, the price, fees, the deposit, add-ons, how it is paid. Each changed field is highlighted and the before and after are listed. Amounts I type (Before tax or After tax) and the Total the renter pays (after tax) work as on Send an offer.
2. Write what changed in Message to the renter and choose how long the offer is open.
3. Press **Save and send the update**: the renter gets the new version by email or text (ticked), and the old version no longer counts. Or press **Save without telling the renter** and tell them yourself.
4. A confirmed booking is changed with **Change the booking** (Propose a change, below).

> Tip: No need to withdraw first. **Withdraw the offer** is only for taking it back for good; **Send again, later expiry** gives the renter more time, and **Renter approved by phone** records a yes given on a call.

## Edit a booking that has started

On a confirmed, on-trip or returned booking (an Admin: a closed one too), Overview, **Edit the booking**, **Edit**.

1. Change the pickup or the return (extend or shorten: the rental charge is worked out again at this booking''s rates), the car (on trip: the car it leaves goes to Out of service for Fleet to check), the rental charge for the trip, each fee, the kilometres a day, the deposit (an Admin) and the note.
2. Type why, if you like, and tick **Email the renter what changed**, or leave it off for a silent correction. Press **Save the changes**.
3. What is open now shows at once: **Email a pay link** or **Text a pay link** for exactly that amount, **Charge** the saved card (the renter agreed), or record cash or an e-Transfer on the Money tab.

> Good to know: Each edit is kept with who, when, why, before and after (Edits, under the form) and in the booking''s history. A closed booking''s owner split and the staff commission follow. To have the renter accept and sign first, use Propose a change instead.

## Fees, a forgotten fee and the balance

On the booking''s Money tab, Fees lists each fee. Press **Change or add a fee**.

1. Type a new amount (for the whole trip, before HST) beside any fee, or choose one not on the booking (the young driver fee shows its price for these dates), or add a charge of its own with or without HST.
2. Press **Save the fees**. The balance shows by part (rental, fees) with the pay link, the saved card and Record a payment beside it.
3. The renter sees the balance on their booking with a Pay button, and pays by card on Stripe''s form.

> Good to know: Every change is recorded (Changes to the fees): the amount before and after, who and why. Customer service and sales may change fees while Program settings, Staff may change fees, is on.

## Correct a renter''s details

On the renter''s page (People, Renters) or on any of their bookings, **Edit renter**.

1. Correct the name, email, phone, date of birth, licence, home address (start typing to find it) or the staff note.
2. A new email also becomes their sign-in at once (no confirmation needed for a typo you correct); tick **Email the renter a link to set a password** to send one there. Unsigned agreements and offers go to the new address.
3. Press **Save the renter**. An email that another renter has is refused with their name; the same phone is a warning.
4. The same person entered twice? Possible duplicates (same email, same phone, or same name and date of birth) shows under the renter. **Merge into this record** moves the other record''s bookings, licences, cards, payments, documents and messages here and fills any detail missing here; the other record stays, blocked, with the merge in both histories.

## Payments by part: the rental, the deposit and later charges

On the booking''s Money tab, Money by part shows what is still open for the rental, the fees and later charges, the deposit and the card on file. Each part is paid its own way, in any mix: for example the deposit in cash and the rental by card.

1. **Record a payment**: choose what it is for (the rental, fees, the deposit or a later charge) and how it was paid (e-Transfer, cash, cheque, bank transfer, platform payout, the insurer). An e-Transfer, cheque or transfer needs its reference. Press **Record it**. The renter gets a receipt; **Print** prints one to hand over.
2. **Collect a card**: a payment (Everything open by default: the rental, the fees and any later charge in one), the deposit hold or saving the card. The renter types the card in Stripe''s secure form: on this device (**Open the card form**, then hand it over) or by a link texted or emailed to them (**Send the link**). Staff never type a card number.
3. A deposit hold lasts about 7 days and shows the days left; while the car is out it is collected by itself before it lapses. After the return, settle the deposit (below). **Capture the hold** for all of it keeps the money; a part capture or **Release the hold** waits for the settlement while the car is out or something is open (an Admin may do it with the reason).
4. **Charge the saved card** (Finance or an Admin): extra kilometres, fuel, damage or a late return, with the reason the renter''s receipt shows. For a rental over 7 days, save the card and charge the deposit this way.
5. An offer paid another way: once the renter approved and signed and the money is recorded, the booking is confirmed (or press **Confirm the booking**).
6. A deposit taken in cash or by e-Transfer is given back the same way after the return: Finance gets a task; press **Returned** with the reference or receipt number.

> Good to know: Statements, reconciliation and the deposit settlement read each payment with its method: a cash deposit is never refunded to a card.

## Settle the deposit

The deposit is never given back by itself. Finance or an Admin settles it after the return: on the booking''s Money tab, under Deposit, press **Settle the deposit**. Issue the Check-in statement first.

1. The form shows the deposit, what is still available, the charges owed from the statement and what is taken from the deposit for them. What the deposit does not cover is charged to the card on file; with no card (or a card declined), the renter gets a pay link by email and text, and Finance has a task until it is paid.
2. Tolls and tickets can take up to 7 days to come in. Inside that window the whole rest of the deposit is filled in as the hold-back, until the window ends. To give it back sooner, tick Release now anyway: a toll that comes in later is charged to the card on file.
3. Something still open keeps the whole deposit: an incident, a claim, new damage at the return not priced, damage found later not billed, a toll or ticket on the car during the rental not matched or not charged, a card dispute, or charges not on a statement yet. The form lists them. Only an Admin can release part of it, with the reason; it is recorded.
4. Damage: **Keep the whole deposit (damage)** turns what is left of the deposit into a damage charge, with what was damaged and the photos; the renter is told. **Bill damage** adds a damage charge up to the $2,500 deductible (more goes through a claim): the deposit pays first, then the card on file.
5. Press **Settle**. The money moves at Stripe at once: the charges are collected and what is not owed is refunded or the hold released. A step Stripe refuses is tried again by itself, and Finance gets a task if it keeps failing.

> Good to know: A card hold lapses after about 7 days. While the car is out, or returned and not settled, the hold is collected in full a day and a half before it lapses: that keeps the money, and the settlement refunds what is not owed. A hold that lapses anyway is charged to the saved card, and Finance is told at once.

## A booking

Open **Bookings** > **Bookings**, then a booking number. Or type the number in the search box.

1. Tabs: Overview, Money, Changes, History, and Drivers and documents.
2. Overview shows the trip, the renter, what is still missing for the handover, and the price.
3. Open tasks for this booking, with the queue and the due time.
4. Top right: **Stop blocking the calendar**, **Cancel for the renter** and **Cancel by CarmaCars**.
5. Under the booking number: where the booking is on its way, from Request to Closed, with the dates, the days, the total and who pays.

![](/guides/img/admin-04-booking-desktop-b56b668a.jpg "desktop; size: 1440 960; address: carmacars.ca/admin/bookings/CC-10065; pins: 2 50.0 46.6, 4 85.4 14.5, 5 22.9 26.8")

## Check a car out or in

From the booking, with your phone or a tablet: the same checklist field staff use.

1. A confirmed booking shows **Check out (pickup)** under Check-out, check-in and signing; a booking on rent shows **Check in (return)**. Today lists the check-outs and check-ins due, each with **Check out** or **Check in**.
2. The checklist opens: the ready check, the renter and their licence and card, the odometer (km) and fuel or charge, the keys, the photo set (every side, the wheels, the interior, the odometer and fuel gauge, the plate), damage marks with close-ups, then the renter and you sign.
3. Photos wait on the device without a connection and upload in the background. Each keeps its time, and the place when the device allows location.
4. A field job of the booking is taken over (the history says so); with no job, one is made for you. When done, press **See the photo report**.

> Tip: Fleet, Sales and Customer service check cars out and in the same way from their own booking page.

## The photo report, late returns and the return charges

Under Check-out, check-in and signing, press **Photo report**.

1. The report shows the due-back time, the actual check-out and check-in, Late by (or Overdue by while the car is out), the odometer and kilometres over the allowance, the fuel or charge out and in, every photo with its time and place, and the damage.
2. At check-in the late return (after the grace period of the fee defaults), the mileage overage and the fuel or recharging are written to the return charges at once. A gas car with no pump receipt is priced at the refill price per eighth (Program settings) plus the markup until the receipt is entered.
3. Not charging one? Press **Waive** beside it and give the reason: it stays waived if the charges are worked out again.
4. The time was wrong? Press **Correct the check-in time** (or the check-out time) with the reason: lateness and the late charges follow, and the history keeps both times.
5. The renter gets the same report (without these buttons) by email and in their Documents. Late by shows on the booking and in the Bookings list.

## Signatures on the spot, or by link

The renter or an additional driver signs the rental agreement on your device, or on their own phone.

1. While a signature is missing, the booking shows **Sign now on this device**, **Email the signing link** and **Text the signing link**.
2. No agreement made yet (the renter has not saved their details at home)? **Sign now on this device** still shows: press **Prepare the agreement to sign now** and it is made on the spot.
3. **Sign now on this device**: confirm the name matches their licence and that you saw the original licence (photograph it if none is on file), then press **Hand the device to** and their name.
4. They read both agreements (CarmaCars'' and Blind Spot''s), tick the statements and sign. Then **Back to the staff view** for the next signer.
5. The record is the same as signing online, and says it was signed in person, collected by you, on your device. It is printed on the signed copy''s signature record page.

## Rental agreements: every version, every field

The booking''s Rental agreements card: the current version of CarmaCars'' and Blind Spot''s agreements, every earlier one, and what is still blank.

1. Once the agreement is signed and countersigned, any change to what it prints makes a new version of both documents by itself: the dates, the price lines, the car, a driver added or corrected, the coverage, the deposit or how it was paid, an address.
2. A change to the dates, the price, the car, the drivers or the coverage option is signed again: the renter (and each driver it affects) gets their link by email and text, and the card shows "Agreement v3 waiting for signature". A correction (a typo in an address, a plate written differently) is filed without signing; the renter gets the corrected copy by email.
3. Check-out makes the "as picked up" copy (time out, km out, fuel out, the car''s plate and VIN, the check-out report), countersigned by whoever checked the car out; check-in makes the closing copy (time in, km in, driven and charged, fuel in, late hours, damage, the return charges, the final totals). Both go to the renter by email.
4. **Every version** lists each one with what changed and both PDFs. **Resend the signing links**, or press the button with their first name beside it to have them sign on your phone or tablet.
5. The card lists what the agreements still print blank (a licence expiry, the insurer''s policy number, the insured vehicle, a VIN). Type the values and press **Save the missing fields**: the agreements follow.
6. Check-out stops while a field a claim needs is blank. An Admin can let it go ahead: type the reason and press **Override**; the reason is in the booking''s history.
7. **Make the agreements again** checks both against the booking at once (they also follow every change by themselves).

## Signing that holds up in a dispute

Every signature on the site is made the same way: rental agreements, amendments and new versions (remotely or on your device), and the owner agreements, schedules and forms, a co-owner''s link, the partner, investment and staff agreements.

1. The signer confirms it is them with a 6-digit code sent to their phone or email on file; the licence on file is shown.
2. They say they read the documents, initial the key terms (damage and the deductible, the deposit and later charges, fuel, kilometres and late returns, their coverage, cancellation), give three consents (to sign electronically, to receive records electronically, to card charges under the agreement) and draw their signature.
3. Owners, partners, investors and staff do the same for their documents: the code, the reading, the key terms of their documents initialled (for example the Enrollment Agreement''s three confirmations, Form C''s acknowledgments, Schedule C, the staff agreement''s confidentiality), two consents and the drawn signature. Form C''s witness still types their name beside the owner.
4. Each step is recorded with its time, IP address and device, and the place when the device shares it. The signed PDFs end with a certificate of completion; anyone can check a signed file at `carmacars.ca/verify`.
5. Typed names are off. For a signer who cannot draw, an Admin can turn on the accessibility fallback: **Settings** > **Program**, Esign typed fallback.

## Card disputes: the evidence pack

Everything that proves the rental, in one PDF for Stripe.

1. When a card payment is disputed, the evidence pack is built by itself: the signed agreements with their certificates, the check-out and check-in reports with photos, kilometres and fuel, the licence, the payments and charges, every message to the renter, and the card checks from Stripe. It is staged in Stripe as the dispute''s evidence, and To do gets an urgent task.
2. Open the booking: the Rental agreements card shows the pack. Press **Download** to check it, then **Submit to Stripe** before the evidence date.
3. **Build the dispute evidence pack** makes one at any time (an Admin or Finance).

## The licence before an offer is accepted

Front, back and a selfie, from the request on.

1. After sending a request the renter is asked for their licence. A licence already on file from an earlier booking is used again while it is valid after the return.
2. The offer cannot be accepted (by the renter, or by you on their word) and nothing is paid until the licence and its expiry date are on file.
3. Review the images as usual with **Review documents**: the card Renter documents is on Review and offer too.
4. The switch is in **Settings** > **Program**, Booking requests and offers: Booking licence required (on), with the selfie (on).

## Renter documents: licence and proof of coverage

A renter''s licence photos, selfie and proof of coverage (OPCF 27 or a credit card''s rental coverage) are checked before the handover. You check them yourself; no task is needed.

1. A booking with documents waiting is a line on To do: "Check ''s documents for booking ", marked Now when the pickup is within two days. Press **Review documents**.
2. The pop-up shows each driver''s images and the coverage: the insurer, policy number and expiry, or the card, its type and whether the name matches.
3. What to check is written once at the top. One wrong? Open **Reject this one** under it, type the reason the renter reads and press **Reject**: they are asked for a new one.
4. Then press **Approve all**: every image, the proof of coverage and the Protection Plan still waiting are approved in one step. Anything the system refuses is named with the reason.
5. The same pop-up is on the booking: the card Renter documents (**Review documents**) on Overview and on Drivers and documents.

> Tip: Each opening of a renter''s documents is logged. The links to the images last one minute. Field staff can also check a licence in person at the check-out (photos and four checks): the history says "checked in person". Field staff also review the licence images (not the coverage) of bookings on their own jobs in the next 7 days from My jobs, with the same Approve all or a reason to reject: the history says the reviewer''s role, field. Sales review the licence images (not the coverage) of any booking being arranged or under way from their To do or the booking, with the same Approve all or a reason to reject: the history says the role, sales.

## Payments by day

**Money** > **Payments by day**: every payment and refund of a day or a range, by method, the cash drawer and the refunds waiting. Finance has the same screen.

1. Choose From and To and the methods (card, e-Transfer, cash, cheque, platform payout, insurer, bank transfer, pre-authorized debit, other), then press **Show**.
2. Totals by method and for each day; cards read as the card and its last four digits, never a code.
3. The cash drawer: expected (cash in less cash given back) against the count Finance records with **Record the count**; a difference shows over or short.
4. Refunds waiting: every refund asked for anywhere with the policy maths. **Approve** or **Decline** with the reason in the row, then **Issue the refund**.
5. **Export CSV** for the bookkeeper.

## Propose a change to a confirmed booking

The renter gets an email and answers on their booking. The calendar moves only when they accept.

1. Open the booking''s Changes tab. Under Propose a change, set the new pickup, return or car.
2. To price it by hand, type a New rental charge before tax. Leave it empty to use the car''s rates.
3. Write the Reason, for the renter. They read it.
4. Press **Preview the price**, then **Send to the renter**.

![](/guides/img/admin-05-booking-changes-desktop-97008b21.jpg "desktop; size: 1200 520; address: carmacars.ca/admin/bookings/CC-10065?tab=changes; pins: 1 17.5 33.7, 2 9.2 50.0, 3 38.3 71.2, 4 12.9 91.9")

## Who a booking is credited to

Overview (and Review and offer) shows the Sales credit: the staff member the booking counts for in their sales.

1. A quote or a rental is credited to whoever created or added it. A request from the website is credited to whoever sent its first offer.
2. To give it to someone else, press **Reassign**, choose who (or Nobody), say whether they sourced the client and write the reason. The booking''s history and the audit log keep it, and the deal stays in the same week and month.
3. Sourced means the staff member chose I sourced this client when they entered it, it came with a field staff referral link, or you credited it. Only a sourced booking earns a staff commission. A website request earns none unless you credit someone.
4. Someone said they sourced a website request? The credit line shows the claim: press **Credit them** or **Not theirs**, with a reason.
5. A price typed by hand shows beside the rate-sheet price, with the reason. A price under the floor or past the discount limit is flagged: press **Mark reviewed** once you have looked at it.

> Tip: The renter has 48 hours to accept (and sign the amendment) or decline, with one reminder. Any extra is charged to their Card on File; a lower price raises a refund for your approval.

## Review requests

Every renter is asked for a review by email and text, as they chose, only from 9 am to 9 pm Toronto time. Nothing needs setting up.

| Message | When |
| --- | --- |
| Mid-trip check-in | Rentals of 2 days or more, 24 hours after the pickup: "How is the car? Reply or call if anything is off." No review ask. |
| Review request | 1 hour after the check-in. It links the review page: the renter taps what they liked, adds a sentence, and gets a short draft to copy and post on Google. |
| Reminder | 24 hours after the request. |
| Final follow-up | 7 days after the request. Nothing more after it. |

1. The booking page has the card Review requests: each message with when it went or when it will go, and why it stopped.
2. **Ask for a review** sends the request now (or at 9 am if it is later than 9 pm), on any booking on a trip, returned or closed. Not twice in 24 hours.
3. On hold: a return or later charge (late return, kilometres, fuel, cleaning, smoking, damage, tolls and tickets) is not settled or waived, or an incident or dispute is open. The request goes by itself once they are. Press **Send anyway** to send it now.
4. **Mark reviewed** stops the messages when the renter tells you they already reviewed.

The messages also stop by themselves when the renter presses "I already left a review", leaves a review on the site, unsubscribes, or a Google review is matched to them. **Bookings** > **Reviews** has the numbers (requests sent, on hold, reviews detected, the average rating), the hold list and the Google reviews to match.

> Tip: The draft is made only from what the renter picked and wrote, and from the booking (the car, how long, delivery or pickup). Everyone gets the Google link, whatever their stars; a renter who gives 3 stars or fewer also sees "Something wasn''t right? Tell us directly".

## What the owner sees, and owner deductions

Each booking on an owner''s or partner''s car shows the card What the owner sees at the top of its page.

1. **Hide from the owner** keeps the booking''s revenue from the owner until the car is returned, or until the owner statement covering it is approved. The owner sees the booking as Booked with its dates, and the calendar still shows the car busy. Add a reason if you like: it is kept in the history.
2. **Show to the owner** shows it now. Approving the statement shows every hidden booking on it by itself.
3. Not shown to the owner is for a booking with no owner revenue (an insurance placeholder, a shareholder''s or the owner''s own use at no charge): the owner sees only that the car is unavailable for those dates. A booking with revenue cannot be set this way.
4. Add a rental and Send an offer have What the owner sees. It starts from Settings > Program, Owners and fleet: Owners see a booking''s revenue (right away by default).
5. On the Money tab, Owner deductions on this booking: **Add a booking expense** (cleaning, repair, fuel, platform fee or other, the amount, the reason the owner reads, a receipt number) comes off before Owner Revenue.
6. **Set the Revenue Share for this booking** applies within the car''s signed terms. Above the terms only an Admin can, with Above the signed terms ticked and the reason. **Back to the car''s terms** undoes it.
7. Add a rental has the same under The car''s owner.

> Good to know: The owner''s statement always includes every booking at its true amounts and lists each deduction with its reason, so the payout is always right. Customer service and sales add deductions only while Program settings let them change fees.
', 'Requests, offers and bookings', 'Send an offer with or without a request, change it in place, take payments by part, run a booking, propose a change.',
  'A booking starts as a request from the website, or as an offer you send yourself to a customer on the phone. You check it, adjust it and send the offer; an offer that is out is changed in place. After that, the booking page holds the money, documents, changes and history.

## The request queue

Open **Bookings** > **Requests**. The oldest waiting request is at the top.

1. Filter by New, Waiting on the renter, Pushed back, Offer out, Signing and payment, or Offer expired.
2. Waiting shows how long the renter has waited; red means past the first reply target (5 minutes, set in Program settings). Open a booking number to answer it.

![](/guides/img/admin-02-requests-desktop-6521282d.jpg "desktop; size: 1440 820; address: carmacars.ca/admin/requests; pins: 1 38.9 29.9, 2 22.2 43.3")

> Good to know: A request whose pickup time passes without an offer expires by itself, with a note in its history. The renter is not emailed unless "Email the renter when their request expires that way" is on in Program settings.

## Answer a request with an offer

1. The Review and offer tab shows the request as the renter sent it.
2. Adjust the car, the dates, the rate type, the places, the rates and fees, the deposit and extras.
3. Price on the right updates as you change things.
4. Add a message, choose how long the offer stays open, then press **Send the offer**.

![](/guides/img/admin-03-booking-review-desktop-353f3707.jpg "desktop; size: 1200 1550; address: carmacars.ca/admin/bookings/CC-10069?tab=review; pins: 1 5.0 6.5, 2 7.5 45.8, 3 74.2 42.6, 4 76.7 98.1")

5. Changed fields but not ready to send? Press **Save changes**. The panel "The offer as the renter sees it" shows the result.
6. Can''t do it? Press **Decline** and fill in Reason and any alternative.
7. Need an answer first? Press **Ask the renter** to send a question.

![](/guides/img/admin-03-booking-review-desktop-4dd4ed06.jpg "desktop; size: 500 80; address: carmacars.ca/admin/bookings/CC-10069?tab=review; pins: 6 41.2 52.5, 7 18.0 52.5")

Opening a request takes it for you: everyone else sees "Being answered by" your name and since when, with Send the offer and Decline off, until you send, decline or leave (20 minutes, renewed while you work; Program settings). Press **Take over** to answer one someone else holds; it is noted in the history. A second answer is refused with who answered and when. A request from the website opens to Sales after 15 minutes (Program settings); until then Admins, customer service and fleet answer it.

## Send an offer without a request

**Bookings** > **Send an offer**, or **Send an offer** on Bookings and on Requests. For a customer on the phone, by text or at the counter: no request needed.

1. The customer: type a name, phone or email and choose them. Not on file? Press **Add a new customer**: full legal name, mobile, email (the offer link goes there) and date of birth. A customer already on file with the same email or phone is shown with Use: one person, one record.
2. The car and the dates: type the car code, plate or name, or choose from the list; each car says Free or Not free for the dates. Then the pickup and return places (our location, delivery with the address and distance, airport).
3. The price: the Rate sheet, A total for the whole rental, or A rate per day (times the days). A price typed by hand needs its reason. At the top of the price, Amounts I type: Before tax, or After tax (HST included) to type what the renter pays for each line, worked back to the amount before tax for you (a line without HST stays as typed; the choice is remembered on this device). Or type the Total the renter pays (after tax): the rental charge is worked out so the total comes to it exactly, the other lines kept. Set the kilometres, a promo code, the deposit, a discount and each fee (an Admin), and how damage is covered: with option 3 the Protection Plan price is the one the renter pays.
4. How it is paid: the rental by card online (the usual way), e-Transfer, cash, cheque, bank transfer, platform payout or the insurer; the deposit by card hold, cash, e-Transfer or no deposit (an Admin).
5. Who found this client, the message to the renter, how long the offer is open, and how the link goes: Email, Text, both or neither.
6. The right side is the offer as the renter will see it, priced by the database as you type. Press **Send the offer**. **Save without sending** keeps it as a request for later.

> Good to know: It makes the same request and offer the website makes: the renter approves, signs and pays (or you record the payment), and only then is the car on the calendar. No "request received" email goes to the renter for an offer you send. Staff commissions and statements count it like any other booking.

## Change an offer that is out

The renter has the offer (Offered), or approved it and has not paid (Signing and payment). Open **More actions** on the booking and press **Edit the offer**.

1. Change anything: the car, the dates, the places, the price, fees, the deposit, add-ons, how it is paid. Each changed field is highlighted and the before and after are listed. Amounts I type (Before tax or After tax) and the Total the renter pays (after tax) work as on Send an offer.
2. Write what changed in Message to the renter and choose how long the offer is open.
3. Press **Save and send the update**: the renter gets the new version by email or text (ticked), and the old version no longer counts. Or press **Save without telling the renter** and tell them yourself.
4. A confirmed booking is changed with **Change the booking** (Propose a change, below).

> Tip: No need to withdraw first. **Withdraw the offer** is only for taking it back for good; **Send again, later expiry** gives the renter more time, and **Renter approved by phone** records a yes given on a call.

## Edit a booking that has started

On a confirmed, on-trip or returned booking (an Admin: a closed one too), Overview, **Edit the booking**, **Edit**.

1. Change the pickup or the return (extend or shorten: the rental charge is worked out again at this booking''s rates), the car (on trip: the car it leaves goes to Out of service for Fleet to check), the rental charge for the trip, each fee, the kilometres a day, the deposit (an Admin) and the note.
2. Type why, if you like, and tick **Email the renter what changed**, or leave it off for a silent correction. Press **Save the changes**.
3. What is open now shows at once: **Email a pay link** or **Text a pay link** for exactly that amount, **Charge** the saved card (the renter agreed), or record cash or an e-Transfer on the Money tab.

> Good to know: Each edit is kept with who, when, why, before and after (Edits, under the form) and in the booking''s history. A closed booking''s owner split and the staff commission follow. To have the renter accept and sign first, use Propose a change instead.

## Fees, a forgotten fee and the balance

On the booking''s Money tab, Fees lists each fee. Press **Change or add a fee**.

1. Type a new amount (for the whole trip, before HST) beside any fee, or choose one not on the booking (the young driver fee shows its price for these dates), or add a charge of its own with or without HST.
2. Press **Save the fees**. The balance shows by part (rental, fees) with the pay link, the saved card and Record a payment beside it.
3. The renter sees the balance on their booking with a Pay button, and pays by card on Stripe''s form.

> Good to know: Every change is recorded (Changes to the fees): the amount before and after, who and why. Customer service and sales may change fees while Program settings, Staff may change fees, is on.

## Correct a renter''s details

On the renter''s page (People, Renters) or on any of their bookings, **Edit renter**.

1. Correct the name, email, phone, date of birth, licence, home address (start typing to find it) or the staff note.
2. A new email also becomes their sign-in at once (no confirmation needed for a typo you correct); tick **Email the renter a link to set a password** to send one there. Unsigned agreements and offers go to the new address.
3. Press **Save the renter**. An email that another renter has is refused with their name; the same phone is a warning.
4. The same person entered twice? Possible duplicates (same email, same phone, or same name and date of birth) shows under the renter. **Merge into this record** moves the other record''s bookings, licences, cards, payments, documents and messages here and fills any detail missing here; the other record stays, blocked, with the merge in both histories.

## Payments by part: the rental, the deposit and later charges

On the booking''s Money tab, Money by part shows what is still open for the rental, the fees and later charges, the deposit and the card on file. Each part is paid its own way, in any mix: for example the deposit in cash and the rental by card.

1. **Record a payment**: choose what it is for (the rental, fees, the deposit or a later charge) and how it was paid (e-Transfer, cash, cheque, bank transfer, platform payout, the insurer). An e-Transfer, cheque or transfer needs its reference. Press **Record it**. The renter gets a receipt; **Print** prints one to hand over.
2. **Collect a card**: a payment (Everything open by default: the rental, the fees and any later charge in one), the deposit hold or saving the card. The renter types the card in Stripe''s secure form: on this device (**Open the card form**, then hand it over) or by a link texted or emailed to them (**Send the link**). Staff never type a card number.
3. A deposit hold lasts about 7 days and shows the days left; while the car is out it is collected by itself before it lapses. After the return, settle the deposit (below). **Capture the hold** for all of it keeps the money; a part capture or **Release the hold** waits for the settlement while the car is out or something is open (an Admin may do it with the reason).
4. **Charge the saved card** (Finance or an Admin): extra kilometres, fuel, damage or a late return, with the reason the renter''s receipt shows. For a rental over 7 days, save the card and charge the deposit this way.
5. An offer paid another way: once the renter approved and signed and the money is recorded, the booking is confirmed (or press **Confirm the booking**).
6. A deposit taken in cash or by e-Transfer is given back the same way after the return: Finance gets a task; press **Returned** with the reference or receipt number.

> Good to know: Statements, reconciliation and the deposit settlement read each payment with its method: a cash deposit is never refunded to a card.

## Settle the deposit

The deposit is never given back by itself. Finance or an Admin settles it after the return: on the booking''s Money tab, under Deposit, press **Settle the deposit**. Issue the Check-in statement first.

1. The form shows the deposit, what is still available, the charges owed from the statement and what is taken from the deposit for them. What the deposit does not cover is charged to the card on file; with no card (or a card declined), the renter gets a pay link by email and text, and Finance has a task until it is paid.
2. Tolls and tickets can take up to 7 days to come in. Inside that window the whole rest of the deposit is filled in as the hold-back, until the window ends. To give it back sooner, tick Release now anyway: a toll that comes in later is charged to the card on file.
3. Something still open keeps the whole deposit: an incident, a claim, new damage at the return not priced, damage found later not billed, a toll or ticket on the car during the rental not matched or not charged, a card dispute, or charges not on a statement yet. The form lists them. Only an Admin can release part of it, with the reason; it is recorded.
4. Damage: **Keep the whole deposit (damage)** turns what is left of the deposit into a damage charge, with what was damaged and the photos; the renter is told. **Bill damage** adds a damage charge up to the $2,500 deductible (more goes through a claim): the deposit pays first, then the card on file.
5. Press **Settle**. The money moves at Stripe at once: the charges are collected and what is not owed is refunded or the hold released. A step Stripe refuses is tried again by itself, and Finance gets a task if it keeps failing.

> Good to know: A card hold lapses after about 7 days. While the car is out, or returned and not settled, the hold is collected in full a day and a half before it lapses: that keeps the money, and the settlement refunds what is not owed. A hold that lapses anyway is charged to the saved card, and Finance is told at once.

## A booking

Open **Bookings** > **Bookings**, then a booking number. Or type the number in the search box.

1. Tabs: Overview, Money, Changes, History, and Drivers and documents.
2. Overview shows the trip, the renter, what is still missing for the handover, and the price.
3. Open tasks for this booking, with the queue and the due time.
4. Top right: **Email the renter** and **More actions**, the menu with **Edit the offer**, **Stop blocking the calendar**, **Cancel for the renter**, **Cancel by CarmaCars** and the rest.
5. Under the booking number: **Next step**, what happens next and who does it, with one button for that step (for example **Send the offer**, **Sign on this device** or **Check out the car**); then where the booking is on its way, from Request to Closed, with the dates, the days, the total and who pays.

![](/guides/img/admin-04-booking-desktop-b56b668a.jpg "desktop; size: 1440 960; address: carmacars.ca/admin/bookings/CC-10065; pins: 2 50.0 46.6, 4 85.4 14.5, 5 22.9 26.8")

## Check a car out or in

From the booking, with your phone or a tablet: the same checklist field staff use.

1. A confirmed booking shows **Check out (pickup)** under Check-out, check-in and signing; a booking on rent shows **Check in (return)**. Today lists the check-outs and check-ins due, each with **Check out** or **Check in**.
2. The checklist opens: the ready check, the renter and their licence and card, the odometer (km) and fuel or charge, the keys, the photo set (every side, the wheels, the interior, the odometer and fuel gauge, the plate), damage marks with close-ups, then the renter and you sign.
3. Photos wait on the device without a connection and upload in the background. Each keeps its time, and the place when the device allows location.
4. A field job of the booking is taken over (the history says so); with no job, one is made for you. When done, press **See the photo report**.

> Tip: Fleet, Sales and Customer service check cars out and in the same way from their own booking page.

## The photo report, late returns and the return charges

Under Check-out, check-in and signing, press **Photo report**.

1. The report shows the due-back time, the actual check-out and check-in, Late by (or Overdue by while the car is out), the odometer and kilometres over the allowance, the fuel or charge out and in, every photo with its time and place, and the damage.
2. At check-in the late return (after the grace period of the fee defaults), the mileage overage and the fuel or recharging are written to the return charges at once. A gas car with no pump receipt is priced at the refill price per eighth (Program settings) plus the markup until the receipt is entered.
3. Not charging one? Press **Waive** beside it and give the reason: it stays waived if the charges are worked out again.
4. The time was wrong? Press **Correct the check-in time** (or the check-out time) with the reason: lateness and the late charges follow, and the history keeps both times.
5. The renter gets the same report (without these buttons) by email and in their Documents. Late by shows on the booking and in the Bookings list.

## Signatures on the spot, or by link

The renter or an additional driver signs the rental agreement on your device, or on their own phone.

1. While a signature is missing, the booking shows **Sign now on this device**, **Email the signing link** and **Text the signing link**.
2. No agreement made yet (the renter has not saved their details at home)? **Sign now on this device** still shows: press **Prepare the agreement to sign now** and it is made on the spot.
3. **Sign now on this device**: confirm the name matches their licence and that you saw the original licence (photograph it if none is on file), then press **Hand the device to** and their name.
4. They read both agreements (CarmaCars'' and Blind Spot''s), tick the statements and sign. Then **Back to the staff view** for the next signer.
5. The record is the same as signing online, and says it was signed in person, collected by you, on your device. It is printed on the signed copy''s signature record page.

## Rental agreements: every version, every field

The booking''s Rental agreements card: the current version of CarmaCars'' and Blind Spot''s agreements, every earlier one, and what is still blank.

1. Once the agreement is signed and countersigned, any change to what it prints makes a new version of both documents by itself: the dates, the price lines, the car, a driver added or corrected, the coverage, the deposit or how it was paid, an address.
2. A change to the dates, the price, the car, the drivers or the coverage option is signed again: the renter (and each driver it affects) gets their link by email and text, and the card shows "Agreement v3 waiting for signature". A correction (a typo in an address, a plate written differently) is filed without signing; the renter gets the corrected copy by email.
3. Check-out makes the "as picked up" copy (time out, km out, fuel out, the car''s plate and VIN, the check-out report), countersigned by whoever checked the car out; check-in makes the closing copy (time in, km in, driven and charged, fuel in, late hours, damage, the return charges, the final totals). Both go to the renter by email.
4. **Every version** lists each one with what changed and both PDFs. **Resend the signing links**, or press the button with their first name beside it to have them sign on your phone or tablet.
5. The card lists what the agreements still print blank (a licence expiry, the insurer''s policy number, the insured vehicle, a VIN). Type the values and press **Save the missing fields**: the agreements follow.
6. Check-out stops while a field a claim needs is blank. An Admin can let it go ahead: type the reason and press **Override**; the reason is in the booking''s history.
7. **Make the agreements again** checks both against the booking at once (they also follow every change by themselves).
8. **Edit the wording** (Admin only) changes CarmaCars'' agreement text for this booking: press **Change** beside a clause, edit its text, say why and press **Save the wording**; **Add** writes Additional terms at the end of Part 2. Only clauses not required by law or the insurer can be removed; the consents are fixed, and Blind Spot''s form (the insurer''s official form) is never changed. Before the renter signs, the agreement is made again; after, the change is a new version they sign, and **Every version** shows each clause before and after.

## Signing that holds up in a dispute

Every signature on the site is made the same way: rental agreements, amendments and new versions (remotely or on your device), and the owner agreements, schedules and forms, a co-owner''s link, the partner, investment and staff agreements.

1. The licence on file is shown. A 6-digit code to their phone or email on file is optional: the signer may press **Verify by code (optional)**, and Program settings, E-signing, **ask for a one-time code** makes it a required first step again (off by default). Without the code, the certificate says the identity was not confirmed by a code.
2. They say they read the documents, initial the key terms (each initials box is saved with **Save initials**; **Clear** takes it back to initial again) (damage and the deductible, the deposit and later charges, fuel, kilometres and late returns, their coverage, cancellation), give three consents (to sign electronically, to receive records electronically, to card charges under the agreement) and draw their signature.
3. Owners, partners, investors and staff do the same for their documents: the code, the reading, the key terms of their documents initialled (for example the Enrollment Agreement''s three confirmations, Form C''s acknowledgments, Schedule C, the staff agreement''s confidentiality), two consents and the drawn signature. Form C''s witness still types their name beside the owner.
4. Each step is recorded with its time, IP address and device, and the place when the device shares it. The signed PDFs end with a certificate of completion; anyone can check a signed file at `carmacars.ca/verify`.
5. Typed names are off. For a signer who cannot draw, an Admin can turn on the accessibility fallback: **Settings** > **Program**, Esign typed fallback.

## Card disputes: the evidence pack

Everything that proves the rental, in one PDF for Stripe.

1. When a card payment is disputed, the evidence pack is built by itself: the signed agreements with their certificates, the check-out and check-in reports with photos, kilometres and fuel, the licence, the payments and charges, every message to the renter, and the card checks from Stripe. It is staged in Stripe as the dispute''s evidence, and To do gets an urgent task.
2. Open the booking: the Rental agreements card shows the pack. Press **Download** to check it, then **Submit to Stripe** before the evidence date.
3. **Build the dispute evidence pack** makes one at any time (an Admin or Finance).

## The licence before an offer is accepted

Front, back and a selfie, from the request on.

1. After sending a request the renter is asked for their licence. A licence already on file from an earlier booking is used again while it is valid after the return.
2. The offer cannot be accepted (by the renter, or by you on their word) and nothing is paid until the licence and its expiry date are on file.
3. Review the images as usual with **Review documents**: the card Renter documents is on Review and offer too.
4. The switch is in **Settings** > **Program**, Booking requests and offers: Booking licence required (on), with the selfie (on).

## Renter documents: licence and proof of coverage

A renter''s licence photos, selfie and proof of coverage (OPCF 27 or a credit card''s rental coverage) are checked before the handover. You check them yourself; no task is needed.

1. A booking with documents waiting is a line on To do: "Check ''s documents for booking ", marked Now when the pickup is within two days. Press **Review documents**.
2. The pop-up shows each driver''s images and the coverage: the insurer, policy number and expiry, or the card, its type and whether the name matches.
3. What to check is written once at the top. One wrong? Open **Reject this one** under it, type the reason the renter reads and press **Reject**: they are asked for a new one.
4. Then press **Approve all**: every image, the proof of coverage and the Protection Plan still waiting are approved in one step. Anything the system refuses is named with the reason.
5. The same pop-up is on the booking: the card Renter documents (**Review documents**) on Overview and on Drivers and documents.

> Tip: Each opening of a renter''s documents is logged. The links to the images last one minute. Field staff can also check a licence in person at the check-out (photos and four checks): the history says "checked in person". Field staff also review the licence images (not the coverage) of bookings on their own jobs in the next 7 days from My jobs, with the same Approve all or a reason to reject: the history says the reviewer''s role, field. Sales review the licence images (not the coverage) of any booking being arranged or under way from their To do or the booking, with the same Approve all or a reason to reject: the history says the role, sales.

## Payments by day

**Money** > **Payments by day**: every payment and refund of a day or a range, by method, the cash drawer and the refunds waiting. Finance has the same screen.

1. Choose From and To and the methods (card, e-Transfer, cash, cheque, platform payout, insurer, bank transfer, pre-authorized debit, other), then press **Show**.
2. Totals by method and for each day; cards read as the card and its last four digits, never a code.
3. The cash drawer: expected (cash in less cash given back) against the count Finance records with **Record the count**; a difference shows over or short.
4. Refunds waiting: every refund asked for anywhere with the policy maths. **Approve** or **Decline** with the reason in the row, then **Issue the refund**.
5. **Export CSV** for the bookkeeper.

## Propose a change to a confirmed booking

The renter gets an email and answers on their booking. The calendar moves only when they accept.

1. Open the booking''s Changes tab. Under Propose a change, set the new pickup, return or car.
2. To price it by hand, type a New rental charge before tax. Leave it empty to use the car''s rates.
3. Write the Reason, for the renter. They read it.
4. Press **Preview the price**, then **Send to the renter**.

![](/guides/img/admin-05-booking-changes-desktop-97008b21.jpg "desktop; size: 1200 520; address: carmacars.ca/admin/bookings/CC-10065?tab=changes; pins: 1 17.5 33.7, 2 9.2 50.0, 3 38.3 71.2, 4 12.9 91.9")

## Who a booking is credited to

Overview (and Review and offer) shows the Sales credit: the staff member the booking counts for in their sales.

1. A quote or a rental is credited to whoever created or added it. A request from the website is credited to whoever sent its first offer.
2. To give it to someone else, press **Reassign**, choose who (or Nobody), say whether they sourced the client and write the reason. The booking''s history and the audit log keep it, and the deal stays in the same week and month.
3. Sourced means the staff member chose I sourced this client when they entered it, it came with a field staff referral link, or you credited it. Only a sourced booking earns a staff commission. A website request earns none unless you credit someone.
4. Someone said they sourced a website request? The credit line shows the claim: press **Credit them** or **Not theirs**, with a reason.
5. A price typed by hand shows beside the rate-sheet price, with the reason. A price under the floor or past the discount limit is flagged: press **Mark reviewed** once you have looked at it.

> Tip: The renter has 48 hours to accept (and sign the amendment) or decline, with one reminder. Any extra is charged to their Card on File; a lower price raises a refund for your approval.

## Review requests

Every renter is asked for a review by email and text, as they chose, only from 9 am to 9 pm Toronto time. Nothing needs setting up.

| Message | When |
| --- | --- |
| Mid-trip check-in | Rentals of 2 days or more, 24 hours after the pickup: "How is the car? Reply or call if anything is off." No review ask. |
| Review request | 1 hour after the check-in. It links the review page: the renter taps what they liked, adds a sentence, and gets a short draft to copy and post on Google. |
| Reminder | 24 hours after the request. |
| Final follow-up | 7 days after the request. Nothing more after it. |

1. The booking page has the card Review requests: each message with when it went or when it will go, and why it stopped.
2. **Ask for a review** sends the request now (or at 9 am if it is later than 9 pm), on any booking on a trip, returned or closed. Not twice in 24 hours.
3. On hold: a return or later charge (late return, kilometres, fuel, cleaning, smoking, damage, tolls and tickets) is not settled or waived, or an incident or dispute is open. The request goes by itself once they are. Press **Send anyway** to send it now.
4. **Mark reviewed** stops the messages when the renter tells you they already reviewed.

The messages also stop by themselves when the renter presses "I already left a review", leaves a review on the site, unsubscribes, or a Google review is matched to them. **Bookings** > **Reviews** has the numbers (requests sent, on hold, reviews detected, the average rating), the hold list and the Google reviews to match.

> Tip: The draft is made only from what the renter picked and wrote, and from the booking (the car, how long, delivery or pickup). Everyone gets the Google link, whatever their stars; a renter who gives 3 stars or fewer also sees "Something wasn''t right? Tell us directly".

## What the owner sees, and owner deductions

Each booking on an owner''s or partner''s car shows the card What the owner sees at the top of its page.

1. **Hide from the owner** keeps the booking''s revenue from the owner until the car is returned, or until the owner statement covering it is approved. The owner sees the booking as Booked with its dates, and the calendar still shows the car busy. Add a reason if you like: it is kept in the history.
2. **Show to the owner** shows it now. Approving the statement shows every hidden booking on it by itself.
3. Not shown to the owner is for a booking with no owner revenue (an insurance placeholder, a shareholder''s or the owner''s own use at no charge): the owner sees only that the car is unavailable for those dates. A booking with revenue cannot be set this way.
4. Add a rental and Send an offer have What the owner sees. It starts from Settings > Program, Owners and fleet: Owners see a booking''s revenue (right away by default).
5. On the Money tab, Owner deductions on this booking: **Add a booking expense** (cleaning, repair, fuel, platform fee or other, the amount, the reason the owner reads, a receipt number) comes off before Owner Revenue.
6. **Set the Revenue Share for this booking** applies within the car''s signed terms. Above the terms only an Admin can, with Above the signed terms ticked and the reason. **Back to the car''s terms** undoes it.
7. Add a rental has the same under The car''s owner.

> Good to know: The owner''s statement always includes every booking at its true amounts and lists each deduction with its reason, so the payout is always right. Customer service and sales add deductions only while Program settings let them change fees.

## Email the renter or the adjuster

Press **Email the renter** at the top of a booking, or open its **Messages** tab.

1. Write a **Subject** and a **Message**, or pick a **Quick reply** to start from (Settings > Quick replies keeps them).
2. Press **Email the renter**. It goes from CarmaCars (bookings@carmacars.ca) and replies come back to the bookings inbox. The renter also sees it in their account and can answer there.
3. On a booking an insurer pays, choose **From**: CarmaCars, or Blind Spot Car Rental (insurance). **Email the adjuster** writes to the adjuster''s email on the booking (Insurance claim), always from Blind Spot Car Rental.

The Messages tab shows what you and the renter wrote, newest first, with who wrote it, and every email of the booking with its state (waiting, sent, failed). Each email you send is also in the History tab with your name.

> Good to know: Emails go out through the same daily limit as every email (the line under the form shows today''s use). A message to a renter goes before digests and marketing; past the limit it waits until midnight. To write to a renter from **People** > **Renters**, open the renter: Email the renter is at the bottom, about their latest booking or the one you pick.

### Record the pickup or the return now (details later)
When the car went out or came back but the checklist could not be done (no photos, no time, the renter dropped the keys), the booking''s **Check-out, check-in and signing** card has **Record the pickup now (details later)** on a confirmed booking and **Record the return now (details later)** while the car is on rent. Give the actual time (now, or earlier), the odometer and fuel if you know them, and why. The booking moves on (on rent, or returned), late return charges follow the actual time, and Fleet gets the task **Add the photos and readings for CC-...**. Once returned, the statement can be issued and the deposit settled; releasing the deposit before the photos are in needs an Admin and a reason. A pickup without the deposit taken needs an Admin to waive it with a reason, and without the renter''s signature on the check-out report an Admin''s reason too. Later, **Add the check-out (or check-in) photos and readings** opens the usual checklist (photos, readings, your signature): the task closes when it is saved.

The Agreement card says **Waiting for the renter''s details** when the renter still has blanks to fill (date of birth, address, mobile, licence, coverage): their account asks for them before signing and paying. No email or text is sent.',
  '<p class="gd-p">A booking starts as a request from the website, or as an offer you send yourself to a customer on the phone. You check it, adjust it and send the offer; an offer that is out is changed in place. After that, the booking page holds the money, documents, changes and history.</p><section class="gd-task" id="requests-offers-and-bookings-the-request-queue" data-gd-task><h2 class="gd-h2">The request queue</h2><p class="gd-p">Open <b class="gd-ui">Bookings</b> &gt; <b class="gd-ui">Requests</b>. The oldest waiting request is at the top.</p><div class="gd-stepblock gd-stepblock--below"><div class="gd-stepcol"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Filter by New, Waiting on the renter, Pushed back, Offer out, Signing and payment, or Offer expired.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Waiting shows how long the renter has waited; red means past the first reply target (5 minutes, set in Program settings). Open a booking number to answer it.</div></li></ol></div><figure class="gd-fig gd-fig--desk"><div class="gd-browser"><div class="gd-bar" aria-hidden="true"><i></i><i></i><i></i><span class="gd-addr">carmacars.ca/admin/requests</span></div><div class="gd-imgwrap" style="aspect-ratio:1440/820"><img src="/guides/img/admin-02-requests-desktop-6521282d.jpg" alt="" loading="lazy" decoding="async" width="1440" height="820"><span class="gd-pin" style="left:38.9%;top:29.9%" aria-hidden="true">1</span><span class="gd-pin" style="left:22.2%;top:43.3%" aria-hidden="true">2</span></div></div></figure></div><aside class="gd-box"><span class="gd-lbl">Good to know</span><div>A request whose pickup time passes without an offer expires by itself, with a note in its history. The renter is not emailed unless &quot;Email the renter when their request expires that way&quot; is on in Program settings.</div></aside></section><section class="gd-task" id="requests-offers-and-bookings-answer-a-request-with-an-offer" data-gd-task><h2 class="gd-h2">Answer a request with an offer</h2><div class="gd-stepblock gd-stepblock--below"><div class="gd-stepcol"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">The Review and offer tab shows the request as the renter sent it.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Adjust the car, the dates, the rate type, the places, the rates and fees, the deposit and extras.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Price on the right updates as you change things.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">Add a message, choose how long the offer stays open, then press <b class="gd-ui">Send the offer</b>.</div></li></ol></div><figure class="gd-fig gd-fig--desk"><div class="gd-browser"><div class="gd-bar" aria-hidden="true"><i></i><i></i><i></i><span class="gd-addr">carmacars.ca/admin/bookings/CC-10069?tab=review</span></div><div class="gd-imgwrap" style="aspect-ratio:1200/1550"><img src="/guides/img/admin-03-booking-review-desktop-353f3707.jpg" alt="" loading="lazy" decoding="async" width="1200" height="1550"><span class="gd-pin" style="left:5%;top:6.5%" aria-hidden="true">1</span><span class="gd-pin" style="left:7.5%;top:45.8%" aria-hidden="true">2</span><span class="gd-pin" style="left:74.2%;top:42.6%" aria-hidden="true">3</span><span class="gd-pin" style="left:76.7%;top:98.1%" aria-hidden="true">4</span></div></div></figure></div><div class="gd-stepblock gd-stepblock--below"><div class="gd-stepcol"><ol class="gd-ol" start="5"><li><span class="gd-n" aria-hidden="true">5</span><div class="gd-t">Changed fields but not ready to send? Press <b class="gd-ui">Save changes</b>. The panel &quot;The offer as the renter sees it&quot; shows the result.</div></li><li><span class="gd-n" aria-hidden="true">6</span><div class="gd-t">Can&#39;t do it? Press <b class="gd-ui">Decline</b> and fill in Reason and any alternative.</div></li><li><span class="gd-n" aria-hidden="true">7</span><div class="gd-t">Need an answer first? Press <b class="gd-ui">Ask the renter</b> to send a question.</div></li></ol></div><figure class="gd-fig gd-fig--desk"><div class="gd-browser"><div class="gd-bar" aria-hidden="true"><i></i><i></i><i></i><span class="gd-addr">carmacars.ca/admin/bookings/CC-10069?tab=review</span></div><div class="gd-imgwrap" style="aspect-ratio:500/80"><img src="/guides/img/admin-03-booking-review-desktop-4dd4ed06.jpg" alt="" loading="lazy" decoding="async" width="500" height="80"><span class="gd-pin" style="left:41.2%;top:52.5%" aria-hidden="true">6</span><span class="gd-pin" style="left:18%;top:52.5%" aria-hidden="true">7</span></div></div></figure></div><p class="gd-p">Opening a request takes it for you: everyone else sees &quot;Being answered by&quot; your name and since when, with Send the offer and Decline off, until you send, decline or leave (20 minutes, renewed while you work; Program settings). Press <b class="gd-ui">Take over</b> to answer one someone else holds; it is noted in the history. A second answer is refused with who answered and when. A request from the website opens to Sales after 15 minutes (Program settings); until then Admins, customer service and fleet answer it.</p></section><section class="gd-task" id="requests-offers-and-bookings-send-an-offer-without-a-request" data-gd-task><h2 class="gd-h2">Send an offer without a request</h2><p class="gd-p"><b class="gd-ui">Bookings</b> &gt; <b class="gd-ui">Send an offer</b>, or <b class="gd-ui">Send an offer</b> on Bookings and on Requests. For a customer on the phone, by text or at the counter: no request needed.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">The customer: type a name, phone or email and choose them. Not on file? Press <b class="gd-ui">Add a new customer</b>: full legal name, mobile, email (the offer link goes there) and date of birth. A customer already on file with the same email or phone is shown with Use: one person, one record.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">The car and the dates: type the car code, plate or name, or choose from the list; each car says Free or Not free for the dates. Then the pickup and return places (our location, delivery with the address and distance, airport).</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">The price: the Rate sheet, A total for the whole rental, or A rate per day (times the days). A price typed by hand needs its reason. At the top of the price, Amounts I type: Before tax, or After tax (HST included) to type what the renter pays for each line, worked back to the amount before tax for you (a line without HST stays as typed; the choice is remembered on this device). Or type the Total the renter pays (after tax): the rental charge is worked out so the total comes to it exactly, the other lines kept. Set the kilometres, a promo code, the deposit, a discount and each fee (an Admin), and how damage is covered: with option 3 the Protection Plan price is the one the renter pays.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">How it is paid: the rental by card online (the usual way), e-Transfer, cash, cheque, bank transfer, platform payout or the insurer; the deposit by card hold, cash, e-Transfer or no deposit (an Admin).</div></li><li><span class="gd-n" aria-hidden="true">5</span><div class="gd-t">Who found this client, the message to the renter, how long the offer is open, and how the link goes: Email, Text, both or neither.</div></li><li><span class="gd-n" aria-hidden="true">6</span><div class="gd-t">The right side is the offer as the renter will see it, priced by the database as you type. Press <b class="gd-ui">Send the offer</b>. <b class="gd-ui">Save without sending</b> keeps it as a request for later.</div></li></ol></div><aside class="gd-box"><span class="gd-lbl">Good to know</span><div>It makes the same request and offer the website makes: the renter approves, signs and pays (or you record the payment), and only then is the car on the calendar. No &quot;request received&quot; email goes to the renter for an offer you send. Staff commissions and statements count it like any other booking.</div></aside></section><section class="gd-task" id="requests-offers-and-bookings-change-an-offer-that-is-out" data-gd-task><h2 class="gd-h2">Change an offer that is out</h2><p class="gd-p">The renter has the offer (Offered), or approved it and has not paid (Signing and payment). Open <b class="gd-ui">More actions</b> on the booking and press <b class="gd-ui">Edit the offer</b>.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Change anything: the car, the dates, the places, the price, fees, the deposit, add-ons, how it is paid. Each changed field is highlighted and the before and after are listed. Amounts I type (Before tax or After tax) and the Total the renter pays (after tax) work as on Send an offer.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Write what changed in Message to the renter and choose how long the offer is open.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Press <b class="gd-ui">Save and send the update</b>: the renter gets the new version by email or text (ticked), and the old version no longer counts. Or press <b class="gd-ui">Save without telling the renter</b> and tell them yourself.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">A confirmed booking is changed with <b class="gd-ui">Change the booking</b> (Propose a change, below).</div></li></ol></div><aside class="gd-box"><span class="gd-lbl">Tip</span><div>No need to withdraw first. <b class="gd-ui">Withdraw the offer</b> is only for taking it back for good; <b class="gd-ui">Send again, later expiry</b> gives the renter more time, and <b class="gd-ui">Renter approved by phone</b> records a yes given on a call.</div></aside></section><section class="gd-task" id="requests-offers-and-bookings-edit-a-booking-that-has-started" data-gd-task><h2 class="gd-h2">Edit a booking that has started</h2><p class="gd-p">On a confirmed, on-trip or returned booking (an Admin: a closed one too), Overview, <b class="gd-ui">Edit the booking</b>, <b class="gd-ui">Edit</b>.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Change the pickup or the return (extend or shorten: the rental charge is worked out again at this booking&#39;s rates), the car (on trip: the car it leaves goes to Out of service for Fleet to check), the rental charge for the trip, each fee, the kilometres a day, the deposit (an Admin) and the note.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Type why, if you like, and tick <b class="gd-ui">Email the renter what changed</b>, or leave it off for a silent correction. Press <b class="gd-ui">Save the changes</b>.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">What is open now shows at once: <b class="gd-ui">Email a pay link</b> or <b class="gd-ui">Text a pay link</b> for exactly that amount, <b class="gd-ui">Charge</b> the saved card (the renter agreed), or record cash or an e-Transfer on the Money tab.</div></li></ol></div><aside class="gd-box"><span class="gd-lbl">Good to know</span><div>Each edit is kept with who, when, why, before and after (Edits, under the form) and in the booking&#39;s history. A closed booking&#39;s owner split and the staff commission follow. To have the renter accept and sign first, use Propose a change instead.</div></aside></section><section class="gd-task" id="requests-offers-and-bookings-fees-a-forgotten-fee-and-the-balance" data-gd-task><h2 class="gd-h2">Fees, a forgotten fee and the balance</h2><p class="gd-p">On the booking&#39;s Money tab, Fees lists each fee. Press <b class="gd-ui">Change or add a fee</b>.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Type a new amount (for the whole trip, before HST) beside any fee, or choose one not on the booking (the young driver fee shows its price for these dates), or add a charge of its own with or without HST.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Press <b class="gd-ui">Save the fees</b>. The balance shows by part (rental, fees) with the pay link, the saved card and Record a payment beside it.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">The renter sees the balance on their booking with a Pay button, and pays by card on Stripe&#39;s form.</div></li></ol></div><aside class="gd-box"><span class="gd-lbl">Good to know</span><div>Every change is recorded (Changes to the fees): the amount before and after, who and why. Customer service and sales may change fees while Program settings, Staff may change fees, is on.</div></aside></section><section class="gd-task" id="requests-offers-and-bookings-correct-a-renter-s-details" data-gd-task><h2 class="gd-h2">Correct a renter&#39;s details</h2><p class="gd-p">On the renter&#39;s page (People, Renters) or on any of their bookings, <b class="gd-ui">Edit renter</b>.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Correct the name, email, phone, date of birth, licence, home address (start typing to find it) or the staff note.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">A new email also becomes their sign-in at once (no confirmation needed for a typo you correct); tick <b class="gd-ui">Email the renter a link to set a password</b> to send one there. Unsigned agreements and offers go to the new address.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Press <b class="gd-ui">Save the renter</b>. An email that another renter has is refused with their name; the same phone is a warning.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">The same person entered twice? Possible duplicates (same email, same phone, or same name and date of birth) shows under the renter. <b class="gd-ui">Merge into this record</b> moves the other record&#39;s bookings, licences, cards, payments, documents and messages here and fills any detail missing here; the other record stays, blocked, with the merge in both histories.</div></li></ol></div></section><section class="gd-task" id="requests-offers-and-bookings-payments-by-part-the-rental-the-deposit-and-later-charges" data-gd-task><h2 class="gd-h2">Payments by part: the rental, the deposit and later charges</h2><p class="gd-p">On the booking&#39;s Money tab, Money by part shows what is still open for the rental, the fees and later charges, the deposit and the card on file. Each part is paid its own way, in any mix: for example the deposit in cash and the rental by card.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t"><b class="gd-ui">Record a payment</b>: choose what it is for (the rental, fees, the deposit or a later charge) and how it was paid (e-Transfer, cash, cheque, bank transfer, platform payout, the insurer). An e-Transfer, cheque or transfer needs its reference. Press <b class="gd-ui">Record it</b>. The renter gets a receipt; <b class="gd-ui">Print</b> prints one to hand over.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t"><b class="gd-ui">Collect a card</b>: a payment (Everything open by default: the rental, the fees and any later charge in one), the deposit hold or saving the card. The renter types the card in Stripe&#39;s secure form: on this device (<b class="gd-ui">Open the card form</b>, then hand it over) or by a link texted or emailed to them (<b class="gd-ui">Send the link</b>). Staff never type a card number.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">A deposit hold lasts about 7 days and shows the days left; while the car is out it is collected by itself before it lapses. After the return, settle the deposit (below). <b class="gd-ui">Capture the hold</b> for all of it keeps the money; a part capture or <b class="gd-ui">Release the hold</b> waits for the settlement while the car is out or something is open (an Admin may do it with the reason).</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t"><b class="gd-ui">Charge the saved card</b> (Finance or an Admin): extra kilometres, fuel, damage or a late return, with the reason the renter&#39;s receipt shows. For a rental over 7 days, save the card and charge the deposit this way.</div></li><li><span class="gd-n" aria-hidden="true">5</span><div class="gd-t">An offer paid another way: once the renter approved and signed and the money is recorded, the booking is confirmed (or press <b class="gd-ui">Confirm the booking</b>).</div></li><li><span class="gd-n" aria-hidden="true">6</span><div class="gd-t">A deposit taken in cash or by e-Transfer is given back the same way after the return: Finance gets a task; press <b class="gd-ui">Returned</b> with the reference or receipt number.</div></li></ol></div><aside class="gd-box"><span class="gd-lbl">Good to know</span><div>Statements, reconciliation and the deposit settlement read each payment with its method: a cash deposit is never refunded to a card.</div></aside></section><section class="gd-task" id="requests-offers-and-bookings-settle-the-deposit" data-gd-task><h2 class="gd-h2">Settle the deposit</h2><p class="gd-p">The deposit is never given back by itself. Finance or an Admin settles it after the return: on the booking&#39;s Money tab, under Deposit, press <b class="gd-ui">Settle the deposit</b>. Issue the Check-in statement first.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">The form shows the deposit, what is still available, the charges owed from the statement and what is taken from the deposit for them. What the deposit does not cover is charged to the card on file; with no card (or a card declined), the renter gets a pay link by email and text, and Finance has a task until it is paid.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Tolls and tickets can take up to 7 days to come in. Inside that window the whole rest of the deposit is filled in as the hold-back, until the window ends. To give it back sooner, tick Release now anyway: a toll that comes in later is charged to the card on file.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Something still open keeps the whole deposit: an incident, a claim, new damage at the return not priced, damage found later not billed, a toll or ticket on the car during the rental not matched or not charged, a card dispute, or charges not on a statement yet. The form lists them. Only an Admin can release part of it, with the reason; it is recorded.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">Damage: <b class="gd-ui">Keep the whole deposit (damage)</b> turns what is left of the deposit into a damage charge, with what was damaged and the photos; the renter is told. <b class="gd-ui">Bill damage</b> adds a damage charge up to the $2,500 deductible (more goes through a claim): the deposit pays first, then the card on file.</div></li><li><span class="gd-n" aria-hidden="true">5</span><div class="gd-t">Press <b class="gd-ui">Settle</b>. The money moves at Stripe at once: the charges are collected and what is not owed is refunded or the hold released. A step Stripe refuses is tried again by itself, and Finance gets a task if it keeps failing.</div></li></ol></div><aside class="gd-box"><span class="gd-lbl">Good to know</span><div>A card hold lapses after about 7 days. While the car is out, or returned and not settled, the hold is collected in full a day and a half before it lapses: that keeps the money, and the settlement refunds what is not owed. A hold that lapses anyway is charged to the saved card, and Finance is told at once.</div></aside></section><section class="gd-task" id="requests-offers-and-bookings-a-booking" data-gd-task><h2 class="gd-h2">A booking</h2><p class="gd-p">Open <b class="gd-ui">Bookings</b> &gt; <b class="gd-ui">Bookings</b>, then a booking number. Or type the number in the search box.</p><div class="gd-stepblock gd-stepblock--below"><div class="gd-stepcol"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Tabs: Overview, Money, Changes, History, and Drivers and documents.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Overview shows the trip, the renter, what is still missing for the handover, and the price.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Open tasks for this booking, with the queue and the due time.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">Top right: <b class="gd-ui">Email the renter</b> and <b class="gd-ui">More actions</b>, the menu with <b class="gd-ui">Edit the offer</b>, <b class="gd-ui">Stop blocking the calendar</b>, <b class="gd-ui">Cancel for the renter</b>, <b class="gd-ui">Cancel by CarmaCars</b> and the rest.</div></li><li><span class="gd-n" aria-hidden="true">5</span><div class="gd-t">Under the booking number: <b class="gd-ui">Next step</b>, what happens next and who does it, with one button for that step (for example <b class="gd-ui">Send the offer</b>, <b class="gd-ui">Sign on this device</b> or <b class="gd-ui">Check out the car</b>); then where the booking is on its way, from Request to Closed, with the dates, the days, the total and who pays.</div></li></ol></div><figure class="gd-fig gd-fig--desk"><div class="gd-browser"><div class="gd-bar" aria-hidden="true"><i></i><i></i><i></i><span class="gd-addr">carmacars.ca/admin/bookings/CC-10065</span></div><div class="gd-imgwrap" style="aspect-ratio:1440/960"><img src="/guides/img/admin-04-booking-desktop-b56b668a.jpg" alt="" loading="lazy" decoding="async" width="1440" height="960"><span class="gd-pin" style="left:50%;top:46.6%" aria-hidden="true">2</span><span class="gd-pin" style="left:85.4%;top:14.5%" aria-hidden="true">4</span><span class="gd-pin" style="left:22.9%;top:26.8%" aria-hidden="true">5</span></div></div></figure></div></section><section class="gd-task" id="requests-offers-and-bookings-check-a-car-out-or-in" data-gd-task><h2 class="gd-h2">Check a car out or in</h2><p class="gd-p">From the booking, with your phone or a tablet: the same checklist field staff use.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">A confirmed booking shows <b class="gd-ui">Check out (pickup)</b> under Check-out, check-in and signing; a booking on rent shows <b class="gd-ui">Check in (return)</b>. Today lists the check-outs and check-ins due, each with <b class="gd-ui">Check out</b> or <b class="gd-ui">Check in</b>.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">The checklist opens: the ready check, the renter and their licence and card, the odometer (km) and fuel or charge, the keys, the photo set (every side, the wheels, the interior, the odometer and fuel gauge, the plate), damage marks with close-ups, then the renter and you sign.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Photos wait on the device without a connection and upload in the background. Each keeps its time, and the place when the device allows location.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">A field job of the booking is taken over (the history says so); with no job, one is made for you. When done, press <b class="gd-ui">See the photo report</b>.</div></li></ol></div><aside class="gd-box"><span class="gd-lbl">Tip</span><div>Fleet, Sales and Customer service check cars out and in the same way from their own booking page.</div></aside></section><section class="gd-task" id="requests-offers-and-bookings-the-photo-report-late-returns-and-the-return-charges" data-gd-task><h2 class="gd-h2">The photo report, late returns and the return charges</h2><p class="gd-p">Under Check-out, check-in and signing, press <b class="gd-ui">Photo report</b>.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">The report shows the due-back time, the actual check-out and check-in, Late by (or Overdue by while the car is out), the odometer and kilometres over the allowance, the fuel or charge out and in, every photo with its time and place, and the damage.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">At check-in the late return (after the grace period of the fee defaults), the mileage overage and the fuel or recharging are written to the return charges at once. A gas car with no pump receipt is priced at the refill price per eighth (Program settings) plus the markup until the receipt is entered.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Not charging one? Press <b class="gd-ui">Waive</b> beside it and give the reason: it stays waived if the charges are worked out again.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">The time was wrong? Press <b class="gd-ui">Correct the check-in time</b> (or the check-out time) with the reason: lateness and the late charges follow, and the history keeps both times.</div></li><li><span class="gd-n" aria-hidden="true">5</span><div class="gd-t">The renter gets the same report (without these buttons) by email and in their Documents. Late by shows on the booking and in the Bookings list.</div></li></ol></div></section><section class="gd-task" id="requests-offers-and-bookings-signatures-on-the-spot-or-by-link" data-gd-task><h2 class="gd-h2">Signatures on the spot, or by link</h2><p class="gd-p">The renter or an additional driver signs the rental agreement on your device, or on their own phone.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">While a signature is missing, the booking shows <b class="gd-ui">Sign now on this device</b>, <b class="gd-ui">Email the signing link</b> and <b class="gd-ui">Text the signing link</b>.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">No agreement made yet (the renter has not saved their details at home)? <b class="gd-ui">Sign now on this device</b> still shows: press <b class="gd-ui">Prepare the agreement to sign now</b> and it is made on the spot.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t"><b class="gd-ui">Sign now on this device</b>: confirm the name matches their licence and that you saw the original licence (photograph it if none is on file), then press <b class="gd-ui">Hand the device to</b> and their name.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">They read both agreements (CarmaCars&#39; and Blind Spot&#39;s), tick the statements and sign. Then <b class="gd-ui">Back to the staff view</b> for the next signer.</div></li><li><span class="gd-n" aria-hidden="true">5</span><div class="gd-t">The record is the same as signing online, and says it was signed in person, collected by you, on your device. It is printed on the signed copy&#39;s signature record page.</div></li></ol></div></section><section class="gd-task" id="requests-offers-and-bookings-rental-agreements-every-version-every-field" data-gd-task><h2 class="gd-h2">Rental agreements: every version, every field</h2><p class="gd-p">The booking&#39;s Rental agreements card: the current version of CarmaCars&#39; and Blind Spot&#39;s agreements, every earlier one, and what is still blank.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Once the agreement is signed and countersigned, any change to what it prints makes a new version of both documents by itself: the dates, the price lines, the car, a driver added or corrected, the coverage, the deposit or how it was paid, an address.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">A change to the dates, the price, the car, the drivers or the coverage option is signed again: the renter (and each driver it affects) gets their link by email and text, and the card shows &quot;Agreement v3 waiting for signature&quot;. A correction (a typo in an address, a plate written differently) is filed without signing; the renter gets the corrected copy by email.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Check-out makes the &quot;as picked up&quot; copy (time out, km out, fuel out, the car&#39;s plate and VIN, the check-out report), countersigned by whoever checked the car out; check-in makes the closing copy (time in, km in, driven and charged, fuel in, late hours, damage, the return charges, the final totals). Both go to the renter by email.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t"><b class="gd-ui">Every version</b> lists each one with what changed and both PDFs. <b class="gd-ui">Resend the signing links</b>, or press the button with their first name beside it to have them sign on your phone or tablet.</div></li><li><span class="gd-n" aria-hidden="true">5</span><div class="gd-t">The card lists what the agreements still print blank (a licence expiry, the insurer&#39;s policy number, the insured vehicle, a VIN). Type the values and press <b class="gd-ui">Save the missing fields</b>: the agreements follow.</div></li><li><span class="gd-n" aria-hidden="true">6</span><div class="gd-t">Check-out stops while a field a claim needs is blank. An Admin can let it go ahead: type the reason and press <b class="gd-ui">Override</b>; the reason is in the booking&#39;s history.</div></li><li><span class="gd-n" aria-hidden="true">7</span><div class="gd-t"><b class="gd-ui">Make the agreements again</b> checks both against the booking at once (they also follow every change by themselves).</div></li><li><span class="gd-n" aria-hidden="true">8</span><div class="gd-t"><b class="gd-ui">Edit the wording</b> (Admin only) changes CarmaCars&#39; agreement text for this booking: press <b class="gd-ui">Change</b> beside a clause, edit its text, say why and press <b class="gd-ui">Save the wording</b>; <b class="gd-ui">Add</b> writes Additional terms at the end of Part 2. Only clauses not required by law or the insurer can be removed; the consents are fixed, and Blind Spot&#39;s form (the insurer&#39;s official form) is never changed. Before the renter signs, the agreement is made again; after, the change is a new version they sign, and <b class="gd-ui">Every version</b> shows each clause before and after.</div></li></ol></div></section><section class="gd-task" id="requests-offers-and-bookings-signing-that-holds-up-in-a-dispute" data-gd-task><h2 class="gd-h2">Signing that holds up in a dispute</h2><p class="gd-p">Every signature on the site is made the same way: rental agreements, amendments and new versions (remotely or on your device), and the owner agreements, schedules and forms, a co-owner&#39;s link, the partner, investment and staff agreements.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">The licence on file is shown. A 6-digit code to their phone or email on file is optional: the signer may press <b class="gd-ui">Verify by code (optional)</b>, and Program settings, E-signing, <b class="gd-ui">ask for a one-time code</b> makes it a required first step again (off by default). Without the code, the certificate says the identity was not confirmed by a code.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">They say they read the documents, initial the key terms (each initials box is saved with <b class="gd-ui">Save initials</b>; <b class="gd-ui">Clear</b> takes it back to initial again) (damage and the deductible, the deposit and later charges, fuel, kilometres and late returns, their coverage, cancellation), give three consents (to sign electronically, to receive records electronically, to card charges under the agreement) and draw their signature.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Owners, partners, investors and staff do the same for their documents: the code, the reading, the key terms of their documents initialled (for example the Enrollment Agreement&#39;s three confirmations, Form C&#39;s acknowledgments, Schedule C, the staff agreement&#39;s confidentiality), two consents and the drawn signature. Form C&#39;s witness still types their name beside the owner.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">Each step is recorded with its time, IP address and device, and the place when the device shares it. The signed PDFs end with a certificate of completion; anyone can check a signed file at <span class="gd-url">carmacars.ca/verify</span>.</div></li><li><span class="gd-n" aria-hidden="true">5</span><div class="gd-t">Typed names are off. For a signer who cannot draw, an Admin can turn on the accessibility fallback: <b class="gd-ui">Settings</b> &gt; <b class="gd-ui">Program</b>, Esign typed fallback.</div></li></ol></div></section><section class="gd-task" id="requests-offers-and-bookings-card-disputes-the-evidence-pack" data-gd-task><h2 class="gd-h2">Card disputes: the evidence pack</h2><p class="gd-p">Everything that proves the rental, in one PDF for Stripe.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">When a card payment is disputed, the evidence pack is built by itself: the signed agreements with their certificates, the check-out and check-in reports with photos, kilometres and fuel, the licence, the payments and charges, every message to the renter, and the card checks from Stripe. It is staged in Stripe as the dispute&#39;s evidence, and To do gets an urgent task.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Open the booking: the Rental agreements card shows the pack. Press <b class="gd-ui">Download</b> to check it, then <b class="gd-ui">Submit to Stripe</b> before the evidence date.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t"><b class="gd-ui">Build the dispute evidence pack</b> makes one at any time (an Admin or Finance).</div></li></ol></div></section><section class="gd-task" id="requests-offers-and-bookings-the-licence-before-an-offer-is-accepted" data-gd-task><h2 class="gd-h2">The licence before an offer is accepted</h2><p class="gd-p">Front, back and a selfie, from the request on.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">After sending a request the renter is asked for their licence. A licence already on file from an earlier booking is used again while it is valid after the return.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">The offer cannot be accepted (by the renter, or by you on their word) and nothing is paid until the licence and its expiry date are on file.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Review the images as usual with <b class="gd-ui">Review documents</b>: the card Renter documents is on Review and offer too.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">The switch is in <b class="gd-ui">Settings</b> &gt; <b class="gd-ui">Program</b>, Booking requests and offers: Booking licence required (on), with the selfie (on).</div></li></ol></div></section><section class="gd-task" id="requests-offers-and-bookings-renter-documents-licence-and-proof-of-coverage" data-gd-task><h2 class="gd-h2">Renter documents: licence and proof of coverage</h2><p class="gd-p">A renter&#39;s licence photos, selfie and proof of coverage (OPCF 27 or a credit card&#39;s rental coverage) are checked before the handover. You check them yourself; no task is needed.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">A booking with documents waiting is a line on To do: &quot;Check &#39;s documents for booking &quot;, marked Now when the pickup is within two days. Press <b class="gd-ui">Review documents</b>.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">The pop-up shows each driver&#39;s images and the coverage: the insurer, policy number and expiry, or the card, its type and whether the name matches.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">What to check is written once at the top. One wrong? Open <b class="gd-ui">Reject this one</b> under it, type the reason the renter reads and press <b class="gd-ui">Reject</b>: they are asked for a new one.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">Then press <b class="gd-ui">Approve all</b>: every image, the proof of coverage and the Protection Plan still waiting are approved in one step. Anything the system refuses is named with the reason.</div></li><li><span class="gd-n" aria-hidden="true">5</span><div class="gd-t">The same pop-up is on the booking: the card Renter documents (<b class="gd-ui">Review documents</b>) on Overview and on Drivers and documents.</div></li></ol></div><aside class="gd-box"><span class="gd-lbl">Tip</span><div>Each opening of a renter&#39;s documents is logged. The links to the images last one minute. Field staff can also check a licence in person at the check-out (photos and four checks): the history says &quot;checked in person&quot;. Field staff also review the licence images (not the coverage) of bookings on their own jobs in the next 7 days from My jobs, with the same Approve all or a reason to reject: the history says the reviewer&#39;s role, field. Sales review the licence images (not the coverage) of any booking being arranged or under way from their To do or the booking, with the same Approve all or a reason to reject: the history says the role, sales.</div></aside></section><section class="gd-task" id="requests-offers-and-bookings-payments-by-day" data-gd-task><h2 class="gd-h2">Payments by day</h2><p class="gd-p"><b class="gd-ui">Money</b> &gt; <b class="gd-ui">Payments by day</b>: every payment and refund of a day or a range, by method, the cash drawer and the refunds waiting. Finance has the same screen.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Choose From and To and the methods (card, e-Transfer, cash, cheque, platform payout, insurer, bank transfer, pre-authorized debit, other), then press <b class="gd-ui">Show</b>.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Totals by method and for each day; cards read as the card and its last four digits, never a code.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">The cash drawer: expected (cash in less cash given back) against the count Finance records with <b class="gd-ui">Record the count</b>; a difference shows over or short.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">Refunds waiting: every refund asked for anywhere with the policy maths. <b class="gd-ui">Approve</b> or <b class="gd-ui">Decline</b> with the reason in the row, then <b class="gd-ui">Issue the refund</b>.</div></li><li><span class="gd-n" aria-hidden="true">5</span><div class="gd-t"><b class="gd-ui">Export CSV</b> for the bookkeeper.</div></li></ol></div></section><section class="gd-task" id="requests-offers-and-bookings-propose-a-change-to-a-confirmed-booking" data-gd-task><h2 class="gd-h2">Propose a change to a confirmed booking</h2><p class="gd-p">The renter gets an email and answers on their booking. The calendar moves only when they accept.</p><div class="gd-stepblock gd-stepblock--below"><div class="gd-stepcol"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Open the booking&#39;s Changes tab. Under Propose a change, set the new pickup, return or car.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">To price it by hand, type a New rental charge before tax. Leave it empty to use the car&#39;s rates.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Write the Reason, for the renter. They read it.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">Press <b class="gd-ui">Preview the price</b>, then <b class="gd-ui">Send to the renter</b>.</div></li></ol></div><figure class="gd-fig gd-fig--desk"><div class="gd-browser"><div class="gd-bar" aria-hidden="true"><i></i><i></i><i></i><span class="gd-addr">carmacars.ca/admin/bookings/CC-10065?tab=changes</span></div><div class="gd-imgwrap" style="aspect-ratio:1200/520"><img src="/guides/img/admin-05-booking-changes-desktop-97008b21.jpg" alt="" loading="lazy" decoding="async" width="1200" height="520"><span class="gd-pin" style="left:17.5%;top:33.7%" aria-hidden="true">1</span><span class="gd-pin" style="left:9.2%;top:50%" aria-hidden="true">2</span><span class="gd-pin" style="left:38.3%;top:71.2%" aria-hidden="true">3</span><span class="gd-pin" style="left:12.9%;top:91.9%" aria-hidden="true">4</span></div></div></figure></div></section><section class="gd-task" id="requests-offers-and-bookings-who-a-booking-is-credited-to" data-gd-task><h2 class="gd-h2">Who a booking is credited to</h2><p class="gd-p">Overview (and Review and offer) shows the Sales credit: the staff member the booking counts for in their sales.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">A quote or a rental is credited to whoever created or added it. A request from the website is credited to whoever sent its first offer.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">To give it to someone else, press <b class="gd-ui">Reassign</b>, choose who (or Nobody), say whether they sourced the client and write the reason. The booking&#39;s history and the audit log keep it, and the deal stays in the same week and month.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Sourced means the staff member chose I sourced this client when they entered it, it came with a field staff referral link, or you credited it. Only a sourced booking earns a staff commission. A website request earns none unless you credit someone.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">Someone said they sourced a website request? The credit line shows the claim: press <b class="gd-ui">Credit them</b> or <b class="gd-ui">Not theirs</b>, with a reason.</div></li><li><span class="gd-n" aria-hidden="true">5</span><div class="gd-t">A price typed by hand shows beside the rate-sheet price, with the reason. A price under the floor or past the discount limit is flagged: press <b class="gd-ui">Mark reviewed</b> once you have looked at it.</div></li></ol></div><aside class="gd-box"><span class="gd-lbl">Tip</span><div>The renter has 48 hours to accept (and sign the amendment) or decline, with one reminder. Any extra is charged to their Card on File; a lower price raises a refund for your approval.</div></aside></section><section class="gd-task" id="requests-offers-and-bookings-review-requests" data-gd-task><h2 class="gd-h2">Review requests</h2><p class="gd-p">Every renter is asked for a review by email and text, as they chose, only from 9 am to 9 pm Toronto time. Nothing needs setting up.</p><div class="gd-tablewrap"><table class="gd-table"><thead><tr><th scope="col">Message</th><th scope="col">When</th></tr></thead><tbody><tr><td>Mid-trip check-in</td><td>Rentals of 2 days or more, 24 hours after the pickup: &quot;How is the car? Reply or call if anything is off.&quot; No review ask.</td></tr><tr><td>Review request</td><td>1 hour after the check-in. It links the review page: the renter taps what they liked, adds a sentence, and gets a short draft to copy and post on Google.</td></tr><tr><td>Reminder</td><td>24 hours after the request.</td></tr><tr><td>Final follow-up</td><td>7 days after the request. Nothing more after it.</td></tr></tbody></table></div><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">The booking page has the card Review requests: each message with when it went or when it will go, and why it stopped.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t"><b class="gd-ui">Ask for a review</b> sends the request now (or at 9 am if it is later than 9 pm), on any booking on a trip, returned or closed. Not twice in 24 hours.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">On hold: a return or later charge (late return, kilometres, fuel, cleaning, smoking, damage, tolls and tickets) is not settled or waived, or an incident or dispute is open. The request goes by itself once they are. Press <b class="gd-ui">Send anyway</b> to send it now.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t"><b class="gd-ui">Mark reviewed</b> stops the messages when the renter tells you they already reviewed.</div></li></ol></div><p class="gd-p">The messages also stop by themselves when the renter presses &quot;I already left a review&quot;, leaves a review on the site, unsubscribes, or a Google review is matched to them. <b class="gd-ui">Bookings</b> &gt; <b class="gd-ui">Reviews</b> has the numbers (requests sent, on hold, reviews detected, the average rating), the hold list and the Google reviews to match.</p><aside class="gd-box"><span class="gd-lbl">Tip</span><div>The draft is made only from what the renter picked and wrote, and from the booking (the car, how long, delivery or pickup). Everyone gets the Google link, whatever their stars; a renter who gives 3 stars or fewer also sees &quot;Something wasn&#39;t right? Tell us directly&quot;.</div></aside></section><section class="gd-task" id="requests-offers-and-bookings-what-the-owner-sees-and-owner-deductions" data-gd-task><h2 class="gd-h2">What the owner sees, and owner deductions</h2><p class="gd-p">Each booking on an owner&#39;s or partner&#39;s car shows the card What the owner sees at the top of its page.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t"><b class="gd-ui">Hide from the owner</b> keeps the booking&#39;s revenue from the owner until the car is returned, or until the owner statement covering it is approved. The owner sees the booking as Booked with its dates, and the calendar still shows the car busy. Add a reason if you like: it is kept in the history.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t"><b class="gd-ui">Show to the owner</b> shows it now. Approving the statement shows every hidden booking on it by itself.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Not shown to the owner is for a booking with no owner revenue (an insurance placeholder, a shareholder&#39;s or the owner&#39;s own use at no charge): the owner sees only that the car is unavailable for those dates. A booking with revenue cannot be set this way.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">Add a rental and Send an offer have What the owner sees. It starts from Settings &gt; Program, Owners and fleet: Owners see a booking&#39;s revenue (right away by default).</div></li><li><span class="gd-n" aria-hidden="true">5</span><div class="gd-t">On the Money tab, Owner deductions on this booking: <b class="gd-ui">Add a booking expense</b> (cleaning, repair, fuel, platform fee or other, the amount, the reason the owner reads, a receipt number) comes off before Owner Revenue.</div></li><li><span class="gd-n" aria-hidden="true">6</span><div class="gd-t"><b class="gd-ui">Set the Revenue Share for this booking</b> applies within the car&#39;s signed terms. Above the terms only an Admin can, with Above the signed terms ticked and the reason. <b class="gd-ui">Back to the car&#39;s terms</b> undoes it.</div></li><li><span class="gd-n" aria-hidden="true">7</span><div class="gd-t">Add a rental has the same under The car&#39;s owner.</div></li></ol></div><aside class="gd-box"><span class="gd-lbl">Good to know</span><div>The owner&#39;s statement always includes every booking at its true amounts and lists each deduction with its reason, so the payout is always right. Customer service and sales add deductions only while Program settings let them change fees.</div></aside></section><section class="gd-task" id="requests-offers-and-bookings-email-the-renter-or-the-adjuster" data-gd-task><h2 class="gd-h2">Email the renter or the adjuster</h2><p class="gd-p">Press <b class="gd-ui">Email the renter</b> at the top of a booking, or open its <b class="gd-ui">Messages</b> tab.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Write a <b class="gd-ui">Subject</b> and a <b class="gd-ui">Message</b>, or pick a <b class="gd-ui">Quick reply</b> to start from (Settings &gt; Quick replies keeps them).</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Press <b class="gd-ui">Email the renter</b>. It goes from CarmaCars (bookings@carmacars.ca) and replies come back to the bookings inbox. The renter also sees it in their account and can answer there.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">On a booking an insurer pays, choose <b class="gd-ui">From</b>: CarmaCars, or Blind Spot Car Rental (insurance). <b class="gd-ui">Email the adjuster</b> writes to the adjuster&#39;s email on the booking (Insurance claim), always from Blind Spot Car Rental.</div></li></ol></div><p class="gd-p">The Messages tab shows what you and the renter wrote, newest first, with who wrote it, and every email of the booking with its state (waiting, sent, failed). Each email you send is also in the History tab with your name.</p><aside class="gd-box"><span class="gd-lbl">Good to know</span><div>Emails go out through the same daily limit as every email (the line under the form shows today&#39;s use). A message to a renter goes before digests and marketing; past the limit it waits until midnight. To write to a renter from <b class="gd-ui">People</b> &gt; <b class="gd-ui">Renters</b>, open the renter: Email the renter is at the bottom, about their latest booking or the one you pick.</div></aside><h3 class="gd-h3">Record the pickup or the return now (details later)</h3><p class="gd-p">When the car went out or came back but the checklist could not be done (no photos, no time, the renter dropped the keys), the booking&#39;s <b class="gd-ui">Check-out, check-in and signing</b> card has <b class="gd-ui">Record the pickup now (details later)</b> on a confirmed booking and <b class="gd-ui">Record the return now (details later)</b> while the car is on rent. Give the actual time (now, or earlier), the odometer and fuel if you know them, and why. The booking moves on (on rent, or returned), late return charges follow the actual time, and Fleet gets the task <b class="gd-ui">Add the photos and readings for CC-...</b>. Once returned, the statement can be issued and the deposit settled; releasing the deposit before the photos are in needs an Admin and a reason. A pickup without the deposit taken needs an Admin to waive it with a reason, and without the renter&#39;s signature on the check-out report an Admin&#39;s reason too. Later, <b class="gd-ui">Add the check-out (or check-in) photos and readings</b> opens the usual checklist (photos, readings, your signature): the task closes when it is saved.</p><p class="gd-p">The Agreement card says <b class="gd-ui">Waiting for the renter&#39;s details</b> when the renter still has blanks to fill (date of birth, address, mobile, licence, coverage): their account asks for them before signing and paying. No email or text is sent.</p></section>');
select app.guide_release_section('admin', 'insurance-replacements-rates-and-billing', 'chapter', 'partners-company-cars-and-rentals-added-by-hand', 'Each insurance company pays an agreed rate a day for a replacement car, by car class. The rate sheet keeps those rates with their history; a rental billed to an insurer takes its rate from it, the insurer''s invoice follows it, and each insurer''s page shows what it was billed, paid and still owes.

## The rate sheet

Open **Money** > **Insurer rates**.

1. One row for each insurer, one column for each car class (the list in Settings > Vehicle classes). Each cell shows the rate today and, under it, a rate already saved for a later date. On a phone each insurer is a card with its classes.
2. Press **Set** (or **Change**) in a cell. Type the Daily rate and, when the insurer has them, a weekly cap, a cap for 30 days, a delivery and pickup allowance, the kilometres a day and a taxes note (printed on its invoices). Choose From, say why it changed, and press **Save the rate**.
3. A change never overwrites the rate before it: it is a new rate from its date, and the earlier one stays in the history. **End** stops a rate from a date.
4. Add an insurer, or change its billing contact and email, in Settings > Insurers.

> Good to know: A car takes the rate of its pricing class; when the insurer has no rate for that class, the rate of the car''s other classes, in the order of the list. A 2024 Jetta (standard, also a sedan) replaced for an insurer that pays $65 a day for sedans is billed $65 a day.

## The rate on a rental

- Add a rental, Insurance replacement (or Insurer billed later): once the price is checked and the insurer chosen, the daily rate authorized is filled from its rate sheet for the car, with the caps and the taxes note under it.
- A different rate: type it, and Differs from the rate sheet asks for the reason. The rental is not added without it. Empty the field to take the sheet''s rate again.
- The review screen of a request or an offer does the same when you choose Bill to and the insurer: the rate follows the insurer chosen, and a rate typed that differs needs the reason.
- An insurer with no rate for the car: type the rate the adjuster authorized, as before.
- The booking''s Insurance replacement card (Overview and Money tabs) shows the insurer and the claim, the daily rate and where it comes from, Differs with the reason when it is not the sheet''s, the caps, the days covered, what the insurer pays and its invoices.

## Charges to the insurer

VLF (vehicle licence fee), LDW, T&LDW, PAP/PEC and Waiver Saver are charged to the insurer, a rate a day each, only on a rental billed to an insurer. They have no set price: type the rate the insurer authorized on each booking.

1. Add a rental, Insurer billed later (or the Insurance replacement quick start): under the insurer''s details, **Charges to the insurer** has a box for each, the rate a day before HST. Under each box the amount for the days shows; the check of the price adds each line with its HST. Leave a box empty for none.
2. A request or an offer: on the review screen, once Bill to is an insurer, the same boxes are under the insurer''s details. Save, Send offer or the updated offer keeps them; Bill to back to Renter removes them in the same save.
3. A confirmed booking: the Insurance replacement card lists each charge with its rate a day, the days and the amount. **Change the charges** (or **Add a charge**), type the rates, and press **Save the charges**. Each change is in the booking''s history and the changes to the fees.
4. Each line is the rate times the rental days, plus HST: when the dates change, the amount follows. The insurer pays them whether it pays everything or the rental only.

> Good to know: They never show for a rental the renter pays, and the database refuses them there. They print on both agreements: on Blind Spot''s, VLF in box 43, LDW in 45, T&LDW in 46, PAP/PEC in 47 (each with its rate a day and amount) and Waiver Saver in its box beside Accepted; a box with no charge says N/A.

## Invoices to the insurer

- **Draft insurer invoice** on the booking bills the insurer at the booking''s daily rate (the sheet''s, or the one typed with its reason) for the days authorized.
- The weekly cap and the cap for 30 days lower the amount of a long rental. Billed for the rental only, the insurer also pays delivery and pickup up to its allowance; billed for everything, delivery and pickup above the allowance are the renter''s.
- Each charge to the insurer is a line of its own on the invoice (for example VLF (vehicle licence fee): 3 days at $5.00 a day).
- The invoice line says the rate and where it comes from (for example at $65.00 a day, Example Mutual rate sheet, Sedan), and the PDF prints the taxes note. Send it and record its payments in Money > Insurer invoices, as before.

## Billing history

**Money** > **Insurer rates**, then the insurer''s name.

1. The tiles: bookings, days used and authorized, billed, paid, outstanding, the average daily rate and the days the insurer takes to pay (from sent to paid).
2. Rates by class (Set, Change and End work here too), then the History of the rates: each rate with its dates, its status, why it changed and who saved it.
3. Billing by class: for each class the bookings, days authorized and used, billed, paid, outstanding, the average rate and the days to pay.
4. Bookings: each booking with its class, claim, dates, days, rate (Sheet and the reason when it differs), what was billed, paid and outstanding, and its invoices (each opens its PDF).
5. Choose Picked up from and to and press **Show** for a period. **Download CSV** saves the bookings of the period for a spreadsheet.
', 'Insurance replacements: rates and billing', 'The rate sheet by insurer and car class, the rate on a rental, the invoices and the billing history.',
  'Each insurance company pays an agreed rate a day for a replacement car, by car class. The rate sheet keeps those rates with their history; a rental billed to an insurer takes its rate from it, the insurer''s invoice follows it, and each insurer''s page shows what it was billed, paid and still owes.

## The rate sheet

Open **Money** > **Insurer rates**.

1. One row for each insurer, one column for each car class (the list in Settings > Vehicle classes). Each cell shows the rate today and, under it, a rate already saved for a later date. On a phone each insurer is a card with its classes.
2. Press **Set** (or **Change**) in a cell. Type the Daily rate and, when the insurer has them, a weekly cap, a cap for 30 days, a delivery and pickup allowance, the kilometres a day and a taxes note (printed on its invoices). Choose From, say why it changed, and press **Save the rate**.
3. A change never overwrites the rate before it: it is a new rate from its date, and the earlier one stays in the history. **End** stops a rate from a date.
4. Add an insurer, or change its billing contact and email, in Settings > Insurers.

> Good to know: A car takes the rate of its pricing class; when the insurer has no rate for that class, the rate of the car''s other classes, in the order of the list. A 2024 Jetta (standard, also a sedan) replaced for an insurer that pays $65 a day for sedans is billed $65 a day.

## The rate on a rental

- Add a rental, Insurance replacement (or Insurer billed later): once the price is checked and the insurer chosen, the daily rate authorized is filled from its rate sheet for the car, with the caps and the taxes note under it.
- A different rate: type it, and Differs from the rate sheet asks for the reason. The rental is not added without it. Empty the field to take the sheet''s rate again.
- The review screen of a request or an offer does the same when you choose Bill to and the insurer: the rate follows the insurer chosen, and a rate typed that differs needs the reason.
- An insurer with no rate for the car: type the rate the adjuster authorized, as before.
- The booking''s Insurance replacement card (Overview and Money tabs) shows the insurer and the claim, the daily rate and where it comes from, Differs with the reason when it is not the sheet''s, the caps, the days covered, what the insurer pays and its invoices.

## Charges to the insurer

VLF (vehicle licence fee), LDW, T&LDW, PAP/PEC and Waiver Saver are charged to the insurer, a rate a day each, only on a rental billed to an insurer. They have no set price: type the rate the insurer authorized on each booking.

1. Add a rental, Insurer billed later (or the Insurance replacement quick start): under the insurer''s details, **Charges to the insurer** has a box for each, the rate a day before HST. Under each box the amount for the days shows; the check of the price adds each line with its HST. Leave a box empty for none.
2. A request or an offer: on the review screen, once Bill to is an insurer, the same boxes are under the insurer''s details. Save, Send offer or the updated offer keeps them; Bill to back to Renter removes them in the same save.
3. A confirmed booking: the Insurance replacement card lists each charge with its rate a day, the days and the amount. **Change the charges** (or **Add a charge**), type the rates, and press **Save the charges**. Each change is in the booking''s history and the changes to the fees.
4. Each line is the rate times the rental days, plus HST: when the dates change, the amount follows. The insurer pays them whether it pays everything or the rental only.

> Good to know: They never show for a rental the renter pays, and the database refuses them there. They print on both agreements: on Blind Spot''s, VLF in box 43, LDW in 45, T&LDW in 46, PAP/PEC in 47 (each with its rate a day and amount) and Waiver Saver in its box beside Accepted; a box with no charge says N/A.

## Invoices to the insurer

- **Draft insurer invoice** on the booking bills the insurer at the booking''s daily rate (the sheet''s, or the one typed with its reason) for the days authorized.
- The weekly cap and the cap for 30 days lower the amount of a long rental. Billed for the rental only, the insurer also pays delivery and pickup up to its allowance; billed for everything, delivery and pickup above the allowance are the renter''s.
- Each charge to the insurer is a line of its own on the invoice (for example VLF (vehicle licence fee): 3 days at $5.00 a day).
- The invoice line says the rate and where it comes from (for example at $65.00 a day, Example Mutual rate sheet, Sedan), and the PDF prints the taxes note. Send it and record its payments in Money > Insurer invoices, as before.

## Billing history

**Money** > **Insurer rates**, then the insurer''s name.

1. The tiles: bookings, days used and authorized, billed, paid, outstanding, the average daily rate and the days the insurer takes to pay (from sent to paid).
2. Rates by class (Set, Change and End work here too), then the History of the rates: each rate with its dates, its status, why it changed and who saved it.
3. Billing by class: for each class the bookings, days authorized and used, billed, paid, outstanding, the average rate and the days to pay.
4. Bookings: each booking with its class, claim, dates, days, rate (Sheet and the reason when it differs), what was billed, paid and outstanding, and its invoices (each opens its PDF).
5. Choose Picked up from and to and press **Show** for a period. **Download CSV** saves the bookings of the period for a spreadsheet.

## Emails as Blind Spot Car Rental

Insurance emails go from **Blind Spot Car Rental <blindspotcarrental@carmacars.ca>** and replies come back to that address: the insurer invoice, **Email the adjuster**, and Email the renter when you choose Blind Spot Car Rental as the sender on a booking an insurer pays. Every other email still goes from CarmaCars.

> Good to know: The address sends today. To receive the replies, the mailbox (or an alias of rent@carmacars.ca in Google Workspace) must exist.

### VLF (vehicle licensing fee)
A default VLF a day can be set in **Settings** (Insurer-billed rentals: VLF a day; $0 means none). When a rental is first billed to an insurer, that VLF is put on it as one of its charges to the insurer; change the rate or remove it there, like the others. Before the renter pays again, remove the charges to the insurer.',
  '<p class="gd-p">Each insurance company pays an agreed rate a day for a replacement car, by car class. The rate sheet keeps those rates with their history; a rental billed to an insurer takes its rate from it, the insurer&#39;s invoice follows it, and each insurer&#39;s page shows what it was billed, paid and still owes.</p><section class="gd-task" id="insurance-replacements-rates-and-billing-the-rate-sheet" data-gd-task><h2 class="gd-h2">The rate sheet</h2><p class="gd-p">Open <b class="gd-ui">Money</b> &gt; <b class="gd-ui">Insurer rates</b>.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">One row for each insurer, one column for each car class (the list in Settings &gt; Vehicle classes). Each cell shows the rate today and, under it, a rate already saved for a later date. On a phone each insurer is a card with its classes.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Press <b class="gd-ui">Set</b> (or <b class="gd-ui">Change</b>) in a cell. Type the Daily rate and, when the insurer has them, a weekly cap, a cap for 30 days, a delivery and pickup allowance, the kilometres a day and a taxes note (printed on its invoices). Choose From, say why it changed, and press <b class="gd-ui">Save the rate</b>.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">A change never overwrites the rate before it: it is a new rate from its date, and the earlier one stays in the history. <b class="gd-ui">End</b> stops a rate from a date.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">Add an insurer, or change its billing contact and email, in Settings &gt; Insurers.</div></li></ol></div><aside class="gd-box"><span class="gd-lbl">Good to know</span><div>A car takes the rate of its pricing class; when the insurer has no rate for that class, the rate of the car&#39;s other classes, in the order of the list. A 2024 Jetta (standard, also a sedan) replaced for an insurer that pays $65 a day for sedans is billed $65 a day.</div></aside></section><section class="gd-task" id="insurance-replacements-rates-and-billing-the-rate-on-a-rental" data-gd-task><h2 class="gd-h2">The rate on a rental</h2><ul class="gd-ul"><li>Add a rental, Insurance replacement (or Insurer billed later): once the price is checked and the insurer chosen, the daily rate authorized is filled from its rate sheet for the car, with the caps and the taxes note under it.</li><li>A different rate: type it, and Differs from the rate sheet asks for the reason. The rental is not added without it. Empty the field to take the sheet&#39;s rate again.</li><li>The review screen of a request or an offer does the same when you choose Bill to and the insurer: the rate follows the insurer chosen, and a rate typed that differs needs the reason.</li><li>An insurer with no rate for the car: type the rate the adjuster authorized, as before.</li><li>The booking&#39;s Insurance replacement card (Overview and Money tabs) shows the insurer and the claim, the daily rate and where it comes from, Differs with the reason when it is not the sheet&#39;s, the caps, the days covered, what the insurer pays and its invoices.</li></ul></section><section class="gd-task" id="insurance-replacements-rates-and-billing-charges-to-the-insurer" data-gd-task><h2 class="gd-h2">Charges to the insurer</h2><p class="gd-p">VLF (vehicle licence fee), LDW, T&amp;LDW, PAP/PEC and Waiver Saver are charged to the insurer, a rate a day each, only on a rental billed to an insurer. They have no set price: type the rate the insurer authorized on each booking.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Add a rental, Insurer billed later (or the Insurance replacement quick start): under the insurer&#39;s details, <b class="gd-ui">Charges to the insurer</b> has a box for each, the rate a day before HST. Under each box the amount for the days shows; the check of the price adds each line with its HST. Leave a box empty for none.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">A request or an offer: on the review screen, once Bill to is an insurer, the same boxes are under the insurer&#39;s details. Save, Send offer or the updated offer keeps them; Bill to back to Renter removes them in the same save.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">A confirmed booking: the Insurance replacement card lists each charge with its rate a day, the days and the amount. <b class="gd-ui">Change the charges</b> (or <b class="gd-ui">Add a charge</b>), type the rates, and press <b class="gd-ui">Save the charges</b>. Each change is in the booking&#39;s history and the changes to the fees.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">Each line is the rate times the rental days, plus HST: when the dates change, the amount follows. The insurer pays them whether it pays everything or the rental only.</div></li></ol></div><aside class="gd-box"><span class="gd-lbl">Good to know</span><div>They never show for a rental the renter pays, and the database refuses them there. They print on both agreements: on Blind Spot&#39;s, VLF in box 43, LDW in 45, T&amp;LDW in 46, PAP/PEC in 47 (each with its rate a day and amount) and Waiver Saver in its box beside Accepted; a box with no charge says N/A.</div></aside></section><section class="gd-task" id="insurance-replacements-rates-and-billing-invoices-to-the-insurer" data-gd-task><h2 class="gd-h2">Invoices to the insurer</h2><ul class="gd-ul"><li><b class="gd-ui">Draft insurer invoice</b> on the booking bills the insurer at the booking&#39;s daily rate (the sheet&#39;s, or the one typed with its reason) for the days authorized.</li><li>The weekly cap and the cap for 30 days lower the amount of a long rental. Billed for the rental only, the insurer also pays delivery and pickup up to its allowance; billed for everything, delivery and pickup above the allowance are the renter&#39;s.</li><li>Each charge to the insurer is a line of its own on the invoice (for example VLF (vehicle licence fee): 3 days at $5.00 a day).</li><li>The invoice line says the rate and where it comes from (for example at $65.00 a day, Example Mutual rate sheet, Sedan), and the PDF prints the taxes note. Send it and record its payments in Money &gt; Insurer invoices, as before.</li></ul></section><section class="gd-task" id="insurance-replacements-rates-and-billing-billing-history" data-gd-task><h2 class="gd-h2">Billing history</h2><p class="gd-p"><b class="gd-ui">Money</b> &gt; <b class="gd-ui">Insurer rates</b>, then the insurer&#39;s name.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">The tiles: bookings, days used and authorized, billed, paid, outstanding, the average daily rate and the days the insurer takes to pay (from sent to paid).</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Rates by class (Set, Change and End work here too), then the History of the rates: each rate with its dates, its status, why it changed and who saved it.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Billing by class: for each class the bookings, days authorized and used, billed, paid, outstanding, the average rate and the days to pay.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">Bookings: each booking with its class, claim, dates, days, rate (Sheet and the reason when it differs), what was billed, paid and outstanding, and its invoices (each opens its PDF).</div></li><li><span class="gd-n" aria-hidden="true">5</span><div class="gd-t">Choose Picked up from and to and press <b class="gd-ui">Show</b> for a period. <b class="gd-ui">Download CSV</b> saves the bookings of the period for a spreadsheet.</div></li></ol></div></section><section class="gd-task" id="insurance-replacements-rates-and-billing-emails-as-blind-spot-car-rental" data-gd-task><h2 class="gd-h2">Emails as Blind Spot Car Rental</h2><p class="gd-p">Insurance emails go from <b class="gd-ui">Blind Spot Car Rental &lt;blindspotcarrental@carmacars.ca&gt;</b> and replies come back to that address: the insurer invoice, <b class="gd-ui">Email the adjuster</b>, and Email the renter when you choose Blind Spot Car Rental as the sender on a booking an insurer pays. Every other email still goes from CarmaCars.</p><aside class="gd-box"><span class="gd-lbl">Good to know</span><div>The address sends today. To receive the replies, the mailbox (or an alias of rent@carmacars.ca in Google Workspace) must exist.</div></aside><h3 class="gd-h3">VLF (vehicle licensing fee)</h3><p class="gd-p">A default VLF a day can be set in <b class="gd-ui">Settings</b> (Insurer-billed rentals: VLF a day; $0 means none). When a rental is first billed to an insurer, that VLF is put on it as one of its charges to the insurer; change the rate or remove it there, like the others. Before the renter pays again, remove the charges to the insurer.</p></section>');
select app.guide_release_section('admin', 'owners-and-onboarding', 'chapter', 'chauffeur-service', 'Owners apply on the site with List your car. Every application waits for you in one place, Applications: approve it, ask the owner for something, or decline it. Approved owners sign and pay in their portal.

## Applications

**People** > **Applications**. Every owner application, newest first.

1. The chips filter by status: New, Waiting on owner, Approved, Declined, or All. New applications also show on To do.
2. Each row shows the application number, the owner, the car, how many of the four checks are done, and when they applied.
3. Open an application to decide.

![](/guides/img/admin-33-applications-desktop-152f9e34.jpg "desktop; size: 1440 640; address: carmacars.ca/admin/applications; pins: 1 36.8 39.7, 2 48.6 53.1, 3 19.8 53.1")

## Decide on an application

One page holds everything: the owner, the car, the uploads, the four checks and the notes.

1. Check the driver''s licence, the ownership, the insurance and the lender or lessor. Mark each one Checked, fine, Problem or Not needed.
2. Press **Approve**. The step "Terms and first invoice" opens for each car, filled in with the owner''s negotiated terms (or the standard grid): Insurance Fee, Tracker Fee, management fee (Revenue Share), Install Fee and the first and last month amount (2 x the Insurance Fee unless you type an exact amount). Change any of them to the cent; with several cars, **Use these terms for every car** copies the first car''s numbers to the others.
3. Choose the invoices: First and last month, Registration fee (any exact amount), Tracker install (only once trackers are available) and Another invoice. For each one choose Send now, Save as draft or Already paid. Already paid asks how (e-Transfer, cash, cheque, bank transfer or other), the date and the reference: it is recorded like Record payment and the owner gets the receipt, not an invoice.
4. Press **Approve** at the bottom of the step. Nothing is set or sent before that. The owner becomes active, the documents open for one signature in their portal, only the invoices you chose are made, and the owner gets one email.
5. Missing something? Press **Ask for something**, tick what you need (for example the ownership permit or the insurance slip), add a message if you like, and press **Send to the owner**. The owner gets an email and a task in their portal; the application shows Waiting on owner until they answer.
6. Not a fit? Press **Decline**, write the Reason the owner reads, and press **Decline the application**. The owner is emailed for each car.

![](/guides/img/admin-34-application-desktop-98b64f92.jpg "desktop; size: 1440 812; address: carmacars.ca/admin/applications/c324ef8d-ad00-4bcc-bf04-ca68628a26b4; pins: 1 72.9 67.1, 2 73.9 42.9, 3 84.7 42.9, 4 72.9 49.6")

The application has an Invoices tab: every invoice of its cars, drafts and voids included. An application staff entered for the owner says "Entered by staff" and who; approving it sends the owner the set-up email (review the details and sign) instead of the approval email.

> Tip: Notes on the page are for staff only: **Add note** keeps a line on the record. When the owner answers a request, their answer is in the notes and the application is New again.

## Add a car for an owner

**People** > **Add a car for an owner**, or **Add another car** on an owner''s page. The owner never has to fill in the application.

1. The owner: find them by name, email or phone, or choose New owner and enter the name, email, phone and address.
2. The car: type the VIN. The car is looked up at once and shown in one line (Edit if something is wrong); no VIN at hand, add it by its plate with the year, make and model from the lists. Tap the colour, check the class, then the odometer, insurer and whether it is owned, financed or leased. Photos are optional: the listing shows sample photos until real ones are added. Upload the ownership permit, the insurance slip and the lender''s information if you have them.
3. Terms and first invoice: the same fields as Approve. For another car of the same owner they start from that owner''s terms, or their other car''s; change them for this car.
4. Who sourced the owner: Entered for CarmaCars, or I sourced this owner (only then are you recorded as the one who brought the owner). How the owner signs: by email, or on paper.
5. Press **Add the car and set it up**. The owner gets one email: review the details, correct anything, and sign. An owner with no sign-in gets the link to choose a password in that same email.

Customer service and fleet assistants add cars the same way from their portal; theirs wait in Applications for you, with the terms and invoices they proposed already filled in. On an approved application staff entered, **Send the set-up email again** sends the owner the email with a fresh link.

## Owners

**People** > **Owners**. Every owner, with their cars and where onboarding stands.

1. Each owner shows their application, how many cars, and where onboarding stands.
2. **View as (owner portal)** shows their portal. **Send password link** helps them sign in.
3. Invite an owner on file: fill in Name and Email under Invite an owner, then press **Send invitation**.

![](/guides/img/admin-12-owners-desktop-3a54d505.jpg "desktop; size: 1440 560; address: carmacars.ca/admin/owners; pins: 1 41.0 42.9, 2 37.4 49.3, 3 77.4 82.5")

The owner signs everything at once in their portal (Check and sign: the agreements, schedules and Forms A and B; the official registry forms are printed and signed in ink). The confirmations to tick, then one signature: CarmaCars countersigns at the same moment, under the signing officer''s standing authorization. A car with a second owner on the ownership waits for that owner too: they get their own link by email and sign the same documents.

## Mark a car insured (Insurer confirmed)

A program owner''s car is handed over to a renter only once the insurer confirms in writing that it is on the fleet policy. Requests, offers and payment never wait for it.

1. Each car waiting for the insurer is a line on To do: "Insurer has not confirmed : mark it insured". It says Now when a booking picks the car up soon.
2. When the insurer''s email arrives, press **Mark insured**. The date is today; change it to the date of the insurer''s email if it was earlier. Add its subject as the Reference if you like, and press **Insurer confirmed**.
3. One email for several cars? Press **Mark several insured** on the line " cars wait for the insurer". Every waiting car is ticked: untick any car the insurer did not name, check the date, and confirm them all at once.
4. The same button is on the car: Overview (**Insurer confirmed**) and the Listing tab''s checklist, item "Not on the fleet insurance policy yet".

The car is then on the fleet policy from that date: it can be handed over, its Enrollment Date is that date, its fee terms start, and the owner gets the email "Written confirmation: your car is on the fleet policy". Its paperwork (agreements, registry visit, tracker) stays on its checklist until done. A car already listed and Available stays Available.

## Owners who paid another way, and the terms you agreed

Two lines on To do keep an owner''s money right without opening their page.

1. "Record the first and last month paid by ": their first and last month invoice was voided and nothing paid is recorded. Press **Record what they paid**, type the amount for each car (tax included), or one total for several cars, how and when it was paid and the reference. A draft first and last month invoice is kept or voided, your choice. Each car''s invoice is then marked paid, the owner gets the receipt and the two prepaid months count. Never for a shareholder.
2. "Enter the terms agreed with ": their cars still use the standard grid. Press **Enter the terms**: the Management fee (Revenue Share), the Insurance Fee, the Tracker Fee, the Install Fee and the first and last month are filled in from the grid. Type what you agreed for the owner, and open a car to give it its own. A car whose schedule is signed gets an updated schedule for the owner to sign.
3. Nothing to change? Press **Not needed** or **These are correct**: the line does not come back.

## A shareholder''s own car

On the owner''s page, each car has **Shareholder’s own car**.

1. A shareholder''s own car is split 90/10 (the share in Program settings) and pays no Insurance Fee, Tracker Fee, first and last month or tracker install.
2. Press **Shareholder’s own car**, say why (it is kept in the audit log) and confirm. Press it again to undo. Bookings already made keep their split.
3. A first and last month or a tracker install invoice is refused for such a car, from any screen.

## Cancellation refunds

**Settings** > **Program**: the refund for each cancellation tier.

| When the renter cancels | Refund (default) |
| --- | --- |
| Within 24 hours of booking, 48 hours or more before the start | 95% |
| 48 hours or more before the start | 75% |
| 24 to 48 hours before the start | 50% |
| Under 24 hours, or after the start | 0% |

## An owner''s page

Open an owner from Owners. Three tabs: Overview, Terms and Invoices. **Add another car** and **New invoice** sit under the name.

1. Cars and terms, at the top: each car''s Insurance Fee, Tracker Fee, management fee (Revenue Share), Install Fee and mode, with **Edit** and History (see An owner''s terms, car by car).
2. Upfront invoices: issue the first and last month amount agreed on each car''s terms, for each car whose terms are set.
3. Owner: address, sign-in, agreements, and what is still missing for the registry forms.
4. Statements and payouts for this owner.
5. Forms C and D, with a link to the review queue.
6. Further down: **View as (owner portal)**, **Send password link** and **Send a sign-in link to the owner portal**.

![](/guides/img/admin-13-owner-desktop-819a9f8b.jpg "desktop; size: 410 1030; address: carmacars.ca/admin/owners/50a834dc-270a-4c26-b79e-6396fa7bf2e1; pins: 1 24.6 4.4, 2 16.1 32.9, 3 31.5 73.2, 4 21.2 98.1")

## An owner''s terms, car by car

The table Cars and terms, at the top of an owner''s page and its Terms tab: each car''s Insurance Fee and Tracker Fee a month, management fee (Revenue Share), Install Fee and Management Mode, and since when they apply.

1. Press **Edit** on a car''s row. The row becomes fields: type the exact amounts (to the cent; the management fee in %). Before the Vehicle Schedule is signed you can also change the Install Fee, the Management Mode and the Onboarding Method.
2. Press **Review**. It lists each value before and after, and what happens to each one. Nothing is saved yet.
3. Not signed yet (or not approved yet): **Save** applies the numbers at once. An unsigned Vehicle Schedule is made again with them, so the owner signs these numbers; a car not approved yet keeps them for the Approve step.
4. Signed: a lower amount is in force from today, or the date you choose under Lower amounts from. No notice period is needed because it only lowers what the owner pays. A lower management fee does this while Settings > Program, Lower management % without owner signature, is on (the default); off, the owner signs an updated Vehicle Schedule first.
5. Signed: a higher Insurance Fee or Tracker Fee needs 30 days'' written notice (Enrollment Agreement 4.8). Choose the date under Higher amounts from (30 days ahead at the earliest) and write the Reason: the owner reads it.
6. Signed: a higher management fee (Revenue Share) needs the same notice and the owner''s signature. The owner is emailed the notice and an updated Vehicle Schedule to sign; it applies from the date once signed, or from the day they sign if that is later. Higher fees in the same change apply from the date by the notice either way.
7. Press **Confirm**. The owner is emailed the written notice, which is also a PDF in their portal and in the car''s History.

History, under each car, lists every period of terms (from, to, the amounts, and why: the Vehicle Schedule, a written notice, lowered) and every change with its notice. A change that has not started yet has Cancel (give the reason): the terms before it run on. An updated schedule waiting for the owner has Record signed on paper (with the date) and Withdraw it. One change at a time: cancel or finish the one waiting before making the next.

The same editor is on the car''s page (Records tab, Owner terms). The owner''s default terms (for cars whose terms are set later) and the first and last month invoice stay on the Terms tab.

> Good to know: Invoices follow the dates: a month whose Insurance Fee or Tracker Fee changes part way is billed per day at each rate. The Revenue Share of a rental is the one in force on the day it is booked.

## Change a signed car''s Management Mode

Managed, Self-Managed or Turo-Only, from a date, for a car whose Vehicle Schedule is signed. An Admin only.

1. Open the owner''s Cars and terms table (or the car''s page) and press **Change mode** on the car''s row.
2. Choose the **New Management Mode** and its Onboarding Method (the options that fit how the car is held), the date under **From**, and write the Reason: the owner reads it. Tick **The owner asked for this** only when it is their own request.
3. Press **Review**: it lists each value before and after (a Self-Managed car has no management fee; a Turo-Only car has no Fees and leaves the fleet insurance policy) and says whether the owner has to sign. Nothing is saved yet.
4. The owner asked and no amount goes up: no signature and no notice period. From today (or the date you chose) the car has the new mode, an updated Vehicle Schedule is issued with CarmaCars'' signature and the owner is emailed the notice.
5. Anything else (CarmaCars'' own decision, or a higher fee): the owner is emailed the notice and an updated Vehicle Schedule to sign, the date is at least 30 days away and the car stays as it is until it is signed. In History, **Record signed on paper** or **Withdraw it**.
6. A change dated ahead applies by itself on its date: the schedule is issued and the car moves. **Cancel** in History (give the reason) stops it and emails the owner that their terms stay as they are. The same email goes when a notice of a higher fee is cancelled.

> Good to know: A shareholder-owned car has fixed terms. A car whose schedule is not signed yet changes its mode in the terms editor, where it applies at once.

## Paid and signed

**People** > **Paid and signed**. What each owner still has to pay or sign, and how each item was done.

1. Each owner shows how many items are open and how many are done. Owners with nothing left are hidden; press Show every owner to see them.
2. Open **Checklist and quick actions**. Each line says Signed in the portal, Signed on paper, Paid by e-Transfer, Not signed, and so on.
3. Paid by e-Transfer, cheque, cash or bank transfer? Press **Record payment**. Choose Paid by, the Date received and the Reference (the cheque number for a cheque). Leave Amount empty for the full balance, or type less for a partial payment. Add a photo of the cheque or a screenshot if you have one.
4. Signed on paper? Press **Record paper signature**. Choose the Document, check Signed by and Date signed, add the witnesses where the form needs them, and upload the scan of every signed page.
5. The same checklist sits at the top of each owner''s page.
6. You rarely need to come here: an upfront or overdue owner invoice is a line on To do with **Record payment**, and an owner whose documents were sent two days ago or more and are not signed is a line with **Record paper signature**. Both pop-ups are the same forms, filled in.

A recorded payment marks the invoice paid (or partly paid), stops the automatic debit for that amount, sends the owner a receipt, and shows "Paid by e-Transfer on " in their portal. A paper signature counts as signed everywhere: the checklist, onboarding and the owner portal. The scan is kept privately with the owner''s documents.

> Watch out: Recorded the wrong thing, or a cheque bounced? Press **Void** beside it and give the reason. The invoice owes that amount again and the owner is told; a voided signature makes the item open again. Only an Admin can void.

## Forms C and D

**People** > **Owner forms**. Form C is signed on screen in the owner portal, with the witness on the same screen. Form D (and Form C on paper, if the owner prefers) is printed, signed in front of witnesses, and sent as a photo of each page.

1. Each row shows the owner, the form, the witnesses and when it was uploaded.
2. Press Open to read the photo or scan. Check each marked spot is signed or initialled.
3. Press **Approve**, or **Send back** with What to fix (the owner reads this).

![](/guides/img/admin-22-owner-forms-desktop-c20ad300.jpg "desktop; size: 1440 470; address: carmacars.ca/admin/owner-forms; pins: 1 29.2 52.3, 2 57.6 52.3, 3 76.7 52.3")
', 'Owners and onboarding', 'Applications, the terms and first invoice, adding a car for an owner, an owner''s terms and invoices, paid and signed, and Forms C and D.',
  'Owners apply on the site with List your car. Every application waits for you in one place, Applications: approve it, ask the owner for something, or decline it. Approved owners sign and pay in their portal.

## Applications

**People** > **Applications**. Every owner application, newest first.

1. The chips filter by status: New, Waiting on owner, Approved, Declined, or All. New applications also show on To do.
2. Each row shows the application number, the owner, the car, how many of the four checks are done, and when they applied.
3. Open an application to decide.

![](/guides/img/admin-33-applications-desktop-152f9e34.jpg "desktop; size: 1440 640; address: carmacars.ca/admin/applications; pins: 1 36.8 39.7, 2 48.6 53.1, 3 19.8 53.1")

## Decide on an application

One page holds everything: the owner, the car, the uploads, the four checks and the notes.

1. Check the driver''s licence, the ownership, the insurance and the lender or lessor. Mark each one Checked, fine, Problem or Not needed.
2. Press **Approve**. The step "Terms and first invoice" opens for each car, filled in with the owner''s negotiated terms (or the standard grid): Insurance Fee, Tracker Fee, management fee (Revenue Share), Install Fee and the first and last month amount (2 x the Insurance Fee unless you type an exact amount). Change any of them to the cent; with several cars, **Use these terms for every car** copies the first car''s numbers to the others.
3. Choose the invoices: First and last month, Registration fee (any exact amount), Tracker install (only once trackers are available) and Another invoice. For each one choose Send now, Save as draft or Already paid. Already paid asks how (e-Transfer, cash, cheque, bank transfer or other), the date and the reference: it is recorded like Record payment and the owner gets the receipt, not an invoice.
4. Press **Approve** at the bottom of the step. Nothing is set or sent before that. The owner becomes active, the documents open for one signature in their portal, only the invoices you chose are made, and the owner gets one email.
5. Missing something? Press **Ask for something**, tick what you need (for example the ownership permit or the insurance slip), add a message if you like, and press **Send to the owner**. The owner gets an email and a task in their portal; the application shows Waiting on owner until they answer.
6. Not a fit? Press **Decline**, write the Reason the owner reads, and press **Decline the application**. The owner is emailed for each car.

![](/guides/img/admin-34-application-desktop-98b64f92.jpg "desktop; size: 1440 812; address: carmacars.ca/admin/applications/c324ef8d-ad00-4bcc-bf04-ca68628a26b4; pins: 1 72.9 67.1, 2 73.9 42.9, 3 84.7 42.9, 4 72.9 49.6")

The application has an Invoices tab: every invoice of its cars, drafts and voids included. An application staff entered for the owner says "Entered by staff" and who; approving it sends the owner the set-up email (review the details and sign) instead of the approval email.

> Tip: Notes on the page are for staff only: **Add note** keeps a line on the record. When the owner answers a request, their answer is in the notes and the application is New again.

## Add a car for an owner

**People** > **Add a car for an owner**, or **Add another car** on an owner''s page. The owner never has to fill in the application.

1. The owner: find them by name, email or phone, or choose New owner and enter the name, email, phone and address.
2. The car: type the VIN. The car is looked up at once and shown in one line (Edit if something is wrong); no VIN at hand, add it by its plate with the year, make and model from the lists. Tap the colour, check the class, then the odometer, insurer and whether it is owned, financed or leased. Photos are optional: the listing shows sample photos until real ones are added. Upload the ownership permit, the insurance slip and the lender''s information if you have them.
3. Terms and first invoice: the same fields as Approve. For another car of the same owner they start from that owner''s terms, or their other car''s; change them for this car.
4. Who sourced the owner: Entered for CarmaCars, or I sourced this owner (only then are you recorded as the one who brought the owner). How the owner signs: by email, or on paper.
5. Press **Add the car and set it up**. The owner gets one email: review the details, correct anything, and sign. An owner with no sign-in gets the link to choose a password in that same email.

Customer service and fleet assistants add cars the same way from their portal; theirs wait in Applications for you, with the terms and invoices they proposed already filled in. On an approved application staff entered, **Send the set-up email again** sends the owner the email with a fresh link.

## Owners

**People** > **Owners**. Every owner, with their cars and where onboarding stands.

1. Each owner shows their application, how many cars, and where onboarding stands.
2. **View as (owner portal)** shows their portal. **Send password link** helps them sign in.
3. Invite an owner on file: fill in Name and Email under Invite an owner, then press **Send invitation**.

![](/guides/img/admin-12-owners-desktop-3a54d505.jpg "desktop; size: 1440 560; address: carmacars.ca/admin/owners; pins: 1 41.0 42.9, 2 37.4 49.3, 3 77.4 82.5")

The owner signs everything at once in their portal (Check and sign: the agreements, schedules and Forms A and B; the official registry forms are printed and signed in ink). The confirmations to tick, then one signature: CarmaCars countersigns at the same moment, under the signing officer''s standing authorization. A car with a second owner on the ownership waits for that owner too: they get their own link by email and sign the same documents.

## Mark a car insured (Insurer confirmed)

A program owner''s car is handed over to a renter only once the insurer confirms in writing that it is on the fleet policy. Requests, offers and payment never wait for it.

1. Each car waiting for the insurer is a line on To do: "Insurer has not confirmed : mark it insured". It says Now when a booking picks the car up soon.
2. When the insurer''s email arrives, press **Mark insured**. The date is today; change it to the date of the insurer''s email if it was earlier. Add its subject as the Reference if you like, and press **Insurer confirmed**.
3. One email for several cars? Press **Mark several insured** on the line " cars wait for the insurer". Every waiting car is ticked: untick any car the insurer did not name, check the date, and confirm them all at once.
4. The same button is on the car: Overview (**Insurer confirmed**) and the Listing tab''s checklist, item "Not on the fleet insurance policy yet".

The car is then on the fleet policy from that date: it can be handed over, its Enrollment Date is that date, its fee terms start, and the owner gets the email "Written confirmation: your car is on the fleet policy". Its paperwork (agreements, registry visit, tracker) stays on its checklist until done. A car already listed and Available stays Available.

## Owners who paid another way, and the terms you agreed

Two lines on To do keep an owner''s money right without opening their page.

1. "Record the first and last month paid by ": their first and last month invoice was voided and nothing paid is recorded. Press **Record what they paid**, type the amount for each car (tax included), or one total for several cars, how and when it was paid and the reference. A draft first and last month invoice is kept or voided, your choice. Each car''s invoice is then marked paid, the owner gets the receipt and the two prepaid months count. Never for a shareholder.
2. "Enter the terms agreed with ": their cars still use the standard grid. Press **Enter the terms**: the Management fee (Revenue Share), the Insurance Fee, the Tracker Fee, the Install Fee and the first and last month are filled in from the grid. Type what you agreed for the owner, and open a car to give it its own. A car whose schedule is signed gets an updated schedule for the owner to sign.
3. Nothing to change? Press **Not needed** or **These are correct**: the line does not come back.

## A shareholder''s own car

On the owner''s page, each car has **Shareholder’s own car**.

1. A shareholder''s own car is split 90/10 (the share in Program settings) and pays no Insurance Fee, Tracker Fee, first and last month or tracker install.
2. Press **Shareholder’s own car**, say why (it is kept in the audit log) and confirm. Press it again to undo. Bookings already made keep their split.
3. A first and last month or a tracker install invoice is refused for such a car, from any screen.

## Cancellation refunds

**Settings** > **Program**: the refund for each cancellation tier.

| When the renter cancels | Refund (default) |
| --- | --- |
| Within 24 hours of booking, 48 hours or more before the start | 95% |
| 48 hours or more before the start | 75% |
| 24 to 48 hours before the start | 50% |
| Under 24 hours, or after the start | 0% |

## An owner''s page

Open an owner from Owners. Three tabs: Overview, Terms and Invoices. **Add another car** and **New invoice** sit under the name.

1. Cars and terms, at the top: each car''s Insurance Fee, Tracker Fee, management fee (Revenue Share), Install Fee and mode, with **Edit** and History (see An owner''s terms, car by car).
2. Upfront invoices: issue the first and last month amount agreed on each car''s terms, for each car whose terms are set.
3. Owner: address, sign-in, agreements, and what is still missing for the registry forms.
4. Statements and payouts for this owner.
5. Forms C and D, with a link to the review queue.
6. Further down: **View as (owner portal)**, **Send password link** and **Send a sign-in link to the owner portal**.

![](/guides/img/admin-13-owner-desktop-819a9f8b.jpg "desktop; size: 410 1030; address: carmacars.ca/admin/owners/50a834dc-270a-4c26-b79e-6396fa7bf2e1; pins: 1 24.6 4.4, 2 16.1 32.9, 3 31.5 73.2, 4 21.2 98.1")

## An owner''s terms, car by car

The table Cars and terms, at the top of an owner''s page and its Terms tab: each car''s Insurance Fee and Tracker Fee a month, management fee (Revenue Share), Install Fee and Management Mode, and since when they apply.

1. Press **Edit** on a car''s row. The row becomes fields: type the exact amounts (to the cent; the management fee in %). Before the Vehicle Schedule is signed you can also change the Install Fee, the Management Mode and the Onboarding Method.
2. Press **Review**. It lists each value before and after, and what happens to each one. Nothing is saved yet.
3. Not signed yet (or not approved yet): **Save** applies the numbers at once. An unsigned Vehicle Schedule is made again with them, so the owner signs these numbers; a car not approved yet keeps them for the Approve step.
4. Signed: a lower amount is in force from today, or the date you choose under Lower amounts from. No notice period is needed because it only lowers what the owner pays. A lower management fee does this while Settings > Program, Lower management % without owner signature, is on (the default); off, the owner signs an updated Vehicle Schedule first.
5. Signed: a higher Insurance Fee or Tracker Fee needs 30 days'' written notice (Enrollment Agreement 4.8). Choose the date under Higher amounts from (30 days ahead at the earliest) and write the Reason: the owner reads it.
6. Signed: a higher management fee (Revenue Share) needs the same notice and the owner''s signature. The owner is emailed the notice and an updated Vehicle Schedule to sign; it applies from the date once signed, or from the day they sign if that is later. Higher fees in the same change apply from the date by the notice either way.
7. Press **Confirm**. The owner is emailed the written notice, which is also a PDF in their portal and in the car''s History.

History, under each car, lists every period of terms (from, to, the amounts, and why: the Vehicle Schedule, a written notice, lowered) and every change with its notice. A change that has not started yet has Cancel (give the reason): the terms before it run on. An updated schedule waiting for the owner has Record signed on paper (with the date) and Withdraw it. One change at a time: cancel or finish the one waiting before making the next.

The same editor is on the car''s page (Records tab, Owner terms). The owner''s default terms (for cars whose terms are set later) and the first and last month invoice stay on the Terms tab.

> Good to know: Invoices follow the dates: a month whose Insurance Fee or Tracker Fee changes part way is billed per day at each rate. The Revenue Share of a rental is the one in force on the day it is booked.

## Pay an owner a flat monthly amount

Some owners want the same amount every month for a car instead of a revenue share and fees. An Admin only, car by car.

1. Open the owner''s Cars and terms table (or the car''s page) and press **Pay** on the car''s row.
2. Choose **Flat monthly payment**, type the **Amount a month** (for example 900.00), the date under **From** and, if it ends, the **Last day**. Write the Reason (kept in the history).
3. Press **Review**: it says what happens and lists any monthly invoice already issued for those days. Then press **Confirm**.
4. From that date the owner''s statement pays the amount every month (a part month by the day), with no revenue share and no Insurance Fee or Tracker Fee. Rentals ending on those days stay with CarmaCars, in the company figures.
5. Back to revenue share: press **Pay**, choose Revenue share and the date. The flat period ends the day before; every period stays in the list.

> Good to know: A month already on an approved owner statement never changes: a new date starts after it. A monthly invoice already issued for flat days stays: void or credit it. A booking expense on a flat car is CarmaCars'' own unless you press **Charge to the owner** beside it on the booking (an Admin only): it is then an owner cost on their statement. Owner costs recorded on the owner''s account (tickets, tolls, damage of their own use) are charged as before.

## Change a signed car''s Management Mode

Managed, Self-Managed or Turo-Only, from a date, for a car whose Vehicle Schedule is signed. An Admin only.

1. Open the owner''s Cars and terms table (or the car''s page) and press **Change mode** on the car''s row.
2. Choose the **New Management Mode** and its Onboarding Method (the options that fit how the car is held), the date under **From**, and write the Reason: the owner reads it. Tick **The owner asked for this** only when it is their own request.
3. Press **Review**: it lists each value before and after (a Self-Managed car has no management fee; a Turo-Only car has no Fees and leaves the fleet insurance policy) and says whether the owner has to sign. Nothing is saved yet.
4. The owner asked and no amount goes up: no signature and no notice period. From today (or the date you chose) the car has the new mode, an updated Vehicle Schedule is issued with CarmaCars'' signature and the owner is emailed the notice.
5. Anything else (CarmaCars'' own decision, or a higher fee): the owner is emailed the notice and an updated Vehicle Schedule to sign, the date is at least 30 days away and the car stays as it is until it is signed. In History, **Record signed on paper** or **Withdraw it**.
6. A change dated ahead applies by itself on its date: the schedule is issued and the car moves. **Cancel** in History (give the reason) stops it and emails the owner that their terms stay as they are. The same email goes when a notice of a higher fee is cancelled.

> Good to know: A shareholder-owned car has fixed terms. A car whose schedule is not signed yet changes its mode in the terms editor, where it applies at once.

## Paid and signed

**People** > **Paid and signed**. What each owner still has to pay or sign, and how each item was done.

1. Each owner shows how many items are open and how many are done. Owners with nothing left are hidden; press Show every owner to see them.
2. Open **Checklist and quick actions**. Each line says Signed in the portal, Signed on paper, Paid by e-Transfer, Not signed, and so on.
3. Paid by e-Transfer, cheque, cash or bank transfer? Press **Record payment**. Choose Paid by, the Date received and the Reference (the cheque number for a cheque). Leave Amount empty for the full balance, or type less for a partial payment. Add a photo of the cheque or a screenshot if you have one.
4. Signed on paper? Press **Record paper signature**. Choose the Document, check Signed by and Date signed, add the witnesses where the form needs them, and upload the scan of every signed page.
5. The same checklist sits at the top of each owner''s page.
6. You rarely need to come here: an upfront or overdue owner invoice is a line on To do with **Record payment**, and an owner whose documents were sent two days ago or more and are not signed is a line with **Record paper signature**. Both pop-ups are the same forms, filled in.

A recorded payment marks the invoice paid (or partly paid), stops the automatic debit for that amount, sends the owner a receipt, and shows "Paid by e-Transfer on " in their portal. A paper signature counts as signed everywhere: the checklist, onboarding and the owner portal. The scan is kept privately with the owner''s documents.

> Watch out: Recorded the wrong thing, or a cheque bounced? Press **Void** beside it and give the reason. The invoice owes that amount again and the owner is told; a voided signature makes the item open again. Only an Admin can void.

## Forms C and D

**People** > **Owner forms**. Form C is signed on screen in the owner portal, with the witness on the same screen. Form D (and Form C on paper, if the owner prefers) is printed, signed in front of witnesses, and sent as a photo of each page.

1. Each row shows the owner, the form, the witnesses and when it was uploaded.
2. Press Open to read the photo or scan. Check each marked spot is signed or initialled.
3. Press **Approve**, or **Send back** with What to fix (the owner reads this).

![](/guides/img/admin-22-owner-forms-desktop-c20ad300.jpg "desktop; size: 1440 470; address: carmacars.ca/admin/owner-forms; pins: 1 29.2 52.3, 2 57.6 52.3, 3 76.7 52.3")
',
  '<p class="gd-p">Owners apply on the site with List your car. Every application waits for you in one place, Applications: approve it, ask the owner for something, or decline it. Approved owners sign and pay in their portal.</p><section class="gd-task" id="owners-and-onboarding-applications" data-gd-task><h2 class="gd-h2">Applications</h2><p class="gd-p"><b class="gd-ui">People</b> &gt; <b class="gd-ui">Applications</b>. Every owner application, newest first.</p><div class="gd-stepblock gd-stepblock--below"><div class="gd-stepcol"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">The chips filter by status: New, Waiting on owner, Approved, Declined, or All. New applications also show on To do.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Each row shows the application number, the owner, the car, how many of the four checks are done, and when they applied.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Open an application to decide.</div></li></ol></div><figure class="gd-fig gd-fig--desk"><div class="gd-browser"><div class="gd-bar" aria-hidden="true"><i></i><i></i><i></i><span class="gd-addr">carmacars.ca/admin/applications</span></div><div class="gd-imgwrap" style="aspect-ratio:1440/640"><img src="/guides/img/admin-33-applications-desktop-152f9e34.jpg" alt="" loading="lazy" decoding="async" width="1440" height="640"><span class="gd-pin" style="left:36.8%;top:39.7%" aria-hidden="true">1</span><span class="gd-pin" style="left:48.6%;top:53.1%" aria-hidden="true">2</span><span class="gd-pin" style="left:19.8%;top:53.1%" aria-hidden="true">3</span></div></div></figure></div></section><section class="gd-task" id="owners-and-onboarding-decide-on-an-application" data-gd-task><h2 class="gd-h2">Decide on an application</h2><p class="gd-p">One page holds everything: the owner, the car, the uploads, the four checks and the notes.</p><div class="gd-stepblock gd-stepblock--below"><div class="gd-stepcol"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Check the driver&#39;s licence, the ownership, the insurance and the lender or lessor. Mark each one Checked, fine, Problem or Not needed.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Press <b class="gd-ui">Approve</b>. The step &quot;Terms and first invoice&quot; opens for each car, filled in with the owner&#39;s negotiated terms (or the standard grid): Insurance Fee, Tracker Fee, management fee (Revenue Share), Install Fee and the first and last month amount (2 x the Insurance Fee unless you type an exact amount). Change any of them to the cent; with several cars, <b class="gd-ui">Use these terms for every car</b> copies the first car&#39;s numbers to the others.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Choose the invoices: First and last month, Registration fee (any exact amount), Tracker install (only once trackers are available) and Another invoice. For each one choose Send now, Save as draft or Already paid. Already paid asks how (e-Transfer, cash, cheque, bank transfer or other), the date and the reference: it is recorded like Record payment and the owner gets the receipt, not an invoice.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">Press <b class="gd-ui">Approve</b> at the bottom of the step. Nothing is set or sent before that. The owner becomes active, the documents open for one signature in their portal, only the invoices you chose are made, and the owner gets one email.</div></li><li><span class="gd-n" aria-hidden="true">5</span><div class="gd-t">Missing something? Press <b class="gd-ui">Ask for something</b>, tick what you need (for example the ownership permit or the insurance slip), add a message if you like, and press <b class="gd-ui">Send to the owner</b>. The owner gets an email and a task in their portal; the application shows Waiting on owner until they answer.</div></li><li><span class="gd-n" aria-hidden="true">6</span><div class="gd-t">Not a fit? Press <b class="gd-ui">Decline</b>, write the Reason the owner reads, and press <b class="gd-ui">Decline the application</b>. The owner is emailed for each car.</div></li></ol></div><figure class="gd-fig gd-fig--desk"><div class="gd-browser"><div class="gd-bar" aria-hidden="true"><i></i><i></i><i></i><span class="gd-addr">carmacars.ca/admin/applications/c324ef8d-ad00-4bcc-bf04-ca68628a26b4</span></div><div class="gd-imgwrap" style="aspect-ratio:1440/812"><img src="/guides/img/admin-34-application-desktop-98b64f92.jpg" alt="" loading="lazy" decoding="async" width="1440" height="812"><span class="gd-pin" style="left:72.9%;top:67.1%" aria-hidden="true">1</span><span class="gd-pin" style="left:73.9%;top:42.9%" aria-hidden="true">2</span><span class="gd-pin" style="left:84.7%;top:42.9%" aria-hidden="true">3</span><span class="gd-pin" style="left:72.9%;top:49.6%" aria-hidden="true">4</span></div></div></figure></div><p class="gd-p">The application has an Invoices tab: every invoice of its cars, drafts and voids included. An application staff entered for the owner says &quot;Entered by staff&quot; and who; approving it sends the owner the set-up email (review the details and sign) instead of the approval email.</p><aside class="gd-box"><span class="gd-lbl">Tip</span><div>Notes on the page are for staff only: <b class="gd-ui">Add note</b> keeps a line on the record. When the owner answers a request, their answer is in the notes and the application is New again.</div></aside></section><section class="gd-task" id="owners-and-onboarding-add-a-car-for-an-owner" data-gd-task><h2 class="gd-h2">Add a car for an owner</h2><p class="gd-p"><b class="gd-ui">People</b> &gt; <b class="gd-ui">Add a car for an owner</b>, or <b class="gd-ui">Add another car</b> on an owner&#39;s page. The owner never has to fill in the application.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">The owner: find them by name, email or phone, or choose New owner and enter the name, email, phone and address.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">The car: type the VIN. The car is looked up at once and shown in one line (Edit if something is wrong); no VIN at hand, add it by its plate with the year, make and model from the lists. Tap the colour, check the class, then the odometer, insurer and whether it is owned, financed or leased. Photos are optional: the listing shows sample photos until real ones are added. Upload the ownership permit, the insurance slip and the lender&#39;s information if you have them.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Terms and first invoice: the same fields as Approve. For another car of the same owner they start from that owner&#39;s terms, or their other car&#39;s; change them for this car.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">Who sourced the owner: Entered for CarmaCars, or I sourced this owner (only then are you recorded as the one who brought the owner). How the owner signs: by email, or on paper.</div></li><li><span class="gd-n" aria-hidden="true">5</span><div class="gd-t">Press <b class="gd-ui">Add the car and set it up</b>. The owner gets one email: review the details, correct anything, and sign. An owner with no sign-in gets the link to choose a password in that same email.</div></li></ol></div><p class="gd-p">Customer service and fleet assistants add cars the same way from their portal; theirs wait in Applications for you, with the terms and invoices they proposed already filled in. On an approved application staff entered, <b class="gd-ui">Send the set-up email again</b> sends the owner the email with a fresh link.</p></section><section class="gd-task" id="owners-and-onboarding-owners" data-gd-task><h2 class="gd-h2">Owners</h2><p class="gd-p"><b class="gd-ui">People</b> &gt; <b class="gd-ui">Owners</b>. Every owner, with their cars and where onboarding stands.</p><div class="gd-stepblock gd-stepblock--below"><div class="gd-stepcol"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Each owner shows their application, how many cars, and where onboarding stands.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t"><b class="gd-ui">View as (owner portal)</b> shows their portal. <b class="gd-ui">Send password link</b> helps them sign in.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Invite an owner on file: fill in Name and Email under Invite an owner, then press <b class="gd-ui">Send invitation</b>.</div></li></ol></div><figure class="gd-fig gd-fig--desk"><div class="gd-browser"><div class="gd-bar" aria-hidden="true"><i></i><i></i><i></i><span class="gd-addr">carmacars.ca/admin/owners</span></div><div class="gd-imgwrap" style="aspect-ratio:1440/560"><img src="/guides/img/admin-12-owners-desktop-3a54d505.jpg" alt="" loading="lazy" decoding="async" width="1440" height="560"><span class="gd-pin" style="left:41%;top:42.9%" aria-hidden="true">1</span><span class="gd-pin" style="left:37.4%;top:49.3%" aria-hidden="true">2</span><span class="gd-pin" style="left:77.4%;top:82.5%" aria-hidden="true">3</span></div></div></figure></div><p class="gd-p">The owner signs everything at once in their portal (Check and sign: the agreements, schedules and Forms A and B; the official registry forms are printed and signed in ink). The confirmations to tick, then one signature: CarmaCars countersigns at the same moment, under the signing officer&#39;s standing authorization. A car with a second owner on the ownership waits for that owner too: they get their own link by email and sign the same documents.</p></section><section class="gd-task" id="owners-and-onboarding-mark-a-car-insured-insurer-confirmed" data-gd-task><h2 class="gd-h2">Mark a car insured (Insurer confirmed)</h2><p class="gd-p">A program owner&#39;s car is handed over to a renter only once the insurer confirms in writing that it is on the fleet policy. Requests, offers and payment never wait for it.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Each car waiting for the insurer is a line on To do: &quot;Insurer has not confirmed : mark it insured&quot;. It says Now when a booking picks the car up soon.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">When the insurer&#39;s email arrives, press <b class="gd-ui">Mark insured</b>. The date is today; change it to the date of the insurer&#39;s email if it was earlier. Add its subject as the Reference if you like, and press <b class="gd-ui">Insurer confirmed</b>.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">One email for several cars? Press <b class="gd-ui">Mark several insured</b> on the line &quot; cars wait for the insurer&quot;. Every waiting car is ticked: untick any car the insurer did not name, check the date, and confirm them all at once.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">The same button is on the car: Overview (<b class="gd-ui">Insurer confirmed</b>) and the Listing tab&#39;s checklist, item &quot;Not on the fleet insurance policy yet&quot;.</div></li></ol></div><p class="gd-p">The car is then on the fleet policy from that date: it can be handed over, its Enrollment Date is that date, its fee terms start, and the owner gets the email &quot;Written confirmation: your car is on the fleet policy&quot;. Its paperwork (agreements, registry visit, tracker) stays on its checklist until done. A car already listed and Available stays Available.</p></section><section class="gd-task" id="owners-and-onboarding-owners-who-paid-another-way-and-the-terms-you-agreed" data-gd-task><h2 class="gd-h2">Owners who paid another way, and the terms you agreed</h2><p class="gd-p">Two lines on To do keep an owner&#39;s money right without opening their page.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">&quot;Record the first and last month paid by &quot;: their first and last month invoice was voided and nothing paid is recorded. Press <b class="gd-ui">Record what they paid</b>, type the amount for each car (tax included), or one total for several cars, how and when it was paid and the reference. A draft first and last month invoice is kept or voided, your choice. Each car&#39;s invoice is then marked paid, the owner gets the receipt and the two prepaid months count. Never for a shareholder.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">&quot;Enter the terms agreed with &quot;: their cars still use the standard grid. Press <b class="gd-ui">Enter the terms</b>: the Management fee (Revenue Share), the Insurance Fee, the Tracker Fee, the Install Fee and the first and last month are filled in from the grid. Type what you agreed for the owner, and open a car to give it its own. A car whose schedule is signed gets an updated schedule for the owner to sign.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Nothing to change? Press <b class="gd-ui">Not needed</b> or <b class="gd-ui">These are correct</b>: the line does not come back.</div></li></ol></div></section><section class="gd-task" id="owners-and-onboarding-a-shareholder-s-own-car" data-gd-task><h2 class="gd-h2">A shareholder&#39;s own car</h2><p class="gd-p">On the owner&#39;s page, each car has <b class="gd-ui">Shareholder’s own car</b>.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">A shareholder&#39;s own car is split 90/10 (the share in Program settings) and pays no Insurance Fee, Tracker Fee, first and last month or tracker install.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Press <b class="gd-ui">Shareholder’s own car</b>, say why (it is kept in the audit log) and confirm. Press it again to undo. Bookings already made keep their split.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">A first and last month or a tracker install invoice is refused for such a car, from any screen.</div></li></ol></div></section><section class="gd-task" id="owners-and-onboarding-cancellation-refunds" data-gd-task><h2 class="gd-h2">Cancellation refunds</h2><p class="gd-p"><b class="gd-ui">Settings</b> &gt; <b class="gd-ui">Program</b>: the refund for each cancellation tier.</p><div class="gd-tablewrap"><table class="gd-table"><thead><tr><th scope="col">When the renter cancels</th><th scope="col">Refund (default)</th></tr></thead><tbody><tr><td>Within 24 hours of booking, 48 hours or more before the start</td><td>95%</td></tr><tr><td>48 hours or more before the start</td><td>75%</td></tr><tr><td>24 to 48 hours before the start</td><td>50%</td></tr><tr><td>Under 24 hours, or after the start</td><td>0%</td></tr></tbody></table></div></section><section class="gd-task" id="owners-and-onboarding-an-owner-s-page" data-gd-task><h2 class="gd-h2">An owner&#39;s page</h2><p class="gd-p">Open an owner from Owners. Three tabs: Overview, Terms and Invoices. <b class="gd-ui">Add another car</b> and <b class="gd-ui">New invoice</b> sit under the name.</p><div class="gd-stepblock gd-stepblock--below"><div class="gd-stepcol"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Cars and terms, at the top: each car&#39;s Insurance Fee, Tracker Fee, management fee (Revenue Share), Install Fee and mode, with <b class="gd-ui">Edit</b> and History (see An owner&#39;s terms, car by car).</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Upfront invoices: issue the first and last month amount agreed on each car&#39;s terms, for each car whose terms are set.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Owner: address, sign-in, agreements, and what is still missing for the registry forms.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">Statements and payouts for this owner.</div></li><li><span class="gd-n" aria-hidden="true">5</span><div class="gd-t">Forms C and D, with a link to the review queue.</div></li><li><span class="gd-n" aria-hidden="true">6</span><div class="gd-t">Further down: <b class="gd-ui">View as (owner portal)</b>, <b class="gd-ui">Send password link</b> and <b class="gd-ui">Send a sign-in link to the owner portal</b>.</div></li></ol></div><figure class="gd-fig gd-fig--desk"><div class="gd-browser"><div class="gd-bar" aria-hidden="true"><i></i><i></i><i></i><span class="gd-addr">carmacars.ca/admin/owners/50a834dc-270a-4c26-b79e-6396fa7bf2e1</span></div><div class="gd-imgwrap" style="aspect-ratio:410/1030"><img src="/guides/img/admin-13-owner-desktop-819a9f8b.jpg" alt="" loading="lazy" decoding="async" width="410" height="1030"><span class="gd-pin" style="left:24.6%;top:4.4%" aria-hidden="true">1</span><span class="gd-pin" style="left:16.1%;top:32.9%" aria-hidden="true">2</span><span class="gd-pin" style="left:31.5%;top:73.2%" aria-hidden="true">3</span><span class="gd-pin" style="left:21.2%;top:98.1%" aria-hidden="true">4</span></div></div></figure></div></section><section class="gd-task" id="owners-and-onboarding-an-owner-s-terms-car-by-car" data-gd-task><h2 class="gd-h2">An owner&#39;s terms, car by car</h2><p class="gd-p">The table Cars and terms, at the top of an owner&#39;s page and its Terms tab: each car&#39;s Insurance Fee and Tracker Fee a month, management fee (Revenue Share), Install Fee and Management Mode, and since when they apply.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Press <b class="gd-ui">Edit</b> on a car&#39;s row. The row becomes fields: type the exact amounts (to the cent; the management fee in %). Before the Vehicle Schedule is signed you can also change the Install Fee, the Management Mode and the Onboarding Method.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Press <b class="gd-ui">Review</b>. It lists each value before and after, and what happens to each one. Nothing is saved yet.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Not signed yet (or not approved yet): <b class="gd-ui">Save</b> applies the numbers at once. An unsigned Vehicle Schedule is made again with them, so the owner signs these numbers; a car not approved yet keeps them for the Approve step.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">Signed: a lower amount is in force from today, or the date you choose under Lower amounts from. No notice period is needed because it only lowers what the owner pays. A lower management fee does this while Settings &gt; Program, Lower management % without owner signature, is on (the default); off, the owner signs an updated Vehicle Schedule first.</div></li><li><span class="gd-n" aria-hidden="true">5</span><div class="gd-t">Signed: a higher Insurance Fee or Tracker Fee needs 30 days&#39; written notice (Enrollment Agreement 4.8). Choose the date under Higher amounts from (30 days ahead at the earliest) and write the Reason: the owner reads it.</div></li><li><span class="gd-n" aria-hidden="true">6</span><div class="gd-t">Signed: a higher management fee (Revenue Share) needs the same notice and the owner&#39;s signature. The owner is emailed the notice and an updated Vehicle Schedule to sign; it applies from the date once signed, or from the day they sign if that is later. Higher fees in the same change apply from the date by the notice either way.</div></li><li><span class="gd-n" aria-hidden="true">7</span><div class="gd-t">Press <b class="gd-ui">Confirm</b>. The owner is emailed the written notice, which is also a PDF in their portal and in the car&#39;s History.</div></li></ol></div><p class="gd-p">History, under each car, lists every period of terms (from, to, the amounts, and why: the Vehicle Schedule, a written notice, lowered) and every change with its notice. A change that has not started yet has Cancel (give the reason): the terms before it run on. An updated schedule waiting for the owner has Record signed on paper (with the date) and Withdraw it. One change at a time: cancel or finish the one waiting before making the next.</p><p class="gd-p">The same editor is on the car&#39;s page (Records tab, Owner terms). The owner&#39;s default terms (for cars whose terms are set later) and the first and last month invoice stay on the Terms tab.</p><aside class="gd-box"><span class="gd-lbl">Good to know</span><div>Invoices follow the dates: a month whose Insurance Fee or Tracker Fee changes part way is billed per day at each rate. The Revenue Share of a rental is the one in force on the day it is booked.</div></aside></section><section class="gd-task" id="owners-and-onboarding-pay-an-owner-a-flat-monthly-amount" data-gd-task><h2 class="gd-h2">Pay an owner a flat monthly amount</h2><p class="gd-p">Some owners want the same amount every month for a car instead of a revenue share and fees. An Admin only, car by car.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Open the owner&#39;s Cars and terms table (or the car&#39;s page) and press <b class="gd-ui">Pay</b> on the car&#39;s row.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Choose <b class="gd-ui">Flat monthly payment</b>, type the <b class="gd-ui">Amount a month</b> (for example 900.00), the date under <b class="gd-ui">From</b> and, if it ends, the <b class="gd-ui">Last day</b>. Write the Reason (kept in the history).</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Press <b class="gd-ui">Review</b>: it says what happens and lists any monthly invoice already issued for those days. Then press <b class="gd-ui">Confirm</b>.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">From that date the owner&#39;s statement pays the amount every month (a part month by the day), with no revenue share and no Insurance Fee or Tracker Fee. Rentals ending on those days stay with CarmaCars, in the company figures.</div></li><li><span class="gd-n" aria-hidden="true">5</span><div class="gd-t">Back to revenue share: press <b class="gd-ui">Pay</b>, choose Revenue share and the date. The flat period ends the day before; every period stays in the list.</div></li></ol></div><aside class="gd-box"><span class="gd-lbl">Good to know</span><div>A month already on an approved owner statement never changes: a new date starts after it. A monthly invoice already issued for flat days stays: void or credit it. A booking expense on a flat car is CarmaCars&#39; own unless you press <b class="gd-ui">Charge to the owner</b> beside it on the booking (an Admin only): it is then an owner cost on their statement. Owner costs recorded on the owner&#39;s account (tickets, tolls, damage of their own use) are charged as before.</div></aside></section><section class="gd-task" id="owners-and-onboarding-change-a-signed-car-s-management-mode" data-gd-task><h2 class="gd-h2">Change a signed car&#39;s Management Mode</h2><p class="gd-p">Managed, Self-Managed or Turo-Only, from a date, for a car whose Vehicle Schedule is signed. An Admin only.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Open the owner&#39;s Cars and terms table (or the car&#39;s page) and press <b class="gd-ui">Change mode</b> on the car&#39;s row.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Choose the <b class="gd-ui">New Management Mode</b> and its Onboarding Method (the options that fit how the car is held), the date under <b class="gd-ui">From</b>, and write the Reason: the owner reads it. Tick <b class="gd-ui">The owner asked for this</b> only when it is their own request.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Press <b class="gd-ui">Review</b>: it lists each value before and after (a Self-Managed car has no management fee; a Turo-Only car has no Fees and leaves the fleet insurance policy) and says whether the owner has to sign. Nothing is saved yet.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">The owner asked and no amount goes up: no signature and no notice period. From today (or the date you chose) the car has the new mode, an updated Vehicle Schedule is issued with CarmaCars&#39; signature and the owner is emailed the notice.</div></li><li><span class="gd-n" aria-hidden="true">5</span><div class="gd-t">Anything else (CarmaCars&#39; own decision, or a higher fee): the owner is emailed the notice and an updated Vehicle Schedule to sign, the date is at least 30 days away and the car stays as it is until it is signed. In History, <b class="gd-ui">Record signed on paper</b> or <b class="gd-ui">Withdraw it</b>.</div></li><li><span class="gd-n" aria-hidden="true">6</span><div class="gd-t">A change dated ahead applies by itself on its date: the schedule is issued and the car moves. <b class="gd-ui">Cancel</b> in History (give the reason) stops it and emails the owner that their terms stay as they are. The same email goes when a notice of a higher fee is cancelled.</div></li></ol></div><aside class="gd-box"><span class="gd-lbl">Good to know</span><div>A shareholder-owned car has fixed terms. A car whose schedule is not signed yet changes its mode in the terms editor, where it applies at once.</div></aside></section><section class="gd-task" id="owners-and-onboarding-paid-and-signed" data-gd-task><h2 class="gd-h2">Paid and signed</h2><p class="gd-p"><b class="gd-ui">People</b> &gt; <b class="gd-ui">Paid and signed</b>. What each owner still has to pay or sign, and how each item was done.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Each owner shows how many items are open and how many are done. Owners with nothing left are hidden; press Show every owner to see them.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Open <b class="gd-ui">Checklist and quick actions</b>. Each line says Signed in the portal, Signed on paper, Paid by e-Transfer, Not signed, and so on.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Paid by e-Transfer, cheque, cash or bank transfer? Press <b class="gd-ui">Record payment</b>. Choose Paid by, the Date received and the Reference (the cheque number for a cheque). Leave Amount empty for the full balance, or type less for a partial payment. Add a photo of the cheque or a screenshot if you have one.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">Signed on paper? Press <b class="gd-ui">Record paper signature</b>. Choose the Document, check Signed by and Date signed, add the witnesses where the form needs them, and upload the scan of every signed page.</div></li><li><span class="gd-n" aria-hidden="true">5</span><div class="gd-t">The same checklist sits at the top of each owner&#39;s page.</div></li><li><span class="gd-n" aria-hidden="true">6</span><div class="gd-t">You rarely need to come here: an upfront or overdue owner invoice is a line on To do with <b class="gd-ui">Record payment</b>, and an owner whose documents were sent two days ago or more and are not signed is a line with <b class="gd-ui">Record paper signature</b>. Both pop-ups are the same forms, filled in.</div></li></ol></div><p class="gd-p">A recorded payment marks the invoice paid (or partly paid), stops the automatic debit for that amount, sends the owner a receipt, and shows &quot;Paid by e-Transfer on &quot; in their portal. A paper signature counts as signed everywhere: the checklist, onboarding and the owner portal. The scan is kept privately with the owner&#39;s documents.</p><aside class="gd-box gd-box--warn"><span class="gd-lbl">Watch out</span><div>Recorded the wrong thing, or a cheque bounced? Press <b class="gd-ui">Void</b> beside it and give the reason. The invoice owes that amount again and the owner is told; a voided signature makes the item open again. Only an Admin can void.</div></aside></section><section class="gd-task" id="owners-and-onboarding-forms-c-and-d" data-gd-task><h2 class="gd-h2">Forms C and D</h2><p class="gd-p"><b class="gd-ui">People</b> &gt; <b class="gd-ui">Owner forms</b>. Form C is signed on screen in the owner portal, with the witness on the same screen. Form D (and Form C on paper, if the owner prefers) is printed, signed in front of witnesses, and sent as a photo of each page.</p><div class="gd-stepblock gd-stepblock--below"><div class="gd-stepcol"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Each row shows the owner, the form, the witnesses and when it was uploaded.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Press Open to read the photo or scan. Check each marked spot is signed or initialled.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Press <b class="gd-ui">Approve</b>, or <b class="gd-ui">Send back</b> with What to fix (the owner reads this).</div></li></ol></div><figure class="gd-fig gd-fig--desk"><div class="gd-browser"><div class="gd-bar" aria-hidden="true"><i></i><i></i><i></i><span class="gd-addr">carmacars.ca/admin/owner-forms</span></div><div class="gd-imgwrap" style="aspect-ratio:1440/470"><img src="/guides/img/admin-22-owner-forms-desktop-c20ad300.jpg" alt="" loading="lazy" decoding="async" width="1440" height="470"><span class="gd-pin" style="left:29.2%;top:52.3%" aria-hidden="true">1</span><span class="gd-pin" style="left:57.6%;top:52.3%" aria-hidden="true">2</span><span class="gd-pin" style="left:76.7%;top:52.3%" aria-hidden="true">3</span></div></div></figure></div></section>');
select app.guide_release_section('admin', 'settings', 'chapter', 'search-car-pages-landing-pages-and-guides', 'Settings change the public site and the rules of the program at once. Program settings are kept as dated rows, so earlier values stay on record.

## The Settings page

1. Site setup lists what is still missing on the public site, with **Open site settings**.
2. Site settings: contact details, hours, tagline, logo, socials, Google place id and featured cars.
3. Program settings: every timing and policy value.
4. Forms: Blind Spot''s rental agreement for every booking, and the official ServiceOntario PDFs and what goes in each field.
5. Insurers: insurance companies billed for bookings.

![](/guides/img/admin-24-settings-desktop-89b31691.jpg "desktop; size: 1440 900; address: carmacars.ca/admin/settings; pins: 1 32.6 33.0, 2 25.8 40.2, 3 77.4 40.2, 4 25.8 73.2, 5 25.8 84.9")

The other tiles: Site content (headings, FAQs, legal text), Fee defaults, Deposit tiers, Kilometre choices, Vehicle classes, Vehicle class rules, Airports and delivery, Protection Plan prices, Card coverage, Reviews, Quo contacts (everyone with a phone number as a contact in Quo: see Texts and calls), Text alerts, Partners (each partner company''s CRM link: see Partners, company cars and rentals added by hand), Email aliases and reply-to, Staff and roles, Promo codes and Quick replies.

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
', 'Settings', 'Site, program settings, official forms mapping, insurers and the other lists.',
  'Settings change the public site and the rules of the program at once. Program settings are kept as dated rows, so earlier values stay on record.

## The Settings page

1. Site setup lists what is still missing on the public site, with **Open site settings**.
2. Site settings: contact details, hours, tagline, logo, socials, Google place id and featured cars.
3. Program settings: every timing and policy value.
4. Forms: Blind Spot''s rental agreement for every booking, and the official ServiceOntario PDFs and what goes in each field.
5. Insurers: insurance companies billed for bookings.

![](/guides/img/admin-24-settings-desktop-89b31691.jpg "desktop; size: 1440 900; address: carmacars.ca/admin/settings; pins: 1 32.6 33.0, 2 25.8 40.2, 3 77.4 40.2, 4 25.8 73.2, 5 25.8 84.9")

The other tiles: Site content (headings, FAQs, legal text), Fee defaults, Deposit tiers, Kilometre choices, Vehicle classes, Vehicle class rules, Airports and delivery, Protection Plan prices, Card coverage, Reviews, Quo contacts (everyone with a phone number as a contact in Quo: see Texts and calls), Text alerts, Partners (each partner company''s CRM link: see Partners, company cars and rentals added by hand), Email aliases and reply-to, Staff and roles, Promo codes and Quick replies.

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

> Good to know: Each box is filled only when the booking has the value: the renter and their licence, the additional drivers, the car (plate, make and model, the fleet number as vehicle number), the pickup as time and date out, the due-back date and time, the kilometres allowed, the rate rows (days, weeks or months @ the rate = the amount; a rental counted by the day, such as 31 days at the monthly rate, shows its daily rate rounded to the cent, and box 14 says how the charge was made), the underage fee, the Protection Plan as CDW, winter tires, the subtotal, HST (13% of the subtotal), total and deposit, the deposit received and the day it was taken (before pickup, the amount due at pickup), and for a booking billed to an insurer the insurer, claim number and adjuster. Other charges, such as delivery, are listed in box 14. The boxes filled at check-out and check-in stay blank until then. The fuel gauges are covered and the level of the check-out report (fuel out) and the check-in report (fuel in) is written in words, blank with no reading.

The renter''s signature goes in boxes 16, 17 and 20 of the signed copy, with the day they signed beside box 20 and a signature record page. Each later version (as picked up, as returned, corrected) carries the same signature and day. Both agreements are in the booking''s Drivers and documents tab, in the renter''s Documents, and the signed Blind Spot agreement is attached to the "Your signed rental agreement" email. Admin > Today lists the HST number, the upload and the check until they are done.

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
  '<p class="gd-p">Settings change the public site and the rules of the program at once. Program settings are kept as dated rows, so earlier values stay on record.</p><section class="gd-task" id="settings-the-settings-page" data-gd-task><h2 class="gd-h2">The Settings page</h2><div class="gd-stepblock gd-stepblock--below"><div class="gd-stepcol"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Site setup lists what is still missing on the public site, with <b class="gd-ui">Open site settings</b>.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Site settings: contact details, hours, tagline, logo, socials, Google place id and featured cars.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Program settings: every timing and policy value.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">Forms: Blind Spot&#39;s rental agreement for every booking, and the official ServiceOntario PDFs and what goes in each field.</div></li><li><span class="gd-n" aria-hidden="true">5</span><div class="gd-t">Insurers: insurance companies billed for bookings.</div></li></ol></div><figure class="gd-fig gd-fig--desk"><div class="gd-browser"><div class="gd-bar" aria-hidden="true"><i></i><i></i><i></i><span class="gd-addr">carmacars.ca/admin/settings</span></div><div class="gd-imgwrap" style="aspect-ratio:1440/900"><img src="/guides/img/admin-24-settings-desktop-89b31691.jpg" alt="" loading="lazy" decoding="async" width="1440" height="900"><span class="gd-pin" style="left:32.6%;top:33%" aria-hidden="true">1</span><span class="gd-pin" style="left:25.8%;top:40.2%" aria-hidden="true">2</span><span class="gd-pin" style="left:77.4%;top:40.2%" aria-hidden="true">3</span><span class="gd-pin" style="left:25.8%;top:73.2%" aria-hidden="true">4</span><span class="gd-pin" style="left:25.8%;top:84.9%" aria-hidden="true">5</span></div></div></figure></div><p class="gd-p">The other tiles: Site content (headings, FAQs, legal text), Fee defaults, Deposit tiers, Kilometre choices, Vehicle classes, Vehicle class rules, Airports and delivery, Protection Plan prices, Card coverage, Reviews, Quo contacts (everyone with a phone number as a contact in Quo: see Texts and calls), Text alerts, Partners (each partner company&#39;s CRM link: see Partners, company cars and rentals added by hand), Email aliases and reply-to, Staff and roles, Promo codes and Quick replies.</p></section><section class="gd-task" id="settings-program-settings" data-gd-task><h2 class="gd-h2">Program settings</h2><div class="gd-stepblock gd-stepblock--below"><div class="gd-stepcol"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Turnaround between trips: the time held between two trips. The cleaning block after a trip is this time.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Settings come in groups such as Company, Booking requests and offers, Owner debits and statement emails, Deposits, Delivery, Owners and fleet, and Tolls and damage. Open one to see its fields.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">First reply target for customer service and sales (minutes), under Booking requests and offers: 5 by default. New booking requests, enquiries, changes renters ask for and renter messages are due that many minutes after they come in; the scorecard and the staff screens use it. What renters are told (Reply wording, in Site settings) is separate.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">Staff commissions and prices typed by hand: the commission outside Sales (10%), the three Sales tiers and their days (10%, 15% from 50 days, 20% from 100 days, the month&#39;s target), the price floor a day (empty: none) and the discount from the rate sheet that flags a price (20%). The owner confirmed these values in October 2026. The remote Sales values follow: the three remote tiers (5%, 10%, 15%), the touches a month (400), the drop under it (one tier) and its floor (2.5%), the peak hours a week (20), the reply target (15 minutes) and the peak hours (noon to 6 pm, Thursday to Sunday).</div></li><li><span class="gd-n" aria-hidden="true">5</span><div class="gd-t">Staff agreement defaults by function, at the bottom: pay (a month, an hour or commission only), the rate, the schedule (full time, part time or flexible), days a week and hours a day for Customer service, Fleet, Finance and Sales, the values every assistant shares, and the field staff wage. Sales is commission only: no rate and a flexible schedule. Press <b class="gd-ui">Save the defaults</b>.</div></li><li><span class="gd-n" aria-hidden="true">6</span><div class="gd-t">Live visitors and live chat: recording visits, the signal thresholds, follow-up tasks, the chat and its assistant, and how long visits and chats are kept.</div></li><li><span class="gd-n" aria-hidden="true">7</span><div class="gd-t">Discount games: the same values as Settings, Discount games (the prize table and the games are easier to change there).</div></li><li><span class="gd-n" aria-hidden="true">8</span><div class="gd-t">Deposits: the toll and ticket window after the return (7 days: settling sooner suggests a hold-back), the longest hold-back (30 days after the return), how long before a card hold lapses it is collected (36 hours), and collecting what is owed after the deposit by itself (the card on file, then a pay link, then a Finance task). A deposit is never released by itself.</div></li><li><span class="gd-n" aria-hidden="true">9</span><div class="gd-t">Field jobs and handovers: field jobs made from each confirmed booking (on) and who gets them (the least busy field staff member, or nobody so Fleet assigns), how field staff may take a deposit at the check-out besides a card (e-Transfer and cash), and whether they may release a car whose tracker is not reporting, with a reason (on; you get an urgent task). Field pay: the first day of a pay period (every period is two weeks), the default hourly rate (CA$18.00), whether overtime is paid (off), after how many hours in a week (44) and at what share of the rate (150%), vacation pay added to each statement (off; Ontario 4%) and the longest shift (16 hours).</div></li><li><span class="gd-n" aria-hidden="true">10</span><div class="gd-t">Sign-in by phone: codes by text from the CarmaCars number (on), US numbers (off until the Quo number is registered for US texting, A2P 10DLC), codes per number and per connection an hour, and whether a verified phone confirms an account like a confirmed email. Accepting an offer, signing and paying need a confirmed account; an account made by phone gives its email on the pay page before its first payment.</div></li><li><span class="gd-n" aria-hidden="true">11</span><div class="gd-t">Calendar sync, Turo by email, Booking recovery emails and Site check: how often calendar links are read, the Turo inbound address and who may forward to it, the reminder delays and sending hours, and the site check with the address its alerts go to (rent@carmacars.ca), the minutes before an email, the daily limit and the quiet hours.</div></li><li><span class="gd-n" aria-hidden="true">12</span><div class="gd-t">Change a value and press <b class="gd-ui">Save</b>. It is saved as a new row from today; the rows before stay as they were.</div></li></ol></div><figure class="gd-fig gd-fig--desk"><div class="gd-browser"><div class="gd-bar" aria-hidden="true"><i></i><i></i><i></i><span class="gd-addr">carmacars.ca/admin/settings/program</span></div><div class="gd-imgwrap" style="aspect-ratio:1440/1000"><img src="/guides/img/admin-25-program-settings-desktop-d16b066c.jpg" alt="" loading="lazy" decoding="async" width="1440" height="1000"><span class="gd-pin" style="left:25.8%;top:22%" aria-hidden="true">1</span><span class="gd-pin" style="left:27.8%;top:49%" aria-hidden="true">2</span></div></div></figure></div></section><section class="gd-task" id="settings-vehicle-class-rules" data-gd-task><h2 class="gd-h2">Vehicle class rules</h2><p class="gd-p">Open <b class="gd-ui">Settings</b>, then <b class="gd-ui">Vehicle class rules</b>. How a new car&#39;s class is decided from its VIN: the first rule that matches wins.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">The table lists each rule: its rank, what the car must be (a make, and patterns for the model, the trim and the body), the class it gets, the class once the car is old enough, a note and whether it is on. The lowest rank that matches is used; a car that matches no rule is Standard.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Press <b class="gd-ui">Add a rule</b> or <b class="gd-ui">Change</b>: a rank, at least one condition, the class, optionally the years old after which an older class applies, and a note (it is shown as the reason for the class). A pattern is not case sensitive: ^911 matches models that start with 911. A rule with no condition, a pattern that does not compile and an older class equal to the class are refused.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t"><b class="gd-ui">Try a car</b> gives the class the rules decide for a year, make, model, trim and body, and why.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t"><b class="gd-ui">Delete</b> removes a rule; switch it off instead to keep it. Every add, change and delete is in the audit log, with before and after.</div></li></ol></div><aside class="gd-box"><span class="gd-lbl">Tip</span><div>A rule changes the cars entered from then on. A car already listed keeps its class until you change it on the car.</div></aside></section><section class="gd-task" id="settings-official-serviceontario-forms" data-gd-task><h2 class="gd-h2">Official ServiceOntario forms</h2><p class="gd-p">The five official forms are loaded with a mapping to the owner, car, company and lender details. Each is the form exactly as ServiceOntario publishes it: only its empty text boxes are filled. Its checkboxes, drop-downs and signatures are done by hand at the counter, in ink. Until you check a form, owners get a data sheet with the values.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Open <b class="gd-ui">Settings</b> &gt; <b class="gd-ui">Forms</b>. Each form shows &quot;Mapping to check&quot; (a draft is ready) or &quot;Official PDF in use&quot;. Its notes say what the form is for and which boxes are left blank on purpose.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Press <b class="gd-ui">Download a filled preview</b> for one car and check each value against the form.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Change a field if needed: What goes in it (or &quot;Signed here by hand, in ink&quot;), a Format (for example YYYY/MM/DD) and Only when. Press Save the mapping.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">Press <b class="gd-ui">Checked: use for owners</b>. Every owner&#39;s form of that kind is filled again, except ones already signed or filed. Owners download it, print it and sign it in ink; record it with <b class="gd-ui">Record paper signature</b>. Each form not checked yet is also a line on To do with the same button and Preview it.</div></li><li><span class="gd-n" aria-hidden="true">5</span><div class="gd-t">A new version from ServiceOntario? Press <b class="gd-ui">Upload the official fillable PDF</b>: the fields of the same name keep their mapping.</div></li></ol></div><aside class="gd-box"><span class="gd-lbl">Good to know</span><div>SR-LV-006 (registration), SR-LV-012 (two registrants), ON00453 (a company&#39;s RIN), 013-1155 and 013-0169 (the tax-exempt transfer into an owner&#39;s corporation). 013-1155 is sworn before a commissioner, so it is printed and signed in person. ON00453 is an Adobe form: it opens in Adobe Acrobat Reader. Each form&#39;s notes list what to tick or choose at the counter. A car gets only the forms its onboarding method needs: no form for a Transfer of a car owned outright or financed (the sign-back on the permit), 013-1155 and 013-0169 only for a Lease through a new Owner Corporation.</div></aside></section><section class="gd-task" id="settings-blind-spot-rental-agreement" data-gd-task><h2 class="gd-h2">Blind Spot rental agreement</h2><p class="gd-p">We rent under Blind Spot Car Rental&#39;s insurance, so every booking has two agreements: CarmaCars&#39; rental agreement and Blind Spot&#39;s own. Blind Spot&#39;s is filled in from the booking, the renter and the car, and the renter signs both with one signature. Its PDF is stored privately, never on the website.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Open <b class="gd-ui">Settings</b> &gt; <b class="gd-ui">Forms</b>. The Blind Spot Car Rental agreement card is first. Press <b class="gd-ui">Upload Blind Spot&#39;s PDF</b> and choose Blind Spot&#39;s blank form (2 pages, A4).</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Press <b class="gd-ui">Download the filled sample</b>: a made-up booking on the form. <b class="gd-ui">Sample billed to an insurer</b> also fills the claim number, the adjuster and the insurance company. Check every box.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">On the form the old address (top left and twice in box 15) is replaced by the mailing address of Site settings, box 1 by CarmaCars&#39; HST number (Program settings, Company HST number; blank until it is entered), and box 21 has the representative&#39;s signature instead of Sam&#39;s.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">Press <b class="gd-ui">Checked: use for bookings</b>. From then on each booking gets it when its rental agreement is made; a renter whose agreement is already open gets it the next time they open the signing page.</div></li><li><span class="gd-n" aria-hidden="true">5</span><div class="gd-t">Box 21: Ahmad is written in a script hand, as Blind Spot asked. To use a real signature instead, upload a PNG under Authorized company representative; Remove the image goes back to the written name. Full name is for the signature record page.</div></li><li><span class="gd-n" aria-hidden="true">6</span><div class="gd-t">A new version of Blind Spot&#39;s form? Upload it the same way: it waits for <b class="gd-ui">Checked: use for bookings</b>, and bookings keep the version in use until then.</div></li></ol></div><aside class="gd-box"><span class="gd-lbl">Good to know</span><div>Each box is filled only when the booking has the value: the renter and their licence, the additional drivers, the car (plate, make and model, the fleet number as vehicle number), the pickup as time and date out, the due-back date and time, the kilometres allowed, the rate rows (days, weeks or months @ the rate = the amount; a rental counted by the day, such as 31 days at the monthly rate, shows its daily rate rounded to the cent, and box 14 says how the charge was made), the underage fee, the Protection Plan as CDW, winter tires, the subtotal, HST (13% of the subtotal), total and deposit, the deposit received and the day it was taken (before pickup, the amount due at pickup), and for a booking billed to an insurer the insurer, claim number and adjuster. Other charges, such as delivery, are listed in box 14. The boxes filled at check-out and check-in stay blank until then. The fuel gauges are covered and the level of the check-out report (fuel out) and the check-in report (fuel in) is written in words, blank with no reading.</div></aside><p class="gd-p">The renter&#39;s signature goes in boxes 16, 17 and 20 of the signed copy, with the day they signed beside box 20 and a signature record page. Each later version (as picked up, as returned, corrected) carries the same signature and day. Both agreements are in the booking&#39;s Drivers and documents tab, in the renter&#39;s Documents, and the signed Blind Spot agreement is attached to the &quot;Your signed rental agreement&quot; email. Admin &gt; Today lists the HST number, the upload and the check until they are done.</p></section><section class="gd-task" id="settings-agreements-to-sign-investors-and-staff" data-gd-task><h2 class="gd-h2">Agreements to sign: investors and staff</h2><p class="gd-p">Investment agreements and staff agreements are made from the person&#39;s record and signed in their own portal, or on paper.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Investor: open <b class="gd-ui">People</b> &gt; <b class="gd-ui">Investors</b> and the investor. Under Investment agreement, press <b class="gd-ui">Send the agreement to sign</b>. Check the values it is filled with (amount, yearly percentage, dates, exemption) and press <b class="gd-ui">Send to sign</b>.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Once the investor signs, the agreement shows <b class="gd-ui">Awaiting countersignature</b> on the investor&#39;s page and on To do. It is not countersigned automatically: check it and press <b class="gd-ui">Countersign</b>. CarmaCars is bound once it has countersigned and the funds clear.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Staff: open <b class="gd-ui">People</b> &gt; <b class="gd-ui">Staff</b>. Under Staff agreements, press <b class="gd-ui">Send the agreement to sign</b> beside the person. Pay, schedule, hours and the other values start from the staff profile and the defaults of their function in Program settings; change any before sending. For Sales the Pay is Commission only: the agreement then has no rate, schedule or hours, and pays the commission of section 3.4.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">A field staff member&#39;s agreement prints the home address they entered themselves. Staff enter their home address at their first sign-in, before they sign, or in their profile.</div></li><li><span class="gd-n" aria-hidden="true">5</span><div class="gd-t">They get a notice, check the key values and sign in their portal in a few taps (their name is the signature, or they draw it). The signed copy is filed with their documents.</div></li><li><span class="gd-n" aria-hidden="true">6</span><div class="gd-t">Your own PDF instead? <b class="gd-ui">Send a PDF to sign</b> still works.</div></li><li><span class="gd-n" aria-hidden="true">7</span><div class="gd-t">Signed on paper instead? Press <b class="gd-ui">Record paper signature</b> in the same place and upload the scan.</div></li><li><span class="gd-n" aria-hidden="true">8</span><div class="gd-t">Sent by mistake? Press <b class="gd-ui">Withdraw</b> and give the reason.</div></li></ol></div></section><section class="gd-task" id="settings-the-user-guides" data-gd-task><h2 class="gd-h2">The user guides</h2><p class="gd-p"><b class="gd-ui">Settings</b> &gt; <b class="gd-ui">Guides</b>. The guide of each portal, as people read it under Guide.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Each guide shows its version, when it was published and whether there are unpublished changes.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Open a guide and press a section. Change its text and press <b class="gd-ui">Show the preview</b> to see it as people will. Press <b class="gd-ui">Save the draft</b>; each save is kept in the section&#39;s history.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Move a section with the arrows, hide it, or press <b class="gd-ui">Add a chapter</b>. Upload a screenshot under Screenshots and paste the line it gives you.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">Press <b class="gd-ui">Publish version</b> (the next number). The portals show the new version at once.</div></li><li><span class="gd-n" aria-hidden="true">5</span><div class="gd-t">The stored PDF is printed again by the guides-pdf workflow. Until then the guide says the web guide has newer edits.</div></li></ol></div></section><section class="gd-task" id="settings-the-guides-keep-up-by-themselves" data-gd-task><h2 class="gd-h2">The guides keep up by themselves</h2><p class="gd-p">After every update of the site that changes the portals, the guides are checked without anyone asking.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Every screenshot is taken again on the new version of the site. One whose screen changed replaces the old one in the guide.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">The text of each section whose screen changed, or that names a button the portals no longer show, is rewritten from the portal&#39;s own labels and menu, checked, and published. The PDFs of those guides are printed again.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Such a section says <b class="gd-ui">Changed automatically on</b> and the date, in the list of guides and in the guide&#39;s editor. Not right? Open the section and press <b class="gd-ui">Revert</b>: the text it replaced comes back, published at once.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">This includes sections you edited: the newest automatic text is published, and every earlier version stays in the section&#39;s history. There is nothing to review.</div></li><li><span class="gd-n" aria-hidden="true">5</span><div class="gd-t">A rewrite that does not pass the checks is asked again, more strictly. If it still does not pass, the screenshots and button names are updated, the rest of the text stays as it was, and the next run tries again.</div></li></ol></div><aside class="gd-box"><span class="gd-lbl">Tip</span><div>The card &quot;The guides keep up by themselves&quot; at the top of Guides lists the last runs: when, how many screenshots were replaced, how many sections were rewritten, and how many PDFs were printed.</div></aside></section><section class="gd-task" id="settings-insurers-and-the-other-lists" data-gd-task><h2 class="gd-h2">Insurers and the other lists</h2><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Open Insurers. Each insurer on file opens to edit its billing contact, email, phone, address and notes. Its rates by car class are in <b class="gd-ui">Money</b> &gt; <b class="gd-ui">Insurer rates</b>.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">To add one, fill in the Add form (Name, Billing contact, Billing email and the rest) and press <b class="gd-ui">Add</b>.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Deposit tiers, Kilometre choices, Vehicle classes, Airports, Promo codes and Quick replies work the same way.</div></li></ol></div></section><section class="gd-task" id="settings-promo-codes-end-dates-and-reminders" data-gd-task><h2 class="gd-h2">Promo codes: end dates and reminders</h2><p class="gd-p"><b class="gd-ui">Settings</b> &gt; <b class="gd-ui">All settings</b>, <b class="gd-ui">Promo codes</b>.</p><ul class="gd-ul"><li>Every code made for a person has an end date: a game prize 7 days, a come-back offer 30, a Live visitors code 3 and a code made for one renter 30 unless you set another. The first card of Promo codes holds the 30 days and the two reminders.</li><li>A code for everyone may have no end date: empty Valid until. The Add form starts with an end date 30 days ahead.</li><li>A code that ended is refused wherever it is typed (the request form, an offer, Add a rental, a booking edit) with &quot;This code has expired&quot;.</li><li>A person who has not used a code is reminded 3 days before its last day and the day before, by email and by text as they chose, never once they used it, unsubscribed or the code ended, and never twice. A game code reminder always goes; a reminder of any other code needs their consent to offers.</li><li>The list shows each code&#39;s end date and the reminders sent. The card Codes sent to people lists game prizes, come-back offers and Live visitors codes the same way.</li></ul></section><section class="gd-task" id="settings-card-coverage-which-credit-cards-include-rental-car-coverage" data-gd-task><h2 class="gd-h2">Card coverage: which credit cards include rental car coverage</h2><p class="gd-p"><b class="gd-ui">Settings</b> &gt; <b class="gd-ui">Card coverage</b> is the list renters see at <span class="gd-url">carmacars.ca/credit-card-rental-coverage</span> and staff see under Card coverage in their portal. It starts filled in with 48 Canadian and US cards, each checked on October 23, 2026.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">The table shows each card: who pays first (Primary, Secondary, or not stated), the car value limit (MSRP), the longest rental, whether the numbers were read in the issuer&#39;s own document, and when it was last checked.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Open a card under Change a card, open its official guide, correct what changed and press <b class="gd-ui">Save</b>. Changing the facts without a date marks the card checked today; type a Last checked date to record another day.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">A card whose numbers come from a published summary has Read in the issuer&#39;s own document unticked and the summary&#39;s link under Where the numbers came from. The page shows it as Unverified. Tick it once you have read the issuer&#39;s guide.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">Add a card with the Add form; untick Shown to hide one. Changes reach the public page at once.</div></li></ol></div><aside class="gd-box"><span class="gd-lbl">Tip</span><div>A card not checked for 6 months shows on Today until it is checked again. The page tells renters to confirm with their card issuer and says CarmaCars decides no claims: keep the list to facts from the issuer&#39;s guide.</div></aside></section><section class="gd-task" id="settings-reviews-review-requests-and-google" data-gd-task><h2 class="gd-h2">Reviews: review requests and Google</h2><p class="gd-p"><b class="gd-ui">Settings</b> &gt; <b class="gd-ui">Reviews</b>: when review requests go, the Google review link and the Google Business Profile connection. Review requests are on from the start.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">When review requests go: the check-in (on or off, the shortest rental, hours after the pickup), the request (minutes after the check-in), the reminder (hours) and the final follow-up (days), the sending hours (9 am to 9 pm), and the hold while charges are open.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">The Google review link: the Google place id (Site settings) makes it, or paste the Business Profile&#39;s own review link.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Google Business Profile: press <b class="gd-ui">Connect Google</b> and sign in with rent@carmacars.ca, then allow access. Reviews are read every 6 hours and matched to renters by name within 30 days after their return.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">A clear match stops that renter&#39;s reminders at once. A possible match waits in Reviews: press <b class="gd-ui">Confirm</b>, <b class="gd-ui">Not this renter</b> or <b class="gd-ui">Match to a booking</b>.</div></li></ol></div><aside class="gd-box"><span class="gd-lbl">Tip</span><div>Until Google approves the Business Profile API for the project, the status says so and nothing else changes: renters still get the review link, and &quot;I already left a review&quot;, Mark reviewed and on-site reviews still stop the messages.</div></aside></section>');
select app.guide_release_section('admin', 'usage-and-paid-usage', 'chapter', 'assistant', 'The plans CarmaCars runs on include a free allowance: AI, the website, image transformations, emails, the database and storage. When an allowance runs out, AI and photo features pause with a short message until it resets. Workers AI never runs into paid usage; for photos you are asked before anything is paid.

## The alerts

At 80% of an allowance you get one quiet card on **To do** and one email to the alert address. When it is used up, a second card and email.

1. Workers AI used up shows "Stopped for today, never paid": it starts again at midnight, Toronto time. There is nothing to allow.
2. A used-up image allowance shows "Included ... used up for this month: Allow paid usage". Press **Allow paid usage** to see what continuing costs at the current rates.
3. Choose until the end of today or this month, type the most it may cost (for example $1), and press the Allow button. Or press Keep paused.
4. Nobody answering keeps it paused: nothing is charged. Live chat goes to a person, AI copy waits with the template text, Turo emails are read by the rules, photos keep their original background, the assistant rests.
5. The website and the portals are never paused (that would stop bookings): their card shows the estimated cost, usually cents.

## Settings > Usage

Open **Settings**, then **Usage**: every service, used against included, when it resets, paid usage and the last 30 days.

1. Workers AI by feature, at the top: the neurons each feature used today and in the last 7 days (the staff assistant, visitor chat, the phone line, search copy, listing copy, guide upkeep, Turo emails, the readers), and what each share has left now. Use Cloudflare counted beyond the app''s own record shows as Unmetered.
2. The day is shared in three: 70% is kept for the staff assistant; visitor chat, the phone line and the readers share the rest; background writing (search copy, listing copy, guide rewrites, Turo emails) gets 10%, and from 9 pm what is left of the day, less a small cushion for the assistant.
3. Press **Change the shares** to change the assistant''s reserve, the background share, the release hour or the cushion.
4. Press **Change the allowance** after a plan change (for example a Supabase or Resend upgrade).
5. Supabase egress is not readable automatically: press **Enter a figure** with the number from the Supabase dashboard.
6. Emails cannot be paid on the free plan: when the daily or monthly count is used, booking, payment and sign-in emails still go first and the others wait. A banner on To do says so.
', 'Usage and paid usage', 'Included allowances, the 80% and used-up alerts, Workers AI by feature (never paid), allowing paid usage for photos, what pauses and what never does.',
  'The plans CarmaCars runs on include a free allowance: AI, the website, image transformations, emails, the database and storage. When an allowance runs out, AI and photo features pause with a short message until it resets. Workers AI never runs into paid usage; for photos you are asked before anything is paid.

## The alerts

At 80% of an allowance you get one quiet card on **To do** and one email to the alert address. When it is used up, a second card and email.

1. Workers AI used up shows "Stopped for today, never paid": it starts again at midnight, Toronto time. There is nothing to allow.
2. A used-up image allowance shows "Included ... used up for this month: Allow paid usage". Press **Allow paid usage** to see what continuing costs at the current rates.
3. Choose until the end of today or this month, type the most it may cost (for example $1), and press the Allow button. Or press Keep paused.
4. Nobody answering keeps it paused: nothing is charged. Live chat goes to a person, AI copy waits with the template text, Turo emails are read by the rules, photos keep their original background, the assistant rests.
5. The website and the portals are never paused (that would stop bookings): their card shows the estimated cost, usually cents.

## Settings > Usage

Open **Settings**, then **Usage**: every service, used against included, when it resets, paid usage and the last 30 days.

1. Workers AI by feature, at the top: the neurons each feature used today and in the last 7 days (the staff assistant, visitor chat, the phone line, search copy, listing copy, guide upkeep, Turo emails, the readers), and what each share has left now. Use Cloudflare counted beyond the app''s own record shows as Unmetered.
2. The day is shared in three: 70% is kept for the staff assistant; visitor chat, the phone line and the readers share the rest; background writing (search copy, listing copy, guide rewrites, Turo emails) gets 10%, and from 9 pm what is left of the day, less a small cushion for the assistant.
3. Press **Change the shares** to change the assistant''s reserve, the background share, the release hour or the cushion.
4. Press **Change the allowance** after a plan change (for example a Resend upgrade, or a larger disk on our server).
5. Database size and file storage are our own server''s: near the allowance, clean up or move to a larger server disk. Nothing is billed by use.
6. Emails cannot be paid on the free plan: when the daily or monthly count is used, booking, payment and sign-in emails still go first and the others wait. A banner on To do says so.
',
  '<p class="gd-p">The plans CarmaCars runs on include a free allowance: AI, the website, image transformations, emails, the database and storage. When an allowance runs out, AI and photo features pause with a short message until it resets. Workers AI never runs into paid usage; for photos you are asked before anything is paid.</p><section class="gd-task" id="usage-and-paid-usage-the-alerts" data-gd-task><h2 class="gd-h2">The alerts</h2><p class="gd-p">At 80% of an allowance you get one quiet card on <b class="gd-ui">To do</b> and one email to the alert address. When it is used up, a second card and email.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Workers AI used up shows &quot;Stopped for today, never paid&quot;: it starts again at midnight, Toronto time. There is nothing to allow.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">A used-up image allowance shows &quot;Included ... used up for this month: Allow paid usage&quot;. Press <b class="gd-ui">Allow paid usage</b> to see what continuing costs at the current rates.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Choose until the end of today or this month, type the most it may cost (for example $1), and press the Allow button. Or press Keep paused.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">Nobody answering keeps it paused: nothing is charged. Live chat goes to a person, AI copy waits with the template text, Turo emails are read by the rules, photos keep their original background, the assistant rests.</div></li><li><span class="gd-n" aria-hidden="true">5</span><div class="gd-t">The website and the portals are never paused (that would stop bookings): their card shows the estimated cost, usually cents.</div></li></ol></div></section><section class="gd-task" id="usage-and-paid-usage-settings-usage" data-gd-task><h2 class="gd-h2">Settings &gt; Usage</h2><p class="gd-p">Open <b class="gd-ui">Settings</b>, then <b class="gd-ui">Usage</b>: every service, used against included, when it resets, paid usage and the last 30 days.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Workers AI by feature, at the top: the neurons each feature used today and in the last 7 days (the staff assistant, visitor chat, the phone line, search copy, listing copy, guide upkeep, Turo emails, the readers), and what each share has left now. Use Cloudflare counted beyond the app&#39;s own record shows as Unmetered.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">The day is shared in three: 70% is kept for the staff assistant; visitor chat, the phone line and the readers share the rest; background writing (search copy, listing copy, guide rewrites, Turo emails) gets 10%, and from 9 pm what is left of the day, less a small cushion for the assistant.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Press <b class="gd-ui">Change the shares</b> to change the assistant&#39;s reserve, the background share, the release hour or the cushion.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">Press <b class="gd-ui">Change the allowance</b> after a plan change (for example a Resend upgrade, or a larger disk on our server).</div></li><li><span class="gd-n" aria-hidden="true">5</span><div class="gd-t">Database size and file storage are our own server&#39;s: near the allowance, clean up or move to a larger server disk. Nothing is billed by use.</div></li><li><span class="gd-n" aria-hidden="true">6</span><div class="gd-t">Emails cannot be paid on the free plan: when the daily or monthly count is used, booking, payment and sign-in emails still go first and the others wait. A banner on To do says so.</div></li></ol></div></section>');
select app.guide_release_section('va', 'start-here', 'start', null, '### Who this guide is for

CarmaCars assistants (VAs) in Customer service, Finance, Fleet and Sales. Read chapter 1, then the chapter for your function. If you cover more than one, read each of them.

### What you need

- The invitation email from CarmaCars (the link works for 24 hours)
- A computer for your shift. The portal also works on a phone
- An authenticator app on your phone, if your Admin turns on two-step sign-in

## Your first sign-in

1. Open the invitation email and press its link within 24 hours. Choose a password of 8 characters or more and press **Save the new password**.
2. You land in your portal, on **To do**, working as your main function.
3. At the top of the page, fill in your Home address and Postal code and press **Save my home address**. You need it before you add a rental or earn a commission. Change it later under **Profile**, at the top of the menu.
4. Next time, sign in at `carmacars.ca/sign-in` with your Email and Password, then **Sign in**.
5. Link expired? Press **Send me a new link** on the page it opens, or ask an Admin for a password link.
6. Sign in with your phone: on **Profile**, press **Add and verify my phone number** and enter the 6-digit code we text you. Then press **Use my phone number instead** on the sign-in page. Two-step sign-in still asks for your authenticator code.

![](/guides/img/public-09-sign-in-phone-1f766061.jpg "phone; size: 390 645; pins: 3 95.4 78.4")

> Good to know: Recommended: open your profile and press **Set up two-step sign-in**. Scan the code with your authenticator app, type the 6 digits and press **Continue**. After that every sign-in asks for a code.
', 'Start here', 'Who this is for and your first sign-in.',
  '### Who this guide is for

CarmaCars staff in Customer service, Finance, Fleet and Sales, in the office, remote or in person. Everyone works in one staff portal: its menu shows a group for each function you hold. Read chapter 1, then the chapter for each of your functions. If you also do field work (handovers, returns, moving cars), read the Field Guide too: your jobs are under **Field work** in the same menu.

### What you need

- The invitation email from CarmaCars (the link works for 24 hours)
- A computer for your shift. The portal also works on a phone
- An authenticator app on your phone, if your Admin turns on two-step sign-in

## Your first sign-in

1. Open the invitation email and press its link within 24 hours. Choose a password of 8 characters or more and press **Save the new password**.
2. You land in your portal, on **To do**, working as your main function.
3. At the top of the page, fill in your Home address and Postal code and press **Save my home address**. You need it before you add a rental or earn a commission. Change it later under **Profile**, at the top of the menu.
4. Next time, sign in at `carmacars.ca/sign-in` with your Email and Password, then **Sign in**.
5. Link expired? Press **Send me a new link** on the page it opens, or ask an Admin for a password link.
6. Sign in with your phone: on **Profile**, press **Add and verify my phone number** and enter the 6-digit code we text you. Then press **Use my phone number instead** on the sign-in page. Two-step sign-in still asks for your authenticator code.

![](/guides/img/public-09-sign-in-phone-1f766061.jpg "phone; size: 390 645; pins: 3 95.4 78.4")

> Good to know: Recommended: open your profile and press **Set up two-step sign-in**. Scan the code with your authenticator app, type the 6 digits and press **Continue**. After that every sign-in asks for a code.
',
  '<h3 class="gd-h3">Who this guide is for</h3><p class="gd-p">CarmaCars staff in Customer service, Finance, Fleet and Sales, in the office, remote or in person. Everyone works in one staff portal: its menu shows a group for each function you hold. Read chapter 1, then the chapter for each of your functions. If you also do field work (handovers, returns, moving cars), read the Field Guide too: your jobs are under <b class="gd-ui">Field work</b> in the same menu.</p><h3 class="gd-h3">What you need</h3><ul class="gd-ul"><li>The invitation email from CarmaCars (the link works for 24 hours)</li><li>A computer for your shift. The portal also works on a phone</li><li>An authenticator app on your phone, if your Admin turns on two-step sign-in</li></ul><section class="gd-task" id="start-here-your-first-sign-in" data-gd-task><h2 class="gd-h2">Your first sign-in</h2><div class="gd-stepblock gd-stepblock--side"><div class="gd-stepcol"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Open the invitation email and press its link within 24 hours. Choose a password of 8 characters or more and press <b class="gd-ui">Save the new password</b>.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">You land in your portal, on <b class="gd-ui">To do</b>, working as your main function.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">At the top of the page, fill in your Home address and Postal code and press <b class="gd-ui">Save my home address</b>. You need it before you add a rental or earn a commission. Change it later under <b class="gd-ui">Profile</b>, at the top of the menu.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">Next time, sign in at <span class="gd-url">carmacars.ca/sign-in</span> with your Email and Password, then <b class="gd-ui">Sign in</b>.</div></li><li><span class="gd-n" aria-hidden="true">5</span><div class="gd-t">Link expired? Press <b class="gd-ui">Send me a new link</b> on the page it opens, or ask an Admin for a password link.</div></li><li><span class="gd-n" aria-hidden="true">6</span><div class="gd-t">Sign in with your phone: on <b class="gd-ui">Profile</b>, press <b class="gd-ui">Add and verify my phone number</b> and enter the 6-digit code we text you. Then press <b class="gd-ui">Use my phone number instead</b> on the sign-in page. Two-step sign-in still asks for your authenticator code.</div></li></ol></div><figure class="gd-fig gd-fig--phone"><div class="gd-phone"><div class="gd-imgwrap" style="aspect-ratio:390/645"><img src="/guides/img/public-09-sign-in-phone-1f766061.jpg" alt="" loading="lazy" decoding="async" width="390" height="645"><span class="gd-pin" style="left:95.4%;top:78.4%" aria-hidden="true">3</span></div></div></figure></div><aside class="gd-box"><span class="gd-lbl">Good to know</span><div>Recommended: open your profile and press <b class="gd-ui">Set up two-step sign-in</b>. Scan the code with your authenticator app, type the 6 digits and press <b class="gd-ui">Continue</b>. After that every sign-in asks for a code.</div></aside></section>');
select app.guide_release_section('va', 'customer-service', 'chapter', 'your-workday', 'You answer requests with offers, quote callers, reply to renters, look renters up, and review owner forms. You are often the renter''s first person.

Your rail: Queue, Today, Requests, New quote, Renter messages, Find a renter, Calendar, Listings, Similar cars, Owners and enquiries, Owner forms and Scorecard.

## Answer a request

1. Open **Requests**. Filter by New, Waiting on the renter, Pushed back, Offer out or Offer expired.
2. Waiting shows how long the renter has waited. Open the booking number.

![](/guides/img/va-cs-03-requests-desktop-b3c66d25.jpg "desktop; size: 1440 640; address: carmacars.ca/va/requests; pins: 1 27.1 17.5, 2 52.8 32.8")

3. On the Review tab, check the request: the car is free, the renter, the places.
4. Press **Adjust the booking** to change the car, dates, places, price or extras, then **Save changes**.
5. Add a message and press **Send the offer**. Within your limit you can also use **Approve (within my limit)** or **Approve and send the pay link**.
6. Can''t do it? **Decline** with Reason and any alternative. Need to know more? **Ask the renter**.

![](/guides/img/va-cs-04-booking-review-desktop-52c68a73.jpg "desktop; size: 1440 1000; address: carmacars.ca/va/bookings/CC-10069?tab=review; pins: 3 69.4 24.0, 4 95.8 98.0")

> Tip: Reply within 5 minutes: send the offer, or ask the renter what you need. That is the "First reply in opening hours" measure on your scorecard. Requests waiting longer show in red.

Opening a request takes it for you: the others see "Being answered by" your name and cannot answer it until you send, decline or leave (20 minutes, renewed while you work). One someone else holds shows who, with the buttons off; it opens to you when their claim runs out, or ask an Admin to take it over. Sales: a request from the website shows "Opens to you at" a time for its first 15 minutes, and a To do task says when it opens; after that whoever opens it first answers it, customer service included.

## An enquiry on an example car

Some cars on the site are marked "Example car": samples that show the kind of cars we rent. A request on one is an enquiry, never a booking.

1. The task Suggest a similar real car comes to To do with the enquiry number (EQ-1001 and up), the car asked for, the dates and the contact. When a real car was free for those dates, the task names it after **Free:** (the same make and model first, else the same class and body at a similar price), and the person was told we have a similar car and will confirm it within 2 hours.
2. Check the named car is still right for them (or find a real car of the same kind and price that is free for those dates), and make a **New quote** for it.
3. Call or email the person with the car and the price, then mark the task done.

> Tip: Reply within the first reply target, as for any request. Never offer the example car itself: it does not exist.

## A request from a vehicle page

Every make, model, year and trim page (carmacars.ca/cars/toyota/rav4/2023/xle, for example) has Request it, for the exact car the person wants.

1. The request arrives as an enquiry with the car named in the message ("About the car: 2023 Toyota RAV4 XLE") and an Enquiry task in To do.
2. If we have that car, or one close to it, free for their dates, make a **New quote** for it. If not, suggest the nearest car of the same kind and price.
3. Reply by email or phone, then mark the task done.

> Tip: The pages say only what the data says: EPA fuel use, the Canadian trims and our own cars. Never promise equipment the page does not list.

## A buyer lead from a /buy page

Every vehicle page has a for-sale twin (carmacars.ca/buy/toyota/rav4/2023/xle) with "Find me this car", and twins for financing, detailing and body shop work with their own request: a name, an email or phone, and when.

1. The lead is in **Owner leads** (customer service: **Owners and enquiries**), Buyer leads (kind buyer, finance, detailing or body shop), with the car and what they asked, and a To do line for Sales: A buyer asked us to find a car, Someone asked about financing or leasing a car, A detailing request, or A body shop request.
2. If one of our cars of that kind is for sale (an Admin flags it with its price), offer it. If not, offer to rent them the car for a week first, and say what we can find. We do not lend or lease: on a financing question, say so and offer the rental. For detailing or body shop work, give a time and a price, and always offer a rental while their car is in (an insurance replacement rental when it is a claim). For mechanical work (a "Mechanical work to arrange" task: an oil change, brakes, tires, a tow and the like), CarmaCars does not do the work: book it with a trusted shop or recommend one, never promise the shop''s price or time, and offer a rental while their car is in.
3. Press **Take it**, then **Update** as you go: contacted, qualified, converted or closed with the reason.

> Tip: We mostly rent cars. Never say a car is for sale unless an Admin flagged it; the page shows it with its price when one is.

## Send an offer to a caller

Open **Send an offer** (or **Send an offer** beside a car in Find a car). No request needed: one screen, and the renter has the link.

1. Find the customer by name, phone or email, or press **Add a new customer**: full legal name, mobile, email and date of birth. Already on file with that email or phone? Use them: never a second record.
2. Choose the car (by car code, plate or name; each says Free or Not free), the dates and the places.
3. The price: the rate sheet, a total or a rate per day, with the reason for a price you type. The deposit, discounts and fees are set by an Admin; customer service sets the Protection Plan price. Amounts I type, at the top of the price: Before tax, or After tax (HST included) to type what the renter pays, worked back to before tax for you. Or type the Total the renter pays (after tax): the rental charge is worked out from it.
4. How the rental and the deposit are paid (card online, e-Transfer, cash, platform payout, the insurer; deposit by card hold, cash or e-Transfer), who found this client, the message, how long it is open (48 hours at most) and Email, Text or both.
5. Check the offer as the renter will see it on the right, then press **Send the offer**.

> Tip: An offer that is out is changed in place: **Edit the offer**, change it, then **Save and send the update** or **Save without telling the renter**. No need to withdraw it first.

## New quote for a caller

1. Open **New quote**. Choose the Car, the Pickup and Return (at least 2 hours from now).
2. Choose how the lead came in, then the caller''s Full legal name, Email, Mobile and Date of birth.
3. Set the Licence class and Damage cover, and note places, extras and what they asked.
4. Press **Create the request**. It opens like any request; send the offer from there.

![](/guides/img/va-cs-05-new-quote-desktop-4e386b1c.jpg "desktop; size: 1220 1260; address: carmacars.ca/va/quotes/new; pins: 1 72.1 15.6, 2 72.1 41.7, 3 72.1 72.7, 4 63.9 85.5")

## Edit a booking, a fee or the renter

A booking that is confirmed, on trip or returned is edited directly; the renter''s details are corrected from the booking.

1. Overview, **Edit the booking**: the return (extend or shorten), the car, the rental charge, each fee, the kilometres and the note. Tick **Email the renter what changed**, or leave it off for a silent correction.
2. Money tab, Fees, **Change or add a fee**: a fee forgotten (the young driver fee shows its price for the dates) or a charge of its own.
3. What is open shows at once: **Email a pay link** or **Text a pay link** for exactly that amount, or record cash or an e-Transfer (**Record a payment**, For: the rental and fees).
4. **Edit renter**: a wrong email, phone, name, licence or address. A new email is their sign-in at once.
5. The same renter twice? Under the renter, Possible duplicates: **Merge into this record** moves everything of the other record here.

> Good to know: Each edit is recorded with your name, the time, the reason and the before and after.

## Renter messages and Find a renter

1. **Renter messages** lists the latest messages with their booking. Open the booking to reply, then press **Send**.
2. **Find a renter**: search by name, email, phone or booking number.
3. To open a renter''s private details, press **Open with a reason**. The reason is kept in the access log.

![](/guides/img/va-cs-06-messages-desktop-3441fa91.jpg "desktop; size: 1440 260; address: carmacars.ca/va/messages; pins: 1 32.6 48.5")

## Add a car for an owner

Open **Owners** > **Add a car for an owner** (fleet: under Cars). You enter everything for the owner; they never fill in the application.

1. The owner: find them by name, email or phone, or choose New owner and enter the name, email, phone and address.
2. The car: type the VIN. The car is looked up at once and shown in one line with the year, make, model, trim and details (Edit if something is wrong). No VIN at hand: add it by its plate and choose the year, make and model. Tap the colour and check the class. Upload the ownership permit, the insurance slip and the lender''s information if you have them. Photos are optional.
3. Terms and first invoice: what was agreed with the owner, to the cent. An Admin checks them before anything is sent.
4. Who sourced the owner: Entered for CarmaCars, or I sourced this owner. How the owner signs: by email, or on paper.
5. Press **Add the car and send to an Admin**. The application waits in the Admin''s Applications, marked Entered by staff with your name. When the Admin approves, the owner gets one email to review and sign.

## Owner forms (Forms C and D)

1. Open **Owner forms**. Each row is a scan an owner uploaded, with the witnesses and the status.
2. Press Open to read the scan. Check every page is there and signed, with each witness''s signature and name.
3. Press **Approve**, or **Send back** with What to fix (the owner reads this).

![](/guides/img/va-cs-08-owner-forms-desktop-eceaee0b.jpg "desktop; size: 1440 300; address: carmacars.ca/va/owner-forms; pins: 2 68.6 36.7, 3 76.7 36.7")

## A rental agreement signed on paper

1. Open the booking. Under Signed on paper, press **Record paper signature**.
2. Choose the Rental agreement, or the booking change the renter signed.
3. Check Signed by and Date signed, and upload the scan of every signed page.
4. Press **Record signature**. It counts as signed, and the renter is not asked to sign again.

## Signatures on the spot, or by link

A renter or an additional driver who has not signed yet.

1. On the booking, press **Sign now on this device**. Confirm the name and that you saw the original licence, then **Hand the device to** the signer.
2. Or press **Email the signing link** or **Text the signing link**: they sign on their own phone.
3. The licence comes first: the renter uploads it from the request, and the offer cannot be accepted without it.

## The booking''s rental agreements

The Rental agreements card keeps both agreements in step with the booking.

1. Any change after signing makes a new version by itself. A change to the dates, the price, the car, the drivers or the coverage waits for the renter''s signature: they get the link by email and text, and the card says "Agreement v3 waiting for signature".
2. **Resend the signing links**, or press the button with their first name beside it to have them sign on your device.
3. Fields still blank (a licence expiry, an insurer''s policy number) are listed: type them and press **Save the missing fields**. Check-out stops on a field a claim needs until it is filled or an Admin overrides.
4. Every signature: a code to the signer''s phone or email, the key terms initialled, three consents, a drawn signature.

## Check renter documents

The renter''s licence photos, selfie and proof of coverage, before the handover.

1. Open the task "identity documents or coverage proof to review", or open the booking: **Review** shows the documents of any booking being arranged or under way, with no task needed.
2. Every licence image, selfie and proof of coverage of the booking is on one screen, with what to check written once above them: the name and date of birth, class G2 or G and valid past the return, the selfie matches, the coverage is active to the return date.
3. One is wrong? Open **Reject this one** under it, type the reason the renter reads and press **Reject**.
4. Then press **Approve all**: everything still waiting is approved at once (the Protection Plan too). A document the system refuses is named with the reason; the rest are approved.

> Tip: Each opening is logged. An Admin can do the same from Admin > To do. Field staff review the licence images (not the coverage) of bookings on their own jobs in the next 7 days from their My jobs: the booking history says the role, field.

## Which credit cards include rental car coverage?

Renters ask this often. **Renters** > **Card coverage** (every function has it under Rentals or Bookings) is your quick reference: what to say, what to check, and the list.

1. Send the renter `carmacars.ca/credit-card-rental-coverage`: each card''s car value limit (MSRP), longest rental, key exclusions, its official guide and the day we last checked it.
2. Ask which car they want. Most Canadian cards stop at a car priced $65,000 or $85,000, and many luxury models are priced higher. Give them the car''s model year and trim so they can check.
3. Never tell a renter they are covered. Their card''s issuer decides that: ask them to call the number on the back of their card about this car and these dates. CarmaCars does not decide claims.
4. Over the limit, an excluded make, a debit card or a longer rental than the card allows: offer OPCF 27 on their own auto policy or the CarmaCars Protection Plan.

> Tip: A card marked Unverified came from a published summary, not the issuer''s guide. Something wrong or out of date in the list? Tell an Admin: they correct it in Settings > Card coverage.

## Review requests

Renters are asked for a review by email and text after each trip. **Renters** > **Review requests** shows the ones on hold and the Google reviews to match.

1. On hold: the booking has a charge that is not settled or waived yet (late return, kilometres, fuel, cleaning, smoking, damage, tolls) or an open incident. It leaves the list by itself once the charges are settled or waived.
2. The renter should be asked now anyway? Press **Send anyway**. Should never be asked? Press **Do not ask**.
3. Google reviews: a possible match to a renter shows "possible match". Press **Confirm** if it is them, **Not this renter** if not, or **Match to a booking** with the booking number.
4. On a booking, the card Review requests has **Ask for a review** (for example after a call that went well) and **Mark reviewed** when the renter says they already left one.

> Tip: Never offer anything for a review and never ask only happy renters: everyone gets the same message and the same Google link.

## A change to a confirmed booking

On a booking''s Changes tab you can propose new dates, times or another car, as an Admin does: set the change, write the reason, press **Preview the price**, then **Send to the renter**. The renter has 48 hours to accept and sign the amendment. You also send a new signing link to an additional driver from the booking screen.

## A late return

A booking past its return time shows the late return panel. Work it in order:

| Button | When |
| --- | --- |
| **Log a call** | Record each call to the renter and what they said. |
| **Send T13** | The first late notice email. |
| **Send T14 (final notice)** | The final notice. |
| **Request disable** | Ask an Admin to approve disabling the car. |
| **Open an incident** | When the car is not coming back as planned. |
', 'Customer service', 'Requests and offers, new quotes, renter messages, find a renter, owner forms, late returns.',
  'You answer requests with offers, quote callers, reply to renters, look renters up, and review owner forms. You are often the renter''s first person.

Your rail: Queue, Today, Requests, New quote, Renter messages, Find a renter, Calendar, Listings, Similar cars, Owners and enquiries, Owner forms and Scorecard.

## Answer a request

1. Open **Requests**. Filter by New, Waiting on the renter, Pushed back, Offer out or Offer expired.
2. Waiting shows how long the renter has waited. Open the booking number.

![](/guides/img/va-cs-03-requests-desktop-b3c66d25.jpg "desktop; size: 1440 640; address: carmacars.ca/va/requests; pins: 1 27.1 17.5, 2 52.8 32.8")

3. On the Review tab, check the request: the car is free, the renter, the places.
4. Press **Adjust the booking** to change the car, dates, places, price or extras, then **Save changes**.
5. Add a message and press **Send the offer**. Within your limit you can also use **Approve (within my limit)** or **Approve and send the pay link**.
6. Can''t do it? **Decline** with Reason and any alternative. Need to know more? **Ask the renter**.

![](/guides/img/va-cs-04-booking-review-desktop-52c68a73.jpg "desktop; size: 1440 1000; address: carmacars.ca/va/bookings/CC-10069?tab=review; pins: 3 69.4 24.0, 4 95.8 98.0")

> Tip: Reply within 5 minutes: send the offer, or ask the renter what you need. That is the "First reply in opening hours" measure on your scorecard. Requests waiting longer show in red.

Opening a request takes it for you: the others see "Being answered by" your name and cannot answer it until you send, decline or leave (20 minutes, renewed while you work). One someone else holds shows who, with the buttons off; it opens to you when their claim runs out, or ask an Admin to take it over. Sales: a request from the website shows "Opens to you at" a time for its first 15 minutes, and a To do task says when it opens; after that whoever opens it first answers it, customer service included.

## An enquiry on an example car

Some cars on the site are marked "Example car": samples that show the kind of cars we rent. A request on one is an enquiry, never a booking.

1. The task Suggest a similar real car comes to To do with the enquiry number (EQ-1001 and up), the car asked for, the dates and the contact. When a real car was free for those dates, the task names it after **Free:** (the same make and model first, else the same class and body at a similar price), and the person was told we have a similar car and will confirm it within 2 hours.
2. Check the named car is still right for them (or find a real car of the same kind and price that is free for those dates), and make a **New quote** for it.
3. Call or email the person with the car and the price, then mark the task done.

> Tip: Reply within the first reply target, as for any request. Never offer the example car itself: it does not exist.

## A request from a vehicle page

Every make, model, year and trim page (carmacars.ca/cars/toyota/rav4/2023/xle, for example) has Request it, for the exact car the person wants.

1. The request arrives as an enquiry with the car named in the message ("About the car: 2023 Toyota RAV4 XLE") and an Enquiry task in To do.
2. If we have that car, or one close to it, free for their dates, make a **New quote** for it. If not, suggest the nearest car of the same kind and price.
3. Reply by email or phone, then mark the task done.

> Tip: The pages say only what the data says: EPA fuel use, the Canadian trims and our own cars. Never promise equipment the page does not list.

## A buyer lead from a /buy page

Every vehicle page has a for-sale twin (carmacars.ca/buy/toyota/rav4/2023/xle) with "Find me this car", and twins for financing, detailing and body shop work with their own request: a name, an email or phone, and when.

1. The lead is in **Owner leads** (customer service: **Owners and enquiries**), Buyer leads (kind buyer, finance, detailing or body shop), with the car and what they asked, and a To do line for Sales: A buyer asked us to find a car, Someone asked about financing or leasing a car, A detailing request, or A body shop request.
2. If one of our cars of that kind is for sale (an Admin flags it with its price), offer it. If not, offer to rent them the car for a week first, and say what we can find. We do not lend or lease: on a financing question, say so and offer the rental. For detailing or body shop work, give a time and a price, and always offer a rental while their car is in (an insurance replacement rental when it is a claim). For mechanical work (a "Mechanical work to arrange" task: an oil change, brakes, tires, a tow and the like), CarmaCars does not do the work: book it with a trusted shop or recommend one, never promise the shop''s price or time, and offer a rental while their car is in.
3. Press **Take it**, then **Update** as you go: contacted, qualified, converted or closed with the reason.

> Tip: We mostly rent cars. Never say a car is for sale unless an Admin flagged it; the page shows it with its price when one is.

## Send an offer to a caller

Open **Send an offer** (or **Send an offer** beside a car in Find a car). No request needed: one screen, and the renter has the link.

1. Find the customer by name, phone or email, or press **Add a new customer**: full legal name, mobile, email and date of birth. Already on file with that email or phone? Use them: never a second record.
2. Choose the car (by car code, plate or name; each says Free or Not free), the dates and the places.
3. The price: the rate sheet, a total or a rate per day, with the reason for a price you type. The deposit, discounts and fees are set by an Admin; customer service sets the Protection Plan price. Amounts I type, at the top of the price: Before tax, or After tax (HST included) to type what the renter pays, worked back to before tax for you. Or type the Total the renter pays (after tax): the rental charge is worked out from it.
4. How the rental and the deposit are paid (card online, e-Transfer, cash, platform payout, the insurer; deposit by card hold, cash or e-Transfer), who found this client, the message, how long it is open (48 hours at most) and Email, Text or both.
5. Check the offer as the renter will see it on the right, then press **Send the offer**.

> Tip: An offer that is out is changed in place: **More actions** > **Edit the offer**, change it, then **Save and send the update** or **Save without telling the renter**. No need to withdraw it first.

## New quote for a caller

1. Open **New quote**. Choose the Car, the Pickup and Return (at least 2 hours from now).
2. Choose how the lead came in, then the caller''s Full legal name, Email, Mobile and Date of birth.
3. Set the Licence class and Damage cover, and note places, extras and what they asked.
4. Press **Create the request**. It opens like any request; send the offer from there.

![](/guides/img/va-cs-05-new-quote-desktop-4e386b1c.jpg "desktop; size: 1220 1260; address: carmacars.ca/va/quotes/new; pins: 1 72.1 15.6, 2 72.1 41.7, 3 72.1 72.7, 4 63.9 85.5")

## Edit a booking, a fee or the renter

A booking that is confirmed, on trip or returned is edited directly; the renter''s details are corrected from the booking.

1. Overview, **Edit the booking**: the return (extend or shorten), the car, the rental charge, each fee, the kilometres and the note. Tick **Email the renter what changed**, or leave it off for a silent correction.
2. Money tab, Fees, **Change or add a fee**: a fee forgotten (the young driver fee shows its price for the dates) or a charge of its own.
3. What is open shows at once: **Email a pay link** or **Text a pay link** for exactly that amount, or record cash or an e-Transfer (**Record a payment**, For: the rental and fees).
4. **Edit renter**: a wrong email, phone, name, licence or address. A new email is their sign-in at once.
5. The same renter twice? Under the renter, Possible duplicates: **Merge into this record** moves everything of the other record here.

> Good to know: Each edit is recorded with your name, the time, the reason and the before and after.

## Renter messages and Find a renter

1. **Renter messages** lists the latest messages with their booking. Open the booking to reply, then press **Send**.
2. **Find a renter**: search by name, email, phone or booking number.
3. To open a renter''s private details, press **Open with a reason**. The reason is kept in the access log.

![](/guides/img/va-cs-06-messages-desktop-3441fa91.jpg "desktop; size: 1440 260; address: carmacars.ca/va/messages; pins: 1 32.6 48.5")

## Add a car for an owner

Open **Owners** > **Add a car for an owner** (fleet: under Cars). You enter everything for the owner; they never fill in the application.

1. The owner: find them by name, email or phone, or choose New owner and enter the name, email, phone and address.
2. The car: type the VIN. The car is looked up at once and shown in one line with the year, make, model, trim and details (Edit if something is wrong). No VIN at hand: add it by its plate and choose the year, make and model. Tap the colour and check the class. Upload the ownership permit, the insurance slip and the lender''s information if you have them. Photos are optional.
3. Terms and first invoice: what was agreed with the owner, to the cent. An Admin checks them before anything is sent.
4. Who sourced the owner: Entered for CarmaCars, or I sourced this owner. How the owner signs: by email, or on paper.
5. Press **Add the car and send to an Admin**. The application waits in the Admin''s Applications, marked Entered by staff with your name. When the Admin approves, the owner gets one email to review and sign.

## Owner forms (Forms C and D)

1. Open **Owner forms**. Each row is a scan an owner uploaded, with the witnesses and the status.
2. Press Open to read the scan. Check every page is there and signed, with each witness''s signature and name.
3. Press **Approve**, or **Send back** with What to fix (the owner reads this).

![](/guides/img/va-cs-08-owner-forms-desktop-eceaee0b.jpg "desktop; size: 1440 300; address: carmacars.ca/va/owner-forms; pins: 2 68.6 36.7, 3 76.7 36.7")

## A rental agreement signed on paper

1. Open the booking. Under Signed on paper, press **Record paper signature**.
2. Choose the Rental agreement, or the booking change the renter signed.
3. Check Signed by and Date signed, and upload the scan of every signed page.
4. Press **Record signature**. It counts as signed, and the renter is not asked to sign again.

## Signatures on the spot, or by link

A renter or an additional driver who has not signed yet.

1. On the booking, press **Sign now on this device**. Confirm the name and that you saw the original licence, then **Hand the device to** the signer.
2. Or press **Email the signing link** or **Text the signing link**: they sign on their own phone.
3. The licence comes first: the renter uploads it from the request, and the offer cannot be accepted without it.

## The booking''s rental agreements

The Rental agreements card keeps both agreements in step with the booking.

1. Any change after signing makes a new version by itself. A change to the dates, the price, the car, the drivers or the coverage waits for the renter''s signature: they get the link by email and text, and the card says "Agreement v3 waiting for signature".
2. **Resend the signing links**, or press the button with their first name beside it to have them sign on your device.
3. Fields still blank (a licence expiry, an insurer''s policy number) are listed: type them and press **Save the missing fields**. Check-out stops on a field a claim needs until it is filled or an Admin overrides.
4. Every signature: a code to the signer''s phone or email, the key terms initialled, three consents, a drawn signature.

## Check renter documents

The renter''s licence photos, selfie and proof of coverage, before the handover.

1. Open the task "identity documents or coverage proof to review", or open the booking: **Review** shows the documents of any booking being arranged or under way, with no task needed.
2. Every licence image, selfie and proof of coverage of the booking is on one screen, with what to check written once above them: the name and date of birth, class G2 or G and valid past the return, the selfie matches, the coverage is active to the return date.
3. One is wrong? Open **Reject this one** under it, type the reason the renter reads and press **Reject**.
4. Then press **Approve all**: everything still waiting is approved at once (the Protection Plan too). A document the system refuses is named with the reason; the rest are approved.

> Tip: Each opening is logged. An Admin can do the same from Admin > To do. Field staff review the licence images (not the coverage) of bookings on their own jobs in the next 7 days from their My jobs: the booking history says the role, field.

## Which credit cards include rental car coverage?

Renters ask this often. **Renters** > **Card coverage** (every function has it under Rentals or Bookings) is your quick reference: what to say, what to check, and the list.

1. Send the renter `carmacars.ca/credit-card-rental-coverage`: each card''s car value limit (MSRP), longest rental, key exclusions, its official guide and the day we last checked it.
2. Ask which car they want. Most Canadian cards stop at a car priced $65,000 or $85,000, and many luxury models are priced higher. Give them the car''s model year and trim so they can check.
3. Never tell a renter they are covered. Their card''s issuer decides that: ask them to call the number on the back of their card about this car and these dates. CarmaCars does not decide claims.
4. Over the limit, an excluded make, a debit card or a longer rental than the card allows: offer OPCF 27 on their own auto policy or the CarmaCars Protection Plan.

> Tip: A card marked Unverified came from a published summary, not the issuer''s guide. Something wrong or out of date in the list? Tell an Admin: they correct it in Settings > Card coverage.

## Review requests

Renters are asked for a review by email and text after each trip. **Renters** > **Review requests** shows the ones on hold and the Google reviews to match.

1. On hold: the booking has a charge that is not settled or waived yet (late return, kilometres, fuel, cleaning, smoking, damage, tolls) or an open incident. It leaves the list by itself once the charges are settled or waived.
2. The renter should be asked now anyway? Press **Send anyway**. Should never be asked? Press **Do not ask**.
3. Google reviews: a possible match to a renter shows "possible match". Press **Confirm** if it is them, **Not this renter** if not, or **Match to a booking** with the booking number.
4. On a booking, the card Review requests has **Ask for a review** (for example after a call that went well) and **Mark reviewed** when the renter says they already left one.

> Tip: Never offer anything for a review and never ask only happy renters: everyone gets the same message and the same Google link.

## A change to a confirmed booking

On a booking''s Changes tab you can propose new dates, times or another car, as an Admin does: set the change, write the reason, press **Preview the price**, then **Send to the renter**. The renter has 48 hours to accept and sign the amendment. You also send a new signing link to an additional driver from the booking screen.

## A late return

A booking past its return time shows the late return panel. Work it in order:

| Button | When |
| --- | --- |
| **Log a call** | Record each call to the renter and what they said. |
| **Send T13** | The first late notice email. |
| **Send T14 (final notice)** | The final notice. |
| **Request disable** | Ask an Admin to approve disabling the car. |
| **Open an incident** | When the car is not coming back as planned. |
',
  '<p class="gd-p">You answer requests with offers, quote callers, reply to renters, look renters up, and review owner forms. You are often the renter&#39;s first person.</p><p class="gd-p">Your rail: Queue, Today, Requests, New quote, Renter messages, Find a renter, Calendar, Listings, Similar cars, Owners and enquiries, Owner forms and Scorecard.</p><section class="gd-task" id="customer-service-answer-a-request" data-gd-task><h2 class="gd-h2">Answer a request</h2><div class="gd-stepblock gd-stepblock--below"><div class="gd-stepcol"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Open <b class="gd-ui">Requests</b>. Filter by New, Waiting on the renter, Pushed back, Offer out or Offer expired.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Waiting shows how long the renter has waited. Open the booking number.</div></li></ol></div><figure class="gd-fig gd-fig--desk"><div class="gd-browser"><div class="gd-bar" aria-hidden="true"><i></i><i></i><i></i><span class="gd-addr">carmacars.ca/va/requests</span></div><div class="gd-imgwrap" style="aspect-ratio:1440/640"><img src="/guides/img/va-cs-03-requests-desktop-b3c66d25.jpg" alt="" loading="lazy" decoding="async" width="1440" height="640"><span class="gd-pin" style="left:27.1%;top:17.5%" aria-hidden="true">1</span><span class="gd-pin" style="left:52.8%;top:32.8%" aria-hidden="true">2</span></div></div></figure></div><div class="gd-stepblock gd-stepblock--below"><div class="gd-stepcol"><ol class="gd-ol" start="3"><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">On the Review tab, check the request: the car is free, the renter, the places.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">Press <b class="gd-ui">Adjust the booking</b> to change the car, dates, places, price or extras, then <b class="gd-ui">Save changes</b>.</div></li><li><span class="gd-n" aria-hidden="true">5</span><div class="gd-t">Add a message and press <b class="gd-ui">Send the offer</b>. Within your limit you can also use <b class="gd-ui">Approve (within my limit)</b> or <b class="gd-ui">Approve and send the pay link</b>.</div></li><li><span class="gd-n" aria-hidden="true">6</span><div class="gd-t">Can&#39;t do it? <b class="gd-ui">Decline</b> with Reason and any alternative. Need to know more? <b class="gd-ui">Ask the renter</b>.</div></li></ol></div><figure class="gd-fig gd-fig--desk"><div class="gd-browser"><div class="gd-bar" aria-hidden="true"><i></i><i></i><i></i><span class="gd-addr">carmacars.ca/va/bookings/CC-10069?tab=review</span></div><div class="gd-imgwrap" style="aspect-ratio:1440/1000"><img src="/guides/img/va-cs-04-booking-review-desktop-52c68a73.jpg" alt="" loading="lazy" decoding="async" width="1440" height="1000"><span class="gd-pin" style="left:69.4%;top:24%" aria-hidden="true">3</span><span class="gd-pin" style="left:95.8%;top:98%" aria-hidden="true">4</span></div></div></figure></div><aside class="gd-box"><span class="gd-lbl">Tip</span><div>Reply within 5 minutes: send the offer, or ask the renter what you need. That is the &quot;First reply in opening hours&quot; measure on your scorecard. Requests waiting longer show in red.</div></aside><p class="gd-p">Opening a request takes it for you: the others see &quot;Being answered by&quot; your name and cannot answer it until you send, decline or leave (20 minutes, renewed while you work). One someone else holds shows who, with the buttons off; it opens to you when their claim runs out, or ask an Admin to take it over. Sales: a request from the website shows &quot;Opens to you at&quot; a time for its first 15 minutes, and a To do task says when it opens; after that whoever opens it first answers it, customer service included.</p></section><section class="gd-task" id="customer-service-an-enquiry-on-an-example-car" data-gd-task><h2 class="gd-h2">An enquiry on an example car</h2><p class="gd-p">Some cars on the site are marked &quot;Example car&quot;: samples that show the kind of cars we rent. A request on one is an enquiry, never a booking.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">The task Suggest a similar real car comes to To do with the enquiry number (EQ-1001 and up), the car asked for, the dates and the contact. When a real car was free for those dates, the task names it after <b class="gd-ui">Free:</b> (the same make and model first, else the same class and body at a similar price), and the person was told we have a similar car and will confirm it within 2 hours.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Check the named car is still right for them (or find a real car of the same kind and price that is free for those dates), and make a <b class="gd-ui">New quote</b> for it.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Call or email the person with the car and the price, then mark the task done.</div></li></ol></div><aside class="gd-box"><span class="gd-lbl">Tip</span><div>Reply within the first reply target, as for any request. Never offer the example car itself: it does not exist.</div></aside></section><section class="gd-task" id="customer-service-a-request-from-a-vehicle-page" data-gd-task><h2 class="gd-h2">A request from a vehicle page</h2><p class="gd-p">Every make, model, year and trim page (carmacars.ca/cars/toyota/rav4/2023/xle, for example) has Request it, for the exact car the person wants.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">The request arrives as an enquiry with the car named in the message (&quot;About the car: 2023 Toyota RAV4 XLE&quot;) and an Enquiry task in To do.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">If we have that car, or one close to it, free for their dates, make a <b class="gd-ui">New quote</b> for it. If not, suggest the nearest car of the same kind and price.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Reply by email or phone, then mark the task done.</div></li></ol></div><aside class="gd-box"><span class="gd-lbl">Tip</span><div>The pages say only what the data says: EPA fuel use, the Canadian trims and our own cars. Never promise equipment the page does not list.</div></aside></section><section class="gd-task" id="customer-service-a-buyer-lead-from-a-buy-page" data-gd-task><h2 class="gd-h2">A buyer lead from a /buy page</h2><p class="gd-p">Every vehicle page has a for-sale twin (carmacars.ca/buy/toyota/rav4/2023/xle) with &quot;Find me this car&quot;, and twins for financing, detailing and body shop work with their own request: a name, an email or phone, and when.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">The lead is in <b class="gd-ui">Owner leads</b> (customer service: <b class="gd-ui">Owners and enquiries</b>), Buyer leads (kind buyer, finance, detailing or body shop), with the car and what they asked, and a To do line for Sales: A buyer asked us to find a car, Someone asked about financing or leasing a car, A detailing request, or A body shop request.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">If one of our cars of that kind is for sale (an Admin flags it with its price), offer it. If not, offer to rent them the car for a week first, and say what we can find. We do not lend or lease: on a financing question, say so and offer the rental. For detailing or body shop work, give a time and a price, and always offer a rental while their car is in (an insurance replacement rental when it is a claim). For mechanical work (a &quot;Mechanical work to arrange&quot; task: an oil change, brakes, tires, a tow and the like), CarmaCars does not do the work: book it with a trusted shop or recommend one, never promise the shop&#39;s price or time, and offer a rental while their car is in.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Press <b class="gd-ui">Take it</b>, then <b class="gd-ui">Update</b> as you go: contacted, qualified, converted or closed with the reason.</div></li></ol></div><aside class="gd-box"><span class="gd-lbl">Tip</span><div>We mostly rent cars. Never say a car is for sale unless an Admin flagged it; the page shows it with its price when one is.</div></aside></section><section class="gd-task" id="customer-service-send-an-offer-to-a-caller" data-gd-task><h2 class="gd-h2">Send an offer to a caller</h2><p class="gd-p">Open <b class="gd-ui">Send an offer</b> (or <b class="gd-ui">Send an offer</b> beside a car in Find a car). No request needed: one screen, and the renter has the link.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Find the customer by name, phone or email, or press <b class="gd-ui">Add a new customer</b>: full legal name, mobile, email and date of birth. Already on file with that email or phone? Use them: never a second record.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Choose the car (by car code, plate or name; each says Free or Not free), the dates and the places.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">The price: the rate sheet, a total or a rate per day, with the reason for a price you type. The deposit, discounts and fees are set by an Admin; customer service sets the Protection Plan price. Amounts I type, at the top of the price: Before tax, or After tax (HST included) to type what the renter pays, worked back to before tax for you. Or type the Total the renter pays (after tax): the rental charge is worked out from it.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">How the rental and the deposit are paid (card online, e-Transfer, cash, platform payout, the insurer; deposit by card hold, cash or e-Transfer), who found this client, the message, how long it is open (48 hours at most) and Email, Text or both.</div></li><li><span class="gd-n" aria-hidden="true">5</span><div class="gd-t">Check the offer as the renter will see it on the right, then press <b class="gd-ui">Send the offer</b>.</div></li></ol></div><aside class="gd-box"><span class="gd-lbl">Tip</span><div>An offer that is out is changed in place: <b class="gd-ui">More actions</b> &gt; <b class="gd-ui">Edit the offer</b>, change it, then <b class="gd-ui">Save and send the update</b> or <b class="gd-ui">Save without telling the renter</b>. No need to withdraw it first.</div></aside></section><section class="gd-task" id="customer-service-new-quote-for-a-caller" data-gd-task><h2 class="gd-h2">New quote for a caller</h2><div class="gd-stepblock gd-stepblock--below"><div class="gd-stepcol"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Open <b class="gd-ui">New quote</b>. Choose the Car, the Pickup and Return (at least 2 hours from now).</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Choose how the lead came in, then the caller&#39;s Full legal name, Email, Mobile and Date of birth.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Set the Licence class and Damage cover, and note places, extras and what they asked.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">Press <b class="gd-ui">Create the request</b>. It opens like any request; send the offer from there.</div></li></ol></div><figure class="gd-fig gd-fig--desk"><div class="gd-browser"><div class="gd-bar" aria-hidden="true"><i></i><i></i><i></i><span class="gd-addr">carmacars.ca/va/quotes/new</span></div><div class="gd-imgwrap" style="aspect-ratio:1220/1260"><img src="/guides/img/va-cs-05-new-quote-desktop-4e386b1c.jpg" alt="" loading="lazy" decoding="async" width="1220" height="1260"><span class="gd-pin" style="left:72.1%;top:15.6%" aria-hidden="true">1</span><span class="gd-pin" style="left:72.1%;top:41.7%" aria-hidden="true">2</span><span class="gd-pin" style="left:72.1%;top:72.7%" aria-hidden="true">3</span><span class="gd-pin" style="left:63.9%;top:85.5%" aria-hidden="true">4</span></div></div></figure></div></section><section class="gd-task" id="customer-service-edit-a-booking-a-fee-or-the-renter" data-gd-task><h2 class="gd-h2">Edit a booking, a fee or the renter</h2><p class="gd-p">A booking that is confirmed, on trip or returned is edited directly; the renter&#39;s details are corrected from the booking.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Overview, <b class="gd-ui">Edit the booking</b>: the return (extend or shorten), the car, the rental charge, each fee, the kilometres and the note. Tick <b class="gd-ui">Email the renter what changed</b>, or leave it off for a silent correction.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Money tab, Fees, <b class="gd-ui">Change or add a fee</b>: a fee forgotten (the young driver fee shows its price for the dates) or a charge of its own.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">What is open shows at once: <b class="gd-ui">Email a pay link</b> or <b class="gd-ui">Text a pay link</b> for exactly that amount, or record cash or an e-Transfer (<b class="gd-ui">Record a payment</b>, For: the rental and fees).</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t"><b class="gd-ui">Edit renter</b>: a wrong email, phone, name, licence or address. A new email is their sign-in at once.</div></li><li><span class="gd-n" aria-hidden="true">5</span><div class="gd-t">The same renter twice? Under the renter, Possible duplicates: <b class="gd-ui">Merge into this record</b> moves everything of the other record here.</div></li></ol></div><aside class="gd-box"><span class="gd-lbl">Good to know</span><div>Each edit is recorded with your name, the time, the reason and the before and after.</div></aside></section><section class="gd-task" id="customer-service-renter-messages-and-find-a-renter" data-gd-task><h2 class="gd-h2">Renter messages and Find a renter</h2><div class="gd-stepblock gd-stepblock--below"><div class="gd-stepcol"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t"><b class="gd-ui">Renter messages</b> lists the latest messages with their booking. Open the booking to reply, then press <b class="gd-ui">Send</b>.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t"><b class="gd-ui">Find a renter</b>: search by name, email, phone or booking number.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">To open a renter&#39;s private details, press <b class="gd-ui">Open with a reason</b>. The reason is kept in the access log.</div></li></ol></div><figure class="gd-fig gd-fig--desk"><div class="gd-browser"><div class="gd-bar" aria-hidden="true"><i></i><i></i><i></i><span class="gd-addr">carmacars.ca/va/messages</span></div><div class="gd-imgwrap" style="aspect-ratio:1440/260"><img src="/guides/img/va-cs-06-messages-desktop-3441fa91.jpg" alt="" loading="lazy" decoding="async" width="1440" height="260"><span class="gd-pin" style="left:32.6%;top:48.5%" aria-hidden="true">1</span></div></div></figure></div></section><section class="gd-task" id="customer-service-add-a-car-for-an-owner" data-gd-task><h2 class="gd-h2">Add a car for an owner</h2><p class="gd-p">Open <b class="gd-ui">Owners</b> &gt; <b class="gd-ui">Add a car for an owner</b> (fleet: under Cars). You enter everything for the owner; they never fill in the application.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">The owner: find them by name, email or phone, or choose New owner and enter the name, email, phone and address.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">The car: type the VIN. The car is looked up at once and shown in one line with the year, make, model, trim and details (Edit if something is wrong). No VIN at hand: add it by its plate and choose the year, make and model. Tap the colour and check the class. Upload the ownership permit, the insurance slip and the lender&#39;s information if you have them. Photos are optional.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Terms and first invoice: what was agreed with the owner, to the cent. An Admin checks them before anything is sent.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">Who sourced the owner: Entered for CarmaCars, or I sourced this owner. How the owner signs: by email, or on paper.</div></li><li><span class="gd-n" aria-hidden="true">5</span><div class="gd-t">Press <b class="gd-ui">Add the car and send to an Admin</b>. The application waits in the Admin&#39;s Applications, marked Entered by staff with your name. When the Admin approves, the owner gets one email to review and sign.</div></li></ol></div></section><section class="gd-task" id="customer-service-owner-forms-forms-c-and-d" data-gd-task><h2 class="gd-h2">Owner forms (Forms C and D)</h2><div class="gd-stepblock gd-stepblock--below"><div class="gd-stepcol"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Open <b class="gd-ui">Owner forms</b>. Each row is a scan an owner uploaded, with the witnesses and the status.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Press Open to read the scan. Check every page is there and signed, with each witness&#39;s signature and name.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Press <b class="gd-ui">Approve</b>, or <b class="gd-ui">Send back</b> with What to fix (the owner reads this).</div></li></ol></div><figure class="gd-fig gd-fig--desk"><div class="gd-browser"><div class="gd-bar" aria-hidden="true"><i></i><i></i><i></i><span class="gd-addr">carmacars.ca/va/owner-forms</span></div><div class="gd-imgwrap" style="aspect-ratio:1440/300"><img src="/guides/img/va-cs-08-owner-forms-desktop-eceaee0b.jpg" alt="" loading="lazy" decoding="async" width="1440" height="300"><span class="gd-pin" style="left:68.6%;top:36.7%" aria-hidden="true">2</span><span class="gd-pin" style="left:76.7%;top:36.7%" aria-hidden="true">3</span></div></div></figure></div></section><section class="gd-task" id="customer-service-a-rental-agreement-signed-on-paper" data-gd-task><h2 class="gd-h2">A rental agreement signed on paper</h2><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Open the booking. Under Signed on paper, press <b class="gd-ui">Record paper signature</b>.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Choose the Rental agreement, or the booking change the renter signed.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Check Signed by and Date signed, and upload the scan of every signed page.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">Press <b class="gd-ui">Record signature</b>. It counts as signed, and the renter is not asked to sign again.</div></li></ol></div></section><section class="gd-task" id="customer-service-signatures-on-the-spot-or-by-link" data-gd-task><h2 class="gd-h2">Signatures on the spot, or by link</h2><p class="gd-p">A renter or an additional driver who has not signed yet.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">On the booking, press <b class="gd-ui">Sign now on this device</b>. Confirm the name and that you saw the original licence, then <b class="gd-ui">Hand the device to</b> the signer.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Or press <b class="gd-ui">Email the signing link</b> or <b class="gd-ui">Text the signing link</b>: they sign on their own phone.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">The licence comes first: the renter uploads it from the request, and the offer cannot be accepted without it.</div></li></ol></div></section><section class="gd-task" id="customer-service-the-booking-s-rental-agreements" data-gd-task><h2 class="gd-h2">The booking&#39;s rental agreements</h2><p class="gd-p">The Rental agreements card keeps both agreements in step with the booking.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Any change after signing makes a new version by itself. A change to the dates, the price, the car, the drivers or the coverage waits for the renter&#39;s signature: they get the link by email and text, and the card says &quot;Agreement v3 waiting for signature&quot;.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t"><b class="gd-ui">Resend the signing links</b>, or press the button with their first name beside it to have them sign on your device.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Fields still blank (a licence expiry, an insurer&#39;s policy number) are listed: type them and press <b class="gd-ui">Save the missing fields</b>. Check-out stops on a field a claim needs until it is filled or an Admin overrides.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">Every signature: a code to the signer&#39;s phone or email, the key terms initialled, three consents, a drawn signature.</div></li></ol></div></section><section class="gd-task" id="customer-service-check-renter-documents" data-gd-task><h2 class="gd-h2">Check renter documents</h2><p class="gd-p">The renter&#39;s licence photos, selfie and proof of coverage, before the handover.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Open the task &quot;identity documents or coverage proof to review&quot;, or open the booking: <b class="gd-ui">Review</b> shows the documents of any booking being arranged or under way, with no task needed.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Every licence image, selfie and proof of coverage of the booking is on one screen, with what to check written once above them: the name and date of birth, class G2 or G and valid past the return, the selfie matches, the coverage is active to the return date.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">One is wrong? Open <b class="gd-ui">Reject this one</b> under it, type the reason the renter reads and press <b class="gd-ui">Reject</b>.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">Then press <b class="gd-ui">Approve all</b>: everything still waiting is approved at once (the Protection Plan too). A document the system refuses is named with the reason; the rest are approved.</div></li></ol></div><aside class="gd-box"><span class="gd-lbl">Tip</span><div>Each opening is logged. An Admin can do the same from Admin &gt; To do. Field staff review the licence images (not the coverage) of bookings on their own jobs in the next 7 days from their My jobs: the booking history says the role, field.</div></aside></section><section class="gd-task" id="customer-service-which-credit-cards-include-rental-car-coverage" data-gd-task><h2 class="gd-h2">Which credit cards include rental car coverage?</h2><p class="gd-p">Renters ask this often. <b class="gd-ui">Renters</b> &gt; <b class="gd-ui">Card coverage</b> (every function has it under Rentals or Bookings) is your quick reference: what to say, what to check, and the list.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Send the renter <span class="gd-url">carmacars.ca/credit-card-rental-coverage</span>: each card&#39;s car value limit (MSRP), longest rental, key exclusions, its official guide and the day we last checked it.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Ask which car they want. Most Canadian cards stop at a car priced $65,000 or $85,000, and many luxury models are priced higher. Give them the car&#39;s model year and trim so they can check.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Never tell a renter they are covered. Their card&#39;s issuer decides that: ask them to call the number on the back of their card about this car and these dates. CarmaCars does not decide claims.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">Over the limit, an excluded make, a debit card or a longer rental than the card allows: offer OPCF 27 on their own auto policy or the CarmaCars Protection Plan.</div></li></ol></div><aside class="gd-box"><span class="gd-lbl">Tip</span><div>A card marked Unverified came from a published summary, not the issuer&#39;s guide. Something wrong or out of date in the list? Tell an Admin: they correct it in Settings &gt; Card coverage.</div></aside></section><section class="gd-task" id="customer-service-review-requests" data-gd-task><h2 class="gd-h2">Review requests</h2><p class="gd-p">Renters are asked for a review by email and text after each trip. <b class="gd-ui">Renters</b> &gt; <b class="gd-ui">Review requests</b> shows the ones on hold and the Google reviews to match.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">On hold: the booking has a charge that is not settled or waived yet (late return, kilometres, fuel, cleaning, smoking, damage, tolls) or an open incident. It leaves the list by itself once the charges are settled or waived.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">The renter should be asked now anyway? Press <b class="gd-ui">Send anyway</b>. Should never be asked? Press <b class="gd-ui">Do not ask</b>.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Google reviews: a possible match to a renter shows &quot;possible match&quot;. Press <b class="gd-ui">Confirm</b> if it is them, <b class="gd-ui">Not this renter</b> if not, or <b class="gd-ui">Match to a booking</b> with the booking number.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">On a booking, the card Review requests has <b class="gd-ui">Ask for a review</b> (for example after a call that went well) and <b class="gd-ui">Mark reviewed</b> when the renter says they already left one.</div></li></ol></div><aside class="gd-box"><span class="gd-lbl">Tip</span><div>Never offer anything for a review and never ask only happy renters: everyone gets the same message and the same Google link.</div></aside></section><section class="gd-task" id="customer-service-a-change-to-a-confirmed-booking" data-gd-task><h2 class="gd-h2">A change to a confirmed booking</h2><p class="gd-p">On a booking&#39;s Changes tab you can propose new dates, times or another car, as an Admin does: set the change, write the reason, press <b class="gd-ui">Preview the price</b>, then <b class="gd-ui">Send to the renter</b>. The renter has 48 hours to accept and sign the amendment. You also send a new signing link to an additional driver from the booking screen.</p></section><section class="gd-task" id="customer-service-a-late-return" data-gd-task><h2 class="gd-h2">A late return</h2><p class="gd-p">A booking past its return time shows the late return panel. Work it in order:</p><div class="gd-tablewrap"><table class="gd-table"><thead><tr><th scope="col">Button</th><th scope="col">When</th></tr></thead><tbody><tr><td><b class="gd-ui">Log a call</b></td><td>Record each call to the renter and what they said.</td></tr><tr><td><b class="gd-ui">Send T13</b></td><td>The first late notice email.</td></tr><tr><td><b class="gd-ui">Send T14 (final notice)</b></td><td>The final notice.</td></tr><tr><td><b class="gd-ui">Request disable</b></td><td>Ask an Admin to approve disabling the car.</td></tr><tr><td><b class="gd-ui">Open an incident</b></td><td>When the car is not coming back as planned.</td></tr></tbody></table></div></section>');
select app.guide_release_section('va', 'finance', 'chapter', 'chauffeur-requests', 'You keep the money right: payments, deposits and refunds, toll notices, processor payouts and Turo trips.

Your rail: Queue, Today, Payments, deposits, refunds, Tolls and tickets, Reconciliation, Turo trips, Find a renter, Calendar and Scorecard.

## Your queue

Finance tasks include failed owner debits, toll notices with no match, statements to review and refunds to issue.

![The lanes show what Finance handles: payments to fix, refunds waiting, tolls and tickets, deposits to settle and owner statements. Money today counts them below.](/guides/img/va-finance-01-queue-desktop-2f37513d.jpg "desktop; size: 1230 940; address: carmacars.ca/va; pins: 1 20.3 24.3")

## Payments by day

**Payments by day** is your day in one screen: every payment and refund, by method, with the cash drawer and the refunds to decide.

1. Choose From and To (today by default) and tick the methods you want (card, e-Transfer, cash, cheque, platform payout, insurer and others; none ticked shows all), then press **Show**.
2. Totals by method: received, refunded and net. Each day: the same by method, the cash expected in the drawer (cash received less cash given back) and the cash counted.
3. At the end of the day count the drawer and press **Record the count**. The difference shows "balanced", or "over" or "short" with the amount.
4. Refunds waiting: every refund asked for anywhere (a cancellation, a booking, Finance), with the policy maths (paid, the tier, the percentage back, what is kept). Press **Approve** or **Decline** with the reason in the same row; above your limit it says an Admin approves. Approved: **Issue the refund**.
5. **Export CSV** gives the same rows for the bank or the bookkeeper: refunds as negative amounts, holds marked as not money in.

## Payments, deposits, refunds

1. Failed payments: each with the purpose, amount and the bank''s reason.
2. Deposits to take before pickup, and deposits due back.
3. Refunds in progress. Press **Request the refund** and choose What it refunds (the rental charge, delivery or pickup, kilometres, add-ons or other charges); above your limit it waits for an Admin. Then **Issue the refund**.
4. Owner invoices that failed, and owner statements to prepare.

![](/guides/img/va-finance-02-money-desktop-486a8fbc.jpg "desktop; size: 1230 865; address: carmacars.ca/va/money; pins: 1 10.6 60.3, 2 72.4 21.6, 3 73.2 33.8, 4 11.0 45.9")

## A payment received another way

An owner or renter paid by e-Transfer, cheque, cash or bank transfer.

1. Owner invoice: on **Payments, deposits, refunds**, find it under Owner invoices owing and press **Record payment**.
2. Renter: beside the failed payment, press **Paid another way**. Or open the booking''s Money tab: under Money by part press **Record a payment**, choose what it is for (the rental, fees, the deposit or a later charge) and how it was paid, then **Record it**.
3. Choose Paid by, the Date received and the Reference (the cheque number for a cheque). Leave Amount empty for the full balance; type less for a partial payment.
4. Add the proof if you have it (a screenshot or a photo of the cheque), then press **Record payment**.

The invoice is marked paid or partly paid, the automatic debit stops for that amount and the owner gets a receipt. Above your single limit the payment needs an Admin. Recorded something wrong? Ask an Admin to void it; you cannot void a payment.

Each month''s payments recorded by hand are listed under Reconciliation, with the totals by method, to check against the bank.

## Cards, holds and deposits given back

On the booking''s Money tab.

1. **Charge the saved card**: a later charge (extra kilometres, fuel, damage, a late return) with the reason on the renter''s receipt, or the deposit of a rental over 7 days.
2. A deposit hold: **Capture the hold** for all of it, with the reason. A part capture (the rest is released) or **Release the hold** waits for the settlement while the car is out, inside the toll window or while something is open; an Admin may do it with the reason.
3. A deposit taken in cash or by e-Transfer is given back the same way: the task Give the deposit back the way it came; then press **Returned** with the reference or receipt number.

## Settle a deposit

The deposit is never given back by itself. Finance or an Admin settles it after the return: on the booking''s Money tab, under Deposit, press **Settle the deposit**. Issue the Check-in statement first.

1. The form shows the deposit, what is still available, the charges owed from the statement and what is taken from the deposit for them. What the deposit does not cover is charged to the card on file; with no card (or a card declined), the renter gets a pay link by email and text, and Finance has a task until it is paid.
2. Tolls and tickets can take up to 7 days to come in. Inside that window the whole rest of the deposit is filled in as the hold-back, until the window ends. To give it back sooner, tick Release now anyway: a toll that comes in later is charged to the card on file.
3. Something still open keeps the whole deposit: an incident, a claim, new damage at the return not priced, damage found later not billed, a toll or ticket on the car during the rental not matched or not charged, a card dispute, or charges not on a statement yet. The form lists them. Only an Admin can release part of it, with the reason; it is recorded.
4. Damage: an Admin keeps the whole deposit (**Keep the whole deposit (damage)**) or bills a damage charge up to the $2,500 deductible. Ask an Admin, with the photos.
5. Press **Settle**. The money moves at Stripe at once: the charges are collected and what is not owed is refunded or the hold released. A step Stripe refuses is tried again by itself, and Finance gets a task if it keeps failing.

> Good to know: A card hold lapses after about 7 days. While the car is out, or returned and not settled, the hold is collected in full a day and a half before it lapses: that keeps the money, and the settlement refunds what is not owed. A hold that lapses anyway is charged to the saved card, and Finance is told at once.

## Read a toll notice

1. Open **Tolls and tickets** and press **Read a notice**.
2. Choose the file: a PDF, a photo or a CSV, under 15 MB. Leave the reading profile to find it from the text.
3. Press **Read it**. Then check each line beside the notice and fix what was read wrong.
4. Press **Checked against the notice** on each line (**Leave out** to skip one), then **Save as checked** and **Confirm and import**.

![](/guides/img/va-finance-04-tolls-read-desktop-aa04a6b2.jpg "desktop; size: 1230 580; address: carmacars.ca/va/tolls/read; pins: 2 19.5 44.1, 3 4.1 64.8, 4 4.1 89.7")

> Tip: In the work queue, **Match again** retries the match after a fix, and **Dispute** marks a notice you think is wrong. Renters matched with high confidence are charged at import, with the notice and our fee.

![The work queue: Unmatched, Needs review, Matched not charged and Disputed, with each notice''s plate, date, amount and match.](/guides/img/va-finance-03-tolls-desktop-37b6f99c.jpg "desktop; size: 1230 540; address: carmacars.ca/va/tolls; pins: 1 23.6 12.2")

## Reconciliation and Turo trips

1. **Reconciliation**: press **Record a processor payout**, then **Match** it to the payments it contains. Anything still unmatched at the closing check goes to an Admin.
2. **Turo trips**: press **Add a trip** for one trip, or paste CSV rows and press **Import**.

![](/guides/img/va-finance-06-turo-desktop-b59cc7f9.jpg "desktop; size: 1230 540; address: carmacars.ca/va/turo; pins: 2 95.1 14.8")
', 'Finance', 'Payments, deposits and refunds, tolls and tickets, reconciliation and Turo trips.',
  'You keep the money right: payments, deposits and refunds, toll notices, processor payouts and Turo trips.

Your rail: Queue, Today, Payments, deposits, refunds, Tolls and tickets, Reconciliation, Turo trips, Find a renter, Calendar and Scorecard.

## Your queue

Finance tasks include failed owner debits, toll notices with no match, statements to review and refunds to issue.

![The lanes show what Finance handles: payments to fix, refunds waiting, tolls and tickets, deposits to settle and owner statements. Money today counts them below.](/guides/img/va-finance-01-queue-desktop-2f37513d.jpg "desktop; size: 1230 940; address: carmacars.ca/va; pins: 1 20.3 24.3")

## Payments by day

**Payments by day** is your day in one screen: every payment and refund, by method, with the cash drawer and the refunds to decide.

1. Choose From and To (today by default) and tick the methods you want (card, e-Transfer, cash, cheque, platform payout, insurer and others; none ticked shows all), then press **Show**.
2. Totals by method: received, refunded and net. Each day: the same by method, the cash expected in the drawer (cash received less cash given back) and the cash counted.
3. At the end of the day count the drawer and press **Record the count**. The difference shows "balanced", or "over" or "short" with the amount.
4. Refunds waiting: every refund asked for anywhere (a cancellation, a booking, Finance), with the policy maths (paid, the tier, the percentage back, what is kept). Press **Approve** or **Decline** with the reason in the same row; above your limit it says an Admin approves. Approved: **Issue the refund**.
5. **Export CSV** gives the same rows for the bank or the bookkeeper: refunds as negative amounts, holds marked as not money in.

## Payments, deposits, refunds

1. Failed payments: each with the purpose, amount and the bank''s reason.
2. Deposits to take before pickup, and deposits due back.
3. Refunds in progress. Press **Request the refund** and choose What it refunds (the rental charge, delivery or pickup, kilometres, add-ons or other charges); above your limit it waits for an Admin. Then **Issue the refund**.
4. Owner invoices that failed, and owner statements to prepare.

![](/guides/img/va-finance-02-money-desktop-486a8fbc.jpg "desktop; size: 1230 865; address: carmacars.ca/va/money; pins: 1 10.6 60.3, 2 72.4 21.6, 3 73.2 33.8, 4 11.0 45.9")

## A payment received another way

An owner or renter paid by e-Transfer, cheque, cash or bank transfer.

1. Owner invoice: on **Payments, deposits, refunds**, find it under Owner invoices owing and press **Record payment**.
2. Renter: beside the failed payment, press **Paid another way**. Or open the booking''s Money tab: under Money by part press **Record a payment**, choose what it is for (the rental, fees, the deposit or a later charge) and how it was paid, then **Record it**.
3. Choose Paid by, the Date received and the Reference (the cheque number for a cheque). Leave Amount empty for the full balance; type less for a partial payment.
4. Add the proof if you have it (a screenshot or a photo of the cheque), then press **Record payment**.

The invoice is marked paid or partly paid, the automatic debit stops for that amount and the owner gets a receipt. Above your single limit the payment needs an Admin. Recorded something wrong? Ask an Admin to void it; you cannot void a payment.

Each month''s payments recorded by hand are listed under Reconciliation, with the totals by method, to check against the bank.

## Cards, holds and deposits given back

On the booking''s Money tab.

1. **Charge the saved card**: a later charge (extra kilometres, fuel, damage, a late return) with the reason on the renter''s receipt, or the deposit of a rental over 7 days.
2. A deposit hold: **Capture the hold** for all of it, with the reason. A part capture (the rest is released) or **Release the hold** waits for the settlement while the car is out, inside the toll window or while something is open; an Admin may do it with the reason.
3. A deposit taken in cash or by e-Transfer is given back the same way: the task Give the deposit back the way it came; then press **Returned** with the reference or receipt number.

## Settle a deposit

The deposit is never given back by itself. Finance or an Admin settles it after the return: on the booking''s Money tab, under Deposit, press **Settle the deposit**. Issue the Check-in statement first.

1. The form shows the deposit, what is still available, the charges owed from the statement and what is taken from the deposit for them. What the deposit does not cover is charged to the card on file; with no card (or a card declined), the renter gets a pay link by email and text, and Finance has a task until it is paid.
2. Tolls and tickets can take up to 7 days to come in. Inside that window the whole rest of the deposit is filled in as the hold-back, until the window ends. To give it back sooner, tick Release now anyway: a toll that comes in later is charged to the card on file.
3. Something still open keeps the whole deposit: an incident, a claim, new damage at the return not priced, damage found later not billed, a toll or ticket on the car during the rental not matched or not charged, a card dispute, or charges not on a statement yet. The form lists them. Only an Admin can release part of it, with the reason; it is recorded.
4. Damage: an Admin keeps the whole deposit (**Keep the whole deposit (damage)**) or bills a damage charge up to the $2,500 deductible. Ask an Admin, with the photos.
5. Press **Settle**. The money moves at Stripe at once: the charges are collected and what is not owed is refunded or the hold released. A step Stripe refuses is tried again by itself, and Finance gets a task if it keeps failing.

> Good to know: A card hold lapses after about 7 days. While the car is out, or returned and not settled, the hold is collected in full a day and a half before it lapses: that keeps the money, and the settlement refunds what is not owed. A hold that lapses anyway is charged to the saved card, and Finance is told at once.

## Read a toll notice

1. Open **Tolls and tickets** and press **Read a notice**.
2. Choose the file: a PDF, a photo or a CSV, under 15 MB. Leave the reading profile to find it from the text.
3. Press **Read it**. Then check each line beside the notice and fix what was read wrong.
4. Press **Checked against the notice** on each line (**Leave out** to skip one), then **Save as checked** and **Confirm and import**.

![](/guides/img/va-finance-04-tolls-read-desktop-aa04a6b2.jpg "desktop; size: 1230 580; address: carmacars.ca/va/tolls/read; pins: 2 19.5 44.1, 3 4.1 64.8, 4 4.1 89.7")

> Tip: In the work queue, **Match again** retries the match after a fix, and **Dispute** marks a notice you think is wrong. Renters matched with high confidence are charged at import, with the notice and our fee.

![The work queue: Unmatched, Needs review, Matched not charged and Disputed, with each notice''s plate, date, amount and match.](/guides/img/va-finance-03-tolls-desktop-37b6f99c.jpg "desktop; size: 1230 540; address: carmacars.ca/va/tolls; pins: 1 23.6 12.2")

## Reconciliation and Turo trips

1. **Reconciliation**: press **Record a processor payout**, then **Match** it to the payments it contains. Anything still unmatched at the closing check goes to an Admin.
2. **Turo trips**: press **Add a trip** for one trip, or paste CSV rows and press **Import**.

![](/guides/img/va-finance-06-turo-desktop-b59cc7f9.jpg "desktop; size: 1230 540; address: carmacars.ca/va/turo; pins: 2 95.1 14.8")

## Deposits to release

A deposit is never released by itself. Each morning the system puts one task in your queue for every deposit due back: "Release the deposit for" the booking, with the amount and the day it is due (7 business days after the check-in, or after the return when no check-in was recorded). On the day, and every day after, you and the Admins also get a notice in the portal. Nothing is emailed.

1. Open the task: it opens the booking''s **Money** tab.
2. Settle the deposit: apply what is owed, hold back what an open item needs, release the rest.
3. The task closes by itself once nothing is left to give back.',
  '<p class="gd-p">You keep the money right: payments, deposits and refunds, toll notices, processor payouts and Turo trips.</p><p class="gd-p">Your rail: Queue, Today, Payments, deposits, refunds, Tolls and tickets, Reconciliation, Turo trips, Find a renter, Calendar and Scorecard.</p><section class="gd-task" id="finance-your-queue" data-gd-task><h2 class="gd-h2">Your queue</h2><p class="gd-p">Finance tasks include failed owner debits, toll notices with no match, statements to review and refunds to issue.</p><div class="gd-figblock"><figure class="gd-fig gd-fig--desk"><div class="gd-browser"><div class="gd-bar" aria-hidden="true"><i></i><i></i><i></i><span class="gd-addr">carmacars.ca/va</span></div><div class="gd-imgwrap" style="aspect-ratio:1230/940"><img src="/guides/img/va-finance-01-queue-desktop-2f37513d.jpg" alt="The lanes show what Finance handles: payments to fix, refunds waiting, tolls and tickets, deposits to settle and owner statements. Money today counts them below." loading="lazy" decoding="async" width="1230" height="940"><span class="gd-pin" style="left:20.3%;top:24.3%" aria-hidden="true">1</span></div></div><figcaption>The lanes show what Finance handles: payments to fix, refunds waiting, tolls and tickets, deposits to settle and owner statements. Money today counts them below.</figcaption></figure></div></section><section class="gd-task" id="finance-payments-by-day" data-gd-task><h2 class="gd-h2">Payments by day</h2><p class="gd-p"><b class="gd-ui">Payments by day</b> is your day in one screen: every payment and refund, by method, with the cash drawer and the refunds to decide.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Choose From and To (today by default) and tick the methods you want (card, e-Transfer, cash, cheque, platform payout, insurer and others; none ticked shows all), then press <b class="gd-ui">Show</b>.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Totals by method: received, refunded and net. Each day: the same by method, the cash expected in the drawer (cash received less cash given back) and the cash counted.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">At the end of the day count the drawer and press <b class="gd-ui">Record the count</b>. The difference shows &quot;balanced&quot;, or &quot;over&quot; or &quot;short&quot; with the amount.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">Refunds waiting: every refund asked for anywhere (a cancellation, a booking, Finance), with the policy maths (paid, the tier, the percentage back, what is kept). Press <b class="gd-ui">Approve</b> or <b class="gd-ui">Decline</b> with the reason in the same row; above your limit it says an Admin approves. Approved: <b class="gd-ui">Issue the refund</b>.</div></li><li><span class="gd-n" aria-hidden="true">5</span><div class="gd-t"><b class="gd-ui">Export CSV</b> gives the same rows for the bank or the bookkeeper: refunds as negative amounts, holds marked as not money in.</div></li></ol></div></section><section class="gd-task" id="finance-payments-deposits-refunds" data-gd-task><h2 class="gd-h2">Payments, deposits, refunds</h2><div class="gd-stepblock gd-stepblock--below"><div class="gd-stepcol"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Failed payments: each with the purpose, amount and the bank&#39;s reason.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Deposits to take before pickup, and deposits due back.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Refunds in progress. Press <b class="gd-ui">Request the refund</b> and choose What it refunds (the rental charge, delivery or pickup, kilometres, add-ons or other charges); above your limit it waits for an Admin. Then <b class="gd-ui">Issue the refund</b>.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">Owner invoices that failed, and owner statements to prepare.</div></li></ol></div><figure class="gd-fig gd-fig--desk"><div class="gd-browser"><div class="gd-bar" aria-hidden="true"><i></i><i></i><i></i><span class="gd-addr">carmacars.ca/va/money</span></div><div class="gd-imgwrap" style="aspect-ratio:1230/865"><img src="/guides/img/va-finance-02-money-desktop-486a8fbc.jpg" alt="" loading="lazy" decoding="async" width="1230" height="865"><span class="gd-pin" style="left:10.6%;top:60.3%" aria-hidden="true">1</span><span class="gd-pin" style="left:72.4%;top:21.6%" aria-hidden="true">2</span><span class="gd-pin" style="left:73.2%;top:33.8%" aria-hidden="true">3</span><span class="gd-pin" style="left:11%;top:45.9%" aria-hidden="true">4</span></div></div></figure></div></section><section class="gd-task" id="finance-a-payment-received-another-way" data-gd-task><h2 class="gd-h2">A payment received another way</h2><p class="gd-p">An owner or renter paid by e-Transfer, cheque, cash or bank transfer.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Owner invoice: on <b class="gd-ui">Payments, deposits, refunds</b>, find it under Owner invoices owing and press <b class="gd-ui">Record payment</b>.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Renter: beside the failed payment, press <b class="gd-ui">Paid another way</b>. Or open the booking&#39;s Money tab: under Money by part press <b class="gd-ui">Record a payment</b>, choose what it is for (the rental, fees, the deposit or a later charge) and how it was paid, then <b class="gd-ui">Record it</b>.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Choose Paid by, the Date received and the Reference (the cheque number for a cheque). Leave Amount empty for the full balance; type less for a partial payment.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">Add the proof if you have it (a screenshot or a photo of the cheque), then press <b class="gd-ui">Record payment</b>.</div></li></ol></div><p class="gd-p">The invoice is marked paid or partly paid, the automatic debit stops for that amount and the owner gets a receipt. Above your single limit the payment needs an Admin. Recorded something wrong? Ask an Admin to void it; you cannot void a payment.</p><p class="gd-p">Each month&#39;s payments recorded by hand are listed under Reconciliation, with the totals by method, to check against the bank.</p></section><section class="gd-task" id="finance-cards-holds-and-deposits-given-back" data-gd-task><h2 class="gd-h2">Cards, holds and deposits given back</h2><p class="gd-p">On the booking&#39;s Money tab.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t"><b class="gd-ui">Charge the saved card</b>: a later charge (extra kilometres, fuel, damage, a late return) with the reason on the renter&#39;s receipt, or the deposit of a rental over 7 days.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">A deposit hold: <b class="gd-ui">Capture the hold</b> for all of it, with the reason. A part capture (the rest is released) or <b class="gd-ui">Release the hold</b> waits for the settlement while the car is out, inside the toll window or while something is open; an Admin may do it with the reason.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">A deposit taken in cash or by e-Transfer is given back the same way: the task Give the deposit back the way it came; then press <b class="gd-ui">Returned</b> with the reference or receipt number.</div></li></ol></div></section><section class="gd-task" id="finance-settle-a-deposit" data-gd-task><h2 class="gd-h2">Settle a deposit</h2><p class="gd-p">The deposit is never given back by itself. Finance or an Admin settles it after the return: on the booking&#39;s Money tab, under Deposit, press <b class="gd-ui">Settle the deposit</b>. Issue the Check-in statement first.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">The form shows the deposit, what is still available, the charges owed from the statement and what is taken from the deposit for them. What the deposit does not cover is charged to the card on file; with no card (or a card declined), the renter gets a pay link by email and text, and Finance has a task until it is paid.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Tolls and tickets can take up to 7 days to come in. Inside that window the whole rest of the deposit is filled in as the hold-back, until the window ends. To give it back sooner, tick Release now anyway: a toll that comes in later is charged to the card on file.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Something still open keeps the whole deposit: an incident, a claim, new damage at the return not priced, damage found later not billed, a toll or ticket on the car during the rental not matched or not charged, a card dispute, or charges not on a statement yet. The form lists them. Only an Admin can release part of it, with the reason; it is recorded.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">Damage: an Admin keeps the whole deposit (<b class="gd-ui">Keep the whole deposit (damage)</b>) or bills a damage charge up to the $2,500 deductible. Ask an Admin, with the photos.</div></li><li><span class="gd-n" aria-hidden="true">5</span><div class="gd-t">Press <b class="gd-ui">Settle</b>. The money moves at Stripe at once: the charges are collected and what is not owed is refunded or the hold released. A step Stripe refuses is tried again by itself, and Finance gets a task if it keeps failing.</div></li></ol></div><aside class="gd-box"><span class="gd-lbl">Good to know</span><div>A card hold lapses after about 7 days. While the car is out, or returned and not settled, the hold is collected in full a day and a half before it lapses: that keeps the money, and the settlement refunds what is not owed. A hold that lapses anyway is charged to the saved card, and Finance is told at once.</div></aside></section><section class="gd-task" id="finance-read-a-toll-notice" data-gd-task><h2 class="gd-h2">Read a toll notice</h2><div class="gd-stepblock gd-stepblock--below"><div class="gd-stepcol"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Open <b class="gd-ui">Tolls and tickets</b> and press <b class="gd-ui">Read a notice</b>.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Choose the file: a PDF, a photo or a CSV, under 15 MB. Leave the reading profile to find it from the text.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Press <b class="gd-ui">Read it</b>. Then check each line beside the notice and fix what was read wrong.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">Press <b class="gd-ui">Checked against the notice</b> on each line (<b class="gd-ui">Leave out</b> to skip one), then <b class="gd-ui">Save as checked</b> and <b class="gd-ui">Confirm and import</b>.</div></li></ol></div><figure class="gd-fig gd-fig--desk"><div class="gd-browser"><div class="gd-bar" aria-hidden="true"><i></i><i></i><i></i><span class="gd-addr">carmacars.ca/va/tolls/read</span></div><div class="gd-imgwrap" style="aspect-ratio:1230/580"><img src="/guides/img/va-finance-04-tolls-read-desktop-aa04a6b2.jpg" alt="" loading="lazy" decoding="async" width="1230" height="580"><span class="gd-pin" style="left:19.5%;top:44.1%" aria-hidden="true">2</span><span class="gd-pin" style="left:4.1%;top:64.8%" aria-hidden="true">3</span><span class="gd-pin" style="left:4.1%;top:89.7%" aria-hidden="true">4</span></div></div></figure></div><aside class="gd-box"><span class="gd-lbl">Tip</span><div>In the work queue, <b class="gd-ui">Match again</b> retries the match after a fix, and <b class="gd-ui">Dispute</b> marks a notice you think is wrong. Renters matched with high confidence are charged at import, with the notice and our fee.</div></aside><div class="gd-figblock"><figure class="gd-fig gd-fig--desk"><div class="gd-browser"><div class="gd-bar" aria-hidden="true"><i></i><i></i><i></i><span class="gd-addr">carmacars.ca/va/tolls</span></div><div class="gd-imgwrap" style="aspect-ratio:1230/540"><img src="/guides/img/va-finance-03-tolls-desktop-37b6f99c.jpg" alt="The work queue: Unmatched, Needs review, Matched not charged and Disputed, with each notice&#39;s plate, date, amount and match." loading="lazy" decoding="async" width="1230" height="540"><span class="gd-pin" style="left:23.6%;top:12.2%" aria-hidden="true">1</span></div></div><figcaption>The work queue: Unmatched, Needs review, Matched not charged and Disputed, with each notice&#39;s plate, date, amount and match.</figcaption></figure></div></section><section class="gd-task" id="finance-reconciliation-and-turo-trips" data-gd-task><h2 class="gd-h2">Reconciliation and Turo trips</h2><div class="gd-stepblock gd-stepblock--below"><div class="gd-stepcol"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t"><b class="gd-ui">Reconciliation</b>: press <b class="gd-ui">Record a processor payout</b>, then <b class="gd-ui">Match</b> it to the payments it contains. Anything still unmatched at the closing check goes to an Admin.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t"><b class="gd-ui">Turo trips</b>: press <b class="gd-ui">Add a trip</b> for one trip, or paste CSV rows and press <b class="gd-ui">Import</b>.</div></li></ol></div><figure class="gd-fig gd-fig--desk"><div class="gd-browser"><div class="gd-bar" aria-hidden="true"><i></i><i></i><i></i><span class="gd-addr">carmacars.ca/va/turo</span></div><div class="gd-imgwrap" style="aspect-ratio:1230/540"><img src="/guides/img/va-finance-06-turo-desktop-b59cc7f9.jpg" alt="" loading="lazy" decoding="async" width="1230" height="540"><span class="gd-pin" style="left:95.1%;top:14.8%" aria-hidden="true">2</span></div></div></figure></div></section><section class="gd-task" id="finance-deposits-to-release" data-gd-task><h2 class="gd-h2">Deposits to release</h2><p class="gd-p">A deposit is never released by itself. Each morning the system puts one task in your queue for every deposit due back: &quot;Release the deposit for&quot; the booking, with the amount and the day it is due (7 business days after the check-in, or after the return when no check-in was recorded). On the day, and every day after, you and the Admins also get a notice in the portal. Nothing is emailed.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Open the task: it opens the booking&#39;s <b class="gd-ui">Money</b> tab.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Settle the deposit: apply what is owed, hold back what an open item needs, release the rest.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">The task closes by itself once nothing is left to give back.</div></li></ol></div></section>');
select app.guide_release_section('va', 'fleet', 'chapter', 'finance', 'You keep the cars moving: field jobs, daily checks, photo reviews after returns, and the listing pipeline with its duplicate check and plate covering.

Your rail: Queue, Today, Field jobs, Field hours, Daily checks, Photo reviews, Calendar, Listings, Similar cars, Find a renter and Scorecard.

## Schedule field jobs

Every confirmed booking gets its handover (or delivery) and return (or pickup) jobs by itself, at the booking''s times and place, given to the field staff member with the fewest jobs that day. You check and change them.

1. Jobs, next three days: each with its place, its field staff and whether they acknowledged it. "Made from the booking" marks the ones made by themselves; when the booking moves, they move too, unless you changed them.
2. Change a job with **Assign**, **Reassign**, **Move** (time and place) or **Cancel**.
3. Handovers and returns without a job (when the automatic jobs are off, or one was cancelled) are listed first: press **Schedule**, the place filled in from the booking.
4. An Admin turns the automatic jobs or the assignment off in Settings > Program.

![](/guides/img/va-fleet-02-field-jobs-desktop-8e721230.jpg "desktop; size: 1230 565; address: carmacars.ca/va/fleet; pins: 1 17.9 51.3")

## Field hours

Field staff clock in and out on their phones. You see who is clocked in and every shift of the two-week pay period, and you fix what they cannot.

1. Open **Field hours**. **Clocked in now** lists who is on, since when. **Earlier period** and **Later period** move between pay periods.
2. Someone forgot to clock out: press **Clock out for them**, set the time they finished and write the reason.
3. Someone forgot to clock in, or a time is wrong: **Add hours** enters a shift, **Change** fixes one and **Remove** takes one out. Each needs a reason; the change is kept in a log with what it was before.
4. Once an Admin approves the pay run of a period, its shifts are locked: ask the Admin. You see hours only, not rates or pay.

## Daily checks

Twice a day: the opening check by 9:00 and the closing check by 18:00.

1. Open **Daily checks** and choose **Opening check** or **Closing check**.
2. Each line shows what was found. Tick OK, or Problem with a note.
3. Press **Save the opening check** (or **Save the closing check**). You can save it again.

![](/guides/img/va-fleet-03-daily-checks-desktop-be06d6c0.jpg "desktop; size: 1230 820; address: carmacars.ca/va/checks; pins: 1 6.5 15.4, 2 44.7 42.0, 3 64.2 94.0")

## Check a car out or in

Fleet, Sales and Customer service check cars out and in from the booking.

1. On a confirmed booking press **Check out (pickup)**; on a booking on rent, **Check in (return)**. Today lists the ones due, each with its button.
2. The checklist field staff use opens: readings (km and fuel or charge), the photo set with the plate and the gauges, damage close-ups and both signatures.
3. Afterwards press **Photo report**: times, Late by, kilometres, fuel, photos and the return charges. Fleet waives a charge with **Waive** and a reason.

## Photo reviews after a return

After each return, the field photo set waits under **Photo reviews**. Compare it with the pickup set. Press **Review done**, or **Ask for a re-shoot** if a photo is missing or unclear.

## Similar cars

A possible duplicate never keeps a car off the site: it shows on the car''s checklist until you decide. Only Same car takes it off.

1. Each flag shows the car, what it looks like (same VIN, plate, photo or specs) and the other car.
2. Compare the permit, the plate and the photos.
3. Press **Not a duplicate** with a note when they are different cars, or **Same car** when they are.

![](/guides/img/va-fleet-06-similar-cars-desktop-562b0382.jpg "desktop; size: 1230 460; address: carmacars.ca/va/similar-cars; pins: 1 23.6 30.4, 3 94.8 30.4")

## Rates and kilometres

From a listing, press **The car and its rates**, or open the car from Field jobs.

1. Type the rates an Admin set. Only the daily rate is needed; the others follow from it when empty. The weekend rate is a price per day for each day that starts on a Friday or Saturday.
2. Keep **Use the defaults** for the kilometres, or choose **Custom for this car**.
3. Check What renters pay under the fields, then press **Save the rates**. Rates, kilometres and deposit save together.

## Listings and covering plates

1. Open **Listings**. A draft waiting shows Needs review. Open it.
2. The copy is written by itself (change a line only if you must: it is then kept). Check the photos: on each public photo, cover the plate or mark it not visible.

![](/guides/img/va-fleet-05-listings-desktop-d2672e0a.jpg "desktop; size: 1230 340; address: carmacars.ca/va/listings; pins: 1 54.5 49.1")

3. Press **Cover the plate**. Check the suggested box; **Suggest the plate** asks again.
4. Drag over a plate to draw a box; drag a box to move it, its corner to resize it.
5. Choose **A CarmaCars plate**, **Pixelation** or **Blur**, then **Save the covered photo**.
6. No plate in the shot? **No plate visible on this photo**.

![](/guides/img/admin-11-plate-editor-phone-95d5afd2.jpg "phone; size: 390 776; pins: 3 52.6 78.9, 4 50.0 43.8, 5 61.5 62.1, 6 43.1 92.3")

> Watch out: The plate check never holds a car back: a photo whose plate is not checked stays private, and goes public by itself once it is covered or marked. The covered photo replaces the public one; the original is kept privately.

## Publish now

Customer service and fleet publish a car themselves; nothing has to be finished first.

1. Open the car from Listings or Field jobs. Its listing says why it is not on the site yet; press **Publish now**. With no rates yet it uses the suggested rates (similar cars, else the class defaults).
2. What is still open (paperwork, details, photos, No VIN yet for a car added by its plate, a possible duplicate) shows as warnings after Publish now and on the car. None of them stops publishing.
3. New cars with their rates usually go on the site by themselves (Publish new cars automatically, on by default). A car taken off the site by staff waits for Publish now.

> Tip: A car not on the fleet insurance policy yet can be requested, offered and paid for, but never handed over until the insurer confirms it. Requests and offers for such a car show a warning.

## Calendar sync with Turo and other platforms

**Cars** > **Calendar sync**: a car listed on Turo or Getaround must never be booked twice.

1. Turo has no calendar link: Turo''s trip emails come in by themselves, find their car by themselves (Turo car number, plate, VIN, year, make, model, trim, colour, what earlier emails taught) and block it with the turnaround. Nothing to set up per car.
2. An email the reader cannot place waits as "Which car is this?": press **Which car is this?** and press the right car (best guesses first). It is remembered for that car''s next emails. If the dates or trip number are missing: **Add as a Turo trip** (choose the car, check the dates) or **Dismiss**. A trip whose email did not come: **Add a Turo trip** on the car.
3. Each Turo trip shows the guest''s name and phone when Turo''s email includes them. Contact a Turo guest only about their trip, never with promotions.
4. Turo cannot read our calendar: under "Block on Turo", block each CarmaCars booking on the car''s Turo calendar, then press **Done on Turo**. Dates that changed or a booking cancelled here show the dates to free on Turo.
5. Getaround, Google Calendar or another platform with a calendar (iCal) link: open **Add a calendar link**, choose the platform, paste it and press **Add the link**. Copy the car''s CarmaCars link for that platform with **Copy** and paste it into the platform''s calendar import.
6. A double booking raises an urgent task for you and an email: move, swap or cancel one trip. A link that stops working raises a task after 3 failed reads: copy it from the platform again.
', 'Fleet', 'Field jobs, daily checks, photo reviews, similar cars and listings.',
  'You keep the cars moving: field jobs, daily checks, photo reviews after returns, and the listing pipeline with its duplicate check and plate covering.

Your rail: Queue, Today, Field jobs, Field hours, Daily checks, Photo reviews, Calendar, Listings, Similar cars, Find a renter and Scorecard.

## Schedule field jobs

Every confirmed booking gets its handover (or delivery) and return (or pickup) jobs by itself, at the booking''s times and place, given to the field staff member with the fewest jobs that day. You check and change them.

1. Jobs, next three days: each with its place, its field staff and whether they acknowledged it. "Made from the booking" marks the ones made by themselves; when the booking moves, they move too, unless you changed them.
2. Change a job with **Assign**, **Reassign**, **Move** (time and place) or **Cancel**.
3. Handovers and returns without a job (when the automatic jobs are off, or one was cancelled) are listed first: press **Schedule**, the place filled in from the booking.
4. An Admin turns the automatic jobs or the assignment off in Settings > Program.

![](/guides/img/va-fleet-02-field-jobs-desktop-8e721230.jpg "desktop; size: 1230 565; address: carmacars.ca/va/fleet; pins: 1 17.9 51.3")

## Field hours

Field staff clock in and out on their phones. You see who is clocked in and every shift of the two-week pay period, and you fix what they cannot.

1. Open **Field hours**. **Clocked in now** lists who is on, since when. **Earlier period** and **Later period** move between pay periods.
2. Someone forgot to clock out: press **Clock out for them**, set the time they finished and write the reason.
3. Someone forgot to clock in, or a time is wrong: **Add hours** enters a shift, **Change** fixes one and **Remove** takes one out. Each needs a reason; the change is kept in a log with what it was before.
4. Once an Admin approves the pay run of a period, its shifts are locked: ask the Admin. You see hours only, not rates or pay.

## Daily checks

Twice a day: the opening check by 9:00 and the closing check by 18:00.

1. Open **Daily checks** and choose **Opening check** or **Closing check**.
2. Each line shows what was found. Tick OK, or Problem with a note.
3. Press **Save the opening check** (or **Save the closing check**). You can save it again.

![](/guides/img/va-fleet-03-daily-checks-desktop-be06d6c0.jpg "desktop; size: 1230 820; address: carmacars.ca/va/checks; pins: 1 6.5 15.4, 2 44.7 42.0, 3 64.2 94.0")

## Check a car out or in

Fleet, Sales and Customer service check cars out and in from the booking.

1. On a confirmed booking press **Check out (pickup)**; on a booking on rent, **Check in (return)**. Today lists the ones due, each with its button.
2. The checklist field staff use opens: readings (km and fuel or charge), the photo set with the plate and the gauges, damage close-ups and both signatures.
3. Afterwards press **Photo report**: times, Late by, kilometres, fuel, photos and the return charges. Fleet waives a charge with **Waive** and a reason.

## Photo reviews after a return

After each return, the field photo set waits under **Photo reviews**. Compare it with the pickup set. Press **Review done**, or **Ask for a re-shoot** if a photo is missing or unclear.

## Similar cars

A possible duplicate never keeps a car off the site: it shows on the car''s checklist until you decide. Only Same car takes it off.

1. Each flag shows the car, what it looks like (same VIN, plate, photo or specs) and the other car.
2. Compare the permit, the plate and the photos.
3. Press **Not a duplicate** with a note when they are different cars, or **Same car** when they are.

![](/guides/img/va-fleet-06-similar-cars-desktop-562b0382.jpg "desktop; size: 1230 460; address: carmacars.ca/va/similar-cars; pins: 1 23.6 30.4, 3 94.8 30.4")

## Rates and kilometres

From a listing, press **The car and its rates**, or open the car from Field jobs.

1. Type the rates an Admin set. Only the daily rate is needed; the others follow from it when empty. The weekend rate is a price per day for each day that starts on a Friday or Saturday.
2. Keep **Use the defaults** for the kilometres, or choose **Custom for this car**.
3. Check What renters pay under the fields, then press **Save the rates**. Rates, kilometres and deposit save together.

## Listings and covering plates

1. Open **Listings**. A draft waiting shows Needs review. Open it.
2. The copy is written by itself (change a line only if you must: it is then kept). Check the photos: on each public photo, cover the plate or mark it not visible.

![](/guides/img/va-fleet-05-listings-desktop-d2672e0a.jpg "desktop; size: 1230 340; address: carmacars.ca/va/listings; pins: 1 54.5 49.1")

3. Press **Cover the plate**. Check the suggested box; **Suggest the plate** asks again.
4. Drag over a plate to draw a box; drag a box to move it, its corner to resize it.
5. Choose **A CarmaCars plate**, **Pixelation** or **Blur**, then **Save the covered photo**.
6. No plate in the shot? **No plate visible on this photo**.

![](/guides/img/admin-11-plate-editor-phone-95d5afd2.jpg "phone; size: 390 776; pins: 3 52.6 78.9, 4 50.0 43.8, 5 61.5 62.1, 6 43.1 92.3")

> Watch out: The plate check never holds a car back: a photo whose plate is not checked stays private, and goes public by itself once it is covered or marked. The covered photo replaces the public one; the original is kept privately.

## Publish now

Customer service and fleet publish a car themselves; nothing has to be finished first.

1. Open the car from Listings or Field jobs. Its listing says why it is not on the site yet; press **Publish now**. With no rates yet it uses the suggested rates (similar cars, else the class defaults).
2. What is still open (paperwork, details, photos, No VIN yet for a car added by its plate, a possible duplicate) shows as warnings after Publish now and on the car. None of them stops publishing.
3. New cars with their rates usually go on the site by themselves (Publish new cars automatically, on by default). A car taken off the site by staff waits for Publish now.

> Tip: A car not on the fleet insurance policy yet can be requested, offered and paid for, but never handed over until the insurer confirms it. Requests and offers for such a car show a warning.

## Calendar sync with Turo and other platforms

**Cars** > **Calendar sync**: a car listed on Turo or Getaround must never be booked twice.

1. Turo has no calendar link: Turo''s trip emails come in by themselves, find their car by themselves (Turo car number, plate, VIN, year, make, model, trim, colour, what earlier emails taught) and block it with the turnaround. Nothing to set up per car.
2. An email the reader cannot place waits as "Which car is this?": press **Which car is this?** and press the right car (best guesses first). It is remembered for that car''s next emails. If the dates or trip number are missing: **Add as a Turo trip** (choose the car, check the dates) or **Dismiss**. A trip whose email did not come: **Add a Turo trip** on the car.
3. Each Turo trip shows the guest''s name and phone when Turo''s email includes them. Contact a Turo guest only about their trip, never with promotions.
4. Turo cannot read our calendar: under "Block on Turo", block each CarmaCars booking on the car''s Turo calendar, then press **Done on Turo**. Dates that changed or a booking cancelled here show the dates to free on Turo.
5. Getaround, Google Calendar or another platform with a calendar (iCal) link: open **Add a calendar link**, choose the platform, paste it and press **Add the link**. Copy the car''s CarmaCars link for that platform with **Copy** and paste it into the platform''s calendar import.
6. A double booking raises an urgent task for you and an email: move, swap or cancel one trip. A link that stops working raises a task after 3 failed reads: copy it from the platform again.

### Add the photos and readings
A pickup or return recorded with the details later gives Fleet the task **Add the photos and readings for CC-...**. Open the booking and press **Add the check-out (or check-in) photos and readings**: the usual checklist opens without the ready check or the renter''s signature. Take the photos, the odometer, fuel, keys (and cleanliness at a return), sign and save. The task closes by itself; it cannot be closed by hand before.',
  '<p class="gd-p">You keep the cars moving: field jobs, daily checks, photo reviews after returns, and the listing pipeline with its duplicate check and plate covering.</p><p class="gd-p">Your rail: Queue, Today, Field jobs, Field hours, Daily checks, Photo reviews, Calendar, Listings, Similar cars, Find a renter and Scorecard.</p><section class="gd-task" id="fleet-schedule-field-jobs" data-gd-task><h2 class="gd-h2">Schedule field jobs</h2><p class="gd-p">Every confirmed booking gets its handover (or delivery) and return (or pickup) jobs by itself, at the booking&#39;s times and place, given to the field staff member with the fewest jobs that day. You check and change them.</p><div class="gd-stepblock gd-stepblock--below"><div class="gd-stepcol"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Jobs, next three days: each with its place, its field staff and whether they acknowledged it. &quot;Made from the booking&quot; marks the ones made by themselves; when the booking moves, they move too, unless you changed them.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Change a job with <b class="gd-ui">Assign</b>, <b class="gd-ui">Reassign</b>, <b class="gd-ui">Move</b> (time and place) or <b class="gd-ui">Cancel</b>.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Handovers and returns without a job (when the automatic jobs are off, or one was cancelled) are listed first: press <b class="gd-ui">Schedule</b>, the place filled in from the booking.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">An Admin turns the automatic jobs or the assignment off in Settings &gt; Program.</div></li></ol></div><figure class="gd-fig gd-fig--desk"><div class="gd-browser"><div class="gd-bar" aria-hidden="true"><i></i><i></i><i></i><span class="gd-addr">carmacars.ca/va/fleet</span></div><div class="gd-imgwrap" style="aspect-ratio:1230/565"><img src="/guides/img/va-fleet-02-field-jobs-desktop-8e721230.jpg" alt="" loading="lazy" decoding="async" width="1230" height="565"><span class="gd-pin" style="left:17.9%;top:51.3%" aria-hidden="true">1</span></div></div></figure></div></section><section class="gd-task" id="fleet-field-hours" data-gd-task><h2 class="gd-h2">Field hours</h2><p class="gd-p">Field staff clock in and out on their phones. You see who is clocked in and every shift of the two-week pay period, and you fix what they cannot.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Open <b class="gd-ui">Field hours</b>. <b class="gd-ui">Clocked in now</b> lists who is on, since when. <b class="gd-ui">Earlier period</b> and <b class="gd-ui">Later period</b> move between pay periods.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Someone forgot to clock out: press <b class="gd-ui">Clock out for them</b>, set the time they finished and write the reason.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Someone forgot to clock in, or a time is wrong: <b class="gd-ui">Add hours</b> enters a shift, <b class="gd-ui">Change</b> fixes one and <b class="gd-ui">Remove</b> takes one out. Each needs a reason; the change is kept in a log with what it was before.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">Once an Admin approves the pay run of a period, its shifts are locked: ask the Admin. You see hours only, not rates or pay.</div></li></ol></div></section><section class="gd-task" id="fleet-daily-checks" data-gd-task><h2 class="gd-h2">Daily checks</h2><p class="gd-p">Twice a day: the opening check by 9:00 and the closing check by 18:00.</p><div class="gd-stepblock gd-stepblock--below"><div class="gd-stepcol"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Open <b class="gd-ui">Daily checks</b> and choose <b class="gd-ui">Opening check</b> or <b class="gd-ui">Closing check</b>.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Each line shows what was found. Tick OK, or Problem with a note.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Press <b class="gd-ui">Save the opening check</b> (or <b class="gd-ui">Save the closing check</b>). You can save it again.</div></li></ol></div><figure class="gd-fig gd-fig--desk"><div class="gd-browser"><div class="gd-bar" aria-hidden="true"><i></i><i></i><i></i><span class="gd-addr">carmacars.ca/va/checks</span></div><div class="gd-imgwrap" style="aspect-ratio:1230/820"><img src="/guides/img/va-fleet-03-daily-checks-desktop-be06d6c0.jpg" alt="" loading="lazy" decoding="async" width="1230" height="820"><span class="gd-pin" style="left:6.5%;top:15.4%" aria-hidden="true">1</span><span class="gd-pin" style="left:44.7%;top:42%" aria-hidden="true">2</span><span class="gd-pin" style="left:64.2%;top:94%" aria-hidden="true">3</span></div></div></figure></div></section><section class="gd-task" id="fleet-check-a-car-out-or-in" data-gd-task><h2 class="gd-h2">Check a car out or in</h2><p class="gd-p">Fleet, Sales and Customer service check cars out and in from the booking.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">On a confirmed booking press <b class="gd-ui">Check out (pickup)</b>; on a booking on rent, <b class="gd-ui">Check in (return)</b>. Today lists the ones due, each with its button.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">The checklist field staff use opens: readings (km and fuel or charge), the photo set with the plate and the gauges, damage close-ups and both signatures.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Afterwards press <b class="gd-ui">Photo report</b>: times, Late by, kilometres, fuel, photos and the return charges. Fleet waives a charge with <b class="gd-ui">Waive</b> and a reason.</div></li></ol></div></section><section class="gd-task" id="fleet-photo-reviews-after-a-return" data-gd-task><h2 class="gd-h2">Photo reviews after a return</h2><p class="gd-p">After each return, the field photo set waits under <b class="gd-ui">Photo reviews</b>. Compare it with the pickup set. Press <b class="gd-ui">Review done</b>, or <b class="gd-ui">Ask for a re-shoot</b> if a photo is missing or unclear.</p></section><section class="gd-task" id="fleet-similar-cars" data-gd-task><h2 class="gd-h2">Similar cars</h2><p class="gd-p">A possible duplicate never keeps a car off the site: it shows on the car&#39;s checklist until you decide. Only Same car takes it off.</p><div class="gd-stepblock gd-stepblock--below"><div class="gd-stepcol"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Each flag shows the car, what it looks like (same VIN, plate, photo or specs) and the other car.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Compare the permit, the plate and the photos.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Press <b class="gd-ui">Not a duplicate</b> with a note when they are different cars, or <b class="gd-ui">Same car</b> when they are.</div></li></ol></div><figure class="gd-fig gd-fig--desk"><div class="gd-browser"><div class="gd-bar" aria-hidden="true"><i></i><i></i><i></i><span class="gd-addr">carmacars.ca/va/similar-cars</span></div><div class="gd-imgwrap" style="aspect-ratio:1230/460"><img src="/guides/img/va-fleet-06-similar-cars-desktop-562b0382.jpg" alt="" loading="lazy" decoding="async" width="1230" height="460"><span class="gd-pin" style="left:23.6%;top:30.4%" aria-hidden="true">1</span><span class="gd-pin" style="left:94.8%;top:30.4%" aria-hidden="true">3</span></div></div></figure></div></section><section class="gd-task" id="fleet-rates-and-kilometres" data-gd-task><h2 class="gd-h2">Rates and kilometres</h2><p class="gd-p">From a listing, press <b class="gd-ui">The car and its rates</b>, or open the car from Field jobs.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Type the rates an Admin set. Only the daily rate is needed; the others follow from it when empty. The weekend rate is a price per day for each day that starts on a Friday or Saturday.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Keep <b class="gd-ui">Use the defaults</b> for the kilometres, or choose <b class="gd-ui">Custom for this car</b>.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Check What renters pay under the fields, then press <b class="gd-ui">Save the rates</b>. Rates, kilometres and deposit save together.</div></li></ol></div></section><section class="gd-task" id="fleet-listings-and-covering-plates" data-gd-task><h2 class="gd-h2">Listings and covering plates</h2><div class="gd-stepblock gd-stepblock--below"><div class="gd-stepcol"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Open <b class="gd-ui">Listings</b>. A draft waiting shows Needs review. Open it.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">The copy is written by itself (change a line only if you must: it is then kept). Check the photos: on each public photo, cover the plate or mark it not visible.</div></li></ol></div><figure class="gd-fig gd-fig--desk"><div class="gd-browser"><div class="gd-bar" aria-hidden="true"><i></i><i></i><i></i><span class="gd-addr">carmacars.ca/va/listings</span></div><div class="gd-imgwrap" style="aspect-ratio:1230/340"><img src="/guides/img/va-fleet-05-listings-desktop-d2672e0a.jpg" alt="" loading="lazy" decoding="async" width="1230" height="340"><span class="gd-pin" style="left:54.5%;top:49.1%" aria-hidden="true">1</span></div></div></figure></div><div class="gd-stepblock gd-stepblock--side"><div class="gd-stepcol"><ol class="gd-ol" start="3"><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Press <b class="gd-ui">Cover the plate</b>. Check the suggested box; <b class="gd-ui">Suggest the plate</b> asks again.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">Drag over a plate to draw a box; drag a box to move it, its corner to resize it.</div></li><li><span class="gd-n" aria-hidden="true">5</span><div class="gd-t">Choose <b class="gd-ui">A CarmaCars plate</b>, <b class="gd-ui">Pixelation</b> or <b class="gd-ui">Blur</b>, then <b class="gd-ui">Save the covered photo</b>.</div></li><li><span class="gd-n" aria-hidden="true">6</span><div class="gd-t">No plate in the shot? <b class="gd-ui">No plate visible on this photo</b>.</div></li></ol></div><figure class="gd-fig gd-fig--phone"><div class="gd-phone"><div class="gd-imgwrap" style="aspect-ratio:390/776"><img src="/guides/img/admin-11-plate-editor-phone-95d5afd2.jpg" alt="" loading="lazy" decoding="async" width="390" height="776"><span class="gd-pin" style="left:52.6%;top:78.9%" aria-hidden="true">3</span><span class="gd-pin" style="left:50%;top:43.8%" aria-hidden="true">4</span><span class="gd-pin" style="left:61.5%;top:62.1%" aria-hidden="true">5</span><span class="gd-pin" style="left:43.1%;top:92.3%" aria-hidden="true">6</span></div></div></figure></div><aside class="gd-box gd-box--warn"><span class="gd-lbl">Watch out</span><div>The plate check never holds a car back: a photo whose plate is not checked stays private, and goes public by itself once it is covered or marked. The covered photo replaces the public one; the original is kept privately.</div></aside></section><section class="gd-task" id="fleet-publish-now" data-gd-task><h2 class="gd-h2">Publish now</h2><p class="gd-p">Customer service and fleet publish a car themselves; nothing has to be finished first.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Open the car from Listings or Field jobs. Its listing says why it is not on the site yet; press <b class="gd-ui">Publish now</b>. With no rates yet it uses the suggested rates (similar cars, else the class defaults).</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">What is still open (paperwork, details, photos, No VIN yet for a car added by its plate, a possible duplicate) shows as warnings after Publish now and on the car. None of them stops publishing.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">New cars with their rates usually go on the site by themselves (Publish new cars automatically, on by default). A car taken off the site by staff waits for Publish now.</div></li></ol></div><aside class="gd-box"><span class="gd-lbl">Tip</span><div>A car not on the fleet insurance policy yet can be requested, offered and paid for, but never handed over until the insurer confirms it. Requests and offers for such a car show a warning.</div></aside></section><section class="gd-task" id="fleet-calendar-sync-with-turo-and-other-platforms" data-gd-task><h2 class="gd-h2">Calendar sync with Turo and other platforms</h2><p class="gd-p"><b class="gd-ui">Cars</b> &gt; <b class="gd-ui">Calendar sync</b>: a car listed on Turo or Getaround must never be booked twice.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Turo has no calendar link: Turo&#39;s trip emails come in by themselves, find their car by themselves (Turo car number, plate, VIN, year, make, model, trim, colour, what earlier emails taught) and block it with the turnaround. Nothing to set up per car.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">An email the reader cannot place waits as &quot;Which car is this?&quot;: press <b class="gd-ui">Which car is this?</b> and press the right car (best guesses first). It is remembered for that car&#39;s next emails. If the dates or trip number are missing: <b class="gd-ui">Add as a Turo trip</b> (choose the car, check the dates) or <b class="gd-ui">Dismiss</b>. A trip whose email did not come: <b class="gd-ui">Add a Turo trip</b> on the car.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Each Turo trip shows the guest&#39;s name and phone when Turo&#39;s email includes them. Contact a Turo guest only about their trip, never with promotions.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">Turo cannot read our calendar: under &quot;Block on Turo&quot;, block each CarmaCars booking on the car&#39;s Turo calendar, then press <b class="gd-ui">Done on Turo</b>. Dates that changed or a booking cancelled here show the dates to free on Turo.</div></li><li><span class="gd-n" aria-hidden="true">5</span><div class="gd-t">Getaround, Google Calendar or another platform with a calendar (iCal) link: open <b class="gd-ui">Add a calendar link</b>, choose the platform, paste it and press <b class="gd-ui">Add the link</b>. Copy the car&#39;s CarmaCars link for that platform with <b class="gd-ui">Copy</b> and paste it into the platform&#39;s calendar import.</div></li><li><span class="gd-n" aria-hidden="true">6</span><div class="gd-t">A double booking raises an urgent task for you and an email: move, swap or cancel one trip. A link that stops working raises a task after 3 failed reads: copy it from the platform again.</div></li></ol></div><h3 class="gd-h3">Add the photos and readings</h3><p class="gd-p">A pickup or return recorded with the details later gives Fleet the task <b class="gd-ui">Add the photos and readings for CC-...</b>. Open the booking and press <b class="gd-ui">Add the check-out (or check-in) photos and readings</b>: the usual checklist opens without the ready check or the renter&#39;s signature. Take the photos, the odometer, fuel, keys (and cleanliness at a return), sign and save. The task closes by itself; it cannot be closed by hand before.</p></section>');
select app.guide_release_section('va', 'sales', 'chapter', 'fleet', 'You turn enquiries into bookings and owners into fleet: requests and offers, quotes for callers, and owner leads.

Your menu: To do, Today, My scorecard and My sales, then Requests and offers, Send an offer, Add a rental, New quote, Calendar and Owner leads.

## Requests, offers and new quotes

1. **Requests and offers**: the same queue customer service works. Answer requests and follow offers out.
2. **Send an offer**: one screen for a caller, sent at once, as in chapter 2. **New quote** still makes a request to offer later.
3. An offer that is out: **Edit the offer**, then **Save and send the update**.

![](/guides/img/va-sales-02-requests-desktop-2ab1d17d.jpg "desktop; size: 1230 580; address: carmacars.ca/va/requests; pins: 1 39.8 59.5")

> Tip: Your first reply target is 5 minutes, the "Quote sent" measure on your scorecard. Follow every offer out before it expires.

## Check the renter''s licence

Sales approve the renter''s licence like customer service: the licence front, the licence back and the selfie. The proof of coverage and the Protection Plan stay with customer service and Admins.

1. On **My work** > **To do**, **Licences to check** lists each booking with an image waiting, the longest wait first. Press **Review the licence**.
2. On a booking, the card **Renter licence** has the same: press **Review the licence**.
3. Look at each image: the name and date of birth match the booking, class G2 or G, valid past the return, no alteration, the selfie matches the licence photo.
4. One is wrong? Open **Reject this one** under it, type the reason the renter reads and press **Reject**. The renter is told and asked for a new image.
5. Then press **Approve all**: every image still waiting is approved at once. An image the system refuses is named with the reason.

> Tip: The booking history says who decided and the role, sales. Each opening of the images is logged and the links last one minute.

## In person or remote

Every Sales person works in one of two modes, on the same Sales screens. An Admin sets yours; it shows at the top of To do and on My sales.

|  | In person (Toronto) | Remote (anywhere) |
| --- | --- | --- |
| Commission | Under 50 rental days in the month 10%, from 50 days 15%, from 100 days 20% | Under 50 rental days 5%, from 50 days 10%, from 100 days 15% |
| Credit | Walk-ins, handovers you close, partner visits and the rentals you source | Only the rentals you source. A website request you answer with the first offer during one of your blocks counts as yours. Walk-ins and partner deals earn nothing |
| Hours | You choose | At least 20 hours a week of Thursday to Sunday afternoons (noon to 6 pm, Toronto time), replying within 15 minutes to the chats, texts and calls assigned to you |
| Every day | Nothing set | Marketplace and classified reposts, social media DM replies, three follow-ups on every quote, long-term and business outreach |
| Every month | Nothing set | 400 touches. Under 400 when the month ends, the month''s rate is one tier lower: 15% becomes 10%, 10% becomes 5%, 5% becomes 2.5% |

## Remote: your duties

On **My work** > **To do**, **Remote duties** shows this month''s touches against 400, today''s checklist, the peak hours you scheduled this week and your reply time.

1. Most touches count by themselves: an offer you send, a message or text you send from the portal, a live chat you answer (once a day for each chat), a call or text from the phone line, an ad you post, a call or message to a car owner.
2. For anything else press **Log a touch**: choose the type and add the link of the post, profile or listing if there is one.
3. The checklist ticks itself as the day''s touches come in. Three follow-ups on every quote stays open while a deal of yours has fewer than three.
4. Under My availability choose this week or next, press **Add a block** for each time you will be on, then **Save the week**. Days already past stay as they were.
5. A website request you answer with the first offer during a block is credited to you as sourced, even if you chose Entered for CarmaCars. Off your blocks it stays a claim for an Admin.

> Tip: An Admin can void a touch logged by mistake. Once an Admin approves a month, its mode, its rates and its touches no longer change; a refund can still lower the tier, as for everyone.

## My sales

Open **My work** > **My sales**. It shows your own sales and commissions only.

1. Commissions comes first. Your rate depends on your mode and the rental days of the month: in person 10%, 15% from 50 days, 20% from 100; remote 5%, 10% and 15%. The bar shows your days against the target of 100, and says when your rate rises. By month gives each month in one line: the mode, the days, the rate and, for remote, the touches and any drop.
2. The tiles show this week: quotes created, offers sent, rentals added, bookings confirmed, conversion, booked revenue and follow-ups due. Press **By month** for months, **By week** for weeks.
3. By week (or By month) lists each period with the same figures, newest first.
4. Follow-ups due lists your open deals with what to do next: send the offer, follow up before the offer expires, or follow up while the renter signs and pays. Red means it is past due.
5. Deals lists every booking you created, added or sent an offer on in the last 180 days, with its status and what it counts. Open a request, an offer or a rental you added from its number.

| Figure | How it is counted |
| --- | --- |
| Credited to you | A quote you created, a rental you added, or a website request whose first offer you sent. An Admin can give a deal to someone else. |
| Quotes created, offers sent, rentals added | Counted on the day they happened. |
| Bookings confirmed, booked revenue | Counted on the day the booking was confirmed. |
| Conversion | Of the deals credited to you in the period, the share confirmed so far. |
| Booked revenue | The rental charge before tax, after discounts. A cancelled booking counts only what was kept; refunds come off. |
| Rental days (Sales) | The days of the completed, paid rentals you sourced that end in the month. The month''s tier applies to all of that month''s rentals. |

> Tip: Sales commissions are approved after the month ends, when the month''s tier is known. A refund that drops the month under a tier lowers every commission of that month; anything already paid comes off your next payment.

## Owner leads

1. Owner leads: each enquiry with the name, contact, car and status.
2. Press **Take it** to make it yours, then call the owner.
3. Press **Update** to set the status. When you close a lead, say why.
4. Owner applications, last 90 days, shows who applied and how far onboarding has come.

![](/guides/img/va-sales-04-leads-desktop-3402e913.jpg "desktop; size: 1230 400; address: carmacars.ca/va/leads; pins: 1 6.5 26.5, 3 94.8 44.0, 4 15.4 63.0")
', 'Sales', 'Requests and offers, new quotes and owner leads.',
  'You turn enquiries into bookings and owners into fleet: requests and offers, quotes for callers, and owner leads.

Your menu: To do, Today, My scorecard and My sales, then Requests and offers, Send an offer, Add a rental, New quote, Calendar and Owner leads.

## Requests, offers and new quotes

1. **Requests and offers**: the same queue customer service works. Answer requests and follow offers out.
2. **Send an offer**: one screen for a caller, sent at once, as in chapter 2. **New quote** still makes a request to offer later.
3. An offer that is out: **More actions** > **Edit the offer**, then **Save and send the update**.

![](/guides/img/va-sales-02-requests-desktop-2ab1d17d.jpg "desktop; size: 1230 580; address: carmacars.ca/va/requests; pins: 1 39.8 59.5")

> Tip: Your first reply target is 5 minutes, the "Quote sent" measure on your scorecard. Follow every offer out before it expires.

## Check the renter''s licence

Sales approve the renter''s licence like customer service: the licence front, the licence back and the selfie. The proof of coverage and the Protection Plan stay with customer service and Admins.

1. On **My work** > **To do**, **Licences to check** lists each booking with an image waiting, the longest wait first. Press **Review the licence**.
2. On a booking, the card **Renter licence** has the same: press **Review the licence**.
3. Look at each image: the name and date of birth match the booking, class G2 or G, valid past the return, no alteration, the selfie matches the licence photo.
4. One is wrong? Open **Reject this one** under it, type the reason the renter reads and press **Reject**. The renter is told and asked for a new image.
5. Then press **Approve all**: every image still waiting is approved at once. An image the system refuses is named with the reason.

> Tip: The booking history says who decided and the role, sales. Each opening of the images is logged and the links last one minute.

## In person or remote

Every Sales person works in one of two modes, on the same Sales screens. An Admin sets yours; it shows at the top of To do and on My sales.

|  | In person (Toronto) | Remote (anywhere) |
| --- | --- | --- |
| Commission | Under 50 rental days in the month 10%, from 50 days 15%, from 100 days 20% | Under 50 rental days 5%, from 50 days 10%, from 100 days 15% |
| Credit | Walk-ins, handovers you close, partner visits and the rentals you source | Only the rentals you source. A website request you answer with the first offer during one of your blocks counts as yours. Walk-ins and partner deals earn nothing |
| Hours | You choose | At least 20 hours a week of Thursday to Sunday afternoons (noon to 6 pm, Toronto time), replying within 15 minutes to the chats, texts and calls assigned to you |
| Every day | Nothing set | Marketplace and classified reposts, social media DM replies, three follow-ups on every quote, long-term and business outreach |
| Every month | Nothing set | 400 touches. Under 400 when the month ends, the month''s rate is one tier lower: 15% becomes 10%, 10% becomes 5%, 5% becomes 2.5% |

## Remote: your duties

On **My work** > **To do**, **Remote duties** shows this month''s touches against 400, today''s checklist, the peak hours you scheduled this week and your reply time.

1. Most touches count by themselves: an offer you send, a message or text you send from the portal, a live chat you answer (once a day for each chat), a call or text from the phone line, an ad you post, a call or message to a car owner.
2. For anything else press **Log a touch**: choose the type and add the link of the post, profile or listing if there is one.
3. The checklist ticks itself as the day''s touches come in. Three follow-ups on every quote stays open while a deal of yours has fewer than three.
4. Under My availability choose this week or next, press **Add a block** for each time you will be on, then **Save the week**. Days already past stay as they were.
5. A website request you answer with the first offer during a block is credited to you as sourced, even if you chose Entered for CarmaCars. Off your blocks it stays a claim for an Admin.

> Tip: An Admin can void a touch logged by mistake. Once an Admin approves a month, its mode, its rates and its touches no longer change; a refund can still lower the tier, as for everyone.

## My sales

Open **My work** > **My sales**. It shows your own sales and commissions only.

1. Commissions comes first. Your rate depends on your mode and the rental days of the month: in person 10%, 15% from 50 days, 20% from 100; remote 5%, 10% and 15%. The bar shows your days against the target of 100, and says when your rate rises. By month gives each month in one line: the mode, the days, the rate and, for remote, the touches and any drop.
2. The tiles show this week: quotes created, offers sent, rentals added, bookings confirmed, conversion, booked revenue and follow-ups due. Press **By month** for months, **By week** for weeks.
3. By week (or By month) lists each period with the same figures, newest first.
4. Follow-ups due lists your open deals with what to do next: send the offer, follow up before the offer expires, or follow up while the renter signs and pays. Red means it is past due.
5. Deals lists every booking you created, added or sent an offer on in the last 180 days, with its status and what it counts. Open a request, an offer or a rental you added from its number.

| Figure | How it is counted |
| --- | --- |
| Credited to you | A quote you created, a rental you added, or a website request whose first offer you sent. An Admin can give a deal to someone else. |
| Quotes created, offers sent, rentals added | Counted on the day they happened. |
| Bookings confirmed, booked revenue | Counted on the day the booking was confirmed. |
| Conversion | Of the deals credited to you in the period, the share confirmed so far. |
| Booked revenue | The rental charge before tax, after discounts. A cancelled booking counts only what was kept; refunds come off. |
| Rental days (Sales) | The days of the completed, paid rentals you sourced that end in the month. The month''s tier applies to all of that month''s rentals. |

> Tip: Sales commissions are approved after the month ends, when the month''s tier is known. A refund that drops the month under a tier lowers every commission of that month; anything already paid comes off your next payment.

## Owner leads

1. Owner leads: each enquiry with the name, contact, car and status.
2. Press **Take it** to make it yours, then call the owner.
3. Press **Update** to set the status. When you close a lead, say why.
4. Owner applications, last 90 days, shows who applied and how far onboarding has come.

![](/guides/img/va-sales-04-leads-desktop-3402e913.jpg "desktop; size: 1230 400; address: carmacars.ca/va/leads; pins: 1 6.5 26.5, 3 94.8 44.0, 4 15.4 63.0")
',
  '<p class="gd-p">You turn enquiries into bookings and owners into fleet: requests and offers, quotes for callers, and owner leads.</p><p class="gd-p">Your menu: To do, Today, My scorecard and My sales, then Requests and offers, Send an offer, Add a rental, New quote, Calendar and Owner leads.</p><section class="gd-task" id="sales-requests-offers-and-new-quotes" data-gd-task><h2 class="gd-h2">Requests, offers and new quotes</h2><div class="gd-stepblock gd-stepblock--below"><div class="gd-stepcol"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t"><b class="gd-ui">Requests and offers</b>: the same queue customer service works. Answer requests and follow offers out.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t"><b class="gd-ui">Send an offer</b>: one screen for a caller, sent at once, as in chapter 2. <b class="gd-ui">New quote</b> still makes a request to offer later.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">An offer that is out: <b class="gd-ui">More actions</b> &gt; <b class="gd-ui">Edit the offer</b>, then <b class="gd-ui">Save and send the update</b>.</div></li></ol></div><figure class="gd-fig gd-fig--desk"><div class="gd-browser"><div class="gd-bar" aria-hidden="true"><i></i><i></i><i></i><span class="gd-addr">carmacars.ca/va/requests</span></div><div class="gd-imgwrap" style="aspect-ratio:1230/580"><img src="/guides/img/va-sales-02-requests-desktop-2ab1d17d.jpg" alt="" loading="lazy" decoding="async" width="1230" height="580"><span class="gd-pin" style="left:39.8%;top:59.5%" aria-hidden="true">1</span></div></div></figure></div><aside class="gd-box"><span class="gd-lbl">Tip</span><div>Your first reply target is 5 minutes, the &quot;Quote sent&quot; measure on your scorecard. Follow every offer out before it expires.</div></aside></section><section class="gd-task" id="sales-check-the-renter-s-licence" data-gd-task><h2 class="gd-h2">Check the renter&#39;s licence</h2><p class="gd-p">Sales approve the renter&#39;s licence like customer service: the licence front, the licence back and the selfie. The proof of coverage and the Protection Plan stay with customer service and Admins.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">On <b class="gd-ui">My work</b> &gt; <b class="gd-ui">To do</b>, <b class="gd-ui">Licences to check</b> lists each booking with an image waiting, the longest wait first. Press <b class="gd-ui">Review the licence</b>.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">On a booking, the card <b class="gd-ui">Renter licence</b> has the same: press <b class="gd-ui">Review the licence</b>.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Look at each image: the name and date of birth match the booking, class G2 or G, valid past the return, no alteration, the selfie matches the licence photo.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">One is wrong? Open <b class="gd-ui">Reject this one</b> under it, type the reason the renter reads and press <b class="gd-ui">Reject</b>. The renter is told and asked for a new image.</div></li><li><span class="gd-n" aria-hidden="true">5</span><div class="gd-t">Then press <b class="gd-ui">Approve all</b>: every image still waiting is approved at once. An image the system refuses is named with the reason.</div></li></ol></div><aside class="gd-box"><span class="gd-lbl">Tip</span><div>The booking history says who decided and the role, sales. Each opening of the images is logged and the links last one minute.</div></aside></section><section class="gd-task" id="sales-in-person-or-remote" data-gd-task><h2 class="gd-h2">In person or remote</h2><p class="gd-p">Every Sales person works in one of two modes, on the same Sales screens. An Admin sets yours; it shows at the top of To do and on My sales.</p><div class="gd-tablewrap"><table class="gd-table"><thead><tr><th scope="col"></th><th scope="col">In person (Toronto)</th><th scope="col">Remote (anywhere)</th></tr></thead><tbody><tr><td>Commission</td><td>Under 50 rental days in the month 10%, from 50 days 15%, from 100 days 20%</td><td>Under 50 rental days 5%, from 50 days 10%, from 100 days 15%</td></tr><tr><td>Credit</td><td>Walk-ins, handovers you close, partner visits and the rentals you source</td><td>Only the rentals you source. A website request you answer with the first offer during one of your blocks counts as yours. Walk-ins and partner deals earn nothing</td></tr><tr><td>Hours</td><td>You choose</td><td>At least 20 hours a week of Thursday to Sunday afternoons (noon to 6 pm, Toronto time), replying within 15 minutes to the chats, texts and calls assigned to you</td></tr><tr><td>Every day</td><td>Nothing set</td><td>Marketplace and classified reposts, social media DM replies, three follow-ups on every quote, long-term and business outreach</td></tr><tr><td>Every month</td><td>Nothing set</td><td>400 touches. Under 400 when the month ends, the month&#39;s rate is one tier lower: 15% becomes 10%, 10% becomes 5%, 5% becomes 2.5%</td></tr></tbody></table></div></section><section class="gd-task" id="sales-remote-your-duties" data-gd-task><h2 class="gd-h2">Remote: your duties</h2><p class="gd-p">On <b class="gd-ui">My work</b> &gt; <b class="gd-ui">To do</b>, <b class="gd-ui">Remote duties</b> shows this month&#39;s touches against 400, today&#39;s checklist, the peak hours you scheduled this week and your reply time.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Most touches count by themselves: an offer you send, a message or text you send from the portal, a live chat you answer (once a day for each chat), a call or text from the phone line, an ad you post, a call or message to a car owner.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">For anything else press <b class="gd-ui">Log a touch</b>: choose the type and add the link of the post, profile or listing if there is one.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">The checklist ticks itself as the day&#39;s touches come in. Three follow-ups on every quote stays open while a deal of yours has fewer than three.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">Under My availability choose this week or next, press <b class="gd-ui">Add a block</b> for each time you will be on, then <b class="gd-ui">Save the week</b>. Days already past stay as they were.</div></li><li><span class="gd-n" aria-hidden="true">5</span><div class="gd-t">A website request you answer with the first offer during a block is credited to you as sourced, even if you chose Entered for CarmaCars. Off your blocks it stays a claim for an Admin.</div></li></ol></div><aside class="gd-box"><span class="gd-lbl">Tip</span><div>An Admin can void a touch logged by mistake. Once an Admin approves a month, its mode, its rates and its touches no longer change; a refund can still lower the tier, as for everyone.</div></aside></section><section class="gd-task" id="sales-my-sales" data-gd-task><h2 class="gd-h2">My sales</h2><p class="gd-p">Open <b class="gd-ui">My work</b> &gt; <b class="gd-ui">My sales</b>. It shows your own sales and commissions only.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Commissions comes first. Your rate depends on your mode and the rental days of the month: in person 10%, 15% from 50 days, 20% from 100; remote 5%, 10% and 15%. The bar shows your days against the target of 100, and says when your rate rises. By month gives each month in one line: the mode, the days, the rate and, for remote, the touches and any drop.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">The tiles show this week: quotes created, offers sent, rentals added, bookings confirmed, conversion, booked revenue and follow-ups due. Press <b class="gd-ui">By month</b> for months, <b class="gd-ui">By week</b> for weeks.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">By week (or By month) lists each period with the same figures, newest first.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">Follow-ups due lists your open deals with what to do next: send the offer, follow up before the offer expires, or follow up while the renter signs and pays. Red means it is past due.</div></li><li><span class="gd-n" aria-hidden="true">5</span><div class="gd-t">Deals lists every booking you created, added or sent an offer on in the last 180 days, with its status and what it counts. Open a request, an offer or a rental you added from its number.</div></li></ol></div><div class="gd-tablewrap"><table class="gd-table"><thead><tr><th scope="col">Figure</th><th scope="col">How it is counted</th></tr></thead><tbody><tr><td>Credited to you</td><td>A quote you created, a rental you added, or a website request whose first offer you sent. An Admin can give a deal to someone else.</td></tr><tr><td>Quotes created, offers sent, rentals added</td><td>Counted on the day they happened.</td></tr><tr><td>Bookings confirmed, booked revenue</td><td>Counted on the day the booking was confirmed.</td></tr><tr><td>Conversion</td><td>Of the deals credited to you in the period, the share confirmed so far.</td></tr><tr><td>Booked revenue</td><td>The rental charge before tax, after discounts. A cancelled booking counts only what was kept; refunds come off.</td></tr><tr><td>Rental days (Sales)</td><td>The days of the completed, paid rentals you sourced that end in the month. The month&#39;s tier applies to all of that month&#39;s rentals.</td></tr></tbody></table></div><aside class="gd-box"><span class="gd-lbl">Tip</span><div>Sales commissions are approved after the month ends, when the month&#39;s tier is known. A refund that drops the month under a tier lowers every commission of that month; anything already paid comes off your next payment.</div></aside></section><section class="gd-task" id="sales-owner-leads" data-gd-task><h2 class="gd-h2">Owner leads</h2><div class="gd-stepblock gd-stepblock--below"><div class="gd-stepcol"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Owner leads: each enquiry with the name, contact, car and status.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Press <b class="gd-ui">Take it</b> to make it yours, then call the owner.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Press <b class="gd-ui">Update</b> to set the status. When you close a lead, say why.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">Owner applications, last 90 days, shows who applied and how far onboarding has come.</div></li></ol></div><figure class="gd-fig gd-fig--desk"><div class="gd-browser"><div class="gd-bar" aria-hidden="true"><i></i><i></i><i></i><span class="gd-addr">carmacars.ca/va/leads</span></div><div class="gd-imgwrap" style="aspect-ratio:1230/400"><img src="/guides/img/va-sales-04-leads-desktop-3402e913.jpg" alt="" loading="lazy" decoding="async" width="1230" height="400"><span class="gd-pin" style="left:6.5%;top:26.5%" aria-hidden="true">1</span><span class="gd-pin" style="left:94.8%;top:44%" aria-hidden="true">3</span><span class="gd-pin" style="left:15.4%;top:63%" aria-hidden="true">4</span></div></div></figure></div></section>');
select app.guide_release_section('va', 'shared-tools', 'chapter', 'car-maintenance', 'Every function has the calendar and Find a renter. Use them to answer questions fast.

## The calendar

1. Every car, its bookings, requests and blocks. The red line is now.
2. Use the arrows, Today and the range to move around, or search by plate, booking or name.
3. Fleet and customer service can remove a cleaning block from its side panel (**Remove the block**) when a car is ready sooner.

![](/guides/img/va-cs-09-calendar-desktop-541a6da5.jpg "desktop; size: 1230 800; address: carmacars.ca/va/calendar; pins: 1 60.2 33.8, 2 28.5 17.5")

## Find a car

**Bookings** > **Find a car** (Finance and Fleet: **Rentals** > **Find a car**). A renter quotes the car code on the car''s page (like CC-7F3A).

1. Type the car code, a plate, a VIN or the name. Each car shows its code, plate, status and its page on the site.
2. In Add a rental, type the car code or plate in the box above Car to choose it.

## Find a renter

1. Search by name, email, phone or booking number.
2. Opening a renter''s private details asks for a reason (**Open with a reason**). It is kept in the access log.

![](/guides/img/va-cs-07-renters-desktop-99cfd0ef.jpg "desktop; size: 1230 240; address: carmacars.ca/va/renters; pins: 1 68.3 34.6")
', 'Shared tools', 'The calendar and Find a renter.',
  'Every function has the calendar and Find a renter. Use them to answer questions fast.

## The calendar

1. Every car, its bookings, requests and blocks. The red line is now.
2. Use the arrows, Today and the range to move around, or search by plate, booking or name.
3. Fleet and customer service can remove a cleaning block from its side panel (**Remove the block**) when a car is ready sooner.

![](/guides/img/va-cs-09-calendar-desktop-541a6da5.jpg "desktop; size: 1230 800; address: carmacars.ca/va/calendar; pins: 1 60.2 33.8, 2 28.5 17.5")

## Find a car

**Bookings** > **Find a car** (Finance and Fleet: **Rentals** > **Find a car**). A renter quotes the car code on the car''s page (like CC-7F3A).

1. Type the car code, a plate, a VIN or the name. Each car shows its code, plate, status and its page on the site.
2. In Add a rental, type the car code or plate in the box above Car to choose it.

## Find a renter

1. Search by name, email, phone or booking number.
2. Opening a renter''s private details asks for a reason (**Open with a reason**). It is kept in the access log.

![](/guides/img/va-cs-07-renters-desktop-99cfd0ef.jpg "desktop; size: 1230 240; address: carmacars.ca/va/renters; pins: 1 68.3 34.6")

## Email the renter

Customer service, Sales, Fleet and Finance can all write to the renter from a booking: press **Email the renter**, or open the **Messages** tab.

1. Write a **Subject** and a **Message**, or pick a **Quick reply** to start from.
2. Press **Email the renter**. It goes from CarmaCars and the renter can answer in their account; the answer opens a task for customer service.
3. On a booking an insurer pays you can choose Blind Spot Car Rental (insurance) as the sender, and **Email the adjuster** writes to the adjuster on the booking.

The tab lists the messages both ways and every email of the booking with its state. Each email counts against the daily email limit, shown under the form.',
  '<p class="gd-p">Every function has the calendar and Find a renter. Use them to answer questions fast.</p><section class="gd-task" id="shared-tools-the-calendar" data-gd-task><h2 class="gd-h2">The calendar</h2><div class="gd-stepblock gd-stepblock--below"><div class="gd-stepcol"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Every car, its bookings, requests and blocks. The red line is now.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Use the arrows, Today and the range to move around, or search by plate, booking or name.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Fleet and customer service can remove a cleaning block from its side panel (<b class="gd-ui">Remove the block</b>) when a car is ready sooner.</div></li></ol></div><figure class="gd-fig gd-fig--desk"><div class="gd-browser"><div class="gd-bar" aria-hidden="true"><i></i><i></i><i></i><span class="gd-addr">carmacars.ca/va/calendar</span></div><div class="gd-imgwrap" style="aspect-ratio:1230/800"><img src="/guides/img/va-cs-09-calendar-desktop-541a6da5.jpg" alt="" loading="lazy" decoding="async" width="1230" height="800"><span class="gd-pin" style="left:60.2%;top:33.8%" aria-hidden="true">1</span><span class="gd-pin" style="left:28.5%;top:17.5%" aria-hidden="true">2</span></div></div></figure></div></section><section class="gd-task" id="shared-tools-find-a-car" data-gd-task><h2 class="gd-h2">Find a car</h2><p class="gd-p"><b class="gd-ui">Bookings</b> &gt; <b class="gd-ui">Find a car</b> (Finance and Fleet: <b class="gd-ui">Rentals</b> &gt; <b class="gd-ui">Find a car</b>). A renter quotes the car code on the car&#39;s page (like CC-7F3A).</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Type the car code, a plate, a VIN or the name. Each car shows its code, plate, status and its page on the site.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">In Add a rental, type the car code or plate in the box above Car to choose it.</div></li></ol></div></section><section class="gd-task" id="shared-tools-find-a-renter" data-gd-task><h2 class="gd-h2">Find a renter</h2><div class="gd-stepblock gd-stepblock--below"><div class="gd-stepcol"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Search by name, email, phone or booking number.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Opening a renter&#39;s private details asks for a reason (<b class="gd-ui">Open with a reason</b>). It is kept in the access log.</div></li></ol></div><figure class="gd-fig gd-fig--desk"><div class="gd-browser"><div class="gd-bar" aria-hidden="true"><i></i><i></i><i></i><span class="gd-addr">carmacars.ca/va/renters</span></div><div class="gd-imgwrap" style="aspect-ratio:1230/240"><img src="/guides/img/va-cs-07-renters-desktop-99cfd0ef.jpg" alt="" loading="lazy" decoding="async" width="1230" height="240"><span class="gd-pin" style="left:68.3%;top:34.6%" aria-hidden="true">1</span></div></div></figure></div></section><section class="gd-task" id="shared-tools-email-the-renter" data-gd-task><h2 class="gd-h2">Email the renter</h2><p class="gd-p">Customer service, Sales, Fleet and Finance can all write to the renter from a booking: press <b class="gd-ui">Email the renter</b>, or open the <b class="gd-ui">Messages</b> tab.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Write a <b class="gd-ui">Subject</b> and a <b class="gd-ui">Message</b>, or pick a <b class="gd-ui">Quick reply</b> to start from.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Press <b class="gd-ui">Email the renter</b>. It goes from CarmaCars and the renter can answer in their account; the answer opens a task for customer service.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">On a booking an insurer pays you can choose Blind Spot Car Rental (insurance) as the sender, and <b class="gd-ui">Email the adjuster</b> writes to the adjuster on the booking.</div></li></ol></div><p class="gd-p">The tab lists the messages both ways and every email of the booking with its state. Each email counts against the daily email limit, shown under the form.</p></section>');
select app.guide_release_section('field', 'start-here', 'start', null, '### Who this guide is for

CarmaCars field staff: drivers, detailers, and drivers who also detail. You hand cars over, take them back, move them and shoot listing photos. Everything is on your phone.

### What you need

- Your phone, charged, with a data connection (photos and signatures save as you take them)
- The invitation email from CarmaCars (the link works for 24 hours)
- A car charger and a cloth for the camera lens

## Your first sign-in

1. Open the invitation email on your phone and press its link within 24 hours. Choose a password and press **Save the new password**.
2. You land on **My jobs**. Next time, sign in at `carmacars.ca/sign-in` with your Email and Password.
3. In your browser''s menu, choose **Add to Home Screen**. The portal then opens full screen, like an app.
4. Open **Profile**, add your mobile number and press **Save my phone**.
5. At the top of the page, fill in your Home address and Postal code and press **Save my home address**. You need it before you add a rental or earn a commission.

![](/guides/img/field-04-profile-phone-f05000e2.jpg "phone; size: 390 920; pins: 4 92.3 78.3")

> Good to know: Recommended: on Profile, press **Set up two-step sign-in** and follow the steps with an authenticator app.
', 'Start here', 'Who this is for and your first sign-in.',
  '### Who this guide is for

CarmaCars field staff: drivers, detailers, and drivers who also detail. You hand cars over, take them back, move them and shoot listing photos. Everything is on your phone. Your jobs are under **Field work** in the staff portal; if you also hold another function (Sales, for example), its pages are in the same menu.

### What you need

- Your phone, charged, with a data connection (photos and signatures save as you take them)
- The invitation email from CarmaCars (the link works for 24 hours)
- A car charger and a cloth for the camera lens

## Your first sign-in

1. Open the invitation email on your phone and press its link within 24 hours. Choose a password and press **Save the new password**.
2. You land on **My jobs**. Next time, sign in at `carmacars.ca/sign-in` with your Email and Password.
3. In your browser''s menu, choose **Add to Home Screen**. The portal then opens full screen, like an app.
4. Open **Profile**, add your mobile number and press **Save my phone**.
5. At the top of the page, fill in your Home address and Postal code and press **Save my home address**. You need it before you add a rental or earn a commission.

![](/guides/img/field-04-profile-phone-f05000e2.jpg "phone; size: 390 920; pins: 4 92.3 78.3")

> Good to know: Recommended: on Profile, press **Set up two-step sign-in** and follow the steps with an authenticator app.
',
  '<h3 class="gd-h3">Who this guide is for</h3><p class="gd-p">CarmaCars field staff: drivers, detailers, and drivers who also detail. You hand cars over, take them back, move them and shoot listing photos. Everything is on your phone. Your jobs are under <b class="gd-ui">Field work</b> in the staff portal; if you also hold another function (Sales, for example), its pages are in the same menu.</p><h3 class="gd-h3">What you need</h3><ul class="gd-ul"><li>Your phone, charged, with a data connection (photos and signatures save as you take them)</li><li>The invitation email from CarmaCars (the link works for 24 hours)</li><li>A car charger and a cloth for the camera lens</li></ul><section class="gd-task" id="start-here-your-first-sign-in" data-gd-task><h2 class="gd-h2">Your first sign-in</h2><div class="gd-stepblock gd-stepblock--side"><div class="gd-stepcol"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Open the invitation email on your phone and press its link within 24 hours. Choose a password and press <b class="gd-ui">Save the new password</b>.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">You land on <b class="gd-ui">My jobs</b>. Next time, sign in at <span class="gd-url">carmacars.ca/sign-in</span> with your Email and Password.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">In your browser&#39;s menu, choose <b class="gd-ui">Add to Home Screen</b>. The portal then opens full screen, like an app.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">Open <b class="gd-ui">Profile</b>, add your mobile number and press <b class="gd-ui">Save my phone</b>.</div></li><li><span class="gd-n" aria-hidden="true">5</span><div class="gd-t">At the top of the page, fill in your Home address and Postal code and press <b class="gd-ui">Save my home address</b>. You need it before you add a rental or earn a commission.</div></li></ol></div><figure class="gd-fig gd-fig--phone"><div class="gd-phone"><div class="gd-imgwrap" style="aspect-ratio:390/920"><img src="/guides/img/field-04-profile-phone-f05000e2.jpg" alt="" loading="lazy" decoding="async" width="390" height="920"><span class="gd-pin" style="left:92.3%;top:78.3%" aria-hidden="true">4</span></div></div></figure></div><aside class="gd-box"><span class="gd-lbl">Good to know</span><div>Recommended: on Profile, press <b class="gd-ui">Set up two-step sign-in</b> and follow the steps with an authenticator app.</div></aside></section>');
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
