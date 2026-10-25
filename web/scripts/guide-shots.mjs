// Screenshots for the user guides: signs in as each portal's person (renter, owner, investor, Admin, the four
// assistant functions, field) on the local stack and photographs the screens a new user needs, at desktop
// 1440 x 900 (device scale 2) and phone 390 x 844 (device scale 3), plus the public pages and the request-to-book
// steps. Writes <out>/<portal>/<nn>-<name>-<desktop|phone>.png and <out>/manifest.json (portal, step, name, path,
// viewport, what the screen is for).
//
//   BASE_URL=http://localhost:3000 [PAY_URL=http://localhost:3001] node scripts/guide-shots.mjs --out reports/guides [--portals public,renter,...]
//
// Local stack only (DATA_BACKEND=local): it writes sample data. Run it after the end-to-end suite, which leaves
// realistic records behind; every person on screen is then renamed to a fictional name with an example.com address
// (RFC 2606), so no test address or real person appears. The renter's trip, the field handover and the photo
// shoot are played through the screens themselves. PAY_URL is a second server of the same build with Stripe test
// keys, used for the payment screen only (the session cookie is shared across ports).
import { randomBytes, randomUUID, scryptSync } from 'node:crypto';
import fs from 'node:fs';
import path from 'node:path';
import { chromium } from '@playwright/test';
import postgres from 'postgres';

// the browsers of this machine when present; otherwise Playwright's own cache (CI caches ~/.cache/ms-playwright)
if (!process.env.PLAYWRIGHT_BROWSERS_PATH && fs.existsSync('/opt/pw-browsers')) process.env.PLAYWRIGHT_BROWSERS_PATH = '/opt/pw-browsers';
const BASE = (process.env.BASE_URL ?? 'http://localhost:3000').replace(/\/$/, '');
const PAY = (process.env.PAY_URL ?? '').replace(/\/$/, '');
const arg = (n, d) => { const i = process.argv.indexOf(n); return i > 0 ? process.argv[i + 1] : d; };
const OUT = arg('--out', 'reports/guides');
const ONLY = (arg('--portals', '') ?? '').split(',').filter(Boolean);
const PW = 'guide screens password 1';
const ROOT = path.resolve(path.dirname(new URL(import.meta.url).pathname), '../..');
const sql = postgres(process.env.DATABASE_URL ?? 'postgresql://postgres@127.0.0.1:54322/carmacars', { max: 3, onnotice: () => {} });
const VIEWPORTS = {
  desktop: { viewport: { width: 1440, height: 900 }, deviceScaleFactor: 2 },
  phone: { viewport: { width: 390, height: 844 }, deviceScaleFactor: 3, isMobile: true, hasTouch: true }
};
const MAX_SCREENS = 2.5; // a long page is cut at 2.5 screen heights: the guide shows the top of it
const manifest = [];
const problems = [];
const want = (p) => !ONLY.length || ONLY.includes(p);
const hash = (pw) => { const s = randomBytes(16); return `scrypt$${s.toString('base64')}$${scryptSync(pw, s, 64).toString('base64')}`; };
const day = (n) => new Date(Date.now() + n * 86_400_000);
const ymd = (d) => new Intl.DateTimeFormat('en-CA', { timeZone: 'America/Toronto', year: 'numeric', month: '2-digit', day: '2-digit' }).format(d);

// ------------------------------------------------------------------ the people on screen
const CAST = {
  renter: ['Jordan', 'Lee'], owner: ['Priya', 'Shah'], investor: ['Daniel', 'Okafor'], admin: ['Sam', 'Rivera'],
  va_cs: ['Maya', 'Chen'], va_finance: ['Omar', 'Haddad'], va_fleet: ['Lucas', 'Martin'], va_sales: ['Nina', 'Kowalski'], field: ['Diego', 'Alvarez']
};
const POOL = ['Avery Brooks', 'Chloe Martin', 'Ethan Walker', 'Fatima Ali', 'Gabriel Roy', 'Hannah Kim', 'Isaac Cohen', 'Julia Santos', 'Kevin Nguyen',
  'Laura Bianchi', 'Marcus Reid', 'Nadia Petrov', 'Owen Clarke', 'Paula Mendes', 'Quinn Foster', 'Rosa Alvarez', 'Samir Patel', 'Tara Singh', 'Umar Farouk',
  'Vera Ivanova', 'William Grant', 'Ximena Lopez', 'Yusuf Demir', 'Zoe Campbell', 'Aaron Bell', 'Bianca Rossi', 'Caleb Turner', 'Dana Wright', 'Elena Moreau',
  'Felix Wagner', 'Grace Liu', 'Hugo Lambert', 'Ines Duarte', 'Jamal Brown', 'Keira Walsh', 'Leo Fischer', 'Mia Dubois', 'Noah Bernard', 'Olivia Hayes',
  'Pedro Silva', 'Ruby Evans', 'Sofia Greco', 'Theo Novak', 'Uma Rao', 'Victor Hugo Lima', 'Wendy Park', 'Yara Haddad', 'Zane Murphy'];
const emailOf = (name, n) => `${name.toLowerCase().replace(/[^a-z ]/g, '').trim().split(/\s+/).join('.')}${n ? n : ''}@example.com`;

async function login(id, email) {
  await sql`insert into local_auth.users (id, email, password_hash) values (${id}, ${email}, ${hash(PW)})
            on conflict (id) do update set password_hash = excluded.password_hash, email = excluded.email`;
}
async function bare(role, va) {
  const id = randomUUID(); const email = `guide-${role}-${Date.now()}@example.test`;
  await login(id, email);
  await sql`select public.register_account(${id}, ${email}, ${'Guide ' + role}, null)`;
  if (role !== 'renter') await sql`delete from user_roles where user_id = ${id} and role = 'renter'`;
  if (role === 'owner') { await sql`insert into user_roles (user_id, role) values (${id}, 'owner') on conflict do nothing`; await sql`insert into owners (user_id, owner_type, legal_name, status, email) values (${id}, 'individual', 'Guide Owner', 'active', ${email})`; }
  if (role === 'investor') await sql`insert into investors (user_id, legal_name, investor_type, status, email) values (${id}, 'Guide Investor', 'individual', 'active', ${email})`;
  if (role === 'admin') await sql`insert into user_roles (user_id, role) values (${id}, 'admin') on conflict do nothing`;
  if (va) { await sql`insert into user_roles (user_id, role) values (${id}, 'va') on conflict do nothing`; await sql`insert into staff_profiles (user_id, home_address, home_postal_code, staff_type, va_function, is_active) values (${id}, '1 Test Lane, Testville', 'X9X 9X9', 'va', ${va}::va_function, true)`; }
  if (role === 'field') { await sql`insert into user_roles (user_id, role) values (${id}, 'field') on conflict do nothing`; await sql`insert into staff_profiles (user_id, home_address, home_postal_code, staff_type, field_function, is_active) values (${id}, '1 Test Lane, Testville', 'X9X 9X9', 'field', 'driver', true)`; }
  return id;
}
// The richest account of each role (most records to show), as the role crawl picks them; a bare one if none.
async function pick(role) {
  const no2fa = sql`and not exists (select 1 from local_auth.factors f where f.user_id = u.id and f.verified_at is not null)`;
  const va = /^va_(cs|finance|fleet|sales)$/.exec(role)?.[1];
  const q = {
    owner: sql`select u.id from users u join owners o on o.user_id = u.id where o.status = 'active' ${no2fa}
               order by (select count(*) from owner_statements s where s.owner_id = o.id) + (select count(*) from owner_invoices i where i.owner_id = o.id) desc,
                        (select count(*) from vehicles v where v.owner_id = o.id) desc limit 1`,
    investor: sql`select u.id from users u join investors i on i.user_id = u.id where true ${no2fa}
                  order by (select count(*) from investments x where x.investor_id = i.id) desc limit 1`,
    admin: sql`select u.id from users u join user_roles r on r.user_id = u.id and r.role = 'admin' where u.status = 'active' ${no2fa} order by u.created_at limit 1`,
    field: sql`select u.id from users u join staff_profiles p on p.user_id = u.id and p.staff_type = 'field' where p.is_active ${no2fa}
               order by (select count(*) from field_jobs j where j.assigned_to = u.id) desc limit 1`
  };
  const rows = va
    ? await sql`select u.id from users u join staff_profiles p on p.user_id = u.id and p.staff_type = 'va' and p.va_function = ${va}::va_function
                where p.is_active and coalesce(array_length(p.cover_functions, 1), 0) = 0 ${no2fa}
                order by (select count(*) from tasks t where t.assigned_to = u.id) desc limit 1`
    : role === 'renter' ? [] : await q[role];
  return rows[0]?.id ?? await bare(role, va);
}

