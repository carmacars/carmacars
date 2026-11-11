-- 99: the security audit's standing checks (migration 1600, release 35, helper SEC). Structural: each check reads the
-- catalog, so a later migration that adds a table without row-level security, a policy for the anonymous role, a definer
-- function without a fixed search_path or open to PUBLIC, a new function a browser may call, or a join-path foreign key
-- without an index fails here, and the failure names what to fix. docs/engineering-rules.md explains each rule.
select test.suite('99 r35sec security');

-- ------------------------------------------------------------------ tables and policies
select test.eq('rls: every table in public and app has row-level security (names any that do not)',
  (select string_agg(n.nspname || '.' || c.relname, ', ' order by 1) from pg_class c join pg_namespace n on n.oid = c.relnamespace
    where n.nspname in ('public', 'app') and c.relkind in ('r', 'p') and not c.relrowsecurity), null::text);
select test.eq('rls: no policy anywhere applies to the anonymous role or to PUBLIC (which includes it)',
  (select string_agg(schemaname || '.' || tablename || ':' || policyname, ', ') from pg_policies
    where schemaname in ('public', 'app', 'storage') and roles && array['anon', 'public']::name[]), null::text);
select test.eq('rls: no policy lets a signed-in session write every row (a WITH CHECK or USING of plain true on insert, update or delete)',
  (select string_agg(tablename || ':' || policyname, ', ') from pg_policies
    where schemaname in ('public', 'app') and cmd in ('INSERT', 'UPDATE', 'DELETE', 'ALL') and permissive = 'PERMISSIVE'
      and (coalesce(btrim(qual), '') = 'true' or coalesce(btrim(with_check), '') = 'true')), null::text);
select test.eq('grants: the anonymous role reads exactly one relation (the public listings view) and writes none',
  (select string_agg(table_schema || '.' || table_name || ':' || privilege_type, ',') from information_schema.role_table_grants
    where grantee = 'anon' and table_schema in ('public', 'app', 'storage', 'auth')), 'public.public_vehicle_listings:SELECT');
select test.eq('grants: nothing in the app schema is readable or writable by a browser session except the rate limit hits (read, own rows)',
  (select string_agg(table_name || ':' || privilege_type || ':' || grantee, ',') from information_schema.role_table_grants
    where table_schema = 'app' and grantee in ('anon', 'authenticated')), 'rate_limit_hits:SELECT:authenticated');
select test.eq('views: every view a browser session can read is a security barrier or runs with the reader''s rights',
  (select string_agg(c.relname, ', ') from pg_class c
    where c.relnamespace = 'public'::regnamespace and c.relkind in ('v', 'm')
      and (has_table_privilege('authenticated', c.oid, 'select') or has_table_privilege('anon', c.oid, 'select'))
      and not exists (select 1 from pg_options_to_table(c.reloptions) o where o.option_name in ('security_barrier', 'security_invoker') and o.option_value = 'true')), null::text);

-- ------------------------------------------------------------------ functions
select test.eq('functions: every SECURITY DEFINER function fixes its search_path',
  (select string_agg(p.oid::regprocedure::text, ', ') from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where p.prosecdef and n.nspname in ('public', 'app', 'auth', 'storage')
      and not exists (select 1 from unnest(coalesce(p.proconfig, '{}')) c where c like 'search_path=%')), null::text);
select test.eq('functions: no SECURITY DEFINER function is executable by PUBLIC (grant the roles by name)',
  (select string_agg(p.oid::regprocedure::text, ', ') from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where p.prosecdef and n.nspname in ('public', 'app')
      and not exists (select 1 from pg_depend d where d.objid = p.oid and d.deptype = 'e')
      and (p.proacl is null or exists (select 1 from aclexplode(p.proacl) a where a.grantee = 0 and a.privilege_type = 'EXECUTE'))), null::text);
select test.eq('functions: the server may run every function in public and app',
  (select count(*) from pg_proc p where p.pronamespace in ('public'::regnamespace, 'app'::regnamespace)
    and not has_function_privilege('service_role', p.oid, 'execute')), 0::bigint);

