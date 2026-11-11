-- 99: release 35 gaps (migration 1850): the Fund a car sheet's default daily rate is a Program setting.
select test.suite('99 r35 gaps 2');
select test.mk_user('g2_inv', 'renter');
insert into investors (id, user_id, legal_name, investor_type, status, email) values (test.id('g2:inv'), test.id('g2_inv'), 'Gee Example', 'individual', 'active', 'g2@example.test');
select test.eq('the sheet daily rate defaults to $80', (select investor_sheet_daily_rate_cents from program_settings), 8000);
update program_settings set investor_sheet_daily_rate_cents = 9500;
select test.eq('an investor reads the setting with the sheet terms and no fleet figure',
  (select (x ->> 'sheet_daily_rate_cents') || '/' || (x ? 'cars')::text from (select public.door(test.id('g2_inv'), 'aal2', 'investor_read', 'model_terms', '{}') as x) q), '9500/false');
select test.throws('a negative rate is refused', 'update program_settings set investor_sheet_daily_rate_cents = -1', 'check');
