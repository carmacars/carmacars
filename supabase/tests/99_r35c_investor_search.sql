-- 99: Search Console on the investor deck (1507). The gsc workflow's daily rows are stored; the deck reads clicks and
-- impressions of the last 28 days against the 28 before, the weekly trend, and the indexed pages (an Admin's figure from
-- Search Console, else an estimate); never fleet size, utilisation, premium or costs; only an investor while the deck is
-- shown, or an Admin. Fixtures start with "isx"; example.test.
select test.suite('99 r35c investor search');

select test.mk_user('isx_admin', 'admin');
select test.mk_user('isx_inv', 'renter');
select test.mk_user('isx_cs', 'va', 'cs');
insert into investors (id, legal_name, investor_type, user_id, status) values (test.id('inv:isx'), 'Isx Investor', 'individual', test.id('isx_inv'), 'active');

select test.eq('the workflow''s rows are stored (a bad day is skipped)', app.gsc_search_store((select jsonb_agg(jsonb_build_object('day', current_date - d, 'clicks', case when d < 31 then 20 else 10 end, 'impressions', case when d < 31 then 1000 else 500 end))
  from generate_series(3, 58) d) || '[{"day": "not a day", "clicks": 1}]'::jsonb), 56);
create temp table isx as select app.door(test.id('isx_admin'), 'aal2', 'admin_read', 'deck_search') v;
select test.eq('28 days against the 28 before: clicks and impressions doubled',
  (select format('%s|%s|%s|%s', v ->> 'clicks_28d', v ->> 'impressions_28d', v ->> 'clicks_growth_pct', v ->> 'impressions_growth_pct') from isx), '560|28000|100|100');
select test.ok('the weekly trend', (select jsonb_array_length(v -> 'weeks') between 8 and 10 from isx));
select test.eq('no fleet, utilisation, premium or cost in it', (select v ?| array['fleet', 'cars', 'utilisation', 'utilization', 'premium', 'costs', 'insurance'] from isx), false);
select test.throws('staff cannot type the indexed pages', format('select app.door(%L, %L, %L, %L, %L::jsonb)', test.id('isx_cs'), 'aal2', 'admin_do', 'deck_search_indexed', '{"indexed_pages": "172,000"}'), 'Admin');
select app.door(test.id('isx_admin'), 'aal2', 'admin_do', 'deck_search_indexed', '{"indexed_pages": "172,000"}');
select test.eq('the Admin''s figure from Search Console', (select format('%s|%s', v ->> 'indexed_pages', v ->> 'indexed_estimate') from (select app.deck_search() v) x), '172000|false');
update deck_settings set show_to_investors = false;
select test.throws('an investor while the deck is hidden: no', format('select app.door(%L, %L, %L, %L)', test.id('isx_inv'), 'aal2', 'investor_read', 'deck_search'), 'not available');
update deck_settings set show_to_investors = true;
select test.eq('an investor while it is shown: yes', app.door(test.id('isx_inv'), 'aal2', 'investor_read', 'deck_search') ->> 'clicks_28d', '560');
select test.throws('a staff member is not an investor', format('select app.door(%L, %L, %L, %L)', test.id('isx_cs'), 'aal2', 'investor_read', 'deck_search'), 'investors');