// Every person gets a fictional name and an example.com address; the cast keeps the names above. Names and
// addresses are replaced in every table that copies them (renters, owners, drivers, signatures, outbox, ...).
async function polish(ids) {
  await sql`create temp table if not exists guide_map (old_email text, new_email text, old_name text, new_name text, user_id uuid)`;
  await sql`truncate guide_map`;
  const cast = new Map(Object.entries(ids).map(([role, id]) => [id, CAST[role].join(' ')]));
  const people = await sql`
    select u.id as user_id, u.email, u.full_name from users u
    union all select null, r.email, r.legal_name from renters r where r.user_id is null and r.email is not null
    union all select null, l.email, l.name from leads l where l.email is not null`;
  const used = new Set(Object.values(CAST).map((c) => c.join(' ')));
  let i = 0; const taken = new Map();
  for (const p of people) {
    let name = p.user_id && cast.get(p.user_id);
    if (!name) { name = POOL[i % POOL.length]; i++; }
    if (!cast.has(p.user_id) && used.has(name)) { name = POOL[i % POOL.length]; i++; }
    const n = taken.get(name) ?? 0; taken.set(name, n + 1);
    await sql`insert into guide_map values (${p.email}, ${emailOf(name, n ? n + 1 : 0)}, ${p.full_name}, ${name}, ${p.user_id})`;
  }
  await sql.begin(async (t) => {
    await t`set local session_replication_role = replica`;
    // through a placeholder first: the new addresses may swap between people on a second run
    await t`update users u set email = 'swap-' || u.id || '@example.com' from guide_map m where m.user_id = u.id`;
    await t`update local_auth.users a set email = 'swap-' || a.id || '@example.com' from guide_map m where m.user_id = a.id`;
    await t`update users u set email = m.new_email, full_name = m.new_name from guide_map m where m.user_id = u.id`;
    await t`update local_auth.users a set email = m.new_email from guide_map m where m.user_id = a.id`;
    await t`update renters r set email = m.new_email, legal_name = m.new_name from guide_map m where m.user_id = r.user_id`;
    await t`update owners o set email = m.new_email, legal_name = m.new_name, first_name = split_part(m.new_name, ' ', 1),
              last_name = regexp_replace(m.new_name, '^\\S+\\s+', '') from guide_map m where m.user_id = o.user_id and o.owner_type = 'individual'`;
    await t`update owners o set email = m.new_email, signing_officer_name = m.new_name from guide_map m where m.user_id = o.user_id and o.owner_type <> 'individual'`;
    await t`update investors x set email = m.new_email, legal_name = m.new_name from guide_map m where m.user_id = x.user_id`;
    // copies elsewhere: by address first, then by the old name
    const cols = await t`select c.table_name, c.column_name from information_schema.columns c join information_schema.tables tb using (table_schema, table_name)
      where c.table_schema = 'public' and tb.table_type = 'BASE TABLE' and c.data_type in ('text', 'character varying', 'citext')
        and (c.table_name, c.column_name) in (values ('renters','email'), ('drivers','email'), ('leads','email'), ('messages','to_address'), ('notification_outbox','to_address'),
             ('rental_agreement_signers','signer_email'), ('signature_records','signer_email'), ('email_suppressions','email'), ('form_drafts','resume_email'), ('owners','email'), ('investors','email'))`;
    for (const c of cols) await t.unsafe(`update public.${c.table_name} x set ${c.column_name} = m.new_email from guide_map m where lower(x.${c.column_name}) = lower(m.old_email)`);
    const names = [['renters', 'legal_name'], ['drivers', 'full_name'], ['booking_drivers', 'full_name'], ['leads', 'name'], ['notification_outbox', 'to_name'],
      ['rental_agreement_signers', 'signer_name'], ['signature_records', 'signer_name'], ['signature_records', 'typed_name'], ['payment_methods', 'cardholder_name'], ['rental_agreements', 'countersigner_name']];
    for (const [tb, c] of names) await t.unsafe(`update public.${tb} x set ${c} = m.new_name from (select distinct on (old_name) old_name, new_name from guide_map where old_name is not null order by old_name, user_id nulls last) m where x.${c} = m.old_name`);
    // any address still from a test domain becomes a fictional one
    for (const [tb, c] of [['renters', 'email'], ['drivers', 'email'], ['notification_outbox', 'to_address'], ['messages', 'to_address']])
      await t.unsafe(`update public.${tb} set ${c} = 'guest' || substr(md5(${c}), 1, 6) || '@example.com' where ${c} ilike '%@example.test'`);
  });
  // listing copy written by the tests to look alike (the similarity check) reads as filler: a plain description instead
  await sql`update vehicle_listings set description = 'Clean, quiet and easy to drive, with room for four and their bags. Heated seats, Apple CarPlay and Android Auto, a backup camera and keyless entry. Picked up downtown or delivered to your door.'
            where description ~ '(\\m\\w+\\M)( \\w+){2,} \\1( \\w+){2,} \\1'`;
  const left = await sql`select count(*)::int n from users where email ilike '%example.test' or full_name ~* '(test|e2e|crawl|verify|guide )'`;
  if (left[0].n) problems.push(`polish: ${left[0].n} users still look like test accounts`);
}

// ------------------------------------------------------------------ sample records the screens need
const STAFF_NOTE = 'Your car is ready. We kept your dates and added the child seat.';
async function freeCar(start, days, past = 0) {
  const from = day(start); const to = new Date(from.getTime() + days * 86_400_000);
  const since = past > 0 ? new Date(Math.min(from.getTime(), Date.now() - past * 86_400_000)) : from;
  const rows = await sql`select v.id, l.slug from vehicles v join vehicle_listings l on l.vehicle_id = v.id
    where l.status = 'published' and app.vehicle_bookable(v.id)
      and not exists (select 1 from bookings b where b.vehicle_id = v.id and b.status in ('requested','offered','pending_payment','confirmed','on_rent','returned','closed')
                        and tstzrange(b.pickup_at - interval '1 day', b.return_at + interval '1 day') && tstzrange(${since.toISOString()}::timestamptz, ${to.toISOString()}::timestamptz))
      and not exists (select 1 from vehicle_calendar_blocks k where k.vehicle_id = v.id and k.removed_at is null and k.starts_at < ${to.toISOString()}::timestamptz and (k.ends_at is null or k.ends_at > ${from.toISOString()}::timestamptz))
      and not exists (select 1 from field_jobs j where j.vehicle_id = v.id and j.status not in ('cancelled', 'done') and j.scheduled_at between ${from.toISOString()}::timestamptz - interval '3 days' and ${to.toISOString()}::timestamptz)
    order by l.slug limit 1`;
  if (!rows[0]) throw new Error('no free car');
  await sql`update vehicles set year_approximate = false where id = ${rows[0].id} and year_approximate`;   // the offer names the car with its year
  return { id: rows[0].id, slug: rows[0].slug, from: ymd(from), to: ymd(to) };
}
async function request(renter, car, name) {
  const req = {
    request_key: randomUUID(), vehicle_id: car.id, pickup_at: `${car.from}T10:00:00-04:00`, return_at: `${car.to}T10:00:00-04:00`, booking_type: 'standard',
    pickup_method: 'collected', return_method: 'returned', pickup_location: { kind: 'our_location' }, return_location: { kind: 'our_location' },
    coverage_option: 2, extras: { winter_tire: false, baby_seats: 1 },
    renter: { email: renter.email, full_name: name, mobile: '+16475550142', date_of_birth: '1990-04-09', licence_class: 'G', licence_issuer: 'ON' }, additional_drivers: [],
    consents: { terms: { accepted: true, version: 'guide', text: 'I agree.' }, privacy: { accepted: true, version: 'guide', text: 'I agree.' }, marketing: { opted_in: false, version: 'guide', text: 'No.' } },
    details: { source: 'guide' }
  };
  const [r] = await sql`select public.submit_booking_request(${sql.json(req)}, '203.0.113.9', 'guide', ${renter.id}) v`;
  if (!r.v.ok) throw new Error(`request refused: ${r.v.message}`);
  return r.v;
}
/** The licence photos and its expiry, which an offer may not be accepted without (migration 0130). */
async function giveLicence(booking) {
  await sql`update booking_drivers set licence_expiry = coalesce(licence_expiry, date '2031-01-01') where booking_id = ${booking}::uuid and role = 'renter'`;
  for (const k of ['licence_front', 'licence_back', 'selfie']) {
    await sql`select app.register_verification_upload(${booking}::uuid, null, ${k}, d.driver_id, ${`guide/${booking}/${k}.jpg`}, null, 'image/jpeg', null, 'identity')
                from booking_drivers d where d.booking_id = ${booking}::uuid and d.role = 'renter'
                 and not exists (select 1 from verification_uploads u where u.booking_id = d.booking_id and u.driver_id = d.driver_id and u.kind = ${k} and u.status in ('submitted', 'approved'))`;
  }
}
/** The signature that holds up (migration 0154), as the renter does it: the code, the reading, the initials, the consents, the drawn signature. */
async function strongSign(page) {
  const flow = page.getByTestId('esign-flow');
  await flow.waitFor({ timeout: 20_000 });
  const ch = flow.getByTestId('esign-channel-sms');
  if (await ch.count()) await ch.check();
  await flow.getByTestId('esign-send').click();
  const dev = flow.getByTestId('esign-dev-code');
  await dev.waitFor({ timeout: 15_000 });
  const code = ((await dev.textContent()) ?? '').replace(/\D/g, '').slice(-6);
  await page.addStyleTag({ content: '[data-testid="esign-dev-code"] { display: none !important; }' }).catch(() => {});
  await flow.getByTestId('esign-code').fill(code);
  await flow.getByTestId('esign-confirm').click();
  await flow.getByTestId('esign-verified').waitFor({ timeout: 15_000 });
  await flow.getByTestId('esign-viewed').click();
  await page.waitForTimeout(800);
  const stroke = async (pad, points) => {
    await pad.scrollIntoViewIfNeeded(); await page.waitForTimeout(700);
    const b = await pad.boundingBox();
    await page.mouse.move(b.x + 12, b.y + b.height * 0.6); await page.mouse.down();
    for (let i = 1; i <= points; i++) await page.mouse.move(b.x + 12 + i * ((b.width - 30) / points), b.y + b.height * (0.55 + 0.25 * Math.sin(i / 2)), { steps: 2 });
    await page.mouse.up();
  };
  for (let n = 0; n < 6; n++) {
    const pad = flow.locator('canvas[data-testid^="initials-"]').first();
    if (!(await pad.count())) break;
    const id = await pad.getAttribute('data-testid');
    await stroke(pad, 10);
    await flow.locator(`canvas[data-testid="${id}"]`).waitFor({ state: 'detached', timeout: 15_000 }).catch(() => {});
  }
  for (let n = 0; n < 4; n++) {
    const c = flow.locator('input[data-testid^="esign-consent-"]:not(:checked)').first();
    if (!(await c.count())) break;
    await c.click(); await page.waitForTimeout(600);
  }
  await stroke(flow.getByTestId('signature-pad'), 30);
  await flow.waitFor({ state: 'visible' }); await page.waitForFunction(() => document.querySelector('[data-testid="esign-flow"]')?.getAttribute('data-complete') === 'true', null, { timeout: 15_000 }).catch(() => {});
}

