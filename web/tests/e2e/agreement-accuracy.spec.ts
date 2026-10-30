import AxeBuilder from '@axe-core/playwright';
import { expect, test, type Page } from '@playwright/test';
import { randomBytes, randomUUID, scryptSync, createHash } from 'node:crypto';
import { mkdirSync, readFileSync } from 'node:fs';
import { acceptCookies, db, giveLicence, noOverflow, storeFixturePdf, strongSign } from './helpers';

// Migration 0154 end to end, at both widths: the booking's Rental agreements card lists what the agreements print blank
// and saves it; a material change (the coverage option) makes version 2 of both agreements, waiting for the renter's
// signature; the renter signs it on its own link with the code, the initials, the consents and a drawn signature; its
// signed copy (signatures page and certificate) is filed; /verify finds a signed file by its SHA-256 and refuses a
// changed one. The agreement itself is signed through the database with a complete signing session (the signing pages
// are the portal and second-agreement specs).
const SHOTS = '/tmp/claude-0/-home-claude/cd546a4d-311f-50f2-8aac-0a6c92256d38/scratchpad/agreement-shots';
const PW = 'correct horse battery';
type Sql = ReturnType<typeof db>;
mkdirSync(SHOTS, { recursive: true });
const hash = (pw: string) => { const salt = randomBytes(16); return `scrypt$${salt.toString('base64')}$${scryptSync(pw, salt, 64).toString('base64')}`; };

