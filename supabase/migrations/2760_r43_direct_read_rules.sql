-- 2760 (release 43): the masked-number rule also holds on direct table reads.
-- Since 0970 a person who works in Sales only is shown customer numbers masked: every read through the door comes back
-- masked. The row policies of 0012 to 0280 still returned the same rows, unmasked, to a session reading the tables
-- themselves. The website never reads these tables as a browser session (it goes through the door), so for that person
-- the direct read of the tables that hold customer numbers is closed. Admins, customer service, fleet and finance are
-- unchanged, and so is a person's own renter record.

create or replace function app.direct_read_masked() returns boolean
language sql stable security definer set search_path = public, app as $$
  select app.uid() is not null
     and app.user_va_has(app.uid(), 'sales')
     and not app.user_is_admin(app.uid())
     and not app.user_va_has(app.uid(), 'cs', 'fleet', 'finance')
$$;
revoke all on function app.direct_read_masked() from public, anon;
grant execute on function app.direct_read_masked() to authenticated, service_role;
comment on function app.direct_read_masked() is '2760: the signed-in person works in Sales only (numbers are masked for them, 0970): the tables that hold customer numbers are not read directly.';

drop policy if exists masked_no_direct on renters;
create policy masked_no_direct on renters as restrictive for select to authenticated
  using (not app.direct_read_masked() or id = app.my_renter_id());
drop policy if exists masked_no_direct on contact_captures;
create policy masked_no_direct on contact_captures as restrictive for select to authenticated
  using (not app.direct_read_masked());
drop policy if exists masked_no_direct on chauffeur_requests;
create policy masked_no_direct on chauffeur_requests as restrictive for select to authenticated
  using (not app.direct_read_masked());
drop policy if exists masked_no_direct on phone_gate_contacts;
create policy masked_no_direct on phone_gate_contacts as restrictive for select to authenticated
  using (not app.direct_read_masked());