/** Offered, approved, signed, paid, verified, covered, confirmed (as procedures 1 and 2 leave a booking). */
async function confirm(booking, admin, holder) {
  await sql`select app.send_offer(${booking}::uuid, ${admin}::uuid)`;
  await giveLicence(booking);
  await sql`select app.approve_offer(b.id, b.current_offer_version, (select user_id from renters where id = b.renter_id)) from bookings b where b.id = ${booking}`;
  const doc = randomUUID(); const sig = randomUUID();
  await sql`insert into documents (id, kind, storage_bucket, storage_path, booking_id) values (${doc}, 'rental_agreement', 'agreements', ${`bookings/${booking}/agreement.pdf`}, ${booking})`;
  await sql`insert into signature_requests (id, document_id, provider, provider_envelope, status, completed_at) values (${sig}, ${doc}, 'esign', ${`env-${booking}`}, 'completed', now())`;
  await sql`update bookings set signature_request_id = ${sig}, agreement_document_id = ${doc} where id = ${booking}`;
  await sql`insert into payments (booking_id, renter_id, purpose, kind, method, amount_cents, status, processed_at)
            select id, renter_id, 'booking_total', 'charge', 'card', renter_due_at_booking_cents, 'succeeded', now() from bookings where id = ${booking}`;
  await sql`insert into payment_methods (renter_id, card_brand, card_last4, cardholder_name, exp_month, exp_year, is_credit)
            select renter_id, 'visa', '4242', ${holder}, 12, 2031, true from bookings where id = ${booking}`;
  await sql`update bookings b set card_on_file_id = (select pm.id from payment_methods pm where pm.renter_id = b.renter_id order by pm.created_at desc limit 1) where b.id = ${booking}`;
  await sql`update bookings set status = 'confirmed' where id = ${booking}`;
  await sql`update booking_drivers set identity_method = 'staff_review', identity_verified_on = current_date, licence_number = coalesce(licence_number, 'L1234-56789-01234'), licence_expiry = coalesce(licence_expiry, date '2031-01-01') where booking_id = ${booking}`;
  await sql`insert into coverage_proofs (booking_id, coverage_option, status, card_issuer, card_last4, confirmed_at) values (${booking}, 2, 'confirmed', 'Bank', '4242', now())`;
  await sql`update bookings set coverage_option = 2, coverage_confirmed_at = now(), blocks_calendar = true where id = ${booking}`;
}
async function newRenter(name) {
  const id = randomUUID(); const email = emailOf(name, '').replace('@', `.${id.slice(0, 6)}@`);
  await login(id, email);
  await sql`select public.register_account(${id}, ${email}, ${name}, null)`;
  return { id, email };
}

// Car pictures for the photo steps: the stand-in illustrations drawn as JPEG, as a phone camera would give them.
const IMG = new Map();
async function photos(browser) {
  const dir = path.join(ROOT, 'prototype/assets/photos');
  const files = fs.readdirSync(dir).filter((f) => /^(toyota-camry|honda-civic|bmw-330i)-.*\.svg$/.test(f));
  const p = await browser.newPage({ viewport: { width: 1200, height: 800 } });
  for (const f of files) {
    await p.setContent(`<html><body style="margin:0"><img src="data:image/svg+xml;base64,${fs.readFileSync(path.join(dir, f)).toString('base64')}" style="width:1200px;height:800px;object-fit:cover"></body></html>`);
    IMG.set(f, await p.screenshot({ type: 'jpeg', quality: 82 }));
  }
  await p.close();
}
const photo = (i) => { const all = [...IMG.values()]; return { name: `photo-${i}.jpg`, mimeType: 'image/jpeg', buffer: all[i % all.length] }; };

// ------------------------------------------------------------------ browser helpers
async function session(browser, kind, email) {
  const c = await browser.newContext({ ...VIEWPORTS[kind], baseURL: BASE, reducedMotion: 'reduce', locale: 'en-CA', timezoneId: 'America/Toronto' });
  const page = await c.newPage();
  page.setDefaultTimeout(20_000);
  await page.goto('/', { waitUntil: 'domcontentloaded' });
  await cookies(page, 8000);
  if (email) {
    await page.goto('/sign-in', { waitUntil: 'networkidle' });
    await page.locator('input[type="email"]').fill(email);
    await page.locator('input[type="password"]').fill(PW);
    await page.getByRole('button', { name: 'Sign in' }).click();
    await page.waitForURL((u) => !u.pathname.startsWith('/sign-in'), { timeout: 30_000 });
    if (page.url().includes('/choose-portal')) await page.goto('/');
  }
  return page;
}
async function cookies(page, wait = 0) {
  const b = page.getByRole('button', { name: 'Necessary only' }).first();
  if (wait) await b.waitFor({ state: 'visible', timeout: wait }).catch(() => {});
  if (await b.isVisible().catch(() => false)) { await b.click().catch(() => {}); await page.waitForTimeout(300); }
}
async function settle(page) {
  await page.waitForLoadState('networkidle', { timeout: 15_000 }).catch(() => {});
  await cookies(page);
  // the first-visit strip ("New here? Read the guide") is not part of the screen a guide shows
  await page.addStyleTag({ content: '[data-testid="guide-banner"] { display: none !important; }' }).catch(() => {});
  await page.evaluate(() => document.fonts.ready).catch(() => {});
  await page.evaluate(() => { if (document.activeElement instanceof HTMLElement) document.activeElement.blur(); window.scrollTo(0, 0); }).catch(() => {});
  await page.waitForTimeout(250);
}
let counters = {};
async function shoot(page, portal, name, description, { kind, step, element } = {}) {
  await settle(page);
  const vp = kind ?? (page.viewportSize().width > 800 ? 'desktop' : 'phone');
  counters[portal] ??= {};
  const nn = step ?? (counters[portal][name] ??= Object.keys(counters[portal]).length + 1);
  const file = `${String(nn).padStart(2, '0')}-${name}-${vp}.png`;
  fs.mkdirSync(path.join(OUT, portal), { recursive: true });
  const size = page.viewportSize();
  const h = await page.evaluate(() => document.documentElement.scrollHeight);
  const over = await page.evaluate(() => document.documentElement.scrollWidth - innerWidth);
  const height = Math.min(h, Math.round(size.height * MAX_SCREENS));
  if (element) {
    // one part of the page, with a margin: the part the step is about
    await element.scrollIntoViewIfNeeded(); await page.waitForTimeout(400);
    const b = await element.boundingBox();
    const y = Math.max(0, b.y + (await page.evaluate(() => scrollY)) - 24);
    await page.evaluate((yy) => scrollTo(0, yy), y); await page.waitForTimeout(300);
    await page.screenshot({ path: path.join(OUT, portal, file), clip: { x: 0, y: 0, width: size.width, height: Math.min(size.height, Math.ceil(b.height) + 48) }, animations: 'disabled', caret: 'hide' });
    const u2 = new URL(page.url());
    manifest.push({ portal, step: nn, name, file: `${portal}/${file}`, path: u2.pathname + u2.search, viewport: vp, width: size.width, height: Math.min(size.height, Math.ceil(b.height) + 48),
      scale: VIEWPORTS[vp].deviceScaleFactor, title: await page.title().catch(() => ''), description, part_of_page: true });
    console.log(`  ${portal}/${file}`);
    return;
  }
  // a full-page picture repeats fixed and sticky bars where the viewport was: they are put in the flow for the picture
  const n = await page.evaluate(() => { let k = 0; for (const e of document.querySelectorAll('body *')) { const p = getComputedStyle(e).position; if (p === 'fixed' || p === 'sticky') { e.dataset.guidePos = e.style.position || '-'; e.style.position = 'static'; k++; } } return k; });
  const hh = n ? Math.min(await page.evaluate(() => document.documentElement.scrollHeight), Math.round(size.height * MAX_SCREENS)) : height;
  await page.screenshot({ path: path.join(OUT, portal, file), fullPage: true, clip: { x: 0, y: 0, width: size.width, height: hh }, animations: 'disabled', caret: 'hide' });
  if (n) await page.evaluate(() => { for (const e of document.querySelectorAll('[data-guide-pos]')) { e.style.position = e.dataset.guidePos === '-' ? '' : e.dataset.guidePos; delete e.dataset.guidePos; } });
  const u = new URL(page.url());
  manifest.push({ portal, step: nn, name, file: `${portal}/${file}`, path: u.pathname + u.search, viewport: vp, width: size.width, height: hh, scale: VIEWPORTS[vp].deviceScaleFactor,
    title: await page.title().catch(() => ''), description, ...(over > 0 ? { overflow_px: over } : {}) });
  if (over > 0) problems.push(`${portal}/${file}: ${over} px wider than the screen`);
  console.log(`  ${portal}/${file}`);
}
/** Open a path in both viewports and photograph it. */
async function both(pages, portal, name, pathOrFn, description, before) {
  for (const page of pages) {
    try {
      const p = typeof pathOrFn === 'function' ? await pathOrFn() : pathOrFn;
      if (!p) { problems.push(`${portal}/${name}: no record to show`); return; }
      await page.goto(p, { waitUntil: 'domcontentloaded' });
      if (before) await before(page);
      await shoot(page, portal, name, description);
    } catch (e) { problems.push(`${portal}/${name} (${page.viewportSize().width}): ${String(e.message ?? e).split('\n')[0]}`); }
  }
}
const one = async (q) => (await q)[0] ?? null;

