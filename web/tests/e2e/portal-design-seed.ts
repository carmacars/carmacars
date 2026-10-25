import { randomBytes, randomUUID, scryptSync } from 'node:crypto';
import type postgres from 'postgres';

// Fixtures for the owner and investor portal design (2026-10-24-owner-investor-portal-design.md): an owner with three
// cars on the website (one on rent, one available, one in service), six months of bookings, statements, payouts and
// monthly fee invoices; and an investor with an investment past its lockup, paid Returns and an open Return.
// Fictional people only (example.test). Dates are relative to today, so the "this month" figures always have data.
type Sql = postgres.Sql;
export const PW = 'correct horse battery';
const hash = (pw: string) => { const salt = randomBytes(16); return `scrypt$${salt.toString('base64')}$${scryptSync(pw, salt, 64).toString('base64')}`; };
const tag = () => `${Date.now().toString(36)}${Math.floor(Math.random() * 1e6).toString(36)}`.toUpperCase();
const VIN = 'ABCDEFGHJKLMNPRSTUVWXYZ0123456789';
const vin = (p: string) => p + Array.from({ length: 17 - p.length }, () => VIN[Math.floor(Math.random() * VIN.length)]).join('');

async function person(sql: Sql, kind: string, name: string) {
  const id = randomUUID(); const email = `${kind}.design.${tag().toLowerCase()}@example.test`;
  await sql`insert into local_auth.users (id, email, password_hash) values (${id}, ${email}, ${hash(PW)})`;
  await sql`insert into users (id, email, full_name) values (${id}, ${email}, ${name})`;
  return { id, email };
}

export interface OwnerFixture { email: string; userId: string; ownerId: string; cars: Array<{ id: string; name: string; status: string }> }