async function check(page: Page, where: string, scope?: string) {
  await noOverflow(page);
  // the admin booking page is long: the card itself is checked there
  const axe = new AxeBuilder({ page: page as never }).withTags(['wcag2a', 'wcag2aa', 'wcag21a', 'wcag21aa']);
  const r = await (scope ? axe.include(scope) : axe).analyze();
  const bad = r.violations.filter((v) => v.impact === 'serious' || v.impact === 'critical');
  expect(bad.map((v) => `${where} ${v.id}: ${v.nodes.map((n) => n.target.join(' ')).slice(0, 3).join(', ')}`)).toEqual([]);
  expect((await page.locator('body').innerText()).match(/[—–]/)?.[0], `${where}: long dash`).toBeUndefined();
}
async function mkUser(sql: Sql, role: 'admin' | 'renter') {
  const id = randomUUID(); const email = `${role}.ag.${Date.now()}.${Math.floor(Math.random() * 1e4)}@example.test`;
  await sql`insert into local_auth.users (id, email, password_hash) values (${id}, ${email}, ${hash(PW)})`;
  if (role === 'renter') { await sql`select public.register_account(${id}, ${email}, 'Riley Agreement', null)`; return { id, email }; }
  await sql`insert into users (id, email, full_name) values (${id}, ${email}, 'Ada Admin')`;
  await sql`insert into user_roles (user_id, role) values (${id}, 'admin')`;
  return { id, email };
}
async function freeCar(sql: Sql) {
  const from = new Date(Date.now() + 40 * 86_400_000 + Math.floor(Math.random() * 200) * 86_400_000); const to = new Date(from.getTime() + 3 * 86_400_000);
  const rows = await sql`select v.id from vehicles v join vehicle_listings l on l.vehicle_id = v.id
    where l.status = 'published' and app.vehicle_bookable(v.id) and v.partner_id is null and (not v.is_sample or v.sample_bookable) and app.vehicle_on_policy(v.id)
      and not exists (select 1 from bookings b where b.vehicle_id = v.id and b.status in ('requested','offered','pending_payment','confirmed','on_rent','returned','closed')
                        and tstzrange(b.pickup_at - interval '1 day', b.return_at + interval '1 day') && tstzrange(${from.toISOString()}::timestamptz, ${to.toISOString()}::timestamptz))
      and not exists (select 1 from vehicle_calendar_blocks k where k.vehicle_id = v.id and k.removed_at is null and k.starts_at < ${to.toISOString()}::timestamptz and (k.ends_at is null or k.ends_at > ${from.toISOString()}::timestamptz))
    order by random() limit 1`;
  if (!rows[0]) throw new Error('no free car');
  const ymd = (d: Date) => new Intl.DateTimeFormat('en-CA', { timeZone: 'America/Toronto', year: 'numeric', month: '2-digit', day: '2-digit' }).format(d);
  return { id: rows[0].id as string, from: ymd(from), to: ymd(to) };
}
/** A booking with its rental agreement signed (through a complete signing session) and countersigned: version 1. */
async function signedBooking(sql: Sql, admin: string) {
  const renter = await mkUser(sql, 'renter');
  const car = await freeCar(sql);
  const req = {
    request_key: randomUUID(), vehicle_id: car.id, pickup_at: `${car.from}T10:00:00-04:00`, return_at: `${car.to}T10:00:00-04:00`, booking_type: 'standard',
    pickup_method: 'collected', return_method: 'returned', pickup_location: { kind: 'our_location' }, return_location: { kind: 'our_location' }, coverage_option: 2, extras: { winter_tire: false, baby_seats: 0 },
    renter: { email: renter.email, full_name: 'Riley Agreement', mobile: '+16475550188', date_of_birth: '1988-03-14', licence_class: 'G', licence_issuer: 'ON' }, additional_drivers: [],
    consents: { terms: { accepted: true, version: 'e2e', text: 'I agree.' }, privacy: { accepted: true, version: 'e2e', text: 'I agree.' }, marketing: { opted_in: false, version: 'e2e', text: 'No.' } }, details: { source: 'e2e' }
  };
  const [r] = await sql`select public.submit_booking_request(${sql.json(req)}, '203.0.113.9', 'e2e', ${renter.id}) v`;
  const v = r!.v as { ok: boolean; booking_id: string; booking_number: string };
  expect(v.ok).toBe(true);
  const b = v.booking_id;
  await sql`update renters r set address_line1 = '1 Agreement Street', city = 'Toronto', province = 'ON', postal_code = 'M5H 2N2' from bookings x where x.id = ${b} and r.id = x.renter_id`;
  await sql`select app.send_offer(${b}::uuid, ${admin}::uuid)`;
  await giveLicence(sql, b);
  await sql`update booking_drivers set licence_number = 'A1234-56789-00314', licence_issuer = 'ON' where booking_id = ${b}`;
  await sql`select app.approve_offer(x.id, x.current_offer_version, ${renter.id}::uuid) from bookings x where x.id = ${b}`;
  storeFixturePdf('agreements', `bookings/${b}/agreement.pdf`);
  const sha = 'a'.repeat(64);
  await sql`select public.renter_open_agreement(${b}::uuid, ${renter.id}::uuid, 'e2e', ${sha}, ${`bookings/${b}/agreement.pdf`})`;
  const [g] = await sql`select g.id from rental_agreement_signers g join rental_agreements a on a.id = g.agreement_id where a.booking_id = ${b} and g.signer_role = 'renter' and a.status = 'open'`;
  const [s] = await sql`select (public.server_esign_start(jsonb_build_object('context', 'rental_agreement', 'signer_ref', ${g!.id}::uuid, 'ip', '203.0.113.9', 'user_agent', 'e2e')) ->> 'id') id`;
  await sql`select public.server_esign_code_set(${s!.id}::uuid, 'email', ${'c'.repeat(64)})`;
  await sql`select public.server_esign_code_check(${s!.id}::uuid, ${'c'.repeat(64)})`;
  await sql`select public.server_esign_step(${s!.id}::uuid, 'viewed', '{}')`;
  for (const k of ['damage', 'charges', 'fees', 'coverage', 'cancellation']) await sql`select public.server_esign_step(${s!.id}::uuid, 'initial', ${sql.json({ code: k, path: `esign/${s!.id}/initials-${k}.png` })})`;
  for (const k of ['esign', 'erecords', 'card']) await sql`select public.server_esign_step(${s!.id}::uuid, 'consent', ${sql.json({ code: k, text: 'I agree' })})`;
  await sql`select public.server_esign_step(${s!.id}::uuid, 'signature', ${sql.json({ method: 'drawn', path: `esign/${s!.id}/signature.png` })})`;
  await sql`select public.renter_sign_agreement(${b}::uuid, ${renter.id}::uuid, 'I sign.', ${sha}, '[]'::jsonb, null, ${`esign/${s!.id}/signature.png`}, '203.0.113.9', 'e2e')`;
  await sql`update rental_agreements set status = 'completed', completed_at = now() where booking_id = ${b} and status = 'signed'`;
  await sql`update signature_requests set status = 'completed', completed_at = now() where id = (select signature_request_id from bookings where id = ${b})`;
  await sql`insert into payments (booking_id, renter_id, purpose, kind, method, amount_cents, status, processed_at) select id, renter_id, 'booking_total', 'charge', 'card', renter_due_at_booking_cents, 'succeeded', now() from bookings where id = ${b}`;
  await sql`insert into coverage_proofs (booking_id, coverage_option, status, card_issuer, card_last4, confirmed_at) values (${b}, 2, 'confirmed', 'Example Bank', '4242', now())`;
  await sql`insert into payment_methods (renter_id, card_brand, card_last4, cardholder_name, exp_month, exp_year, is_credit)
            select renter_id, 'visa', '4242', 'Riley Agreement', 12, 2031, true from bookings where id = ${b}`;
  await sql`update bookings x set card_on_file_id = (select pm.id from payment_methods pm where pm.renter_id = x.renter_id order by pm.created_at desc limit 1) where x.id = ${b}`;
  await sql`update bookings set status = 'confirmed' where id = ${b}`;
  return { booking: b, number: v.booking_number, renter };
}

