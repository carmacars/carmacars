-- 0543: referral links between owners: a share of the management fee and a read-only view of the cars
-- (docs/changes/2026-11-07-r28-operations.md, A10).
--
-- The owner: an owner on a 40% management fee and $350 a month per car (owner_terms, set per car by an Admin as
-- before); the 10 points above the standard 30% go to the owner who referred them, every statement period, as a line
-- per referred car on the referrer's statement; and the referrer sees every car of the referred owner in the owner
-- portal, read only: bookings, utilization, revenue, the per-car performance (never the referred owner's personal
-- details). Set up by an Admin between any two owners (Admin > Owners > the referrer > Referral links); nothing is
-- named here.
--   owner_referral_links    referrer, referred, the share (basis points of the revenue base the fee is taken from,
--                           1000 = 10 points), whether the referrer sees the cars, from, to.
--   owner_referral_shares   one row per link and booking split (never paid twice): the base, the share, the amount,
--                           the referrer's statement that pays it.
--   Statements: building the referrer's statement adds a "Referral share" line per referred car (line_type
--   referral_share) and adds it to the payout (as Referral Kickbacks are). A referrer with no car of their own gets a
--   statement whenever the referred owner's statement is built. The share comes out of CarmaCars' share of that
--   booking, never out of the referred owner's payout.
-- No applied migration is edited.

create function pg_temp.copy_grants(p_new regprocedure, p_old regprocedure) returns void
language plpgsql as $$
declare g text;
begin
  execute format('revoke all on function %s from public, anon, authenticated', p_new);
  foreach g in array array['anon', 'authenticated', 'service_role'] loop
    if has_function_privilege(g, p_old, 'execute') then execute format('grant execute on function %s to %I', p_new, g); end if;
  end loop;
end $$;

create table if not exists owner_referral_links (
  id                uuid primary key default gen_random_uuid(),
  referrer_owner_id uuid not null references owners (id),
  referred_owner_id uuid not null references owners (id),
  share_bps         integer not null default 1000 check (share_bps between 0 and 5000),
  sees_cars         boolean not null default true,
  effective_from    date not null default current_date,
  effective_to      date,
  note              text check (char_length(note) <= 500),
  created_by        uuid references users (id) on delete set null,
  created_at        timestamptz not null default now(),
  updated_at        timestamptz not null default now(),
  check (referrer_owner_id <> referred_owner_id),
  check (effective_to is null or effective_to > effective_from)
);
create unique index if not exists owner_referral_links_one_open on owner_referral_links (referrer_owner_id, referred_owner_id) where effective_to is null;
alter table owner_referral_links enable row level security;
create policy admin_all on owner_referral_links for all to authenticated using (app.is_admin()) with check (app.is_admin());
create trigger audit_owner_referral_links after insert or update or delete on owner_referral_links for each row execute function app.audit_row();
comment on table owner_referral_links is 'An owner who referred another owner (0543): a share of the revenue base of the referred owner''s cars on each statement, and a read-only view of those cars. Set by an Admin.';

create table if not exists owner_referral_shares (
  id                 uuid primary key default gen_random_uuid(),
  link_id            uuid not null references owner_referral_links (id),
  booking_id         uuid not null references bookings (id),
  vehicle_id         uuid not null references vehicles (id),
  referrer_owner_id  uuid not null references owners (id),
  payout_month       date not null,
  base_cents         bigint not null,
  share_bps          integer not null,
  amount_cents       bigint not null,
  owner_statement_id uuid references owner_statements (id),
  created_at         timestamptz not null default now(),
  unique (link_id, booking_id, vehicle_id)
);
create index if not exists owner_referral_shares_open on owner_referral_shares (referrer_owner_id) where owner_statement_id is null;
alter table owner_referral_shares enable row level security;
create policy admin_read on owner_referral_shares for select to authenticated using (app.is_admin());
comment on table owner_referral_shares is 'Each booking''s referral share for an owner referral link (0543): paid once, on the referrer''s statement.';

alter table owner_statement_lines drop constraint if exists owner_statement_lines_line_type_check;
alter table owner_statement_lines add constraint owner_statement_lines_line_type_check check (line_type = any (array[
  'rental', 'turo_trip', 'withheld', 'fees_deducted', 'owner_cost', 'refund_or_chargeback', 'arrears_moved', 'kickback_earned',
  'hst_on_payout', 'balance_brought_forward', 'later_revenue', 'flat_payment', 'referral_share']));

