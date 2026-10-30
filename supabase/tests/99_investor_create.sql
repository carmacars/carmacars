-- 99: Admin adds an investor record (migration 0210). Fixtures start with "ivc".
select test.suite('99 investor create');
select test.mk_user('ivc_admin', 'admin');
select test.mk_user('ivc_cs', 'va', 'cs');

select test.eq('an individual, with the offer''s yearly percentage by default',
  (public.door(test.id('ivc_admin'), 'aal2', 'admin_do', 'investor_create', '{"legal_name": "Iris Investor", "investor_type": "individual", "email": "Iris.Ivc@example.test", "phone": "+14165550100", "address": "100 Queen Street West, Toronto, ON"}') ->> 'offered_yearly_bps')::int,
  (select deck_return_bps from deck_settings limit 1));
select test.ok('on file as a prospect, the email in lower case', exists (select 1 from investors where email = 'iris.ivc@example.test' and status = 'prospect' and user_id is null and address like '100 Queen%'));
select test.throws('one record per email',
  format($s$select public.door(%L, 'aal2', 'admin_do', 'investor_create', '{"legal_name": "Iris Again", "email": "iris.ivc@example.test"}')$s$, test.id('ivc_admin')), 'already on file');
select test.throws('a corporation names its signatory',
  format($s$select public.door(%L, 'aal2', 'admin_do', 'investor_create', '{"legal_name": "Ivc Holdings Inc.", "investor_type": "corporation", "email": "hold.ivc@example.test"}')$s$, test.id('ivc_admin')), 'signs for the corporation');
select public.door(test.id('ivc_admin'), 'aal2', 'admin_do', 'investor_create', '{"legal_name": "Ivc Holdings Inc.", "investor_type": "corporation", "signatory_name": "Ivan Officer", "email": "hold.ivc@example.test", "committed_amount_cents": 5000000, "offered_yearly_bps": 2500}');
select test.ok('a corporation with its signatory, the amount committed and a typed percentage', exists (select 1 from investors where email = 'hold.ivc@example.test'
  and investor_type = 'corporation' and signatory_name = 'Ivan Officer' and committed_amount_cents = 5000000 and offered_yearly_bps = 2500));
select test.throws('Admins only',
  format($s$select public.door(%L, 'aal2', 'admin_do', 'investor_create', '{"legal_name": "Nope", "email": "nope.ivc@example.test"}')$s$, test.id('ivc_cs')));
select test.throws('an email is required',
  format($s$select public.door(%L, 'aal2', 'admin_do', 'investor_create', '{"legal_name": "No Mail"}')$s$, test.id('ivc_admin')), 'email');
