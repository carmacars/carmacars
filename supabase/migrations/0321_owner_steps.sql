-- 0321_owner_steps.sql
-- The features waiting on a step only the owner can take (docs/changes/2026-11-06-audit-gaps.md, item 5): every deploy
-- lists them in one annotation with the exact step each needs (scripts/deploy/owner-steps.sh), so no switch-on step is
-- ever hidden. This read covers what the database knows: Meta publishing's Page token, the partner CRM links'
-- GoHighLevel tokens, the RentalCoverage affiliate link, and whether the vault of the live database holds the five Apple
-- Wallet values the deploy reads (the phone alerts' keys are made by the deploy itself, scripts/deploy/vapid.sh). The
-- deploy adds the Cloudflare email binding (a repository variable). Service role only; it returns names, never a value.

create or replace function app.owner_steps() returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare
  v_vault text[] := '{}';
  m meta_publishing;
  a coverage_affiliate;
  v_out jsonb := '[]'::jsonb;
  n integer;
begin
  if to_regclass('vault.decrypted_secrets') is not null then
    execute $q$select coalesce(array_agg(name), '{}') from vault.decrypted_secrets where name like 'deploy\_%' and coalesce(decrypted_secret, '') <> ''$q$ into v_vault;
  end if;
  n := (select count(*) from unnest(array['deploy_wallet_pass_cert', 'deploy_wallet_pass_key', 'deploy_wallet_wwdr_cert', 'deploy_wallet_pass_type_id', 'deploy_wallet_team_id']) w where w = any (v_vault));
  if n < 5 then
    v_out := v_out || jsonb_build_object('key', 'wallet', 'feature', 'Add to Apple Wallet',
      'step', format('Apple Developer account, Certificates, Identifiers & Profiles: create the Pass Type ID pass.ca.carmacars.booking and its certificate; then add deploy_wallet_pass_cert (PEM), deploy_wallet_pass_key (PKCS #8 PEM), deploy_wallet_wwdr_cert (Apple WWDR G4, PEM), deploy_wallet_pass_type_id and deploy_wallet_team_id to the vault of the live database (the company server: Studio through the SSH tunnel of infra/vps/CUTOVER.md, SQL editor, select vault.create_secret(''<value>'', ''<name>'');), and deploy (%s of 5 there now).', n));
  end if;
  select * into m from meta_publishing limit 1;
  if m.singleton is not null and (m.token_ref is null and m.token_hint is null) then
    v_out := v_out || jsonb_build_object('key', 'meta', 'feature', 'Posting approved ads to Facebook and Instagram',
      'step', 'Admin > Settings > Meta publishing: enter the Facebook Page id, the Instagram professional account id and a Page access token (Meta Business Suite > Settings > System users), then turn it on.');
  end if;
  if to_regclass('public.partner_crm_connections') is not null then
    select count(*) into n from partner_crm_connections where enabled and token_ref is null and token_hint is null;
    if n > 0 then
      v_out := v_out || jsonb_build_object('key', 'ghl', 'feature', 'Partner CRM links (GoHighLevel)',
        'step', format('Admin > Partners > the partner > CRM: paste the partner''s GoHighLevel Private Integration token (%s link%s on, without a token).', n, case when n = 1 then '' else 's' end));
    end if;
  end if;
  select * into a from coverage_affiliate limit 1;
  if a.singleton is not null and not coalesce(app.coverage_affiliate_usable(a), false) then
    v_out := v_out || jsonb_build_object('key', 'rentalcoverage', 'feature', 'RentalCoverage affiliate link on the coverage step',
      'step', 'Admin > Settings > Coverage affiliate: paste the tracking link from the RentalCoverage affiliate dashboard (and the affiliate ID if the link has {id}), then turn it on.');
  end if;
  return v_out;
end $$;

create or replace function public.server_owner_steps() returns jsonb
language sql stable security definer set search_path = public, app as $$ select app.owner_steps() $$;

revoke all on function app.owner_steps(), public.server_owner_steps() from public, anon, authenticated;
grant execute on function app.owner_steps(), public.server_owner_steps() to service_role;