// ------------------------------------------------------------------ the portals
async function publicPages(browser) {
  counters.public = Object.fromEntries(['home', 'cars', 'car-page', 'book-1-trip', 'book-2-driver', 'book-3-licence', 'book-4-review', 'book-5-sent', 'sign-in', 'create-account',
    'reset-password', 'link-expired', 'list-your-car'].map((n, i) => [n, i + 1]));
  const d = await session(browser, 'desktop'); const m = await session(browser, 'phone');
  const car = await freeCar(40, 3);
  const P = [d, m];
  await both(P, 'public', 'home', '/', 'The home page: search by dates, the fleet, how renting works.');
  await both(P, 'public', 'cars', '/cars', 'All cars with their daily price; filter by class and dates.');
  await both(P, 'public', 'car-page', `/cars/${car.slug}`, 'A car page: photos, price, what is included, the calendar of free dates, Request to book.');
  // the request-to-book steps (not sent here; the renter's story sends one)
  for (const page of P) {
    try {
      await page.goto(`/book/${car.slug}?from=${car.from}&to=${car.to}&tf=10:00&tt=10:00`, { waitUntil: 'networkidle' });
      await shoot(page, 'public', 'book-1-trip', 'Request to book, step 1: dates, times, pickup and return, extras and the price.');
      await page.getByRole('button', { name: 'Continue to driver details' }).click();
      await page.locator('#rq-first').waitFor();
      await page.locator('#rq-first').fill('Jordan'); await page.locator('#rq-last').fill('Lee');
      await page.locator('#rq-email').fill('jordan.lee@example.com'); await page.locator('#rq-phone').fill('647-555-0142');
      await page.locator('#rq-dobm').selectOption('4'); await page.locator('#rq-dobd').fill('9'); await page.locator('#rq-doby').fill('1990');
      await shoot(page, 'public', 'book-2-driver', 'Step 2: the main driver: name, email, phone, date of birth.');
      await page.getByRole('button', { name: 'Continue to licence' }).click();
      await page.locator('label', { hasText: 'Ontario G2' }).waitFor();
      await page.locator('label', { hasText: 'Ontario G2' }).click();
      if (await page.locator('label.option', { hasText: 'Option 2' }).count()) await page.locator('label.option', { hasText: 'Option 2' }).click();
      await shoot(page, 'public', 'book-3-licence', 'Step 3: the licence and how the car is covered.');
      await page.getByRole('button', { name: 'Continue to add-ons' }).click();
      await page.getByRole('heading', { name: 'Add-ons', exact: true }).waitFor();
      await shoot(page, 'public', 'book-4-addons', 'Step 4: optional add-ons; the estimate shows the price as you choose.', { step: 14 });
      await page.getByRole('button', { name: 'Review request' }).click();
      await page.locator('input[name="agree"]').waitFor();
      await shoot(page, 'public', 'book-4-review', 'Step 4: review everything, agree to the terms, Send request. Nothing is charged yet.');
    } catch (e) { problems.push(`public/book (${page.viewportSize().width}): ${String(e.message).split('\n')[0]}`); }
  }
  await both(P, 'public', 'sign-in', '/sign-in', 'Sign in with email and password, for every portal.');
  await both(P, 'public', 'create-account', '/create-account', 'Create an account (renters). Owners apply from List your car; staff and investors are invited.');
  await both(P, 'public', 'reset-password', '/reset-password', 'Forgot the password, or invited and never chose one: send a link that is valid for one hour.');
  await both(P, 'public', 'link-expired', '/link-expired', 'What an expired or used email link opens: Send me a new link.');
  await both(P, 'public', 'list-your-car', '/list-your-car', 'For owners: how the program works, and Apply to list your car.');
  await d.context().close(); await m.context().close();
}