-- ================================================================ the shares due to a referrer up to a month
create or replace function app.referral_shares_sync(p_referrer uuid, p_month date) returns integer
language plpgsql security definer set search_path = public, app as $$
declare
  v_month date := app.month_start(p_month);
  v_n integer;
begin
  insert into owner_referral_shares (link_id, booking_id, vehicle_id, referrer_owner_id, payout_month, base_cents, share_bps, amount_cents)
  select l.id, s.booking_id, s.vehicle_id, l.referrer_owner_id, s.payout_month, s.owner_revenue_cents, l.share_bps,
         round(s.owner_revenue_cents * l.share_bps / 10000.0)::bigint
    from owner_referral_links l
    join booking_splits s on s.owner_id = l.referred_owner_id
   where l.referrer_owner_id = p_referrer and l.share_bps > 0
     and s.status <> 'reversed' and s.uncollected_cents = 0 and s.payout_month <= v_month
     and s.payout_month >= app.month_start(l.effective_from) and (l.effective_to is null or s.payout_month < l.effective_to)
     and s.owner_revenue_cents > 0
  on conflict (link_id, booking_id, vehicle_id) do nothing;
  get diagnostics v_n = row_count;
  return v_n;
end $$;

-- ================================================================ statements
alter function app.build_owner_statement(uuid, date, uuid) rename to build_owner_statement_pre0543;
create function app.build_owner_statement(p_owner uuid, p_month date, p_by uuid default null) returns uuid
language plpgsql security definer set search_path = public, app as $$
declare
  v_month date := app.month_start(p_month);
  v_id uuid;
  v_share bigint;
  v_total bigint;
  r record;
begin
  -- a draft built again, or a statement voided: its shares are free to be paid again
  update owner_referral_shares x set owner_statement_id = null
    from owner_statements st
   where x.owner_statement_id = st.id and st.owner_id = p_owner
     and ((st.statement_month = v_month and st.status = 'draft') or st.status = 'void');
  v_id := app.build_owner_statement_pre0543(p_owner, p_month, p_by);
  if v_id is null then return v_id; end if;

  if exists (select 1 from owner_referral_links l where l.referrer_owner_id = p_owner) then
    perform app.referral_shares_sync(p_owner, v_month);
    update owner_referral_shares set owner_statement_id = v_id
     where referrer_owner_id = p_owner and owner_statement_id is null and payout_month <= v_month;
    insert into owner_statement_lines (owner_statement_id, vehicle_id, line_type, description, rental_charge_cents, booking_share_bps, amount_cents)
    select v_id, null, 'referral_share',
           format('Referral share, %s%s (%s booking%s)', app.vehicle_name(x.vehicle_id), coalesce(', fleet ' || v.fleet_number, ''),
                  count(*), case when count(*) = 1 then '' else 's' end),
           sum(x.base_cents), max(x.share_bps), sum(x.amount_cents)
      from owner_referral_shares x join vehicles v on v.id = x.vehicle_id
     where x.owner_statement_id = v_id
     group by x.vehicle_id, v.fleet_number
    having sum(x.amount_cents) <> 0;
    select coalesce(sum(amount_cents), 0) into v_share from owner_statement_lines where owner_statement_id = v_id and line_type = 'referral_share';
    if v_share <> 0 then
      select payout_cents + balance_carried_forward_cents + v_share into v_total from owner_statements where id = v_id;
      update owner_statements
         set kickbacks_earned_cents = kickbacks_earned_cents + v_share,
             payout_cents = greatest(v_total, 0), balance_carried_forward_cents = least(v_total, 0)
       where id = v_id;
    end if;
  end if;

  -- the referrer of this owner, when they have no car of their own (the monthly run builds owners with cars only)
  if coalesce(current_setting('app.referral_build', true), '') <> 'on' then
    for r in select distinct l.referrer_owner_id as id from owner_referral_links l
              where l.referred_owner_id = p_owner and l.share_bps > 0
                and not exists (select 1 from vehicles v where v.owner_id = l.referrer_owner_id and v.enrollment_date is not null)
                and not exists (select 1 from owner_statements s where s.owner_id = l.referrer_owner_id and s.statement_month = v_month and s.status <> 'draft') loop
      perform set_config('app.referral_build', 'on', true);
      begin
        perform app.build_owner_statement(r.id, v_month, p_by);
      exception when others then
        raise warning '0543 referral statement for %: %', r.id, sqlerrm;
      end;
      perform set_config('app.referral_build', '', true);
    end loop;
  end if;
  return v_id;
