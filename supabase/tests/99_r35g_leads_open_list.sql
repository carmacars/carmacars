-- 99: release 35 part G (migration 1152): no lead is given to anyone by itself; leads wait on the Sales lead list for a
-- salesperson to claim, one new claim every 5 minutes a person, at most max_active (3) held at once; a claim that runs out
-- returns the lead; the one-time sweep sends auto-assigned leads back to the list. Fixtures start with "gl".
select test.suite('99 r35g leads open list');

select test.mk_user('gl_admin', 'admin');
select test.mk_user('gl_roman', 'va', 'sales');
select test.mk_user('gl_ana', 'va', 'sales');
update sales_lead_settings set claim_cooldown_minutes = 5, lead_cap_base = 3, lead_cap_per_wins = 5, lead_cap_max = 10;

create function pg_temp.dr(p_user text, p_name text, p jsonb) returns jsonb language sql as
$$ select public.door(test.id(p_user), 'aal2', 'ops_do', p_name, p) $$;
create function pg_temp.lead(p_label text) returns uuid language sql as $$
  insert into leads (id, kind, name, email, source) values (test.id('lead:' || p_label), 'contact', 'Lead ' || p_label, p_label || '.lead@example.test', 'web') returning id $$;
-- the claim log of a person moved back in time (as if the 5 minutes had passed)
create function pg_temp.later(p_user text) returns void language sql as
$$ update lead_claim_log set at = at - interval '6 minutes' where user_id = test.id(p_user) and by_user = test.id(p_user) $$;

-- ---------------------------------------------------------------- 1. no automatic assignment
select test.eq('defaults: 3 held, one more every 5 wins, at most 10; one claim every 5 minutes',
  (select string_agg(column_default, ',' order by column_name) from information_schema.columns where table_name = 'sales_lead_settings'
    and column_name in ('lead_cap_base', 'lead_cap_per_wins', 'lead_cap_max', 'claim_cooldown_minutes')), '5,3,10,5');
select test.ok('the least-loaded pick names nobody', app.lead_real_assignee() is null);
create temp table gl_sub as select app.submit_lead(jsonb_build_object('kind', 'owner_program', 'name', 'Gl Owner', 'email', 'gl.owner@example.test', 'consent_marketing', false), null) r;
select test.ok('website form (owner program): unassigned', (select l.assigned_to is null from leads l where l.email = 'gl.owner@example.test'));
create temp table gl_sub2 as select app.submit_lead(jsonb_build_object('kind', 'contact', 'name', 'Gl Contact', 'email', 'gl.contact@example.test', 'message', 'Hello there', 'consent_marketing', false), null) r;
select test.ok('website form (contact): unassigned', (select l.assigned_to is null from leads l where l.email = 'gl.contact@example.test'));
insert into leads (id, kind, name, email, source, assigned_to) values (test.id('lead:gl_auto'), 'contact', 'Auto', 'gl.auto@example.test', 'web', test.id('gl_roman'));
select test.ok('any insert with an assignee picked by itself: unassigned', (select assigned_to is null from leads where id = test.id('lead:gl_auto')));
insert into leads (id, kind, name, email, source, assigned_to, sourced_by) values (test.id('lead:gl_own'), 'owner_program', 'Own', 'gl.own@example.test', 'referral', test.id('gl_ana'), test.id('gl_ana'));
select test.eq('a salesperson''s own lead stays theirs', (select assigned_to from leads where id = test.id('lead:gl_own')), test.id('gl_ana'));
select pg_temp.dr('gl_admin', 'lead_reassign', jsonb_build_object('lead', test.id('lead:gl_auto'), 'to', test.id('gl_roman')));
select test.eq('an Admin''s reassign still assigns', (select assigned_to from leads where id = test.id('lead:gl_auto')), test.id('gl_roman'));
select pg_temp.dr('gl_admin', 'lead_unclaim', jsonb_build_object('lead', test.id('lead:gl_auto'), 'note', 'test'));

-- ---------------------------------------------------------------- 2. one new claim every 5 minutes
select pg_temp.lead(x) from unnest(array['a', 'b', 'c', 'd']) x;
select pg_temp.dr('gl_roman', 'lead_claim', jsonb_build_object('lead', test.id('lead:a')));
select test.throws('pacing: a second claim at once is refused', format($$select pg_temp.dr('gl_roman', 'lead_claim', jsonb_build_object('lead', %L))$$, test.id('lead:b')), 'claim the next one in');
select test.throws('pacing: Next lead too', $$select pg_temp.dr('gl_roman', 'lead_next', '{}'::jsonb)$$, 'claim the next one in');
select test.ok('pacing: the list says when', (public.door(test.id('gl_roman'), 'aal2', 'ops_read', 'sales_leads', '{}'::jsonb) ->> 'next_claim_at') is not null);
select test.lives('pacing: another person is not held by it', format($$select pg_temp.dr('gl_ana', 'lead_claim', jsonb_build_object('lead', %L))$$, test.id('lead:d')));
select pg_temp.later('gl_roman');
select test.lives('pacing: after 5 minutes the next claim goes', format($$select pg_temp.dr('gl_roman', 'lead_claim', jsonb_build_object('lead', %L))$$, test.id('lead:b')));

