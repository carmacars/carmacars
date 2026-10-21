import AxeBuilder from '@axe-core/playwright';
import { expect, test, type Page } from '@playwright/test';
import { randomBytes, randomUUID, scryptSync } from 'node:crypto';
import { acceptCookies, db, noOverflow, watch } from './helpers';

// The renter portal end to end, at 375 and 1440: request (the wizard, signed in), the staff step seeded
// through app.send_offer, approve, details, sign by drawing on the canvas, pay with the fake adapter
// (authorize, database confirms, capture), confirmed and blocking on the public calendar, signed copy,
// uploads, documents, notifications, profile, previews, cancellation numbers equal to the database.
// A second test runs the race: another renter is confirmed first, the authorization is voided and the
// push-back message is shown. Every portal page is checked with axe (no serious or critical issue).
const STAFF = '00000000-0000-4000-8000-0000000000c5';
const SHOTS = 'test-results/portal';

async function axe(page: Page, where: string) {
  const wide = await page.evaluate(() => [...document.querySelectorAll('body *')].filter((e) => e.getBoundingClientRect().right > innerWidth + 1 && !e.closest('.table-scroll, .agreement')).slice(0, 5).map((e) => `${e.tagName}.${e.className}`));
  expect(wide, `${where}: elements wider than the screen`).toEqual([]);
  await noOverflow(page);
  const r = await new AxeBuilder({ page: page as never }).withTags(['wcag2a', 'wcag2aa', 'wcag21a', 'wcag21aa']).analyze();
  const bad = r.violations.filter((v) => v.impact === 'serious' || v.impact === 'critical');
  expect(bad.map((v) => `${where} ${v.id}: ${v.nodes.map((n) => n.target.join(' ')).slice(0, 3).join(', ')}`)).toEqual([]);
}

async function staff(sql: ReturnType<typeof db>) {
  await sql`insert into users (id, email, full_name) values (${STAFF}, 'e2e.staff@example.test', 'Casey Staff') on conflict do nothing`;
  await sql`insert into user_roles (user_id, role) values (${STAFF}, 'va') on conflict do nothing`;
  await sql`insert into staff_profiles (user_id, home_address, home_postal_code, staff_type, va_function) values (${STAFF}, '1 Test Lane, Testville', 'X9X 9X9', 'va', 'cs') on conflict do nothing`;
}

/** A free window of `days` on the car, at least `from` days ahead (no confirmed booking within a day either side). */
async function freeWindow(sql: ReturnType<typeof db>, slug: string, start: number, days = 3) {
  for (let off = start; off < start + 200; off += 5) {
    const d = new Date(); d.setUTCDate(d.getUTCDate() + off);
    const from = d.toISOString().slice(0, 10); d.setUTCDate(d.getUTCDate() + days);
    const to = d.toISOString().slice(0, 10);
    const busy = await sql`select count(*)::int n from bookings b join vehicle_listings l using (vehicle_id)
      where l.slug = ${slug} and (b.status in ('confirmed','on_rent') or (b.status in ('requested','offered','pending_payment') and b.request_details ->> 'source' = 'e2e'))
        and tstzrange(b.pickup_at - interval '1 day', b.return_at + interval '1 day') && tstzrange(${from}::date::timestamptz, ${to}::date::timestamptz + interval '1 day')`;
    if (busy[0]!.n === 0) return { from, to };
  }
  throw new Error('no free window');
}

async function drawSignature(page: Page) {
  const pad = page.getByTestId('signature-pad');
  await pad.scrollIntoViewIfNeeded();
  const b = (await pad.boundingBox())!;
  await page.mouse.move(b.x + 20, b.y + b.height * 0.6);
  await page.mouse.down();
  for (let i = 1; i <= 30; i++) await page.mouse.move(b.x + 20 + i * ((b.width - 60) / 30), b.y + b.height * (0.6 + 0.25 * Math.sin(i / 2.5)), { steps: 2 });
  await page.mouse.up();
}

