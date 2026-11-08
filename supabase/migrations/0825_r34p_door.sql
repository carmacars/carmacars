-- 0825: the door for Release 34, part P (docs/changes/2026-11-08-r34-owner-onboarding.md). No applied migration is
-- edited; app.door is wrapped (door_pre0825). Each call checks who may use it itself (the owner, an Admin, customer
-- service, fleet; sales read the owners they brought in), so the owner portal and the staff portals use the same names.
--   reads (ops_read, va_read, admin_read): onboarding_overview, onboarding_owners (the staff list), onboarding_photos, onboarding_document (the stored file of
--     a photo, staff), government_forms (the list), government_form_fill (one form)
--   changes (ops_do, va_do): onboarding_photo_replace, onboarding_photo_remove, onboarding_photo_review,
--     government_forms_make_again (Admin), owner_add_vins
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

alter function app.door(uuid, text, text, text, jsonb) rename to door_pre0825;
create function app.door(p_user uuid, p_aal text, p_call text, p_name text, p jsonb default '{}'::jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
begin
  if (p_call in ('ops_read', 'va_read', 'admin_read') and p_name in ('onboarding_overview', 'onboarding_owners', 'onboarding_photos', 'onboarding_document', 'government_forms', 'government_form_fill'))
     or (p_call in ('ops_do', 'va_do') and p_name in ('onboarding_photo_replace', 'onboarding_photo_remove', 'onboarding_photo_review', 'government_forms_make_again', 'owner_add_vins')) then
    if coalesce(p, '{}'::jsonb) ? '_va' then perform set_config('app.va_active', coalesce(p ->> '_va', ''), true); end if;
    perform app.door_begin(p_user, p_aal);
    p := coalesce(p, '{}'::jsonb) - '_va';
    return case p_name
      when 'onboarding_overview' then app.onboarding_overview(p_user, p)
      when 'onboarding_owners' then app.onboarding_owners(p_user, p)
      when 'onboarding_photos' then app.onboarding_photos(p_user, p)
      when 'onboarding_document' then app.onboarding_photo_file(p_user, p)
      when 'government_forms' then app.government_forms_list(p_user, p)
      when 'government_form_fill' then app.government_form_fill_read(p_user, p)
      when 'onboarding_photo_replace' then app.onboarding_photo_replace(p_user, p)
      when 'onboarding_photo_remove' then app.onboarding_photo_remove(p_user, p)
      when 'onboarding_photo_review' then app.onboarding_photo_review(p_user, p)
      when 'government_forms_make_again' then app.government_forms_make_again(p_user, p)
      else app.owner_add_vins(p_user, p) end;
  end if;
  return app.door_pre0825(p_user, p_aal, p_call, p_name, p);
end $$;
select pg_temp.copy_grants('app.door(uuid, text, text, text, jsonb)'::regprocedure, 'app.door_pre0825(uuid, text, text, text, jsonb)'::regprocedure);
revoke all on function app.door_pre0825(uuid, text, text, text, jsonb) from public, anon, authenticated;