async function renterStory(browser, ids) {
  const r = { id: ids.renter, email: (await one(sql`select email from users where id = ${ids.renter}`)).email };
  const car = await freeCar(45, 3);
  // 1. the request through the form, signed in
  const d = await session(browser, 'desktop', r.email); const m = await session(browser, 'phone', r.email);
  // the form's steps are the public pages' screens above; the request itself is made as the form's server action makes it
  const made = await request(r, car, 'Jordan Lee');
  const number = (await one(sql`select booking_number from bookings where id = ${made.booking_id}`)).booking_number;
  await d.goto(`/book/sent/${encodeURIComponent(number)}`, { waitUntil: 'networkidle' });
  await shoot(d, 'public', 'book-5-sent', 'After Send request: the request number and what happens next (CarmaCars replies with an offer).');
  await m.goto(d.url().replace(BASE, ''), { waitUntil: 'domcontentloaded' }); await shoot(m, 'public', 'book-5-sent', 'After Send request: the request number and what happens next (CarmaCars replies with an offer).');
  const b = await one(sql`select id from bookings where booking_number = ${number}`);
  const P = [d, m];
  await both(P, 'renter', 'trips-requested', '/account', 'Trips: the request waits for CarmaCars to send an offer.');
  // 2. the offer
  await sql`select app.send_offer(${b.id}, ${ids.admin}, ${STAFF_NOTE}, null)`;
  await both(P, 'renter', 'trips-offer', '/account', 'Trips: the next step is shown first (here: Review offer).');
  await both(P, 'renter', 'offer', `/account/bookings/${number}/offer`, 'The offer: price, what changed, the time left. Approve and continue, Ask for a change, or Decline.');
  await giveLicence(b.id);
  await d.goto(`/account/bookings/${number}/offer`); await d.getByRole('button', { name: 'Approve and continue' }).click(); await d.waitForURL(/\/sign$/, { timeout: 30_000 });
  // the screens that follow show the licence still to upload
  await sql`delete from verification_uploads where booking_id = ${b.id}`;
  await sql`update booking_drivers set licence_expiry = null where booking_id = ${b.id} and role = 'renter'`;
  // 3. sign
  await both(P, 'renter', 'sign-details', `/account/bookings/${number}/sign`, 'Sign, part 1: address and licence details for the agreement (Save details).');
  await d.locator('#pt-d-address_line1').fill('100 Queen Street West'); await d.locator('#pt-d-city').fill('Toronto'); await d.locator('#pt-d-postal_code').fill('M5H 2N2');
  await d.locator('#pt-d-licence_number').fill('L1234-56789-01234'); await d.locator('#pt-d-licence_expiry').fill('2031-06-30');
  await d.getByRole('button', { name: 'Save details' }).click();
  await d.locator('.agreement').getByText('100 Queen Street West').first().waitFor({ state: 'attached', timeout: 20_000 });
  await both(P, 'renter', 'sign-agreement', `/account/bookings/${number}/sign`, 'Sign, part 2: the key values at the top, the full agreement one tap away (also as a PDF), one tap ticks the four statements, your name is your signature (or draw it).');
  try { await d.getByLabel(/All four/).check({ timeout: 10_000 }); } catch (e) { problems.push(`renter/sign: All four: ${String(e.message).split('\n')[0]}`); }
  try { await strongSign(d); } catch (e) { problems.push(`renter/sign: ${String(e.message).split('\n')[0]}`); }
  await d.evaluate(() => window.scrollTo(0, document.body.scrollHeight));
  await shoot(d, 'renter', 'sign-ready', 'Sign, ready: consents ticked and the signature in place; Sign and continue to payment.');
  await d.getByRole('button', { name: 'Sign and continue to payment' }).click();
  await d.waitForURL(/\/pay$/, { timeout: 30_000 }).catch(async (e) => {
    // keep what the page said, as a screen of its own, to see why the signature did not go through
    await shoot(d, 'renter', 'sign-failed', `Debug: ${String(await d.locator('[role="alert"], .error').allInnerTexts().catch(() => '')).slice(0, 300)}`, { step: 98 });
    throw e;
  });
  // 4. pay (the Stripe form when a server with test keys is given; the local card form otherwise)
  for (const page of P) {
    try {
      if (PAY) {
        await page.goto(`${PAY}/account/bookings/${number}/pay`, { waitUntil: 'domcontentloaded', timeout: 45_000 });
        await page.locator('iframe[name^="__privateStripeFrame"]').first().waitFor({ timeout: 25_000 }).catch(() => problems.push('pay: the Stripe form did not appear'));
        await page.waitForTimeout(2500);
      } else await page.goto(`/account/bookings/${number}/pay`, { waitUntil: 'domcontentloaded' });
      await page.locator('#pt-card-name').fill('Jordan Lee').catch(() => {});
      await shoot(page, 'renter', 'pay', 'Pay: the card is authorized now and charged once the booking is confirmed; it becomes the Card on File for the deposit.');
    } catch (e) { problems.push(`renter/pay (${page.viewportSize().width}): ${String(e.message).split('\n')[0]}`); }
  }
  await d.goto(`/account/bookings/${number}/pay`, { waitUntil: 'networkidle' });
  await d.locator('#pt-card-name').fill('Jordan Lee');
  if (await d.getByTestId('fake-card').isVisible().catch(() => false)) {
    await d.locator('#pt-card-number').fill('4242 4242 4242 4242'); await d.locator('#pt-card-exp').fill('12 / 31'); await d.locator('#pt-card-cvc').fill('123');
    await d.getByRole('button', { name: /^Pay \$/ }).click();
    await d.waitForURL((u) => !u.pathname.endsWith('/pay'), { timeout: 45_000 }).catch(() => problems.push('pay: the fake payment did not finish'));
  }
  // 5. confirmed: the booking, documents, verification
  await both(P, 'renter', 'booking-confirmed', `/account/bookings/${number}`, 'A booking: status, progress, pickup details, drivers, documents, price and payments, and what you can do.');
  await both(P, 'renter', 'verify', `/account/bookings/${number}/verify`, 'Before pickup: upload the licence (front and back), a selfie and the proof of coverage.');
  // an earlier trip, closed, so the list and the review page have something
  // requested ahead (a request must be), then moved back to the past window found free and closed
  const past = await freeCar(-40, 3, 45);
  const ahead = { ...past, from: ymd(day(400)), to: ymd(day(403)) };
  const old = await request(r, ahead, 'Jordan Lee');
  await sql.begin(async (t) => {
    await t`set local session_replication_role = replica`;
    await t`update bookings set pickup_at = ${past.from + 'T10:00:00-04:00'}::timestamptz, return_at = ${past.to + 'T10:00:00-04:00'}::timestamptz, status = 'closed' where id = ${old.booking_id}`;
  });
  await both(P, 'renter', 'trips', '/account', 'Trips: the next step, then current, upcoming and past trips.');
  await both(P, 'renter', 'extend', `/account/bookings/${number}/extend`, 'Ask for more days: See the price, then request; paid before the current return time.');
  await both(P, 'renter', 'change', `/account/bookings/${number}/change`, 'Ask to change dates: the price difference is shown before you ask.');
  await both(P, 'renter', 'cancel', `/account/bookings/${number}/cancel`, 'Cancel: the refund by the cancellation table, then type to confirm and Cancel booking.');
  await both(P, 'renter', 'review', `/account/bookings/${old.booking_number}/review`, 'After a trip: stars, an optional review, and whether it may be shown on the site.');
  await both(P, 'renter', 'documents', '/account/documents', 'Your documents: agreements, receipts, statements, uploads.');
  await both(P, 'renter', 'notifications', '/account/notifications', 'Notifications and which emails you get.');
  await both(P, 'renter', 'profile', '/account/profile', 'Profile: contact details, drivers, the Card on File, marketing choice, password.');
  await d.context().close(); await m.context().close();
}

async function ownerPortal(browser, ids) {
  const email = (await one(sql`select email from users where id = ${ids.owner}`)).email;
  const o = await one(sql`select id from owners where user_id = ${ids.owner}`);
  const d = await session(browser, 'desktop', email); const m = await session(browser, 'phone', email); const P = [d, m];
  const v = await one(sql`select id from vehicles where owner_id = ${o.id} order by (select count(*) from bookings b where b.vehicle_id = vehicles.id) desc limit 1`);
  const inv = await one(sql`select invoice_number from owner_invoices where owner_id = ${o.id} order by (status in ('issued', 'failed')) desc, created_at desc limit 1`);
  const st = await one(sql`select id from owner_statements where owner_id = ${o.id} and status in ('approved', 'paid', 'sent') order by statement_month desc limit 1`);
  const form = await one(sql`select f.id from government_form_fills f where f.owner_id = ${o.id} and f.pdf_template_id is not null and f.superseded_at is null order by f.generated_at desc nulls last limit 1`).catch(() => null);
  counters.owner = Object.fromEntries(['home', 'vehicles', 'vehicle', 'calendar', 'invoices', 'invoice', 'banking', 'statements', 'statement', 'payouts', 'documents', 'forms-c-d',
    'official-form', 'notifications', 'profile', 'form-c-screen'].map((n, i) => [n, i + 1]));
  await both(P, 'owner', 'home', '/owner', 'Home: the next thing to do (sign, pay, upload), your cars, money this month, the next debit.');
  await both(P, 'owner', 'vehicles', '/owner/vehicles', 'Vehicles: each car, its status and its next step.');
  await both(P, 'owner', 'vehicle', () => v && `/owner/vehicles/${v.id}`, 'A vehicle: status, fees, the onboarding checklist, uploads, bookings, invoices, exit notice.');
  await both(P, 'owner', 'calendar', '/owner/bookings', 'Bookings and calendar: two months of your cars; Book my own car.');
  await both(P, 'owner', 'invoices', '/owner/invoices', 'Invoices: what is due, paid, being debited.');
  if (inv) await both(P, 'owner', 'invoice', `/owner/invoices/${inv.invoice_number}`, 'An invoice: the lines, when it will be debited, and Pay by card or pre-authorized debit.');
  else await asOther(browser, sql`select o.user_id, i.invoice_number as k from owner_invoices i join owners o on o.id = i.owner_id where o.user_id is not null order by (i.status in ('issued', 'failed')) desc, i.created_at desc limit 1`,
    'owner', 'invoice', (k) => `/owner/invoices/${k}`, 'An invoice: the lines, when it will be debited, and Pay by card or pre-authorized debit.');
  await both(P, 'owner', 'banking', '/owner/banking', 'Banking: the account the monthly fees are debited from (Set up pre-authorized debit), and where payouts go.');
  await both(P, 'owner', 'statements', '/owner/statements', 'Statements: one a month, approved by CarmaCars.');
  await both(P, 'owner', 'statement', () => st && `/owner/statements/${st.id}`, 'A statement: every booking, the revenue share, deductions and the payout.');
  await both(P, 'owner', 'payouts', '/owner/payouts', 'Payouts: what was paid and when.');
  await both(P, 'owner', 'documents', '/owner/documents', 'Documents: signed agreements, uploads, government forms, and Forms C and D to sign with witnesses.');
  await both(P, 'owner', 'forms-c-d', '/owner/documents', 'Forms C and D: print the filled form (every spot to sign marked), sign it with witnesses, take a photo of each page with the phone.',
    async (page) => { const s = page.getByText(/Forms to sign with witnesses/).first(); if (await s.isVisible().catch(() => false)) await s.scrollIntoViewIfNeeded(); });
  const offDesc = 'An official ServiceOntario form filled from your records: Download the filled form, or Sign on screen.';
  if (form) await both(P, 'owner', 'official-form', `/owner/documents/forms/${form.id}/official`, offDesc);
  else await asOther(browser, sql`select o.user_id, f.id as k from government_form_fills f join owners o on o.id = f.owner_id where o.user_id is not null and f.pdf_template_id is not null and f.superseded_at is null order by f.generated_at desc nulls last limit 1`,
    'owner', 'official-form', (k) => `/owner/documents/forms/${k}/official`, offDesc);
  await both(P, 'owner', 'notifications', '/owner/notifications', 'Messages and notices from CarmaCars.');
  await both(P, 'owner', 'profile', '/owner/profile', 'Profile: contact details and password.');
  // October 16, 2026 (0053): Form C signed on screen, with the witness on the same screen
  // a financed or leased car whose Form C is still to sign: this owner's, or another owner's on the stack (on this local stack only, an
  // approved Form C is set aside for the picture)
  const fc = await one(sql`select v.id vehicle_id, u.id user_id, u.email, (v.owner_id = ${o.id}) mine from vehicles v join vehicle_schedules s on s.vehicle_id = v.id and s.superseded_by is null
                            join owners ow on ow.id = v.owner_id join users u on u.id = ow.user_id
                            where s.title_status in ('financed', 'leased') and v.status not in ('exited', 'declined', 'total_loss')
                            order by (v.owner_id = ${o.id}) desc, v.created_at limit 1`).catch(() => null);
  if (fc) {
    await sql`update owner_agreement_forms set status = 'replaced' where form_code = 'C' and vehicle_id = ${fc.vehicle_id} and status in ('approved', 'uploaded')`.catch(() => undefined);
    if (!fc.mine) await sql`insert into local_auth.users (id, email, password_hash) values (${fc.user_id}, ${fc.email}, ${hash(PW)})
                            on conflict (id) do update set password_hash = excluded.password_hash`;
    const FP = fc.mine ? P : [await session(browser, 'desktop', fc.email), await session(browser, 'phone', fc.email)];
    await both(FP, 'owner', 'form-c-screen', `/owner/documents/form-c/${fc.vehicle_id}`, 'Form C on screen: you sign, then your witness signs on the same screen.');
    if (!fc.mine) for (const x of FP) await x.context().close();
  } else problems.push('owner/form-c-screen: no financed or leased car on the stack');
  await d.context().close(); await m.context().close();
}