-- The door allow-list: what the API serves to a visitor who is not signed in, and what it adds for a signed-in session.
-- Everything else goes through the server (service_role and public.door). A function added to either list must be added
-- here on purpose, with the reason in its migration; extension functions (pg_trgm, btree_gist) are left out.
create temporary table r35sec_anon_ok (name text primary key);
insert into r35sec_anon_ok values
  ('addons_for_car'), ('app_links'), ('article'), ('articles_public'), ('booking_car'), ('booking_cars'), ('business_rating'),
  ('calc_billable_days'), ('calc_booking_split'), ('calc_bps'), ('calc_buyout_price'), ('calc_cancellation'), ('calc_capped_per_day'),
  ('calc_claim_result'), ('calc_damage_billing'), ('calc_deposit_method'), ('calc_election_effective_month'), ('calc_extension'),
  ('calc_fee_days'), ('calc_fuel_charge'), ('calc_hst'), ('calc_investment_return'), ('calc_kickback'), ('calc_late_return'),
  ('calc_loss_of_use'), ('calc_mileage_overage'), ('calc_monthly_interest'), ('calc_payment_retry_at'), ('calc_prorated_fee'),
  ('calc_refund_bps'), ('calc_rental_charge'), ('calc_retransfer_payer'), ('calc_round'), ('calc_split'), ('calc_total_loss'),
  ('car_page'), ('card_coverage_public'), ('chat_greeting'), ('chat_poll'), ('chat_typing'), ('chauffeur_services'), ('cookie_choice'),
  ('coverage_affiliate_public'), ('effective_fee'), ('enquiry_has_match'), ('featured_cars'), ('fleet'), ('game_cfg'), ('game_reveal'),
  ('game_start'), ('game_terms'), ('handover_places'), ('hiring_role_public'), ('hiring_roles_public'), ('model_hub'), ('model_hubs'),
  ('owner_calc_data'), ('partner_referral_code_ok'), ('place_directory_index'), ('place_directory_page'), ('place_hub'), ('place_roots'),
  ('place_sitemap'), ('place_sitemap_files'), ('place_terms_public'), ('places_known'), ('public_reviews'), ('public_vehicle_calendar'),
  ('quote_booking'), ('record_cookie_choice'), ('record_cookie_notice'), ('referral_partner_code_ok'), ('referral_program_public'),
  ('resolve_path'), ('sample_car_match'), ('search_available'), ('seo_hub_links'), ('seo_links'), ('seo_page'), ('seo_pages_public'),
  ('shop_services_public'), ('signin_phone_rules'), ('site_content'), ('site_facts'), ('site_file'), ('site_hero_photos'),
  ('site_settings_public'), ('sitemap_all'), ('sitemap_rows'), ('stock_photos_generic'), ('track_beat'), ('track_ingest'),
  ('vehicle_buy_extras'), ('vehicle_classes'), ('vehicle_fleet_makes'), ('vehicle_hub_path'), ('vehicle_is_available'),
  ('vehicle_make_index'), ('vehicle_make_page'), ('vehicle_makes'), ('vehicle_model_page'), ('vehicle_photos_public'),
  ('vehicle_sitemap'), ('vehicle_sitemap_files'), ('vehicle_sitemap_index'), ('vehicle_sitemap_tree'), ('vehicle_stock_photo'),
  ('vehicle_tier_files_count'), ('vehicle_tier_page'), ('vehicle_tier_sitemap'), ('vehicle_tiers'), ('vehicle_trim_page'),
  ('vehicle_year_page'),
  -- r35/r36 public reads (2140 checked each: read-only, public page data only)
  ('airport_pages'), ('calc_rental_charge_tiers'), ('delivery_to_point'), ('fleet_popular_ids'), ('rent_vs_own_inputs'),
  ('rent_vs_own_page'), ('review_summary'), ('seo_event'), ('seo_events_list'), ('seo_i18n_bundle'), ('seo_languages_state'),
  ('sitemap_families'), ('sitemap_languages'), ('tracker_product');
create temporary table r35sec_signed_in_ok (name text primary key);
insert into r35sec_signed_in_ok values
  ('mark_notifications_read'), ('my_booking'), ('my_booking_change_preview'), ('my_booking_messages'), ('my_booking_readiness'),
  ('my_bookings'), ('my_cancellation_preview'), ('my_document'), ('my_documents'), ('my_extension_offers'), ('my_extension_preview'),
  ('my_notification_preferences'), ('my_notifications'), ('my_profile'), ('my_promo_code_problem'), ('my_rewards'), ('my_trip_photos'),
  ('my_unread_count'), ('rewards_mine_code_cancel'), ('rewards_mine_google_claim'), ('rewards_mine_redeem'), ('rewards_mine_social'),
  ('set_notification_preference');

