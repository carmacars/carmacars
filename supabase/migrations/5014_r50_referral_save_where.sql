-- 5014 (release 50): the incorporation referral's save names its row (where singleton), as pg_safeupdate requires of
-- every update (99_safeupdate_usage_server). Same function as 4511 otherwise.
-- SCHEMA_MARKER 5014.

create or replace function app.incorporation_referral_save(p_by uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app, pg_temp as $$
declare
  a incorporation_affiliate;
  o incorporation_affiliate;
  v_url text := case when p ? 'link_template' then nullif(btrim(coalesce(p ->> 'link_template', '')), '') end;
  v_on boolean;
begin
  perform app.assert_admin(p_by);
  select * into o from incorporation_affiliate for update;
  if v_url is not null and v_url !~ '^https://[^[:space:]]+$' then raise exception 'Paste the affiliate link exactly as the provider gives it: it starts with https://' using errcode = '22023'; end if;
  v_on := coalesce((p ->> 'enabled')::boolean, case when v_url is not null and o.link_template is null then true else o.enabled end);
  if v_on and coalesce(case when p ? 'link_template' then v_url else o.link_template end, '') = '' then raise exception 'Paste the affiliate link before turning the referral on' using errcode = '22023'; end if;
  update incorporation_affiliate set
    provider_name = coalesce(nullif(btrim(coalesce(p ->> 'provider_name', '')), ''), provider_name),
    link_template = case when p ? 'link_template' then v_url else link_template end,
    commission_note = coalesce(nullif(btrim(coalesce(p ->> 'commission_note', '')), ''), commission_note),
    enabled = v_on, updated_by = p_by, updated_at = now()
   where singleton
   returning * into a;
  insert into audit_log (actor_user_id, action, entity_table, entity_id, before, after)
  values (p_by, 'incorporation_referral_save', 'incorporation_affiliate', 'singleton', jsonb_build_object('provider', o.provider_name, 'enabled', o.enabled, 'has_link', o.link_template is not null),
          jsonb_build_object('provider', a.provider_name, 'enabled', a.enabled, 'has_link', a.link_template is not null));
  return jsonb_build_object('enabled', a.enabled, 'usable', app.incorporation_usable(a));
end $$;