// A screen the main person has no record for, shown as another person of the same portal who has one.
async function asOther(browser, query, portal, name, pathOf, description) {
  const r = await one(query).catch(() => null);
  if (!r) { problems.push(`${portal}/${name}: no record to show`); return; }
  const u = await one(sql`select email from users where id = ${r.user_id}`);
  await login(r.user_id, u.email);
  const d = await session(browser, 'desktop', u.email); const m = await session(browser, 'phone', u.email);
  await both([d, m], portal, name, pathOf(r.k), description);
  await d.context().close(); await m.context().close();
}

async function investorPortal(browser, ids) {
  const email = (await one(sql`select email from users where id = ${ids.investor}`)).email;
  const d = await session(browser, 'desktop', email); const m = await session(browser, 'phone', email); const P = [d, m];
  const i = await one(sql`select id from investors where user_id = ${ids.investor}`);
  const st = await one(sql`select r.id from investment_returns r join investments x on x.id = r.investment_id where x.investor_id = ${i.id} order by r.return_month desc limit 1`).catch(() => null);
  await both(P, 'investor', 'investments', '/investor', 'Investments: each investment, its returns and what was paid.');
  await both(P, 'investor', 'statements', '/investor/statements', 'Statements: one per month, as PDF.');
  await both(P, 'investor', 'statement', () => st && `/investor/statements/${st.id}`, 'A statement and its PDF.');
  await both(P, 'investor', 'profile', '/investor/profile', 'Profile and notices: contact details, sending a notice, two-step sign-in.');
  await d.context().close(); await m.context().close();
}

async function adminPortal(browser, ids) {
  // fixed numbers: a screen with no record to show must not move the numbers of the ones after it (the guides name the files)
  counters.admin = Object.fromEntries(['today', 'requests', 'booking-review', 'booking', 'booking-changes', 'calendar', 'vehicle-calendar', 'vehicles', 'listings', 'listing-review',
    'plate-editor', 'owners', 'owner', 'owner-invoices', 'owner-debits', 'statements', 'statement', 'company-statements', 'tolls', 'tolls-read', 'tolls-review', 'owner-forms',
    'email', 'settings', 'program-settings', 'staff', 'portals', 'view-as', 'audit', 'overview', 'menu', 'search', 'applications', 'application', 'renters', 'sample-photos'].map((n, i) => [n, i + 1]));
  const email = (await one(sql`select email from users where id = ${ids.admin}`)).email;
  const d = await session(browser, 'desktop', email); const m = await session(browser, 'phone', email); const P = [d, m];
  const req = await one(sql`select booking_number from bookings where status = 'requested' order by created_at desc limit 1`);
  const conf = await one(sql`select booking_number from bookings where status in ('confirmed', 'on_rent') and request_details ->> 'source' = 'guide' order by created_at desc limit 1`)
    ?? await one(sql`select booking_number from bookings where status in ('confirmed', 'on_rent') order by created_at desc limit 1`);
  const v = await one(sql`select v.id from vehicles v order by (select count(*) from bookings b where b.vehicle_id = v.id) desc limit 1`);
  const intake = await one(sql`select i.id from listing_intakes i where exists (select 1 from vehicle_photos p where p.vehicle_id = i.vehicle_id and p.status = 'approved')
                               order by (i.state = 'needs_review') desc, i.created_at desc limit 1`);
  const owner = await one(sql`select id from owners where user_id = ${ids.owner}`);
  const st = await one(sql`select id from owner_statements order by (status = 'draft') desc, built_at desc nulls last limit 1`);
  const read = await one(sql`select id from toll_notice_reads order by created_at desc limit 1`).catch(() => null);
  await both(P, 'admin', 'today', '/admin', 'Today: alerts, requests waiting, pickups and returns, payments failed, approvals, email use.');
  await both(P, 'admin', 'requests', '/admin/requests', 'Requests: every request to book, offers out, waiting for signature or payment.');
  await both(P, 'admin', 'booking-review', () => req && `/admin/bookings/${req.booking_number}?tab=review`, 'Review a request: adjust the car, dates, price and extras, then Send offer.');
  await both(P, 'admin', 'booking', () => conf && `/admin/bookings/${conf.booking_number}`, 'A booking: overview, money, documents, changes and history.');
  await both(P, 'admin', 'booking-changes', () => conf && `/admin/bookings/${conf.booking_number}?tab=changes`, 'Propose a change to a confirmed booking: Preview the price, then Send to the renter.');
  await both(P, 'admin', 'calendar', '/admin/calendar', 'The master calendar: every car, bookings, requests, blocks; drag to move.');
  await both(P, 'admin', 'vehicle-calendar', () => v && `/admin/vehicles/${v.id}?tab=calendar`, 'One car\'s calendar, its blocks and its own turnaround time.');
  await both(P, 'admin', 'vehicles', '/admin/vehicles', 'Vehicles: the fleet with status, owner and next booking.');
  await both(P, 'admin', 'listings', '/admin/listings', 'Listings: the listing pipeline, drafts waiting for review, published cars.');
  await both(P, 'admin', 'listing-review', () => intake && `/admin/listings/${intake.id}`, 'Review a listing: copy, photos, each photo\'s plate check, Approve and Publish.');
  for (const page of P) {
    try {
      if (!intake) { problems.push('admin/plate-editor: no record to show'); break; }
      await page.goto(`/admin/listings/${intake.id}`, { waitUntil: 'networkidle' });
      await page.locator('[data-testid^="plate-edit-"]').first().click({ timeout: 8000 });
      await page.getByTestId('plate-editor').waitFor(); await page.waitForTimeout(2500);
      await shoot(page, 'admin', 'plate-editor', 'The plate editor: the suggested box, boxes drawn by hand, the cover style, Save the covered photo.', { element: page.getByTestId('plate-editor') });
    } catch (e) { problems.push(`admin/plate-editor (${page.viewportSize().width}): ${String(e.message).split('\n')[0]}`); }
  }
  await both(P, 'admin', 'owners', '/admin/owners', 'Owners: applications and owners, with their sign-in.');
  await both(P, 'admin', 'owner', () => owner && `/admin/owners/${owner.id}`, 'An owner: vehicles and terms, invoices, Forms C and D, sign-in links, View as.');
  await both(P, 'admin', 'owner-invoices', '/admin/invoices', 'Owner invoices: issued, paid, failed; record an offline payment.');
  await both(P, 'admin', 'owner-debits', '/admin/debits', 'Owner debits: the next debit day, scheduled and processing debits, mandates, results and the run log.');
  await both(P, 'admin', 'statements', '/admin/statements', 'Owner statements: drafts to approve, approved, paid.');
  await both(P, 'admin', 'statement', () => st && `/admin/statements/${st.id}`, 'An owner statement before approval.');
  await both(P, 'admin', 'company-statements', '/admin/reports', 'Company statements: the twelve sections, PDFs, Email me the PDFs.');
  await both(P, 'admin', 'tolls', '/admin/tolls', 'Tolls and tickets: the work queue, reads of notices and their exceptions.');
  await both(P, 'admin', 'tolls-read', '/admin/tolls/read', 'Read a notice: upload a PDF, photo or CSV; it is read in the browser.');
  await both(P, 'admin', 'tolls-review', () => read && `/admin/tolls/read/${read.id}`, 'Check the lines beside the notice, then Confirm and import.');
  await both(P, 'admin', 'owner-forms', '/admin/owner-forms', 'Owner forms: Forms C and D uploaded by owners, to approve or send back.');
  await both(P, 'admin', 'email', '/admin/messages', 'Email: the outbox, today\'s use against the daily limit, held and failed emails.');
  await both(P, 'admin', 'settings', '/admin/settings', 'Settings: site, content, program settings, fees, forms, staff and more.');
  await both(P, 'admin', 'program-settings', '/admin/settings/program', 'Program settings: every timing and policy value, saved as a new dated row.');
  await both(P, 'admin', 'staff', '/admin/settings/staff', 'Staff: invite, set functions and limits, end access.');
  await both(P, 'admin', 'portals', '/admin/portals', 'Portals and sign-in: invite into any role, send a password link, View as any portal.');
  // view as: the owner portal read only, with the red banner
  try {
    await d.goto('/admin/portals', { waitUntil: 'networkidle' });
    const r = await d.request.post('/api/view-as/start', { form: { user: ids.owner, portal: 'owner' }, maxRedirects: 0 });
    if (r.status() >= 400) throw new Error(`view as answered ${r.status()}`);
    await d.goto('/owner', { waitUntil: 'networkidle' });
    await shoot(d, 'admin', 'view-as', 'View as: the owner\'s portal as they see it, read only, with the red banner and Exit.');
    await d.request.post('/api/view-as/exit', { maxRedirects: 0 });
  } catch (e) { problems.push(`admin/view-as: ${e.message}`); }
  await both(P, 'admin', 'audit', '/admin/audit', 'Audit log: who changed what, including every View as.');
  // October 16, 2026 (0054): the menu in seven groups, the Overview, search, Applications, Renters, sample photos
  const app = await one(sql`select id from owner_applications order by (status = 'new') desc, created_at desc limit 1`).catch(() => null);
  await both(P, 'admin', 'overview', '/admin/overview', 'Overview: money this month, the fleet, the queues and the alerts.');
  await both(P, 'admin', 'menu', '/admin/requests', 'The menu: seven groups, the current one open; on a phone behind one Menu button.', async (page) => {
    if (page.viewportSize().width < 800) { await page.getByTestId('nav-menu').click(); await page.waitForTimeout(300); }
  });
  await both(P, 'admin', 'search', () => conf && `/admin/search?q=${encodeURIComponent(conf.booking_number)}`, 'Search: bookings, cars, owners, partners and renters in one box.');
  await both(P, 'admin', 'applications', '/admin/applications', 'Applications: every owner application, New, Waiting on owner, Approved, Declined.');
  await both(P, 'admin', 'application', () => app && `/admin/applications/${app.id}`, 'One application: the checks, Approve, Ask for something, Decline.');
  await both(P, 'admin', 'renters', '/admin/renters', 'Renters: everyone who books, with their trips.');
  await both(P, 'admin', 'sample-photos', '/admin/settings/sample-photos', 'Sample photos: the pictures a listing shows until its real photos are in.');
  await d.context().close(); await m.context().close();
}