async function signIn(page: Page, email: string, next: string) {
  await page.goto(`/sign-in?next=${encodeURIComponent(next)}`, { waitUntil: 'networkidle' });
  await acceptCookies(page);
  await page.locator('input[type="email"]').fill(email);
  await page.locator('input[type="password"]').fill('correct horse battery');
  await page.getByRole('button', { name: 'Sign in' }).click();
}

test('renter portal: offer, approve, sign, pay, confirmed, documents, uploads, self-service', async ({ page }, info) => {
  test.setTimeout(Number(process.env.PORTAL_TIMEOUT ?? 200_000));
  const phone = info.project.name.startsWith('phone');
  const errors = watch(page);
  const sql = db();
  await sql`delete from app.rate_limit_hits`;
  await staff(sql);
  const slug = phone ? 'honda-civic' : 'toyota-camry';
  const range = await freeWindow(sql, slug, 70);
  const email = `portal.${info.project.name}.${Date.now()}@example.test`;

  // 1. account and request (signed in, so the request is attached to this account)
  await seedRenter(sql, email, 'Morgan Payer');
  await signIn(page, email, '/account');
  await page.waitForURL(/\/account$/);
  await page.goto(`/book/${slug}?from=${range.from}&to=${range.to}&tf=10:00&tt=10:00`, { waitUntil: 'networkidle' });
  await page.getByRole('button', { name: 'Continue to driver details' }).click();
  await page.locator('#rq-first').fill('Morgan');
  await page.locator('#rq-last').fill('Payer');
  await page.locator('#rq-email').fill(email);
  await page.locator('#rq-phone').fill('647-555-0177');
  await page.locator('#rq-dobm').selectOption('4');
  await page.locator('#rq-dobd').fill('9');
  await page.locator('#rq-doby').fill('1990');
  await page.getByRole('button', { name: 'Continue to licence' }).click();
  await page.locator('label', { hasText: 'Ontario G2' }).click();
  await page.locator('label.option', { hasText: 'Option 2' }).click();
  await page.getByRole('button', { name: 'Continue to add-ons' }).click();
  await page.getByRole('button', { name: 'Review request' }).click();
  await page.locator('input[name="agree"]').check();
  await page.getByRole('button', { name: 'Send request' }).click();
  await page.waitForURL(/\/book\/sent\//, { timeout: 30_000 });
  const number = decodeURIComponent(page.url().split('/').pop()!);
  const [bk] = await sql`select b.id, b.vehicle_id, b.status::text from bookings b join renters r on r.id = b.renter_id join users u on u.id = r.user_id where b.booking_number = ${number} and u.email = ${email}`;
  expect(bk?.status).toBe('requested');
  await sql`update bookings set request_details = request_details || '{"source":"e2e"}' where id = ${bk!.id}`;

  // 2. the staff step: customer service sends the offer (seeded through the database function)
  await sql`select app.send_offer(${bk!.id}, ${STAFF}, 'Your car is ready. We kept your dates.', null)`;

  // 3. the portal shows the next step; the offer page shows the version, price, countdown and the rule
  await page.goto('/account');
  await expect(page.getByTestId('next-step')).toContainText('Approve your offer');
  await axe(page, '/account');
  await page.getByTestId('next-step').getByRole('link', { name: 'Review offer' }).click();
  await page.waitForURL(/\/offer$/);
  await expect(page.getByRole('heading', { level: 1 })).toContainText('Your offer');
  await expect(page.getByTestId('offer-hold-rule')).toContainText('This offer does not hold the car.');
  await expect(page.getByTestId('offer-countdown')).toContainText(/left/);
  const [due] = await sql`select renter_due_at_booking_cents::int c from bookings where id = ${bk!.id}`;
  const dollars = (c: number) => `$${(c / 100).toLocaleString('en-CA', { minimumFractionDigits: 2 })}`;
  await expect(page.getByTestId('total-due')).toHaveText(dollars(due!.c));
  await axe(page, 'offer');
  await page.screenshot({ path: `${SHOTS}-${info.project.name}-offer.png`, fullPage: true });

  // a stale version is refused: staff re-send the offer while the page is open
  await sql`select app.send_offer(${bk!.id}, ${STAFF}, 'Version two, same terms.', null)`;
  await page.getByRole('button', { name: 'Approve and continue' }).click();
  await expect(page.getByText('This offer was updated. Review the new version.').first()).toBeVisible();
  await page.reload();
  await expect(page.getByText('Version two, same terms.')).toBeVisible();

  // 4. approve: the agreement for the approved version is opened, then the signing page
  await page.getByRole('button', { name: 'Approve and continue' }).click();
  await page.waitForURL(/\/sign$/, { timeout: 30_000 });
  await expect(page.getByRole('heading', { level: 1 })).toHaveText('Sign your rental agreement');
  await page.locator('#pt-d-address_line1').fill('100 Queen Street West');
  await page.locator('#pt-d-city').fill('Toronto');
  await page.locator('#pt-d-postal_code').fill('M5H 2N2');
  await page.locator('#pt-d-licence_number').fill('P1234-56789-01234');
  await page.locator('#pt-d-licence_expiry').fill('2031-06-30');
  await page.getByRole('button', { name: 'Save details' }).click();
  await expect(page.locator('.agreement')).toContainText('100 Queen Street West', { timeout: 15_000 });
  await expect(page.locator('.agreement')).toContainText('P1234-56789-01234');
  await expect(page.locator('.agreement')).toContainText('Part 6: Booking Consents');
  const pdf = await page.request.get(await page.getByTestId('agreement-pdf').getAttribute('href') as string);
  expect(pdf.status()).toBe(200);
  expect((await pdf.body()).subarray(0, 4).toString()).toBe('%PDF');
  await axe(page, 'sign');
  await page.screenshot({ path: `${SHOTS}-${info.project.name}-sign.png`, fullPage: true });
  // the four statements are required (one tap on "All four" ticks them, each stays on screen), then a drawn signature
  await page.getByRole('button', { name: 'Sign and continue to payment' }).click();
  await expect(page.getByText('Tick the four statements (one tap on "All four").')).toBeVisible();
  await page.getByTestId('consents-all').check();
  for (const c of await page.locator('.pk-statements input[type="checkbox"]').all()) await expect(c).toBeChecked();
  await page.getByTestId('signature-mode').click();
  await drawSignature(page);
  await page.getByRole('button', { name: 'Sign and continue to payment' }).click();
  await page.waitForURL(/\/pay$/, { timeout: 30_000 });
  const [sig] = await sql`select r.method, r.provider_signature, host(r.ip_address) ip, r.user_agent, (select count(*)::int from consents c where c.booking_id = ${bk!.id} and c.consent_code in ('tracking_disabling','identity_verification','electronic_signature','card_authorization')) consents
    from signature_records r join bookings b on b.signature_request_id = r.signature_request_id where b.id = ${bk!.id} and r.signer_role = 'renter'`;
  expect(sig?.method).toBe('drawn');
  expect(sig?.provider_signature).toMatch(/^bookings\/.+\/signatures\/renter-.+\.png$/);
  expect(sig?.user_agent).toContain('Mozilla');
  expect(sig?.consents).toBe(4);

  // 5. pay with the fake adapter: wrong name and a declined card first
  await expect(page.getByTestId('fake-card')).toBeVisible();
  await axe(page, 'pay');
  await page.screenshot({ path: `${SHOTS}-${info.project.name}-pay.png`, fullPage: true });
  await page.locator('#pt-card-name').fill('Someone Else');
  await page.locator('#pt-card-number').fill('4242 4242 4242 4242');
  await page.locator('#pt-card-exp').fill('12 / 30');
  await page.locator('#pt-card-cvc').fill('123');
  await page.getByRole('button', { name: /^Pay \$/ }).click();
  await expect(page.getByText('The card must be in the renter\'s name.')).toBeVisible();
  await page.locator('#pt-card-name').fill('Morgan Payer');
  await page.locator('#pt-card-number').fill('4000 0000 0000 0002');
  await page.getByRole('button', { name: /^Pay \$/ }).click();
  await expect(page.getByText('Your card was declined.')).toBeVisible();
  await page.locator('#pt-card-number').fill('4242 4242 4242 4242');
  await page.getByRole('button', { name: /^Pay \$/ }).click();
  await page.waitForURL(new RegExp(`/account/bookings/${number}\\?paid=1`), { timeout: 30_000 });
  await expect(page.getByTestId('paid-panel')).toContainText('Booking confirmed');
  await expect(page.getByTestId('status-badge').first()).toHaveText('Confirmed');
  await axe(page, 'booking');

  // the database: confirmed, the payment succeeded for the amount due, the card is on file,
  // the agreement is completed with the signed copy attached
  const [conf] = await sql`select b.status::text, b.card_on_file_id is not null card, b.blocks_calendar,
      (select string_agg(p.status || ':' || p.amount_cents, ',') from payments p where p.booking_id = b.id and p.purpose = 'booking_total') pay,
      a.status::text agreement, s.signed_document_id is not null signed
    from bookings b join rental_agreements a on a.booking_id = b.id and a.status = 'completed' join signature_requests s on s.id = a.signature_request_id where b.id = ${bk!.id}`;
  expect(conf).toMatchObject({ status: 'confirmed', card: true, blocks_calendar: true, pay: `succeeded:${due!.c}`, agreement: 'completed', signed: true });
  // blocking on the public calendar (the same function the car page reads)
  const cal = await sql`select unavailable_from, unavailable_to from public_vehicle_calendar(${bk!.vehicle_id}, ${range.from}::date - 1, ${range.to}::date + 1)`;
  expect(cal.some((r) => new Date(r.unavailable_from as string) <= new Date(`${range.from}T16:00:00Z`) && new Date(r.unavailable_to as string) >= new Date(`${range.to}T14:00:00Z`))).toBe(true);
  // the signed agreement downloads as a PDF with a signature record page
  const signedLink = page.getByTestId('doc-rental_agreement').last();
  const signed = await page.request.get(await signedLink.getAttribute('href') as string);
  expect(signed.status()).toBe(200);
  expect((await signed.body()).subarray(0, 4).toString()).toBe('%PDF');

  // 6. uploads from the phone camera or files: licence front, back, selfie, and the coverage proof
  await page.goto(`/account/bookings/${number}/verify`);
  await axe(page, 'verify');
  const png = await page.screenshot({ clip: { x: 0, y: 0, width: 300, height: 200 } });
  for (const kind of ['licence_front', 'licence_back', 'selfie']) {
    const card = page.locator(`[data-testid^="upload-${kind}-"]`).first();
    await card.locator('input[type="file"]').setInputFiles({ name: `${kind}.png`, mimeType: 'image/png', buffer: png });
    await expect(card.getByText('In review')).toBeVisible({ timeout: 15_000 });
  }
  // coverage option 2 (0071): the card that paid, a credit card in the renter's name; the renter ticks its coverage
  await expect(page.getByTestId('coverage-card')).toContainText('ending 4242');
  await page.getByTestId('coverage-card-tick').check();
  await page.getByTestId('coverage-card-confirm').click();
  await expect(page.getByTestId('coverage-card-confirmed')).toBeVisible({ timeout: 15_000 });
  // and adds the card's benefit document (optional)
  const proof = Buffer.from('%PDF-1.4\n1 0 obj << /Type /Catalog >> endobj\ntrailer << /Root 1 0 R >>\n%%EOF\n');
  await page.getByTestId('upload-coverage_proof').locator('input[type="file"]').setInputFiles({ name: 'benefits.pdf', mimeType: 'application/pdf', buffer: proof });
  await expect(page.getByTestId('upload-coverage_proof').getByText('In review')).toBeVisible({ timeout: 15_000 });
  // a file that is not what it says is refused and deleted
  await page.locator('[data-testid^="upload-selfie-"]').first().locator('input[type="file"]').setInputFiles({ name: 'x.png', mimeType: 'image/png', buffer: Buffer.from('not an image at all') });
  await expect(page.locator('[data-testid^="upload-selfie-"]').first().locator('.error')).not.toBeEmpty();
  const ups = await sql`select u.kind, u.status, d.storage_bucket, d.retention::text from verification_uploads u join documents d on d.id = u.document_id where u.booking_id = ${bk!.id} and u.status = 'submitted' order by u.kind`;
  expect(ups.map((u) => `${u.kind}:${u.storage_bucket}`)).toEqual(['coverage_proof:documents', 'licence_back:identity', 'licence_front:identity', 'selfie:identity']);
  const [cp] = await sql`select coverage_option, card_last4 from coverage_proofs where booking_id = ${bk!.id}`;
  expect(cp).toMatchObject({ coverage_option: 2, card_last4: '4242' });

  // 7. documents, notifications, profile
  await page.goto('/account/documents');
  await expect(page.locator('table')).toContainText('Rental agreement');
  await axe(page, 'documents');
  await page.goto('/account/notifications');
  await expect(page.getByRole('heading', { level: 1 })).toHaveText('Notifications');
  await axe(page, 'notifications');
  await page.goto('/account/profile');
  await expect(page.locator('#pt-p-address_line1')).toHaveValue('100 Queen Street West');
  await page.locator('#pt-p-mobile').fill('416-555-0199');
  await page.getByRole('button', { name: 'Save' }).click();
  await expect(page.getByText('Saved.')).toBeVisible();
  // the button fades back from its disabled grey: check the contrast once it is settled, not mid-transition
  await expect(page.getByRole('button', { name: 'Save' })).toBeEnabled();
  await page.mouse.move(0, 0);
  await page.waitForTimeout(400);
  await axe(page, 'profile');

  // 8. extension and change previews come from the database
  await page.goto(`/account/bookings/${number}/extend`);
  await axe(page, 'extend');
  const newReturn = new Date(`${range.to}T12:00:00Z`); newReturn.setUTCDate(newReturn.getUTCDate() + 2);
  await page.locator('#pt-ext-d').fill(newReturn.toISOString().slice(0, 10));
  await page.getByRole('button', { name: 'See the price' }).click();
  await expect(page.getByTestId('preview-total')).toBeVisible();
  const [ep] = await sql`select (app.preview_extension(${bk!.id}, (${newReturn.toISOString().slice(0, 10)} || ' 10:00 America/Toronto')::timestamptz) ->> 'total_cents')::int c`;
  await expect(page.getByTestId('preview-total')).toHaveText(dollars(ep!.c));
  await page.goto(`/account/bookings/${number}/change`);
  await axe(page, 'change');

  // 9. cancellation: the numbers on the page equal the database's preview, then cancel
  await page.goto(`/account/bookings/${number}/cancel`);
  await axe(page, 'cancel');
  const [cpv] = await sql`select app.preview_cancellation(${bk!.id}, now(), null) v`;
  const v = cpv!.v as { tier: string; refund_cents: number; total_paid_cents: number };
  await expect(page.getByTestId('cancel-tier')).toHaveAttribute('data-tier', v.tier);
  await expect(page.getByTestId('cancel-refund')).toHaveText(dollars(v.refund_cents));
  expect(v.total_paid_cents).toBe(due!.c);
  await page.locator('#pt-cancel-confirm').fill('nope');
  await page.getByRole('button', { name: 'Cancel booking' }).click();
  await expect(page.getByText(`Type ${number}.`)).toBeVisible();
  await page.locator('#pt-cancel-confirm').fill(number);
  await page.getByRole('button', { name: 'Cancel booking' }).click();
  await expect(page.getByText('Booking cancelled')).toBeVisible();
  const [after] = await sql`select b.status::text, c.refund_cents::int r from bookings b join booking_cancellations c on c.booking_id = b.id where b.id = ${bk!.id}`;
  expect(after).toMatchObject({ status: 'cancelled', r: v.refund_cents });
  await sql.end();
  expect(errors.filter((e) => !/Failed to load resource/.test(e))).toEqual([]);
});

// ---------------------------------------------------------------- the race for the car
function hash(pw: string) { const salt = randomBytes(16); return `scrypt$${salt.toString('base64')}$${scryptSync(pw, salt, 64).toString('base64')}`; }

async function seedRenter(sql: ReturnType<typeof db>, email: string, name: string) {
  const id = randomUUID();
  await sql`insert into local_auth.users (id, email, password_hash) values (${id}, ${email}, ${hash('correct horse battery')})`;
  await sql`select public.register_account(${id}, ${email}, ${name}, null)`;
  return id;
}
async function seedRequest(sql: ReturnType<typeof db>, user: string | null, email: string, name: string, vehicle: string, from: string, to: string) {
  const req = {
    request_key: randomUUID(), vehicle_id: vehicle, pickup_at: `${from}T10:00:00-05:00`, return_at: `${to}T10:00:00-05:00`, booking_type: 'standard',
    pickup_method: 'collected', return_method: 'returned', pickup_location: { kind: 'our_location' }, return_location: { kind: 'our_location' },
    coverage_option: 2, extras: { winter_tire: false, baby_seats: 0 },
    renter: { email, full_name: name, mobile: '+16475550123', date_of_birth: '1988-03-14', licence_class: 'G', licence_issuer: 'ON' }, additional_drivers: [],
    consents: { terms: { accepted: true, version: 'e2e', text: 'I agree.' }, privacy: { accepted: true, version: 'e2e', text: 'I agree.' }, marketing: { opted_in: false, version: 'e2e', text: 'No.' } },
    details: { source: 'e2e' }
  };
  const [r] = await sql`select public.submit_booking_request(${sql.json(req)}, '203.0.113.9', 'e2e', ${user}) v`;
  const v = r!.v as { ok: boolean; booking_id: string; booking_number: string; message?: string };
  expect(v.ok, v.message).toBe(true);
  await sql`update bookings set request_details = request_details || '{"source":"e2e"}' where id = ${v.booking_id}`;
  return v;
}

test('race: another renter pays first, the authorization is voided and the push-back is shown', async ({ page }, info) => {
  test.setTimeout(Number(process.env.PORTAL_TIMEOUT ?? 180_000));
  const sql = db();
  await sql`delete from app.rate_limit_hits`;
  await staff(sql);
  const slug = info.project.name.startsWith('phone') ? 'kia-forte' : 'hyundai-elantra';
  const [car] = await sql`select vehicle_id from vehicle_listings where slug = ${slug}`;
  const range = await freeWindow(sql, slug, 90);
  const stamp = `${info.project.name}.${Date.now()}`;
  const emailA = `race.a.${stamp}@example.test`, emailB = `race.b.${stamp}@example.test`;
  const userA = await seedRenter(sql, emailA, 'Avery Slow');
  const userB = await seedRenter(sql, emailB, 'Blake Fast');
  const a = await seedRequest(sql, userA, emailA, 'Avery Slow', car!.vehicle_id, range.from, range.to);
  const b = await seedRequest(sql, userB, emailB, 'Blake Fast', car!.vehicle_id, range.from, range.to);
  await sql`select app.send_offer(${a.booking_id}, ${STAFF}, null, null)`;
  await sql`select app.send_offer(${b.booking_id}, ${STAFF}, null, null)`;

  // A signs in, approves, signs by typing the legal name, and opens the pay page
  await signIn(page, emailA, `/account/bookings/${a.booking_number}/offer`);
  await page.waitForURL(/\/offer$/);
  await page.getByRole('button', { name: 'Approve and continue' }).click();
  await page.waitForURL(/\/sign$/, { timeout: 30_000 });
  await page.locator('#pt-d-address_line1').fill('1 Yonge Street');
  await page.locator('#pt-d-city').fill('Toronto');
  await page.locator('#pt-d-postal_code').fill('M5E 1E5');
  await page.locator('#pt-d-licence_number').fill('S1234-56789-01234');
  await page.locator('#pt-d-licence_expiry').fill('2030-01-31');
  await page.getByRole('button', { name: 'Save details' }).click();
  await expect(page.locator('.agreement')).toContainText('1 Yonge Street', { timeout: 15_000 });
  // the legal name on file is the signature: one tap for the statements, one to sign
  await page.getByTestId('consents-all').check();
  await expect(page.getByTestId('signature-adopted')).toBeVisible();
  await page.getByRole('button', { name: 'Sign and continue to payment' }).click();
  await page.waitForURL(/\/pay$/, { timeout: 30_000 });
  await expect(page.getByTestId('fake-card')).toBeVisible();
  await page.waitForTimeout(500); // the intent is created when the form loads

  // meanwhile B approves, signs and pays (through the database functions): B is confirmed first
  await sql`select app.approve_offer(${b.booking_id}, (select current_offer_version from bookings where id = ${b.booking_id}), ${userB})`;
  await sql`select app.open_rental_agreement(${b.booking_id}, ${userB}, 'rental-e2e', encode(sha256(${b.booking_number}::bytea), 'hex'), ${`bookings/${b.booking_id}/agreement.pdf`})`;
  await sql`select app.record_signature(bk.signature_request_id, g.id, g.signer_name, null, '203.0.113.10', 'e2e', 'I sign.')
              from bookings bk join rental_agreements ra on ra.signature_request_id = bk.signature_request_id
              join rental_agreement_signers g on g.agreement_id = ra.id and g.signer_role = 'renter' where bk.id = ${b.booking_id}`;
  const [pb] = await sql`select app.record_booking_payment(bk.id, jsonb_build_object('processor', 'stripe', 'payment_id', 'pi_race_' || bk.id, 'method_id', 'pm_race_' || bk.id, 'customer_id', 'cus_race'),
              bk.renter_due_at_booking_cents, bk.offer_approved_version,
              jsonb_build_object('brand', 'visa', 'last4', '4242', 'cardholder_name', 'Blake Fast', 'exp_month', 12, 'exp_year', 2031, 'is_credit', true), null) v
            from bookings bk where bk.id = ${b.booking_id}`;
  expect((pb!.v as { ok: boolean }).ok).toBe(true);

  // A pays: the card is authorized, the database refuses, the authorization is voided, the push-back is shown
  await page.locator('#pt-card-name').fill('Avery Slow');
  await page.locator('#pt-card-number').fill('4242424242424242');
  await page.locator('#pt-card-exp').fill('11/31');
  await page.locator('#pt-card-cvc').fill('321');
  await page.getByRole('button', { name: /^Pay \$/ }).click();
  await expect(page.getByTestId('pay-pushed-back')).toContainText('Someone else confirmed this car for these dates first. Nothing was charged');
  await axe(page, 'pay pushed back');
  const [ra] = await sql`select b.status::text, (select count(*)::int from payments p where p.booking_id = b.id and p.status = 'succeeded') paid,
      (select status from booking_offers o where o.booking_id = b.id order by version desc limit 1) offer,
      (select count(*)::int from booking_events e where e.booking_id = b.id and e.kind = 'payment_refused') refused
    from bookings b where b.id = ${a.booking_id}`;
  expect(ra).toMatchObject({ status: 'requested', paid: 0, offer: 'withdrawn', refused: 1 });
  const [rb] = await sql`select status::text from bookings where id = ${b.booking_id}`;
  expect(rb!.status).toBe('confirmed');
  // the booking page and the pay page say the same afterwards
  await page.goto(`/account/bookings/${a.booking_number}/pay`);
  await expect(page.getByTestId('pay-pushed-back')).toContainText('Nothing was charged');
  // tidy: B's sample booking would otherwise block this car for later runs
  await sql`update bookings set status = 'cancelled' where id = ${b.booking_id}`.catch(() => undefined);
  await sql.end();
});