test('the Rental agreements card: missing fields filled; a material change signed on its own link; the signed copy; /verify', async ({ page, browser }, info) => {
  test.setTimeout(300_000);
  const w = info.project.name;
  const sql = db();
  await sql`delete from app.rate_limit_hits`;
  const admin = await mkUser(sql, 'admin');
  const bk = await signedBooking(sql, admin.id);
  const [v1] = await sql`select version_no, kind, status from agreement_versions where booking_id = ${bk.booking}`;
  expect(v1).toMatchObject({ version_no: 1, kind: 'signed', status: 'signed' });
  // a field a claim needs goes blank (the licence expiry): the card lists it
  await sql`update booking_drivers set licence_expiry = null where booking_id = ${bk.booking}`;
  await sql`update drivers set licence_expiry = null where id = (select driver_id from booking_drivers where booking_id = ${bk.booking} and role = 'renter')`;
  const [drv] = await sql`select driver_id from booking_drivers where booking_id = ${bk.booking} and role = 'renter'`;

  await page.goto('/sign-in', { waitUntil: 'networkidle' });
  await acceptCookies(page);
  await page.locator('input[type="email"]').fill(admin.email);
  await page.locator('input[type="password"]').fill(PW);
  await page.getByRole('button', { name: 'Sign in' }).click();
  await page.waitForURL((u) => u.pathname.startsWith('/admin'), { timeout: 20_000 });
  await page.goto(`/admin/bookings/${bk.number}`, { waitUntil: 'networkidle' });
  const card = page.getByTestId('agreement-panel');
  await expect(card).toBeVisible();
  await expect(card.getByTestId('agreement-current')).toContainText(/Current: version \d/);
  await expect(card.getByTestId('agreement-missing')).toContainText('Renter: licence expiry');
  await check(page, 'agreement card', '[data-testid="agreement-panel"]');
  await page.screenshot({ path: `${SHOTS}/${w}-card.png`, fullPage: true });
  await card.getByTestId(`fill-drivers-${drv!.driver_id}-licence-expiry`).fill('2032-03-14');
  await card.getByTestId('agreement-fill').click();
  await expect(card.getByText('Saved. The agreements follow in a moment.')).toBeVisible({ timeout: 15_000 });
  await expect.poll(async () => (await sql`select licence_expiry::text e from booking_drivers where booking_id = ${bk.booking} and role = 'renter'`)[0]!.e).toBe('2032-03-14');

  // a material change: the coverage option; the agreements are made again at once (the card's button kicks the job)
  await sql`update bookings set coverage_option = 3 where id = ${bk.booking}`;
  await page.reload({ waitUntil: 'networkidle' });
  await page.getByTestId('agreement-regenerate').click();
  await expect.poll(async () => (await sql`select count(*)::int n from agreement_versions where booking_id = ${bk.booking} and status = 'awaiting_signature'`)[0]!.n, { timeout: 90_000 }).toBe(1);
  const [ver] = await sql`select v.version_no, v.kind, v.changes from agreement_versions v where v.booking_id = ${bk.booking} and v.status = 'awaiting_signature'`;
  expect(ver!.kind).toBe('change');
  expect(JSON.stringify(ver!.changes)).toContain('Coverage option');
  // version 1 stays the signed original; the corrected licence expiry is in a version of its own or in this one
  const kinds = (await sql`select kind from agreement_versions where booking_id = ${bk.booking} order by version_no`).map((x) => x.kind);
  expect(kinds[0]).toBe('signed');
  await page.reload({ waitUntil: 'networkidle' });
  await expect(page.getByTestId('agreement-waiting')).toContainText(`Agreement v${ver!.version_no} waiting for signature`);
  const [sent] = await sql`select count(*)::int n from app_events where code = 'renter_agreement_version' and payload ->> 'needs_signature' = 'true' and payload ->> 'booking_id' = ${bk.booking}`;
  expect(sent!.n).toBeGreaterThan(0);

  // the renter signs on their own link (no sign-in), every step of the session
  const [tok] = await sql`select g.link_token::text t from agreement_version_signers g join agreement_versions v on v.id = g.version_id where v.booking_id = ${bk.booking} and v.status = 'awaiting_signature'`;
  const rp = await (await browser.newContext({ viewport: page.viewportSize() ?? undefined, baseURL: test.info().project.use.baseURL })).newPage();
  await rp.goto(`/sign/agreement/${tok!.t}`, { waitUntil: 'networkidle' });
  await acceptCookies(rp);
  await expect(rp.getByRole('heading', { name: `Version ${ver!.version_no} of your rental agreement` })).toBeVisible();
  await expect(rp.locator('table')).toContainText('Coverage option');
  await check(rp, 'version sign page');
  await strongSign(rp, rp, 'email', true);   // the optional code (0186), opened by the signer
  await rp.screenshot({ path: `${SHOTS}/${w}-version-ready.png`, fullPage: true });
  await rp.getByTestId('version-sign').click();
  await expect(rp.getByTestId('version-signed')).toBeVisible({ timeout: 20_000 });
  const [after] = await sql`select v.status, (select count(*)::int from esign_events e join esign_sessions s on s.id = e.session_id where s.context = 'agreement_version' and s.signer_ref = g.id) events
    from agreement_versions v join agreement_version_signers g on g.version_id = v.id where g.link_token = ${tok!.t}::uuid`;
  expect(after!.status).toBe('signed');
  expect(after!.events).toBeGreaterThanOrEqual(12);
  await expect.poll(async () => (await sql`select count(*)::int n from agreement_versions where booking_id = ${bk.booking} and signed_carmacars_document_id is not null`)[0]!.n, { timeout: 90_000 }).toBe(1);

  // /verify: the signed copy's SHA-256 is found; a changed copy is not
  const [doc] = await sql`select d.storage_path p, d.sha256 from agreement_versions v join documents d on d.id = v.signed_carmacars_document_id where v.booking_id = ${bk.booking}`;
  const file = readFileSync(`.local-storage/agreements/${doc!.p}`);
  expect(createHash('sha256').update(file).digest('hex')).toBe(doc!.sha256);
  await rp.goto('/verify', { waitUntil: 'networkidle' });
  await rp.getByTestId('verify-file').setInputFiles({ name: 'signed.pdf', mimeType: 'application/pdf', buffer: file });
  await expect(rp.getByTestId('verify-found')).toBeVisible({ timeout: 15_000 });
  await check(rp, 'verify');
  await rp.getByTestId('verify-file').setInputFiles({ name: 'changed.pdf', mimeType: 'application/pdf', buffer: Buffer.concat([file, Buffer.from(' ')]) });
  await expect(rp.getByTestId('verify-not-found')).toBeVisible({ timeout: 15_000 });
  await rp.context().close();
  await sql.end();
});
