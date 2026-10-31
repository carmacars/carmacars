import AxeBuilder from '@axe-core/playwright';
import { expect, test, type Page } from '@playwright/test';
import { randomBytes, randomUUID, scryptSync } from 'node:crypto';
import { PDFArray, PDFDocument, PDFName, PDFString, StandardFonts } from 'pdf-lib';
import { acceptCookies, db, noOverflow, pdfText, watch, giveLicence, strongSign, completeAgreementDetails } from './helpers';

// The second rental agreement (docs/changes/2026-10-23-second-rental-agreement.md), end to end at 1440:
// - an Admin uploads Blind Spot's form in Settings > Forms (a stand-in made here: Blind Spot's PDF is private and never
//   in the repository), downloads the filled sample (the mailing address in place of the old one) and checks it;
// - a renter approves an offer: the signing page shows the Blind Spot agreement beside the rental agreement, filled with
//   the booking and their details; one signature signs both; after payment the signed Blind Spot agreement (with its
//   signature record page) is stored and listed in their documents.
// The template is set back to unchecked at the end, so the other specs run without it. Fictional people only.
const PW = 'correct horse battery';
const STAFF = '00000000-0000-4000-8000-0000000000c5';
type Sql = ReturnType<typeof db>;
const hash = (pw: string) => { const salt = randomBytes(16); return `scrypt$${salt.toString('base64')}$${scryptSync(pw, salt, 64).toString('base64')}`; };

