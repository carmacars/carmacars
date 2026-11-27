-- r49: the booking record's document list leaves out removed documents (0821 soft removal) and purged ones. Fixtures start with "r49d".
select test.suite('99 r49 booking documents tab');
grant usage on schema test to service_role;
grant execute on all functions in schema test to authenticated, anon, service_role;

select test.mk_owner('r49d_o');
select test.mk_vehicle('R49D', 'r49d_o');
select test.mk_renter('r49d_r', false);
select test.mk_booking('R49D-1', 'R49D', 'r49d_r', test.fut('2026-12-02 10:00'), test.fut('2026-12-04 10:00'), 'confirmed', 20000);

insert into documents (kind, title, storage_bucket, storage_path, booking_id) values
  ('receipt', 'kept', 'documents', 'r49d/kept.pdf', test.id('booking:R49D-1')),
  ('receipt', 'removed', 'documents', 'r49d/removed.pdf', test.id('booking:R49D-1'));
update documents set removed_at = now(), removed_reason = 'Replaced' where title = 'removed' and booking_id = test.id('booking:R49D-1');

select test.eq('only the kept document is listed',
  (select string_agg(x ->> 'title', ',') from jsonb_array_elements(app.admin_booking_detail(test.id('booking:R49D-1')) -> 'documents') x), 'kept');
select test.ok('the rest of the record is still there', (app.admin_booking_detail(test.id('booking:R49D-1')) -> 'booking') is not null or (app.admin_booking_detail(test.id('booking:R49D-1')) ? 'events'));
