-- 2361: referral partners who send rentals (the owner, November 11, 20:19 and 20:24; Admin > Referral partners refused a 60%
-- kickback for an insurance broker, E-DGB6AN, because 0164 capped the percentage at 50%).
--   1. A partner's percentage goes up to 100% of the rental before tax (after discounts: app.commission_base_cents, the same
--      base as staff commission). A new kind, "Insurer rentals" (insurance replacement referrals).
--   2. HST on the commission: off by default (commission_hst); when on, the partner's statement adds 13% on top of what they
--      earned (hst_cents on each earning and the totals). The commission itself is always computed before tax.
--   3. Sourced by: a Sales person who brought the partner earns sourced_by_bps of each rental the partner refers (the same
--      pre-tax base, no HST on it), as staff_commissions of kind partner_sourced: on their statement, approved and paid with
--      their other commissions, following the partner's earning on that booking (accruing, pending approval, void when the
--      partner's is). 2330's rule holds: a person with only customer service, Fleet or Finance is never that person (refused
--      when picked; the commission row is never made).
-- No applied migration is edited: functions are wrapped (their grants copied).
set local check_function_bodies = off;

create function pg_temp.copy_grants(p_new regprocedure, p_old regprocedure) returns void
language plpgsql as $$
declare g text;
begin
  execute format('revoke all on function %s from public, anon, authenticated', p_new);
  foreach g in array array['anon', 'authenticated', 'service_role'] loop
    if has_function_privilege(g, p_old, 'execute') then execute format('grant execute on function %s to %I', p_new, g); end if;
  end loop;
end $$;

-- ================================================================ 1. the columns
do $$
declare c record;
begin
  for c in select conname from pg_constraint where conrelid = 'referral_partners'::regclass and contype = 'c'
              and (pg_get_constraintdef(oid) like '%rate_bps%' or pg_get_constraintdef(oid) like '%insurance_broker%') loop
    execute format('alter table referral_partners drop constraint %I', c.conname);
  end loop;
end $$;
alter table referral_partners add constraint referral_partners_rate_bps_check check (rate_bps between 0 and 10000);
alter table referral_partners add constraint referral_partners_kind_check check (kind in ('body_shop', 'tow_truck', 'dealership', 'insurance_broker', 'insurer_rentals'));
alter table referral_partners add column if not exists commission_hst boolean not null default false;
alter table referral_partners add column if not exists sourced_by uuid references users (id) on delete set null;
alter table referral_partners add column if not exists sourced_by_bps integer not null default 0 check (sourced_by_bps between 0 and 10000);
create index if not exists referral_partners_sourced_by_idx on referral_partners (sourced_by);
comment on column referral_partners.commission_hst is 'HST added on top of the partner''s commission on their statement (2361); off by default. The commission is always computed before tax.';
comment on column referral_partners.sourced_by is 'The Sales person who brought this partner (2361): earns sourced_by_bps of each rental the partner refers, before tax, no HST (staff_commissions kind partner_sourced).';

alter table staff_commissions add column if not exists referral_partner_id uuid references referral_partners (id);
create index if not exists staff_commissions_referral_partner_idx on staff_commissions (referral_partner_id);
alter table staff_commissions drop constraint if exists staff_commissions_kind_check;
alter table staff_commissions add constraint staff_commissions_kind_check check (kind in ('commission', 'clawback', 'adjustment', 'owner_recruit', 'partner_sourced'));
alter table staff_commissions drop constraint if exists staff_commissions_clawback_of_check;
alter table staff_commissions add constraint staff_commissions_clawback_of_check check (kind in ('commission', 'owner_recruit', 'partner_sourced') or clawback_of is not null);
alter table staff_commissions add constraint staff_commissions_partner_sourced_check check ((kind = 'partner_sourced') = (referral_partner_id is not null) or kind in ('clawback', 'adjustment'));
create unique index if not exists staff_commissions_partner_sourced_idx on staff_commissions (booking_id, staff_id) where kind = 'partner_sourced';