-- ---------------------------------------------------------------- 3. the cap (2 here)
update sales_lead_settings set lead_cap_base = 2;
select pg_temp.later('gl_roman');
select test.throws('cap: at 2 of 2 the third claim is refused', format($$select pg_temp.dr('gl_roman', 'lead_claim', jsonb_build_object('lead', %L))$$, test.id('lead:c')), 'close one (won, lost or handled) or unclaim it first');
select test.eq('cap: the list says 2 of 2', (select (d ->> 'mine_active') || ' of ' || (d ->> 'max_active') from (select public.door(test.id('gl_roman'), 'aal2', 'ops_read', 'sales_leads', '{}'::jsonb) d) x), '2 of 2');
select pg_temp.dr('gl_roman', 'lead_handled', jsonb_build_object('lead', test.id('lead:a')));
select test.lives('cap: one handled, the next claim goes', format($$select pg_temp.dr('gl_roman', 'lead_claim', jsonb_build_object('lead', %L))$$, test.id('lead:c')));
select test.lives('cap: an Admin is not capped or paced', format($$select pg_temp.dr('gl_admin', 'lead_reassign', jsonb_build_object('lead', %L, 'to', %L))$$, test.id('lead:d'), test.id('gl_roman')));

-- the cap grows with wins in the last 30 days: base 3, one more for every 5 won, at most 10; only won counts
update sales_lead_settings set lead_cap_base = 3;
create function pg_temp.won(p_user text, n integer, p_ago interval, p_outcome text default 'won') returns void language sql as $$
  insert into leads (kind, name, email, source, sales_outcome, sales_outcome_by, sales_outcome_at, handled_at)
  select 'contact', 'Won ' || g, p_user || '.' || p_outcome || '.' || g || '.' || extract(epoch from p_ago)::bigint || '@example.test', 'web', p_outcome, test.id(p_user), now() - p_ago, now() - p_ago
    from generate_series(1, n) g $$;
select test.mk_user('gl_wins', 'va', 'sales');
select test.eq('cap: no wins, the base 3', app.sl_cap(test.id('gl_wins')) ->> 'cap', '3');
select test.eq('cap: no wins, 5 more wins to the next', app.sl_cap(test.id('gl_wins')) ->> 'wins_to_next', '5');
select pg_temp.won('gl_wins', 4, interval '1 day');
select test.eq('cap: 4 wins, still 3, one more win to go', (app.sl_cap(test.id('gl_wins')) ->> 'cap') || ':' || (app.sl_cap(test.id('gl_wins')) ->> 'wins_to_next'), '3:1');
select pg_temp.won('gl_wins', 1, interval '2 days');
select test.eq('cap: 5 wins, 4', app.sl_cap(test.id('gl_wins')) ->> 'cap', '4');
select pg_temp.won('gl_wins', 10, interval '40 days');
select test.eq('cap: wins older than 30 days do not count', app.sl_cap(test.id('gl_wins')) ->> 'cap', '4');
select pg_temp.won('gl_wins', 10, interval '3 days', 'lost');
select test.eq('cap: lost leads do not count', app.sl_cap(test.id('gl_wins')) ->> 'cap', '4');
select pg_temp.won('gl_wins', 60, interval '3 days');
select test.eq('cap: at most 10, and no next slot', (app.sl_cap(test.id('gl_wins')) ->> 'cap') || ':' || coalesce(app.sl_cap(test.id('gl_wins')) ->> 'wins_to_next', 'none'), '10:none');
select test.eq('cap: the lead list shows the person''s cap', public.door(test.id('gl_wins'), 'aal2', 'ops_read', 'sales_leads', '{}'::jsonb) ->> 'max_active', '10');
select test.ok('cap: the Admin''s team table shows each cap',
  coalesce((select bool_and(t ? 'cap') from jsonb_array_elements(public.door(test.id('gl_admin'), 'aal2', 'ops_read', 'sales_dashboard', '{}'::jsonb) -> 'team') t), true));

-- ---------------------------------------------------------------- 4. a claim that runs out returns the lead
update lead_claims set expires_at = now() - interval '1 minute' where lead_id = test.id('lead:b');
select app.sl_expire();
select test.ok('expiry: the lead is back on the list', not exists (select 1 from lead_claims where lead_id = test.id('lead:b')));
select test.eq('expiry: logged', (select count(*) from lead_claim_log where lead_id = test.id('lead:b') and action = 'expire')::int, 1);

-- ---------------------------------------------------------------- 5. the one-time sweep
select pg_temp.lead('sweep1'); select pg_temp.lead('sweep2');
select set_config('app.lead_admin_move', 'on', false);
update leads set assigned_to = test.id('gl_ana') where id in (test.id('lead:sweep1'), test.id('lead:sweep2'));
select set_config('app.lead_admin_move', '', false);
insert into lead_contacts (lead_id, by_user, channel, note) values (test.id('lead:sweep2'), test.id('gl_ana'), 'call', 'Called them');
select test.ok('sweep: moves the auto-assigned lead', app.leads_unassign_auto() >= 1);
select test.ok('sweep: the untouched lead is open again', (select assigned_to is null from leads where id = test.id('lead:sweep1')));
select test.eq('sweep: logged as a release', (select count(*) from lead_claim_log where lead_id = test.id('lead:sweep1') and action = 'release' and user_id = test.id('gl_ana'))::int, 1);
select test.eq('sweep: a lead with real work stays', (select assigned_to from leads where id = test.id('lead:sweep2')), test.id('gl_ana'));
select test.eq('sweep: a salesperson''s own lead stays', (select assigned_to from leads where id = test.id('lead:gl_own')), test.id('gl_ana'));

-- back to the relaxed values of the other suites (helpers.sql)
update sales_lead_settings set claim_cooldown_minutes = 0, lead_cap_base = 25, lead_cap_per_wins = 5, lead_cap_max = 25;