end $$;
select pg_temp.copy_grants('app.build_owner_statement(uuid, date, uuid)'::regprocedure, 'app.build_owner_statement_pre0543(uuid, date, uuid)'::regprocedure);

-- ================================================================ Admin: the links
create or replace function app.owner_referral_links_read(p_by uuid, p jsonb) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare v_owner uuid := nullif(p ->> 'owner', '')::uuid;
begin
  if not app.user_is_admin(p_by) then raise exception 'Only an Admin sees referral links' using errcode = '42501'; end if;
  return jsonb_build_object('owners', coalesce((select jsonb_agg(jsonb_build_object('id', o.id, 'name', coalesce(o.corporation_name, o.legal_name)) order by coalesce(o.corporation_name, o.legal_name))
      from owners o where o.status in ('active', 'in_default') and not coalesce(o.is_test, false)), '[]'::jsonb),
    'links', coalesce((select jsonb_agg(jsonb_build_object('id', l.id, 'referrer_owner_id', l.referrer_owner_id, 'referred_owner_id', l.referred_owner_id,
             'referrer', coalesce(ro.corporation_name, ro.legal_name), 'referred', coalesce(fo.corporation_name, fo.legal_name),
             'share_bps', l.share_bps, 'sees_cars', l.sees_cars, 'effective_from', l.effective_from, 'effective_to', l.effective_to, 'note', l.note,
             'paid_cents', (select coalesce(sum(x.amount_cents), 0) from owner_referral_shares x where x.link_id = l.id and x.owner_statement_id is not null),
             'cars', (select count(*) from vehicles v where v.owner_id = l.referred_owner_id and v.retired_at is null)) order by l.created_at desc)
      from owner_referral_links l join owners ro on ro.id = l.referrer_owner_id join owners fo on fo.id = l.referred_owner_id
     where v_owner is null or l.referrer_owner_id = v_owner or l.referred_owner_id = v_owner), '[]'::jsonb));
end $$;