-- ================================================================ 2. the save: the new kind, HST, sourced by
alter function app.referral_partner_save(uuid, jsonb) rename to referral_partner_save_pre2361;
create function app.referral_partner_save(p_by uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  v jsonb;
  v_id uuid;
  v_src uuid := nullif(p ->> 'sourced_by', '')::uuid;
  v_bps integer := nullif(p ->> 'sourced_by_bps', '')::integer;
  v_kind text := nullif(p ->> 'kind', '');
begin
  perform app.assert_admin(p_by);
  if coalesce((p ->> 'rate_bps')::integer, 0) not between 0 and 10000 then raise exception 'A percentage is 0 to 100%%' using errcode = '22023'; end if;
  if v_bps is not null and v_bps not between 0 and 10000 then raise exception 'The sourced-by percentage is 0 to 100%%' using errcode = '22023'; end if;
  if v_src is not null and not app.user_is_sales_staff(v_src) and not app.user_is_admin(v_src) then raise exception 'Sourced by: pick a Sales person' using errcode = '22023'; end if;
  if v_src is not null and app.credit_blocked(v_src) then raise exception 'Customer service, Fleet and Finance earn no commission (2330): pick a Sales person' using errcode = '22023'; end if;
  -- 0164's save knows four kinds: the new one is saved as a broker first, then set
  v := app.referral_partner_save_pre2361(p_by, case when v_kind = 'insurer_rentals' then p || '{"kind": "insurance_broker"}' else p end);
  v_id := (v ->> 'id')::uuid;
  update referral_partners set
    kind = case when v_kind = 'insurer_rentals' then 'insurer_rentals' else kind end,
    commission_hst = case when p ? 'commission_hst' then coalesce((p ->> 'commission_hst')::boolean, false) else commission_hst end,
    sourced_by = case when p ? 'sourced_by' then v_src else sourced_by end,
    sourced_by_bps = case when p ? 'sourced_by_bps' then coalesce(v_bps, 0) else sourced_by_bps end
   where id = v_id;
  if p ? 'sourced_by' or p ? 'sourced_by_bps' or p ? 'commission_hst' then
    insert into audit_log (actor_user_id, action, entity_table, entity_id, after)
    select p_by, 'referral_partner_terms', 'referral_partners', v_id::text, jsonb_build_object('sourced_by', x.sourced_by, 'sourced_by_bps', x.sourced_by_bps, 'commission_hst', x.commission_hst)
      from referral_partners x where x.id = v_id;
  end if;
  return app.referral_partner_row((select x from referral_partners x where x.id = v_id));
end $$;
select pg_temp.copy_grants('app.referral_partner_save(uuid, jsonb)'::regprocedure, 'app.referral_partner_save_pre2361(uuid, jsonb)'::regprocedure);

-- ================================================================ 3. what the partner page shows
alter function app.referral_partner_row(referral_partners) rename to referral_partner_row_pre2361;
create function app.referral_partner_row(p referral_partners) returns jsonb
language sql stable security definer set search_path = public, app as $$
  select app.referral_partner_row_pre2361(p) || jsonb_build_object(
    'sourced_by_name', (select coalesce(nullif(btrim(u.greeting_name), ''), u.full_name, u.email) from users u where u.id = p.sourced_by),
    'sourced_by_text', case when p.sourced_by is not null and p.sourced_by_bps > 0
      then trim(trailing '.' from trim(trailing '0' from to_char(p.sourced_by_bps / 100.0, 'FM990.00'))) || '% of each referred rental before tax, no HST' end,
    'hst_text', case when p.commission_hst then 'HST (13%) added on top of the commission' else 'No HST on the commission' end,
    'sourced_by_cents', (select coalesce(sum(c.amount_cents), 0) from staff_commissions c where c.referral_partner_id = p.id and c.kind = 'partner_sourced' and c.status not in ('void', 'reversed')))
$$;
select pg_temp.copy_grants('app.referral_partner_row(referral_partners)'::regprocedure, 'app.referral_partner_row_pre2361(referral_partners)'::regprocedure);

-- HST on an earning (the partner's statement): 13% of the amount when the partner has HST on, else 0
create function app.referral_earning_hst_cents(p_partner uuid, p_amount bigint) returns bigint
language sql stable security definer set search_path = public, app as $$
  select case when coalesce((select commission_hst from referral_partners where id = p_partner), false) then round(coalesce(p_amount, 0) * 0.13)::bigint else 0 end
$$;
alter function app.referral_earning_row(referral_partner_earnings) rename to referral_earning_row_pre2361;
create function app.referral_earning_row(e referral_partner_earnings) returns jsonb
language sql stable security definer set search_path = public, app as $$
  select app.referral_earning_row_pre2361(e) || jsonb_build_object('hst_cents', app.referral_earning_hst_cents(e.partner_id, e.amount_cents),
    'total_cents', e.amount_cents + app.referral_earning_hst_cents(e.partner_id, e.amount_cents))
$$;
select pg_temp.copy_grants('app.referral_earning_row(referral_partner_earnings)'::regprocedure, 'app.referral_earning_row_pre2361(referral_partner_earnings)'::regprocedure);

-- the Sales people an Admin may pick as Sourced by (the list page)
alter function app.referral_partners_read(uuid, jsonb) rename to referral_partners_read_pre2361;
create function app.referral_partners_read(p_by uuid, p jsonb) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare v jsonb := app.referral_partners_read_pre2361(p_by, p);
begin
  return jsonb_set(v, '{settings,sales_staff}', coalesce((select jsonb_agg(jsonb_build_array(sp.user_id, coalesce(nullif(btrim(u.greeting_name), ''), u.full_name, u.email)) order by u.full_name)
    from staff_profiles sp join users u on u.id = sp.user_id where sp.is_active and 'sales' = any (sp.functions) and not app.credit_blocked(sp.user_id)), '[]'::jsonb));
end $$;
select pg_temp.copy_grants('app.referral_partners_read(uuid, jsonb)'::regprocedure, 'app.referral_partners_read_pre2361(uuid, jsonb)'::regprocedure);

-- ================================================================ 4. the sourced-by commission follows the partner's earning
create function app.referral_sourced_sync(p_booking uuid) returns void
language plpgsql security definer set search_path = public, app as $$
declare
  e referral_partner_earnings;
  pr referral_partners;
  c staff_commissions;
  v_amount bigint;
  v_status text;
begin
  select * into e from referral_partner_earnings x where x.booking_id = p_booking and x.kind = 'earning' order by x.created_at desc limit 1;
  -- the rows of a partner no longer credited on this booking: void (a paid one stays for an Admin)
  update staff_commissions set status = 'void', reason = 'The booking is no longer the partner''s', updated_at = now()
   where booking_id = p_booking and kind = 'partner_sourced' and status in ('accruing', 'pending_approval', 'approved')
     and (e.id is null or referral_partner_id is distinct from e.partner_id);
  if e.id is null then return; end if;
  select * into pr from referral_partners where id = e.partner_id;
  select * into c from staff_commissions where booking_id = p_booking and kind = 'partner_sourced' and referral_partner_id = pr.id and status <> 'void' for update;
  v_status := case when e.status in ('void', 'reversed') or e.reversed_at is not null then 'void'
                   when e.status = 'accruing' then 'accruing' else 'pending_approval' end;
  if pr.sourced_by is null or pr.sourced_by_bps <= 0 then
    if c.id is not null and c.status in ('accruing', 'pending_approval', 'approved') then
      update staff_commissions set status = 'void', reason = 'The partner has no sourced-by person now', updated_at = now() where id = c.id;
    end if;
    return;
  end if;
  v_amount := round(greatest(e.base_cents, 0) * pr.sourced_by_bps / 10000.0)::bigint;
  if c.id is null then
    if v_status <> 'void' then
      insert into staff_commissions (booking_id, staff_id, kind, referral_partner_id, month, base_cents, rate_bps, amount_cents, status, earned_at, note)
      values (p_booking, pr.sourced_by, 'partner_sourced', pr.id, date_trunc('month', app.today())::date, greatest(e.base_cents, 0), pr.sourced_by_bps, v_amount, v_status,
              case when v_status = 'pending_approval' then now() end, 'Sourced partner: ' || pr.business_name || ' (before tax, no HST)');
    end if;
  elsif c.status in ('accruing', 'pending_approval', 'approved') then
    update staff_commissions set base_cents = greatest(e.base_cents, 0), amount_cents = v_amount,
           status = case when v_status = 'void' then 'void' when c.status = 'approved' and c.amount_cents = v_amount then 'approved' else v_status end,
           earned_at = case when v_status = 'pending_approval' then coalesce(earned_at, now()) else null end, updated_at = now()
     where id = c.id;
  end if;
end $$;

alter function app.referral_partner_sync(uuid) rename to referral_partner_sync_pre2361;
create function app.referral_partner_sync(p_booking uuid) returns void
language plpgsql security definer set search_path = public, app as $$
begin
  perform app.referral_partner_sync_pre2361(p_booking);
  perform app.referral_sourced_sync(p_booking);
end $$;
select pg_temp.copy_grants('app.referral_partner_sync(uuid)'::regprocedure, 'app.referral_partner_sync_pre2361(uuid)'::regprocedure);

-- ================================================================ 5. privileges
do $$
declare f record;
begin
  for f in
    select p.oid::regprocedure as sig from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'app' and p.proname = any (array['referral_partner_save_pre2361', 'referral_partner_row_pre2361', 'referral_earning_hst_cents', 'referral_earning_row_pre2361',
       'referral_partners_read_pre2361', 'referral_sourced_sync', 'referral_partner_sync_pre2361'])
  loop
    execute format('revoke all on function %s from public, anon, authenticated', f.sig);
    execute format('grant execute on function %s to service_role', f.sig);
  end loop;
end $$;

-- ================================================================ 6. the home address and pay options follow where the person works
-- (the owner, 20:24: a Toronto in-person hire was shown a Philippine address example and GCash / OnlineJobs.ph): canada is true
-- for a person located in Canada or hired in person (Sales in person; field staff work in the Toronto area)
alter function app.staff_home_address_read(uuid) rename to staff_home_address_read_pre2361;
create function app.staff_home_address_read(p_user uuid) returns jsonb
language sql stable security definer set search_path = public, app as $$
  select app.staff_home_address_read_pre2361(p_user) || jsonb_build_object('canada', coalesce((
    select coalesce(sp.location_country, '') ~* '^\s*(canada|ca)\s*$' or sp.sales_work_mode = 'in_person' or 'field' = any (sp.functions) or app.user_is_field(p_user)
      from staff_profiles sp where sp.user_id = p_user), app.user_is_field(p_user)))
$$;
select pg_temp.copy_grants('app.staff_home_address_read(uuid)'::regprocedure, 'app.staff_home_address_read_pre2361(uuid)'::regprocedure);
revoke all on function app.staff_home_address_read_pre2361(uuid) from public, anon, authenticated;
grant execute on function app.staff_home_address_read_pre2361(uuid) to service_role;
