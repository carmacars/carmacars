-- 2424_r40_partner_sourced_by_in_person.sql
-- Release 40: Sourced by (2361) accepted only what app.user_is_sales_staff accepts (a VA, or a field person with the field
-- role), but the list of Sales people the Admin picks from is every active staff member with the Sales function. An in-person
-- Sales person was in the dropdown and was refused on save ("Sourced by: pick a Sales person"). The save now checks what the
-- list shows: an active staff member with 'sales' in functions (credit_blocked staff stay refused by the line after it), or an
-- Admin. The commission engine (referral_sourced_sync) checks nobody, so the sourced-by share is paid to whoever is saved.
do $$
declare
  v_def text := pg_get_functiondef('app.referral_partner_save(uuid, jsonb)'::regprocedure);
  v_old text := 'not app.user_is_sales_staff(v_src) and not app.user_is_admin(v_src)';
  v_new text := 'not exists (select 1 from staff_profiles sp where sp.user_id = v_src and sp.is_active and ''sales'' = any (sp.functions)) and not app.user_is_admin(v_src)';
begin
  if position(v_old in v_def) = 0 then raise exception '2424: the sourced-by check of referral_partner_save was not found'; end if;
  execute replace(v_def, v_old, v_new);
end $$;