export async function seedOwner(sql: Sql): Promise<OwnerFixture> {
  const u = await person(sql, 'owner', 'Olivia Premium');
  await sql`insert into user_roles (user_id, role) values (${u.id}, 'owner')`;
  const admin = await person(sql, 'admin', 'Ada Admin');
  await sql`insert into user_roles (user_id, role) values (${admin.id}, 'admin')`;
  const owner = randomUUID(); const agr = randomUUID(); const t = tag();
  await sql`insert into owners (id, user_id, owner_type, legal_name, status, email, phone) values (${owner}, ${u.id}, 'individual', 'Olivia Premium', 'active', ${u.email}, '416-555-0101')`;
  await sql`insert into owner_agreements (id, owner_id, kind, agreement_number, agreement_date, status) values (${agr}, ${owner}, 'enrollment', ${`EA-${t}`}, current_date - 200, 'signed')`;
  const [renter] = await sql`select id from renters order by created_at limit 1`;
  const photos = await sql`select processed_path, width, height from vehicle_photos where is_cover and status = 'approved' and processed_path is not null order by processed_path limit 3`;
  const specs = [
    { make: 'Mercedes-Benz', model: 'C300', year: 2023, colour: 'Obsidian Black', status: 'on_rent', daily: 14900 },
    { make: 'Mercedes-Benz', model: 'GLC300', year: 2022, colour: 'Polar White', status: 'available', daily: 16900 },
    { make: 'Mercedes-Benz', model: 'A220', year: 2021, colour: 'Mountain Grey', status: 'out_of_service', daily: 9900 }
  ];
  const cars: OwnerFixture['cars'] = [];
  let n = 0;
  for (const [i, s] of specs.entries()) {
    const car = randomUUID();
    await sql`insert into vehicles (id, owner_id, fleet_number, year, make, model, vin, plate, class, status, management_mode, onboarding_method, on_fleet_policy, fleet_policy_added_on, enrollment_date, colour)
              values (${car}, ${owner}, ${`F-${t}-${i}`}, ${s.year}, ${s.make}, ${s.model}, ${vin('WDD')}, ${`DS${t.slice(-4)}${i}`}, 'luxury', 'ready_to_list', 'managed', 'transfer', true, current_date - 190, current_date - 190, ${s.colour})`;
    await sql`insert into vehicle_schedules (vehicle_id, owner_agreement_id, schedule_number, vehicle_number, held_by, title_status, management_mode, onboarding_method,
                insurance_fee_cents, tracker_fee_cents, install_fee_cents, revenue_share_bps, enrollment_date, signed_at)
              values (${car}, ${agr}, ${`VS-${t}-${i}`}, ${i + 1}, 'individual', 'owned_outright', 'managed', 'transfer', 45000, 2500, 10000, 3500, current_date - 190, now() - interval '190 days')`;
    await sql`insert into vehicle_fee_history (vehicle_id, source, insurance_fee_cents, tracker_fee_cents, revenue_share_bps, effective_from) values (${car}, 'signed_schedule', 45000, 2500, 3500, current_date - 190)`;
    await sql`insert into rate_cards (vehicle_id, daily_rate_cents, weekend_rate_cents, weekly_rate_cents, monthly_rate_cents, km_allowance_per_day, overage_cents_per_km, deposit_cents, delivery_fee_cents, pickup_fee_cents, effective_from)
              values (${car}, ${s.daily}, ${s.daily + 1000}, ${s.daily * 6}, ${s.daily * 22}, 250, 25, 50000, 7500, 7500, now() - interval '190 days')`;
    await sql`select app.ensure_listing(${car}::uuid)`;
    await sql`update vehicle_listings set seats = 5, transmission = 'automatic', status = 'published', published_at = now(), first_published_at = now() where vehicle_id = ${car}`;
    const p = photos[i % Math.max(1, photos.length)];
    if (p) await sql`insert into vehicle_photos (vehicle_id, angle, shot_type, original_path, processed_path, status, sort_order, is_cover, alt_text, width, height, variants, background_status, is_public, approved_at)
                     values (${car}, 'front_left', 'front_left', ${`original/${p.processed_path}`}, ${p.processed_path}, 'approved', 0, true, ${`${s.year} ${s.make} ${s.model}`}, ${p.width}, ${p.height}, ${sql.json([])}, 'done', true, now())`;
    await sql`update vehicles set status = ${s.status}::vehicle_status where id = ${car}`;
    cars.push({ id: car, name: `${s.year} ${s.make} ${s.model}`, status: s.status });
    // bookings: two a month for six months back, one on now for the car on rent, upcoming ones for the first two cars
    const trips: Array<[number, number, string]> = [];
    for (let m = 5; m >= 1; m--) trips.push([-(m * 30) + 3 + i, -(m * 30) + 7 + i + (m % 3), 'closed'], [-(m * 30) + 14 + i, -(m * 30) + 18 + i, 'closed']);
    trips.push([-24 + i, -20 + i, 'closed']);
    if (s.status === 'on_rent') trips.push([-3, 4, 'on_rent']);
    if (i < 2) trips.push([6 + i * 3, 10 + i * 3, 'confirmed'], [16 + i, 21 + i, 'confirmed']);
    for (const [a, b, st] of trips) {
      n++;
      const days = b - a; const charge = s.daily * days;
      await sql`insert into bookings (booking_number, booking_type, status, vehicle_id, renter_id, booked_at, pickup_at, return_at, original_return_at, billable_days,
                  daily_rate_cents, weekend_rate_cents, weekly_rate_cents, monthly_rate_cents, rate_applied, daily_days, weekend_days,
                  rental_charge_cents, discount_cents, km_allowance_per_day, km_allowance_total, overage_cents_per_km, deposit_cents,
                  subtotal_at_booking_cents, hst_at_booking_cents, total_due_at_booking_cents)
                values (${`DS-${t.slice(-5)}${String(n).padStart(3, '0')}`}, 'standard', ${st}::booking_status, ${car}, ${renter!.id}, now() + make_interval(days => ${a - 10}),
                  date_trunc('day', now()) + make_interval(days => ${a}) + interval '14 hours', date_trunc('day', now()) + make_interval(days => ${b}) + interval '14 hours',
                  date_trunc('day', now()) + make_interval(days => ${b}) + interval '14 hours', ${days}, ${s.daily}, ${s.daily + 1000}, ${s.daily * 6}, ${s.daily * 22}, 'daily', ${days}, 0,
                  ${charge}, 0, 250, ${250 * days}, 25, 50000, ${charge}, ${Math.round(charge * 0.13)}, ${charge + Math.round(charge * 0.13)})`;
    }
    // monthly fee invoices, paid, for the last six months
    for (let m = 5; m >= 0; m--) {
      await sql`insert into owner_invoices (owner_id, vehicle_id, kind, period_month, billing_date, status, fees_cents, hst_cents, paid_cents, paid_at)
                values (${owner}, ${car}, 'monthly', date_trunc('month', current_date - make_interval(months => ${m}))::date, date_trunc('month', current_date - make_interval(months => ${m}))::date,
                  'paid', 47500, 6175, 53675, now() - make_interval(months => ${m}))`;
    }
  }
  // statements and payouts for the five months before this one; the latest approved, paid out in six days
  const pays = [412500, 538000, 476250, 601900, 655400];
  for (const [k, cents] of pays.entries()) {
    const m = 5 - k;
    const status = m === 1 ? 'approved' : 'paid';
    await sql`insert into owner_statements (owner_id, statement_month, payout_date, status, approved_by, approved_at, payout_cents, owner_revenue_cents, is_final)
              values (${owner}, date_trunc('month', current_date - make_interval(months => ${m}))::date, ${status === 'paid' ? sql`(date_trunc('month', current_date - make_interval(months => ${m - 1})) + interval '14 days')::date` : sql`current_date + 6`},
                ${status}, ${admin.id}, now(), ${cents}, ${cents + 120000}, true)`;
    await sql`insert into payouts (payee_type, owner_id, kind, amount_cents, method, scheduled_for, status, approved_by, paid_at)
              values ('owner', ${owner}, 'owner_statement', ${cents}, 'bank_transfer', ${status === 'paid' ? sql`(date_trunc('month', current_date - make_interval(months => ${m - 1})) + interval '14 days')::date` : sql`current_date + 6`}, ${status === 'paid' ? 'paid' : 'approved'}, ${admin.id},
                ${status === 'paid' ? sql`now()` : null})`;
  }
  return { email: u.email, userId: u.id, ownerId: owner, cars };
}