const VA_SCREENS = {
  va_cs: [['queue', '/va', 'Queue: the tasks of customer service, oldest due first.'], ['today', '/va/today', 'Today: pickups, returns and what is due.'],
    ['requests', '/va/requests', 'Requests: review each request and send the offer.'], ['booking-review', 'REQ', 'Review a request: adjust, Preview, Send offer.'],
    ['new-quote', '/va/quotes/new', 'New quote: price a car for a caller and send it as an offer.'], ['messages', '/va/messages', 'Renter messages: answer renters.'],
    ['renters', '/va/renters', 'Find a renter by name, email, phone or booking.'], ['owner-forms', '/va/owner-forms', 'Owner forms: approve or send back Forms C and D.'],
    ['calendar', '/va/calendar', 'The calendar.']],
  va_finance: [['queue', '/va', 'Queue: the tasks of Finance.'], ['money', '/va/money', 'Payments, deposits and refunds.'], ['tolls', '/va/tolls', 'Tolls and tickets: the work queue.'],
    ['tolls-read', '/va/tolls/read', 'Read a notice and check its lines.'], ['reconciliation', '/va/reconciliation', 'Reconciliation of processor payouts.'], ['turo', '/va/turo', 'Turo trips.']],
  va_fleet: [['queue', '/va', 'Queue: the tasks of Fleet.'], ['field-jobs', '/va/fleet', 'Field jobs: schedule and assign handovers, returns, moves, photo shoots.'],
    ['daily-checks', '/va/checks', 'Daily checks of the cars.'], ['photo-reviews', '/va/reviews', 'Photo reviews after a return.'], ['listings', '/va/listings', 'Listings and their review.'],
    ['similar-cars', '/va/similar-cars', 'Similar cars: decide possible duplicates before publishing.']],
  va_sales: [['queue', '/va', 'Queue: the tasks of Sales.'], ['requests', '/va/requests', 'Requests and offers.'], ['new-quote', '/va/quotes/new', 'New quote.'],
    ['leads', '/va/leads', 'Owner leads.'], ['scorecard', '/va/scorecard', 'Scorecard: what you did this week.']]
};
async function vaPortal(browser, ids, role) {
  const email = (await one(sql`select email from users where id = ${ids[role]}`)).email;
  const d = await session(browser, 'desktop', email); const m = await session(browser, 'phone', email); const P = [d, m];
  const portal = role.replace('_', '-');
  for (const [name, p, desc] of VA_SCREENS[role]) {
    await both(P, portal, name, async () => p === 'REQ' ? (await one(sql`select booking_number from bookings where status = 'requested' order by created_at desc limit 1`).then((r) => r && `/va/bookings/${r.booking_number}?tab=review`)) : p, desc);
  }
  await d.context().close(); await m.context().close();
}

