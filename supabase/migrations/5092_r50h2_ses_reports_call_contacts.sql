-- 5092 (R50 hotfix 2, comms; tests: supabase/tests/99_r50h2_ses_contacts.sql). SCHEMA_MARKER 5092.
-- 1. Amazon SES never sent (production, Nov 27: every email of the day went through Resend, and the emails held for
--    Resend's daily 100 all went at midnight). The send-outbox function on the server still binds its reports as
--    `${JSON.stringify(x)}::jsonb`, which postgres.js sends as a JSON string ("{\"seen\":true}"): server_ses_email_result
--    then took its failure branch every minute, ses_seen_at stayed empty, app.ses_email_left was 0 and SES was never
--    tried. f4df37d3 fixed the binds in the function, but that commit's deploy was cancelled, so the server runs the old
--    code. The database now reads a report given as a JSON string the same as the object, so SES sends as soon as this
--    migration is applied, whichever send-outbox build runs. Cloudflare's report (server_cf_email_result) the same.
-- 2. Calls (owner, Nov 25 to 27): the call screen's keypad gets the person's contacts. app.voice_contacts gives the
--    people a staff member may call: with no search, the people they called last; with a search (2 letters or digits),
--    renters and leads by name or number. Sales (0970) see only their own leads and the masked number, and the call goes
--    by the record (lead or renter id), so the full number never reaches their browser; a masked number shown without a
--    record is kept in phone_masks so the server finds it (as every other masked number, 0970). Only the phone staff
--    (app.assert_phone_staff, 0970: Admins, customer service, Sales and Fleet) may search, as phone_renter_search; a
--    name shown to Sales is masked too (a name that holds a number never shows it in full); %, _ and \ in a search are
--    plain characters.
-- Re-run safe: every function is create or replace.
set local check_function_bodies = off;

-- ================================================================ 1. a report given as a JSON string is read as its object
create or replace function app.jsonb_arg(p jsonb) returns jsonb
language plpgsql immutable set search_path = public, app, pg_temp as $$
begin
  if jsonb_typeof(p) = 'string' then
    begin return (p #>> '{}')::jsonb; exception when others then return p; end;
  end if;
  return p;
end $$;

create or replace function public.server_ses_email_result(p jsonb) returns jsonb
language sql security definer set search_path = public, app, pg_temp as $$ select app.server_ses_email_result(app.jsonb_arg(p)) $$;
create or replace function public.server_cf_email_result(p jsonb) returns jsonb
language sql security definer set search_path = public, app, pg_temp as $$ select app.server_cf_email_result(app.jsonb_arg(p)) $$;

-- ================================================================ 2. contacts for the call screen
create or replace function app.voice_contacts(p_user uuid, p jsonb) returns jsonb
language plpgsql volatile security definer set search_path = public, app, pg_temp as $$
declare
  q text := left(nullif(btrim(coalesce(p ->> 'q', '')), ''), 60);
  d text := regexp_replace(coalesce(q, ''), '[^0-9]', '', 'g');
  -- the search as ilike text: %, _ and the escape character \ match only themselves
  v_like text := '%' || replace(replace(replace(coalesce(q, ''), '\', '\\'), '%', '\%'), '_', '\_') || '%';
  v_sales boolean := app.user_sales_only(p_user);
  v jsonb;
begin
  perform app.assert_phone_staff(p_user);
  if q is not null and length(q) < 2 then return '[]'::jsonb; end if;
  with found as (
    -- the people this person called last (no search)
    select x.name, x.number, x.lead_id, x.renter_id, x.at, 1 as k from (
      select distinct on (c.to_number) coalesce(t.name, l.name, r.legal_name) as name, c.to_number as number, c.lead_id, c.renter_id, c.started_at as at
        from outbound_calls c left join phone_threads t on t.id = c.thread_id left join leads l on l.id = c.lead_id left join renters r on r.id = c.renter_id
       where q is null and c.staff_user_id = p_user and c.to_number is not null
       order by c.to_number, c.started_at desc) x
    union all
    -- a search: leads (Sales: their own only)
    select l.name, app.phone_e164(l.phone), l.id, null::uuid, l.updated_at, 2 from leads l
     where q is not null and app.phone_e164(l.phone) is not null and l.merged_into is null and l.do_not_contact_at is null
       and (l.name ilike v_like or (length(d) >= 3 and regexp_replace(coalesce(l.phone, ''), '[^0-9]', '', 'g') like '%' || d || '%'))
       and (not v_sales or app.lead_is_mine(l.id, l.sourced_by, l.assigned_to, l.payload, l.sales_outcome_by, p_user))
    union all
    -- a search: renters (not for Sales, who work their leads)
    select r.legal_name, app.phone_e164(r.mobile), null::uuid, r.id, r.created_at, 3 from renters r
     where q is not null and not v_sales and app.phone_e164(r.mobile) is not null
       and (r.legal_name ilike v_like or (length(d) >= 3 and regexp_replace(coalesce(r.mobile, ''), '[^0-9]', '', 'g') like '%' || d || '%'))
  ), picked as (
    select distinct on (f.number) f.*, (v_sales and not app.phone_unlocked_for(p_user, f.number)) as masked
      from found f order by f.number, f.k, f.at desc nulls last
  ), top as (select * from picked order by at desc nulls last limit 12),
  kept as (
    insert into phone_masks (user_id, number, display, seen_at)
    select p_user, t.number, app.phone_mask_display(t.number), now() from top t where t.masked
    on conflict (user_id, number) do update set seen_at = excluded.seen_at, display = excluded.display
    returning 1)
  select coalesce(jsonb_agg(jsonb_build_object(
           'name', case when t.masked then coalesce(app.mask_phone_text(p_user, nullif(btrim(t.name), ''), null), app.phone_mask_display(t.number))
                        else coalesce(nullif(btrim(t.name), ''), app.phone_display(t.number)) end,
           'number', case when t.masked then app.phone_mask_display(t.number) else t.number end,
           'shown', case when t.masked then app.phone_mask_display(t.number) else app.phone_display(t.number) end,
           'lead', t.lead_id, 'renter', t.renter_id) order by t.at desc nulls last), '[]'::jsonb)
    into v from top t, (select count(*) from kept) k;
  return v;
end $$;
create or replace function public.server_voice_contacts(p_user uuid, p jsonb) returns jsonb
language sql volatile security definer set search_path = public, app, pg_temp as $$ select app.voice_contacts(p_user, p) $$;

-- ================================================================ grants
revoke all on function app.jsonb_arg(jsonb), app.voice_contacts(uuid, jsonb), public.server_voice_contacts(uuid, jsonb),
                       public.server_ses_email_result(jsonb), public.server_cf_email_result(jsonb) from public, anon, authenticated;
grant execute on function app.jsonb_arg(jsonb), app.voice_contacts(uuid, jsonb), public.server_voice_contacts(uuid, jsonb),
                          public.server_ses_email_result(jsonb), public.server_cf_email_result(jsonb) to service_role;