export interface InvestorFixture { email: string; userId: string; investorId: string; investedCents: number }

export async function seedInvestor(sql: Sql, opts: { reinvest?: boolean } = {}): Promise<InvestorFixture> {
  const u = await person(sql, 'investor', 'Isabel Grant');
  const inv = randomUUID(); const agr = randomUUID(); const doc = randomUUID(); const x = randomUUID();
  await sql`insert into investors (id, user_id, legal_name, investor_type, status, email, tax_information_complete) values (${inv}, ${u.id}, 'Isabel Grant', 'individual', 'active', ${u.email}, true)`;
  await sql`insert into documents (id, kind, storage_bucket, storage_path) values (${doc}, 'other', 'documents', ${`x/${doc}.pdf`})`;
  await sql`insert into investment_agreements (id, investor_id, agreement_number, status, schedule_c_document_id, schedule_d_document_id, exemption_category, legal_advice_choice)
            values (${agr}, ${inv}, ${`IA-${tag().slice(-6)}`}, 'signed', ${doc}, ${doc}, 'accredited_investor', 'declined')`;
  const principal = 5000000;
  // invested 13 months ago: six months of lockup, then Returns from the seventh month
  await sql`insert into investments (id, investor_id, agreement_id, is_initial, principal_cents, yearly_bps, investment_date, lockup_end_date)
            values (${x}, ${inv}, ${agr}, true, ${principal}, 3000, (date_trunc('month', current_date) - interval '13 months')::date, (date_trunc('month', current_date) - interval '7 months')::date)`;
  for (let m = 7; m >= 1; m--) {
    const ret = Math.round((principal * 3000) / 120000);
    const status = m === 1 ? 'accrued' : 'paid';
    await sql`insert into investment_returns (investment_id, return_month, opening_invested_cents, yearly_bps, days_earning, days_in_month, return_cents, disposition, payment_date, closing_invested_cents, status)
              select ${x}, d::date, ${principal}, 3000, extract(day from (d + interval '1 month' - interval '1 day'))::int, extract(day from (d + interval '1 month' - interval '1 day'))::int, ${ret},
                ${opts.reinvest ? 'reinvest' : 'pay'}, (d + interval '1 month' + interval '14 days')::date, ${principal}, ${status}
                from (select date_trunc('month', current_date) - make_interval(months => ${m}) as d) q`;
  }
  return { email: u.email, userId: u.id, investorId: inv, investedCents: principal };
}