const next = async (page, title) => { await page.getByTestId('next').click(); await page.getByTestId('step-title').filter({ hasText: title }).waitFor({ timeout: 15_000 }); };
async function fieldPortal(browser, ids) {
  const email = (await one(sql`select email from users where id = ${ids.field}`)).email;
  // a confirmed booking with its handover job for today, as procedures 1 and 2 leave it
  const renter = await newRenter('Elena Moreau');
  const car = await freeCar(1, 2, 4);
  const rq = await request(renter, car, 'Elena Moreau');
  await confirm(rq.booking_id, ids.admin, 'Elena Moreau');
  const [pay] = await sql`insert into payments (booking_id, renter_id, purpose, kind, method, amount_cents, status, processed_at)
    select id, renter_id, 'deposit', 'hold', 'card', deposit_cents, 'authorized', now() from bookings where id = ${rq.booking_id} returning id`;
  await sql`select app.record_deposit_taken(${rq.booking_id}::uuid, ${pay.id}::uuid, ${ids.admin}::uuid)`;
  const trk = randomUUID();
  await sql`insert into tracker_devices (id, serial_number, vehicle_id, status, installed_at, tested_at) values (${trk}, ${`TRK-${trk.slice(0, 6)}`}, ${car.id}, 'installed', now(), now())`;
  await sql`insert into tracker_status (tracker_device_id, reported_at, speed_kmh, ignition_on) values (${trk}, now() + interval '30 minutes', 0, false)`;
  // the request needs a pickup two hours ahead or more, and the field list shows today: the pickup moves to a few hours from now
  await sql`update bookings set return_at = return_at + (now() + interval '3 hours' - pickup_at), pickup_at = now() + interval '3 hours' where id = ${rq.booking_id}`;
  const bk = await one(sql`select pickup_at from bookings where id = ${rq.booking_id}`);
  const [job] = await sql`select app.create_field_job('handover', ${car.id}::uuid, ${bk.pickup_at}::timestamptz, ${ids.admin}::uuid, ${rq.booking_id}::uuid, ${ids.field}::uuid, '100 Front St W, Toronto') id`;
  const odo = await one(sql`select coalesce(odometer_km, 0)::int o from vehicles where id = ${car.id}`);
  const shootCar = await one(sql`select v.id from vehicles v where v.id <> ${car.id} and not exists (select 1 from field_jobs j where j.vehicle_id = v.id and j.kind = 'photo_shoot' and j.status <> 'cancelled') order by v.created_at desc limit 1`);
  const sjob = randomUUID();
  if (shootCar) await sql`insert into field_jobs (id, kind, vehicle_id, assigned_to, scheduled_at, status, place) values (${sjob}, 'photo_shoot', ${shootCar.id}, ${ids.field}, now() + interval '3 hours', 'scheduled', '25 King St W, Toronto')`.catch(async () =>
    sql`insert into field_jobs (id, kind, vehicle_id, assigned_to, scheduled_at, status) values (${sjob}, 'photo_shoot', ${shootCar.id}, ${ids.field}, now() + interval '3 hours', 'scheduled')`);

  const d = await session(browser, 'desktop', email); const m = await session(browser, 'phone', email); const P = [d, m];
  await both(P, 'field', 'today', '/field', 'My jobs: today\'s handovers, returns, moves and photo shoots, in order.');
  await both(P, 'field', 'job', `/field/jobs/${job.id}`, 'A job: the car, the place, the renter, what to bring; Acknowledge, then Start.');
  // the handover checklist, step by step, on the phone
  let s = 0; const step = async (name, desc) => { s++; await shoot(m, 'field', `handover-${String(s).padStart(2, '0')}-${name}`, desc, { kind: 'phone', step: 20 + s }); };
  try {
    await m.goto(`/field/jobs/${job.id}`);
    await m.getByTestId('acknowledge').click(); await m.getByTestId('start').click();
    await m.getByTestId('ready-check').waitFor({ timeout: 15_000 });
    await step('ready', 'Handover, before you start: what must be ready (signed agreement, paid, ID checked, deposit).');
    await next(m, 'Car ready'); await step('car-ready', 'Step: the car is clean, fuelled and ready.'); await m.getByRole('button', { name: 'Yes' }).click();
    await next(m, 'Is this the renter?'); await step('renter', 'Step: compare the renter with the photo on file.'); await m.getByRole('button', { name: 'Yes' }).click();
    await next(m, 'Original licence'); await step('licence', 'Step: see the original licence.'); await m.getByRole('button', { name: 'Yes' }).click();
    await next(m, 'Card on File'); await step('card', 'Step: the Card on File is the renter\'s.'); await m.getByRole('button', { name: 'Yes' }).click();
    await next(m, 'Odometer'); await m.getByTestId('odometer').fill(String(odo.o + 12)); await step('odometer', 'Step: the odometer reading.');
    await next(m, 'Fuel or charge'); await m.getByTestId('fuel').fill('7'); await step('fuel', 'Step: fuel or charge level.');
    await next(m, 'Keys'); await m.getByTestId('keys-more').click(); await m.getByTestId('keys-more').click(); await step('keys', 'Step: how many keys are handed over.');
    await next(m, 'Photo set');
    const n = await m.locator('[data-testid^="shot-"]').count();
    for (let i = 1; i <= n; i++) await m.getByTestId(`shot-${i}`).setInputFiles(photo(i));
    await m.getByTestId('upload-count').filter({ hasText: 'all uploaded' }).waitFor({ timeout: 90_000 });
    await step('photos', 'Step: the photo set in a fixed order, taken with the phone camera.');
    await next(m, 'Damage'); await step('damage', 'Step: mark existing damage on the car diagram.');
    await next(m, 'Tracker'); await step('tracker', 'Step: the tracker check.');
    await next(m, 'Renter reviews'); await step('summary', 'Step: the renter reads the summary.');
    await next(m, 'Signatures'); await step('signatures', 'Step: the renter and you sign on the screen.');
  } catch (e) { problems.push(`field/handover: ${String(e.message).split('\n')[0]}`); }
  await both(P, 'field', 'report', '/field/report', 'Report: an incident, damage, a breakdown or a ticket, with photos.');
  await both(P, 'field', 'profile', '/field/profile', 'Profile: contact details and availability.');
  // the photo shoot: the listing capture inside the job
  if (shootCar) {
    for (const page of P) {
      try {
        await page.goto(`/field/jobs/${sjob}`, { waitUntil: 'networkidle' });
        await shoot(page, 'field', 'photo-shoot-job', 'A photo shoot job: the car and the shot list; Start the listing.');
        const ack = page.getByTestId('acknowledge'); if (await ack.isVisible().catch(() => false)) { await ack.click(); await page.getByTestId('start').waitFor({ timeout: 15_000 }).catch(() => {}); }
        const st = page.getByTestId('start'); if (await st.isVisible().catch(() => false)) await st.click();
        const ls = page.getByTestId('listing-start').or(page.getByTestId('listing-capture'));
        await ls.first().waitFor({ timeout: 20_000 });
        if (await page.getByTestId('listing-start').isVisible().catch(() => false)) await page.getByTestId('listing-start').click();
        await page.getByTestId('listing-capture').waitFor({ timeout: 20_000 });
        const codes = await sql`select code from listing_shot_types where required and is_active order by seq limit 4`;
        for (const [i, c] of codes.entries()) { await page.getByTestId(`shot-${c.code}`).setInputFiles(photo(i + 3)).catch(() => {}); }
        await page.waitForTimeout(3000);
        await shoot(page, 'field', 'photo-shoot-capture', 'Photo shoot capture: Take photo for each shot, the progress bar, Send again on a failed upload, Submit.');
      } catch (e) { problems.push(`field/photo-shoot (${page.viewportSize().width}): ${String(e.message).split('\n')[0]}`); }
    }
  }
  await d.context().close(); await m.context().close();
}

// ------------------------------------------------------------------ run
const roles = ['owner', 'investor', 'admin', 'va_cs', 'va_finance', 'va_fleet', 'va_sales', 'field'];
const ids = {};
for (const r of roles) ids[r] = await pick(r);
ids.renter = (await newRenter('Jordan Lee')).id;
// the assistants and the field person have saved a home address (otherwise their home shows the form that asks for it)
for (const r of roles.filter((x) => x.startsWith('va_') || x === 'field')) await sql`update staff_profiles set home_address = coalesce(nullif(home_address, ''), '100 King Street West, Toronto, Ontario, Canada'), home_postal_code = coalesce(nullif(home_postal_code, ''), 'M5X 1A9'), home_address_set_at = coalesce(home_address_set_at, now()) where user_id = ${ids[r]}`;
// a few requests waiting, so the request queues are not empty
for (const [i, name] of ['Hannah Kim', 'Marcus Reid'].entries()) { try { const rr = await newRenter(name); await request(rr, await freeCar(60 + i * 9, 3 + i), name); } catch (e) { problems.push(`sample request: ${e.message}`); } }
await polish(ids);
for (const r of [...roles, 'renter']) { const u = await one(sql`select email from users where id = ${ids[r]}`); await login(ids[r], u.email); }
await sql`delete from app.rate_limit_hits`;
fs.mkdirSync(OUT, { recursive: true });
const browser = await chromium.launch({ args: ['--no-proxy-server', '--font-render-hinting=none'] });
await photos(browser);
const run = async (p, fn) => { if (!want(p)) return; console.log(p); try { await fn(); } catch (e) { problems.push(`${p}: ${String(e.message ?? e).split('\n')[0]}`); } };
await run('public', () => publicPages(browser));
await run('renter', () => renterStory(browser, ids));
await run('owner', () => ownerPortal(browser, ids));
await run('investor', () => investorPortal(browser, ids));
await run('admin', () => adminPortal(browser, ids));
for (const r of ['va_cs', 'va_finance', 'va_fleet', 'va_sales']) await run(r.replace('_', '-'), () => vaPortal(browser, ids, r));
await run('field', () => fieldPortal(browser, ids));
await browser.close();

const people = Object.fromEntries(await Promise.all(Object.entries(ids).map(async ([r, id]) => [r, (await one(sql`select email, full_name from users where id = ${id}`))])));
manifest.sort((a, b) => a.portal.localeCompare(b.portal) || a.step - b.step || a.viewport.localeCompare(b.viewport));
fs.writeFileSync(path.join(OUT, 'manifest.json'), JSON.stringify({
  generated_at: new Date().toISOString(), source: 'the local stack (same build as carmacars.ca) with sample data; every person is fictional (example.com)',
  viewports: { desktop: '1440 x 900 at device scale 2', phone: '390 x 844 at device scale 3' }, cut_at: `${MAX_SCREENS} screen heights`,
  people, screens: manifest, problems
}, null, 2));
console.log(`${manifest.length} screenshots, ${problems.length} problems`);
for (const p of problems) console.log(`  PROBLEM ${p}`);
await sql.end();
