-- 99: one page per object for Admin and staff (r31 "Simple", web/src/features/shared-pages). The Admin and staff
-- addresses render the same booking, vehicle and listing page; what each staff function sees comes from the reads
-- below, so these pin what each function's door answers on those pages: the page shows a part only when the read has it.
-- Uses the request helpers of 06 (test.rq_new, test.b) and the operations helper of 09 (test.op_confirm).
select test.suite('99 shared pages');

select test.mk_user('shp_admin', 'admin');
select test.mk_user('shp_cs', 'va', 'cs');
select test.mk_user('shp_fin', 'va', 'finance');
select test.mk_user('shp_fleet', 'va', 'fleet');
select test.mk_user('shp_sales', 'va', 'sales');
select test.mk_user('shp_field', 'field', null, 'driver');
select test.mk_owner('shp_o');
select test.mk_vehicle('shpV', 'shp_o');
select test.mk_renter('shp_r');
select test.rq_new('shpA', 'shp_r', 'shpV', '2031-03-02 10:00', '2031-03-05 10:00');
select test.op_confirm('shpA', 'shp_r');
insert into listing_intakes (id, vehicle_id, started_by, started_role, review_required, state)
  values (test.id('intake:shpV'), test.id('vehicle:shpV'), test.id('shp_admin'), 'admin', true, 'needs_review');

create function test.shp_keys(p_user text, p_call text, p_name text, p jsonb) returns text language sql as $$
  select string_agg(k, ',' order by k) from jsonb_object_keys(public.door(test.id(p_user), null, p_call, p_name, p)) k
  where k in ('payments', 'refunds', 'statements', 'emails', 'history', 'offers', 'documents', 'deposit', 'events', 'drivers',
              'terms', 'fee_overrides', 'fee_types', 'schedule', 'owner', 'coverage_prices', 'rate_history', 'transitions')
$$;

-- ---------------------------------------------------------------- the booking page
select test.eq('booking: an Admin reads everything the page shows',
  test.shp_keys('shp_admin', 'admin_read', 'booking', jsonb_build_object('id', test.b('shpA'))),
  'deposit,documents,drivers,emails,events,history,offers,payments,refunds,statements');
select test.eq('booking: Fleet reads no money (the page has no Money section for Fleet)',
  test.shp_keys('shp_fleet', 'va_read', 'booking', jsonb_build_object('id', test.b('shpA'), '_va', 'fleet')),
  'deposit,documents,drivers,events,history,offers');
select test.eq('booking: customer service reads the payments and refunds (shown, no refund button)',
  test.shp_keys('shp_cs', 'va_read', 'booking', jsonb_build_object('id', test.b('shpA'), '_va', 'cs')),
  'deposit,documents,drivers,emails,events,history,offers,payments,refunds,statements');
select test.eq('booking: Finance reads the payments and refunds',
  test.shp_keys('shp_fin', 'va_read', 'booking', jsonb_build_object('id', test.b('shpA'), '_va', 'finance')),
  'deposit,documents,drivers,emails,events,history,offers,payments,refunds,statements');
select test.throws('booking: Sales is refused a confirmed booking (the page says it is not theirs)',
  format($$select public.door(%L, null, 'va_read', 'booking', jsonb_build_object('id', %L, '_va', 'sales'))$$, test.id('shp_sales'), test.b('shpA')),
  'Sales works on requests and offers only');
select test.throws('booking: field staff have no office booking read',
  format($$select public.door(%L, null, 'va_read', 'booking', jsonb_build_object('id', %L))$$, test.id('shp_field'), test.b('shpA')));
select test.throws('booking: an assistant cannot use the Admin read of the same page',
  format($$select public.door(%L, null, 'admin_read', 'booking', jsonb_build_object('id', %L))$$, test.id('shp_cs'), test.b('shpA')), 'Only an Admin');

-- ---------------------------------------------------------------- the vehicle page
select test.eq('vehicle: an Admin reads the owner terms, the fees and the transitions',
  test.shp_keys('shp_admin', 'admin_read', 'vehicle', jsonb_build_object('id', test.id('vehicle:shpV'))),
  'coverage_prices,documents,fee_overrides,fee_types,owner,rate_history,schedule,terms,transitions');
select test.eq('vehicle: Fleet reads the car and its documents, without the owner terms, fees or Revenue Share',
  test.shp_keys('shp_fleet', 'va_read', 'vehicle', jsonb_build_object('id', test.id('vehicle:shpV'), '_va', 'fleet')), 'documents');
select test.eq('vehicle: customer service the same',
  test.shp_keys('shp_cs', 'va_read', 'vehicle', jsonb_build_object('id', test.id('vehicle:shpV'), '_va', 'cs')), 'documents');
select test.throws('vehicle: Finance does not read the car (the page shows its maintenance only)',
  format($$select public.door(%L, null, 'va_read', 'vehicle', jsonb_build_object('id', %L, '_va', 'finance'))$$, test.id('shp_fin'), test.id('vehicle:shpV')), 'Not permitted');
select test.throws('vehicle: nor does Sales',
  format($$select public.door(%L, null, 'va_read', 'vehicle', jsonb_build_object('id', %L, '_va', 'sales'))$$, test.id('shp_sales'), test.id('vehicle:shpV')), 'Not permitted');

-- ---------------------------------------------------------------- the listing review page
select test.ok('listing: customer service reads the listing review',
  public.door(test.id('shp_cs'), null, 'va_read', 'listing', jsonb_build_object('id', test.id('intake:shpV'), '_va', 'cs')) ? 'vehicle_id');
select test.ok('listing: Fleet reads the listing review',
  public.door(test.id('shp_fleet'), null, 'va_read', 'listing', jsonb_build_object('id', test.id('intake:shpV'), '_va', 'fleet')) ? 'vehicle_id');
select test.throws('listing: Finance does not review listings',
  format($$select public.door(%L, null, 'va_read', 'listing', jsonb_build_object('id', %L, '_va', 'finance'))$$, test.id('shp_fin'), test.id('intake:shpV')), 'Listings are reviewed by customer service and fleet');
select test.throws('listing: nor does Sales',
  format($$select public.door(%L, null, 'va_read', 'listing', jsonb_build_object('id', %L, '_va', 'sales'))$$, test.id('shp_sales'), test.id('intake:shpV')), 'Listings are reviewed by customer service and fleet');