create or replace function app.owner_referral_link_save(p_by uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  l owner_referral_links;
  v_id uuid := nullif(p ->> 'id', '')::uuid;
  v_referrer uuid := nullif(p ->> 'referrer_owner_id', '')::uuid;
  v_referred uuid := nullif(p ->> 'referred_owner_id', '')::uuid;
  v_bps integer := coalesce(nullif(p ->> 'share_bps', '')::integer, 1000);
begin
  if not app.user_is_admin(p_by) then raise exception 'Only an Admin sets referral links' using errcode = '42501'; end if;
  if v_id is not null then
    select * into l from owner_referral_links where id = v_id for update;
    if l.id is null then raise exception 'Referral link not found' using errcode = 'P0002'; end if;
    if coalesce((p ->> 'end')::boolean, false) then
      update owner_referral_links set effective_to = greatest(coalesce(nullif(p ->> 'effective_to', '')::date, app.today()), effective_from + 1), updated_at = now()
       where id = v_id returning * into l;
    else
      update owner_referral_links set share_bps = v_bps, sees_cars = coalesce((p ->> 'sees_cars')::boolean, sees_cars),
             note = nullif(left(btrim(coalesce(p ->> 'note', '')), 500), ''), updated_at = now()
       where id = v_id returning * into l;
    end if;
    return to_jsonb(l);
  end if;
  if v_referrer is null or v_referred is null then raise exception 'Choose the owner who referred and the owner referred' using errcode = '22023'; end if;
  if v_referrer = v_referred then raise exception 'An owner does not refer themselves' using errcode = '22023'; end if;
  if v_bps not between 0 and 5000 then raise exception 'The share is 0 to 50 points' using errcode = '22023'; end if;
  insert into owner_referral_links (referrer_owner_id, referred_owner_id, share_bps, sees_cars, effective_from, note, created_by)
  values (v_referrer, v_referred, v_bps, coalesce((p ->> 'sees_cars')::boolean, true),
          coalesce(nullif(p ->> 'effective_from', '')::date, app.month_start(app.today())), nullif(left(btrim(coalesce(p ->> 'note', '')), 500), ''), p_by)
  returning * into l;
  return to_jsonb(l);
end $$;

-- ================================================================ the referrer's read-only view of the referred cars
create or replace function public.server_owner_referred_cars(p_by uuid) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare
  v_owner uuid := (select o.id from owners o where o.user_id = p_by order by o.created_at limit 1);
  v_month date := app.month_start(app.today());
begin
  if v_owner is null then return '[]'::jsonb; end if;
  return coalesce((select jsonb_agg(jsonb_build_object(
      'vehicle_id', v.id, 'name', app.vehicle_name(v.id), 'fleet_number', v.fleet_number, 'status', v.status,
      'share_bps', l.share_bps,
      'days_booked_30', (select coalesce(sum(greatest(0, extract(epoch from (least(b.return_at, now()) - greatest(b.pickup_at, now() - interval '30 days'))) / 86400)), 0)::numeric(6,1)
                           from bookings b where b.vehicle_id = v.id and b.status in ('on_rent', 'returned', 'closed', 'confirmed')
                            and b.pickup_at < now() and b.return_at > now() - interval '30 days' and b.booking_type <> 'owner'),
      'bookings_month', (select count(*) from bookings b where b.vehicle_id = v.id and app.booking_is_booked(b) and b.booking_type <> 'owner'
                            and b.pickup_at < v_month + interval '1 month' and b.return_at >= v_month),
      'revenue_month_cents', (select coalesce(sum(s.owner_revenue_cents), 0) from booking_splits s where s.vehicle_id = v.id and s.payout_month = v_month and s.status <> 'reversed'),
      'revenue_3m_cents', (select coalesce(sum(s.owner_revenue_cents), 0) from booking_splits s where s.vehicle_id = v.id and s.payout_month >= (v_month - interval '3 months')::date and s.status <> 'reversed'),
      'share_paid_cents', (select coalesce(sum(x.amount_cents), 0) from owner_referral_shares x where x.link_id = l.id and x.vehicle_id = v.id and x.owner_statement_id is not null),
      'upcoming', (select coalesce(jsonb_agg(jsonb_build_object('pickup_at', b.pickup_at, 'return_at', b.return_at, 'status', b.status) order by b.pickup_at), '[]'::jsonb)
                     from bookings b where b.vehicle_id = v.id and app.booking_status_booked(b.status) and b.return_at > now() and b.booking_type <> 'owner')
    ) order by v.fleet_number nulls last, v.created_at)
    from owner_referral_links l join vehicles v on v.owner_id = l.referred_owner_id
   where l.referrer_owner_id = v_owner and l.sees_cars and l.effective_from <= app.today() and (l.effective_to is null or l.effective_to > app.today())
     and v.retired_at is null and not coalesce(v.is_sample, false)), '[]'::jsonb);
end $$;
revoke all on function public.server_owner_referred_cars(uuid) from public, anon, authenticated;
grant execute on function public.server_owner_referred_cars(uuid) to service_role;

alter function app.door(uuid, text, text, text, jsonb) rename to door_pre0543;
create function app.door(p_user uuid, p_aal text, p_call text, p_name text, p jsonb default '{}'::jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
begin
  if (p_call = 'ops_read' and p_name = 'owner_referral_links') or (p_call in ('ops_do', 'admin_do') and p_name = 'owner_referral_link_save') then
    perform app.door_begin(p_user, p_aal);
    if p_name = 'owner_referral_links' then return app.owner_referral_links_read(p_user, coalesce(p, '{}'::jsonb)); end if;
    return app.owner_referral_link_save(p_user, coalesce(p, '{}'::jsonb));
  end if;
  return app.door_pre0543(p_user, p_aal, p_call, p_name, p);
end $$;
select pg_temp.copy_grants('app.door(uuid, text, text, text, jsonb)'::regprocedure, 'app.door_pre0543(uuid, text, text, text, jsonb)'::regprocedure);

revoke all on function app.referral_shares_sync(uuid, date), app.owner_referral_links_read(uuid, jsonb), app.owner_referral_link_save(uuid, jsonb) from public, anon, authenticated;