async function standIn(): Promise<Buffer> {
  const doc = await PDFDocument.create();
  const font = await doc.embedFont(StandardFonts.Helvetica);
  const p1 = doc.addPage([595.276, 841.89]);
  doc.addPage([595.276, 841.89]).drawText('TERMS AND CONDITIONS', { x: 50, y: 800, size: 12, font });
  p1.drawText('BLIND SPOT CAR RENTAL (stand-in)', { x: 60, y: 790, size: 14, font });
  const annots = doc.context.obj([]) as PDFArray;
  for (const [rect, text] of [[[49, 745, 286, 757], '104 CROCKFORD BLVD, TORONTO, ON, M1R 3C3'], [[23, 307, 91, 319], '104 Crockford Blvd'], [[209, 307, 277, 319], '104 Crockford Blvd']] as Array<[number[], string]>)
    annots.push(doc.context.register(doc.context.obj({ Type: 'Annot', Subtype: 'FreeText', Rect: rect, Contents: PDFString.of(text), DA: PDFString.of('/Helv 8 Tf 0 g'), F: 4 })));
  p1.node.set(PDFName.of('Annots'), annots);
  return Buffer.from(await doc.save());
}
async function axe(page: Page, where: string, exclude?: string) {
  await noOverflow(page);
  const b = new AxeBuilder({ page: page as never }).withTags(['wcag2a', 'wcag2aa', 'wcag21a', 'wcag21aa']);
  const r = await (exclude ? b.exclude(exclude) : b).analyze();
  expect(r.violations.filter((v) => v.impact === 'serious' || v.impact === 'critical').map((v) => `${where} ${v.id}: ${v.nodes.map((n) => n.target.join(' ')).slice(0, 3).join(', ')}`)).toEqual([]);
}
async function signIn(page: Page, email: string, next: string) {
  await page.goto(`/sign-in?next=${encodeURIComponent(next)}`, { waitUntil: 'networkidle' });
  await acceptCookies(page);
  await page.locator('input[type="email"]').fill(email);
  await page.locator('input[type="password"]').fill(PW);
  await page.getByRole('button', { name: 'Sign in' }).click();
}
async function freeWindow(sql: Sql, slug: string, start: number, days = 3) {
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

test('the Blind Spot agreement: uploaded and checked by an Admin, filled for the booking, signed with the rental agreement', async ({ browser, page }, info) => {
  test.skip(info.project.name.startsWith('phone'), 'one run: the template is one for the whole site');
  test.setTimeout(240_000);
  const errors = watch(page);
  const sql = db();
  await sql`delete from app.rate_limit_hits`;
  await sql`insert into users (id, email, full_name) values (${STAFF}, 'e2e.staff@example.test', 'Casey Staff') on conflict do nothing`;
  await sql`insert into user_roles (user_id, role) values (${STAFF}, 'va') on conflict do nothing`;
  await sql`insert into staff_profiles (user_id, home_address, home_postal_code, staff_type, va_function) values (${STAFF}, '1 Test Lane, Testville', 'X9X 9X9', 'va', 'cs') on conflict do nothing`;
  const [mail] = await sql`select mailing_address m from site_settings where singleton`;
  const street = String(mail!.m).split(',')[0]!.trim();
  const stamp = `${Date.now()}`;

  try {
    // 1. the Admin: upload, sample, check
    const admin = randomUUID(); const adminEmail = `admin.ra2.${stamp}@example.test`;
    await sql`insert into local_auth.users (id, email, password_hash) values (${admin}, ${adminEmail}, ${hash(PW)})`;
    await sql`insert into users (id, email, full_name) values (${admin}, ${adminEmail}, 'Robin Admin')`;
    await sql`insert into user_roles (user_id, role) values (${admin}, 'admin')`;
    const ap = await (await browser.newContext({ viewport: { width: 1440, height: 900 }, baseURL: info.project.use.baseURL })).newPage();
    await signIn(ap, adminEmail, '/admin/settings/forms');
    await ap.waitForURL((u) => !u.pathname.startsWith('/sign-in'), { timeout: 20_000 });
    await ap.goto('/admin/settings/forms', { waitUntil: 'networkidle' });
    const card = ap.getByTestId('rental-form-BLINDSPOT-RA');
    await expect(card).toBeVisible();
    await ap.getByTestId('rental-form-upload-BLINDSPOT-RA').setInputFiles({ name: 'blindspot-standin.pdf', mimeType: 'application/pdf', buffer: await standIn() });
    await expect(ap.getByTestId('rental-form-state-BLINDSPOT-RA')).toHaveText('To check', { timeout: 20_000 });
    const sample = await ap.request.get(await ap.getByTestId('rental-form-sample-BLINDSPOT-RA').getAttribute('href') as string);
    expect(sample.status()).toBe(200);
    const sampleText = await pdfText(await sample.body());
    expect(sampleText).toContain(String(mail!.m).toUpperCase().split(',')[0]);
    expect(sampleText).toContain('CC-10001');
    expect(sampleText).not.toMatch(/crockford/i);
    // the Blind Spot card; the registry forms' field tables below (five official PDFs, about 250 rows) are checked by
    // form-fillers.spec.ts, and a second whole-page scan of them here runs the browser out of memory
    await axe(ap, 'admin forms', '[data-testid^="form-map-"]');
    await ap.getByTestId('rental-form-check-BLINDSPOT-RA').click();
    await expect(ap.getByTestId('rental-form-state-BLINDSPOT-RA')).toHaveText('In use for bookings', { timeout: 20_000 });

    // 2. the renter: approve, the two agreements, one signature
    const email = `ra2.${stamp}@example.test`;
    const user = randomUUID();
    await sql`insert into local_auth.users (id, email, password_hash) values (${user}, ${email}, ${hash(PW)})`;
    await sql`select public.register_account(${user}, ${email}, 'Jordan Second', null)`;
    const slug = 'toyota-camry';
    const [car] = await sql`select vehicle_id from vehicle_listings where slug = ${slug}`;
    const range = await freeWindow(sql, slug, 130);
    const req = {
      request_key: randomUUID(), vehicle_id: car!.vehicle_id, pickup_at: `${range.from}T10:00:00-05:00`, return_at: `${range.to}T10:00:00-05:00`, booking_type: 'standard',
      pickup_method: 'collected', return_method: 'returned', pickup_location: { kind: 'our_location' }, return_location: { kind: 'our_location' },
      coverage_option: 2, extras: { winter_tire: false, baby_seats: 0 },
      renter: { email, full_name: 'Jordan Second', mobile: '+16475550123', date_of_birth: '1988-03-14', licence_class: 'G', licence_issuer: 'ON' }, additional_drivers: [],
      consents: { terms: { accepted: true, version: 'e2e', text: 'I agree.' }, privacy: { accepted: true, version: 'e2e', text: 'I agree.' }, marketing: { opted_in: false, version: 'e2e', text: 'No.' } },
      details: { source: 'e2e' }
    };
    const [r] = await sql`select public.submit_booking_request(${sql.json(req)}, '203.0.113.9', 'e2e', ${user}) v`;
    const bk = r!.v as { ok: boolean; booking_id: string; booking_number: string; message?: string };
    expect(bk.ok, bk.message).toBe(true);
    await sql`update bookings set request_details = request_details || '{"source":"e2e"}' where id = ${bk.booking_id}`;
    await sql`select app.send_offer(${bk.booking_id}, ${STAFF}, null, null)`;
    await giveLicence(sql, bk.booking_id);

    await signIn(page, email, `/account/bookings/${bk.booking_number}/offer`);
    await page.waitForURL(/\/offer$/);
    await page.getByRole('button', { name: 'Approve and continue' }).click();
    await page.waitForURL(/\/sign$/, { timeout: 30_000 });
    await page.locator('#pt-d-address_line1').fill('200 Example Avenue');
    await page.locator('#pt-d-city').fill('Toronto');
    await page.locator('#pt-d-postal_code').fill('M4M 1A1');
    await page.locator('#pt-d-licence_number').fill('S1234-56789-03144');
    await page.locator('#pt-d-licence_expiry').fill('2031-03-14');
    await page.getByRole('button', { name: 'Save details' }).click();
    await completeAgreementDetails(page);
    await expect(page.locator('.agreement')).toContainText('200 Example Avenue', { timeout: 15_000 });
    const second = page.getByTestId('sign-companion');
    await expect(second).toContainText('Blind Spot Car Rental agreement');
    await expect(second).toContainText('Your one signature below signs both agreements.');
    // the Blind Spot agreement, filled with the booking and the details just saved
    const unsigned = await page.request.get(await page.getByTestId('companion-pdf').getAttribute('href') as string);
    expect(unsigned.status()).toBe(200);
    const text = await pdfText(await unsigned.body());
    for (const s of [bk.booking_number, 'Jordan Second', '200 Example Avenue', 'S1234-56789-03144', street]) expect(text).toContain(s);
    expect(text).not.toMatch(/crockford/i);
    await axe(page, 'sign with the second agreement');
    await page.getByTestId('consents-all').check();
    // 0154: the code, the initials, the consents and the drawn signature sign both agreements
    await strongSign(page);
    await page.getByRole('button', { name: 'Sign and continue to payment' }).click();
    await page.waitForURL(/\/pay$/, { timeout: 30_000 });
    const [c1] = await sql`select c.status, s.signer_role from rental_agreement_companions c join signature_records s on s.id = c.renter_record_id where c.booking_id = ${bk.booking_id} and c.status <> 'superseded'`;
    expect(c1).toMatchObject({ status: 'signed', signer_role: 'renter' });

    // 3. paid: the signed copies, the Blind Spot one with the signature record page
    await page.locator('#pt-card-name').fill('Jordan Second');
    await page.locator('#pt-card-number').fill('4242 4242 4242 4242');
    await page.locator('#pt-card-exp').fill('12 / 30');
    await page.locator('#pt-card-cvc').fill('123');
    await page.getByRole('button', { name: /^Pay \$/ }).click();
    await page.waitForURL(new RegExp(`/account/bookings/${bk.booking_number}\\?paid=1`), { timeout: 30_000 });
    await expect.poll(async () => (await sql`select count(*)::int n from rental_agreement_companions where booking_id = ${bk.booking_id} and status = 'completed' and signed_document_id is not null`)[0]!.n, { timeout: 90_000 }).toBe(1);
    const [doc] = await sql`select d.id from rental_agreement_companions c join documents d on d.id = c.signed_document_id where c.booking_id = ${bk.booking_id}`;
    await page.goto('/account/documents', { waitUntil: 'networkidle' });
    await expect(page.getByText(`Blind Spot rental agreement ${bk.booking_number}, signed`)).toBeVisible();
    const signed = await page.request.get(`/account/documents/${doc!.id}`);
    expect(signed.status()).toBe(200);
    const pdf = await PDFDocument.load(await signed.body());
    // the form's two pages, the signature record, then the certificate of completion (0154)
    expect(pdf.getPageCount()).toBeGreaterThanOrEqual(4);
    const signedText = await pdfText(await signed.body());
    expect(signedText).toContain('Signature record');
    expect(signedText).toContain('Certificate of completion');
    expect(errors).toEqual([]);
  } finally {
    await sql`update pdf_templates set verified = false, verified_by = null, verified_at = null where form_code = 'BLINDSPOT-RA' and is_current`;
    await sql.end();
  }
});
