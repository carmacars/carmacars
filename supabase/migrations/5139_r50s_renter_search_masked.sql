-- 5139 (R50 hotfix 2, Sales; docs/changes/2026-11-27-r50-sales-fixes.md). Privacy: "Find a renter" in the phone inbox
-- (app.phone_renter_search, 0085; opened to Sales by 0970's assert_phone_staff) gave Sales the renter's email in full, and
-- the mobile in full whenever the outer read wrapper (2870) did not mask it (a Sales rep whose active function at that
-- moment was not Sales). That breaks 0970: customer numbers are hidden from Sales. Now the function masks by itself:
-- for a Sales rep (app.user_sales_only, or app.viewer_masks_phones) the mobile is the masked display, kept in phone_masks
-- (so the server's Call and Text find it, 0970), and the email is masked (app.esign_mask_email). The link to a renter
-- still goes by the record id (phone_link renter_id). For a masked viewer a number matches by its last 4 digits or in full
-- and an email only in full, so nothing can be probed out a digit at a time. Admins and
-- customer service see the full values as before. No applied migration is edited.
set local check_function_bodies = off;

create or replace function app.phone_renter_search(p_by uuid, p jsonb) returns jsonb
language plpgsql volatile security definer set search_path = public, app, pg_temp as $$
declare
  q text := left(nullif(btrim(coalesce(p ->> 'q', '')), ''), 120);
  d text;
  v_mask boolean;
  v jsonb;
begin
  perform app.assert_phone_staff(p_by);
  if q is null or length(q) < 2 then return '[]'::jsonb; end if;
  d := regexp_replace(q, '[^0-9]', '', 'g');
  v_mask := app.user_sales_only(p_by) or app.viewer_masks_phones(p_by);
  with top as (
    select r.id, r.legal_name, r.email, app.phone_e164(r.mobile) as e164, r.mobile, r.created_at from renters r
     where r.legal_name ilike '%' || replace(replace(replace(q, '\', '\\'), '%', '\%'), '_', '\_') || '%'
        -- a masked viewer matches a number by its last 4 digits or in full, an email in full: nothing can be probed out a
        -- digit at a time
        or (not v_mask and r.email ilike '%' || replace(replace(replace(q, '\', '\\'), '%', '\%'), '_', '\_') || '%')
        or (v_mask and r.email is not null and lower(r.email) = lower(q))
        or (not v_mask and d <> '' and regexp_replace(coalesce(r.mobile, ''), '[^0-9]', '', 'g') like '%' || d || '%')
        or (v_mask and length(d) = 4 and right(regexp_replace(coalesce(r.mobile, ''), '[^0-9]', '', 'g'), 4) = d)
        or (v_mask and length(d) >= 10 and app.phone_e164(r.mobile) = app.phone_e164(q))
     order by r.created_at desc limit 10),
  kept as (
    insert into phone_masks as x (user_id, number, display, seen_at)
    select p_by, t.e164, app.phone_mask_display(t.e164), now() from top t where v_mask and t.e164 is not null
    on conflict (user_id, number) do update set seen_at = excluded.seen_at, display = excluded.display
    returning 1)
  select coalesce(jsonb_agg(jsonb_build_object('id', t.id, 'name', t.legal_name,
           'email', case when v_mask then app.esign_mask_email(t.email) else t.email end,
           'mobile', case when not v_mask then t.mobile when t.e164 is not null then app.phone_mask_display(t.e164) end,
           'masked', v_mask) order by t.created_at desc), '[]'::jsonb)
    into v from top t, (select count(*) from kept) k;
  return v;
end $$;

revoke all on function app.phone_renter_search(uuid, jsonb) from public, anon, authenticated;
grant execute on function app.phone_renter_search(uuid, jsonb) to service_role;