select test.eq('door: the API serves an anonymous visitor only the functions on the allow-list (names any extra)',
  (select string_agg(distinct p.proname, ', ' order by p.proname) from pg_proc p
    where p.pronamespace = 'public'::regnamespace and has_function_privilege('anon', p.oid, 'execute')
      and not exists (select 1 from pg_depend d where d.objid = p.oid and d.deptype = 'e')
      and p.proname not in (select name from r35sec_anon_ok)), null::text);
select test.eq('door: a signed-in session adds only its own reads and its notification and rewards actions (names any extra)',
  (select string_agg(distinct p.proname, ', ' order by p.proname) from pg_proc p
    where p.pronamespace = 'public'::regnamespace and has_function_privilege('authenticated', p.oid, 'execute')
      and not has_function_privilege('anon', p.oid, 'execute')
      and not exists (select 1 from pg_depend d where d.objid = p.oid and d.deptype = 'e')
      and p.proname not in (select name from r35sec_signed_in_ok)), null::text);
select test.eq('door: the staff and investor door and the server functions are for the server only',
  (select string_agg(p.proname, ', ') from pg_proc p
    where p.pronamespace = 'public'::regnamespace and (p.proname = 'door' or p.proname like 'server\_%' or p.proname like 'admin\_%')
      and (has_function_privilege('anon', p.oid, 'execute') or has_function_privilege('authenticated', p.oid, 'execute'))), null::text);
select test.eq('door: every function a visitor may call that writes (volatile and definer) is rate limited, token-gated or a heartbeat',
  (select string_agg(p.proname, ', ') from pg_proc p
    where p.pronamespace = 'public'::regnamespace and has_function_privilege('anon', p.oid, 'execute') and p.provolatile = 'v' and p.prosecdef
      and p.proname not in ('chat_poll', 'chat_typing', 'game_reveal', 'game_start', 'track_beat', 'track_ingest')), null::text);
select test.ok('door: the visitor writes that create rows check the per-address rate limit',
  (select bool_and(p.prosrc ~ 'public_rate_check|rate_limit') from pg_proc p
    where p.pronamespace = 'app'::regnamespace and p.proname in ('record_cookie_choice', 'record_cookie_notice', 'track_ingest', 'game_start_core')));

-- ------------------------------------------------------------------ an internal table, as the anonymous role
set role anon;
select test.eq('rls: an internal app table is closed to the anonymous role (no grant, and row-level security behind it)',
  test.visible('select * from app.phone_gate_codes'), -1::bigint);
reset role;

-- ------------------------------------------------------------------ indexes
select test.eq('indexes: every join-path foreign key has an index (columns that only record who acted are exempt; names any missing)',
  (select string_agg(c.conrelid::regclass::text || '(' || (select string_agg(a.attname, ',') from pg_attribute a where a.attrelid = c.conrelid and a.attnum = any (c.conkey)) || ')', ', ')
     from pg_constraint c
    where c.contype = 'f' and c.connamespace in ('public'::regnamespace, 'app'::regnamespace)
      and not exists (select 1 from pg_index i where i.indrelid = c.conrelid
                        and (i.indkey::int2[])[0:array_length(c.conkey, 1) - 1] @> c.conkey
                        and (i.indkey::int2[])[0:array_length(c.conkey, 1) - 1] <@ c.conkey)
      and not (c.confdeltype = 'a' and app.fk_is_actor_column(c.oid))), null::text);
select test.ok('indexes: the actor-column rule is narrow (created_by is an actor column, booking_id is not)',
  (select bool_and(app.fk_is_actor_column(c.oid) = (a.attname ~ '_by$')) from pg_constraint c join pg_attribute a on a.attrelid = c.conrelid and a.attnum = c.conkey[1]
    where c.contype = 'f' and c.conrelid = 'public.bookings'::regclass and a.attname in ('created_by', 'vehicle_id', 'renter_id')));

drop table r35sec_anon_ok, r35sec_signed_in_ok;
