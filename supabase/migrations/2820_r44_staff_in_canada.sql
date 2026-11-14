-- 2820 (release 44): staff who live in Canada are never shown or contracted as being in the Philippines.
--
-- The remote assistant's agreement took its terms from the assistant defaults of Program settings (0057): country
-- Philippines, currency USD, paid through OnlineJobs.ph. A Sales person working remotely from Canada, or one whose staff
-- record had no country, got those terms, and their record read Philippines.
--   1. app.staff_agreement_prepare: for a staff member who lives in Canada (their location says CA; or, with no location,
--      they work in person, do field work or are paid in Canada) the agreement's terms are Canada, CAD, paid by Interac
--      e-Transfer or direct deposit. Everyone else keeps the defaults of Program settings.
--   2. Every active staff member with no location, or one that says the Philippines, who works in person, does field work
--      or is paid to a Canadian bank or by Interac e-Transfer, is set to Canada once (Toronto when no city is on file).
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

-- ================================================================ who is in Canada
create function app.staff_in_canada(p_user uuid) returns boolean
language sql stable security definer set search_path = public, app as $$
  select coalesce(
    (select case
       when sp.location_country is not null and sp.location_country <> 'PH' then sp.location_country = 'CA'
       else sp.sales_work_mode = 'in_person' or 'field' = any (sp.functions::text[]) or sp.staff_type = 'field'
         or exists (select 1 from staff_payout_accounts a where a.user_id = sp.user_id and a.is_current
                      and (a.method = 'e_transfer' or upper(coalesce(a.country, '')) in ('CA', 'CANADA')
                           or coalesce(a.bank_name, '') ~* '(royal bank|\mrbc\M|\mtd\M|toronto.dominion|cibc|scotia|\mbmo\M|bank of montreal|desjardins|tangerine|national bank|simplii|eq bank|atb|servus|meridian|wealthsimple|koho)'))
       end
       from staff_profiles sp where sp.user_id = p_user), false)
$$;
comment on function app.staff_in_canada(uuid) is 'r44 (2820): the staff member lives in Canada: their location says CA, or (no location, or the Philippines defaulted) they work in person, do field work or are paid in Canada.';
revoke all on function app.staff_in_canada(uuid) from public, anon, authenticated;
grant execute on function app.staff_in_canada(uuid) to service_role;

-- ================================================================ 1. the agreement's terms
alter function app.staff_agreement_prepare(uuid, uuid) rename to staff_agreement_prepare_pre2820;
create function app.staff_agreement_prepare(p_by uuid, p_user uuid) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare
  r jsonb := app.staff_agreement_prepare_pre2820(p_by, p_user);
begin
  if app.staff_in_canada(p_user) and jsonb_typeof(r -> 'defaults') = 'object' and (r #>> '{defaults,country}') is not null then
    r := jsonb_set(r, '{defaults}', (r -> 'defaults') || jsonb_build_object('country', 'Canada', 'currency', 'CAD',
           'platform', 'Interac e-Transfer or direct deposit'));
  end if;
  return r;
end $$;
select pg_temp.copy_grants('app.staff_agreement_prepare(uuid, uuid)'::regprocedure, 'app.staff_agreement_prepare_pre2820(uuid, uuid)'::regprocedure);
revoke all on function app.staff_agreement_prepare_pre2820(uuid, uuid) from public, anon, authenticated;
grant execute on function app.staff_agreement_prepare_pre2820(uuid, uuid) to service_role;

-- ================================================================ 2. the records, once
update staff_profiles sp set location_country = 'CA', location_city = coalesce(nullif(btrim(sp.location_city), ''), 'Toronto')
 where sp.is_active and (sp.location_country is null or sp.location_country = 'PH') and app.staff_in_canada(sp.user_id);
