-- 99: release 35 gaps (migration 1850): the Fund a car sheet's default daily rate is a Program setting.
select test.suite('99 r35 gaps 2');
select test.mk_user('g2_inv', 'renter');
insert into investors (id, user_id, legal_name, investor_type, status, email) values (test.id('g2:inv'), test.id('g2_inv'), 'Gee Example', 'individual', 'active', 'g2@example.test');
select test.eq('the sheet daily rate defaults to $80', (select investor_sheet_daily_rate_cents from program_settings), 8000);
update program_settings set investor_sheet_daily_rate_cents = 9500;
select test.eq('an investor reads the setting with the sheet terms and no fleet figure',
  (select (x ->> 'sheet_daily_rate_cents') || '/' || (x ? 'cars')::text from (select public.door(test.id('g2_inv'), 'aal2', 'investor_read', 'model_terms', '{}') as x) q), '9500/false');
select test.throws('a negative rate is refused', 'update program_settings set investor_sheet_daily_rate_cents = -1', 'check');
-- one phone number everywhere (migration 1851): the old digits are gone from guides, templates and lessons
select test.eq('no guide chapter carries the old phone digits', (select count(*)::int from guide_sections where coalesce(body_md,'') || coalesce(published_md,'') || coalesce(published_html,'') like '%289-321-5991%'), 0);
select test.eq('no template carries the old phone digits', (select count(*)::int from message_templates where body like '%289-321-5991%'), 0);
select test.eq('no academy lesson carries the old phone digits', (select count(*)::int from academy_lessons where scenes::text like '%289-321-5991%'), 0);
