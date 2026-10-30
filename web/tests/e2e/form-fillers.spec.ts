import AxeBuilder from '@axe-core/playwright';
import { expect, test, type Browser, type Page } from '@playwright/test';
import { randomBytes, randomUUID, scryptSync } from 'node:crypto';
import { copyFileSync, mkdirSync, readFileSync } from 'node:fs';
import path from 'node:path';
import { PDFDocument } from 'pdf-lib';
import { filledValues } from '../../src/features/official-forms/pdf-update';
import { acceptCookies, db, noOverflow, pdfText, strongSign, watch } from './helpers';

// The form fillers from the portals (docs/changes/2026-10-23-form-fillers.md), with the official ServiceOntario PDFs
// (tests/fixtures/official-forms) as the stored templates:
// - an Admin opens Settings > Forms, downloads a filled preview of SR-LV-006 for a Co-Registrant car and checks the
//   values sit in their own boxes and that the file is the publisher's PDF with only its text boxes added, then uses
//   SR-LV-006 and SR-LV-012 for owners;
// - the owner, on a phone, opens Documents and downloads the official form filled from their records: the publisher's
//   PDF byte for byte with the values after it; the page says it is printed and signed in ink, with no signature pad;
// - an Admin sends an investment agreement generated from the record; the investor signs it in their portal and "Signed
//   copy" opens the whole agreement followed by the signature page, naming 18122211 Canada Inc. alone as the party.
// Fictional people only.
const PW = 'correct horse battery';
const FIX = path.join(process.cwd(), 'tests/fixtures/official-forms');
const STORE = process.env.LOCAL_STORAGE_DIR ?? path.join(process.cwd(), '.local-storage');
const SHOTS = 'test-results/form-fillers';
mkdirSync(SHOTS, { recursive: true });
type Sql = ReturnType<typeof db>;
const hash = (pw: string) => { const salt = randomBytes(16); return `scrypt$${salt.toString('base64')}$${scryptSync(pw, salt, 64).toString('base64')}`; };
const tag = () => randomBytes(3).toString('hex');
const P1 = 'form1[0].page1[0].body[0].';

async function mkUser(sql: Sql, role: 'admin' | 'owner' | 'investor', name: string) {
  const id = randomUUID(); const email = `${role}.ff.${Date.now()}.${tag()}@example.test`;
  await sql`insert into local_auth.users (id, email, password_hash) values (${id}, ${email}, ${hash(PW)})`;
  await sql`insert into users (id, email, full_name) values (${id}, ${email}, ${name})`;
  if (role !== 'investor') await sql`insert into user_roles (user_id, role) values (${id}, ${role})`;
  return { id, email, name };
}
async function signIn(page: Page, email: string, expectPath: string) {
  await page.goto('/sign-in', { waitUntil: 'networkidle' });
  await acceptCookies(page);
  await page.locator('input[type="email"]').fill(email);
  await page.locator('input[type="password"]').fill(PW);
  await page.getByRole('button', { name: 'Sign in' }).click();
  await page.waitForURL((u) => (expectPath ? u.pathname.startsWith(expectPath) : !u.pathname.startsWith('/sign-in')), { timeout: 20_000 });
}
async function ctx(browser: Browser, phone: boolean) {
  const c = await browser.newContext({ viewport: phone ? { width: 375, height: 812 } : { width: 1440, height: 900 }, hasTouch: phone, baseURL: test.info().project.use.baseURL, acceptDownloads: true });
  const p = await c.newPage();
  p.on('dialog', (d) => void d.accept());
  return p;
}
async function check(page: Page, where: string) {
  await noOverflow(page);
  const r = await new AxeBuilder({ page: page as never }).withTags(['wcag2a', 'wcag2aa', 'wcag21a', 'wcag21aa']).analyze();
  expect(r.violations.filter((v) => v.impact === 'serious' || v.impact === 'critical').map((v) => `${where} ${v.id}`)).toEqual([]);
  await page.screenshot({ path: `${SHOTS}/${where.replace(/\s+/g, '-')}.png`, fullPage: true });
}
const values = async (b: Uint8Array) => filledValues(b);
const prefix = (b: Uint8Array, o: Buffer) => Buffer.from(b.subarray(0, o.length)).equals(o);

/** An individual owner whose car joins under Co-Registrant: SR-LV-006 and SR-LV-012 filled from the records. */
async function coRegistrantOwner(sql: Sql) {
  const u = await mkUser(sql, 'owner', 'Olivia Tremblay');
  const owner = randomUUID(); const car = randomUUID(); const agr = randomUUID(); const t = tag().toUpperCase();
  await sql`insert into owners (id, user_id, owner_type, legal_name, first_name, middle_name, last_name, status, email, phone, address_line1, address_line2, city, province, postal_code)
            values (${owner}, ${u.id}, 'individual', 'Olivia Margaret Tremblay', 'Olivia', 'Margaret', 'Tremblay', 'active', ${u.email}, '+14165550142', '1204 Bay Street', 'Unit 1807', 'Toronto', 'ON', 'm5r2a5')`;
  await sql`insert into owner_private_details (owner_id, licence_number, licence_province, date_of_birth) values (${owner}, 'T6512-48390-85421', 'ON', date '1985-02-03')`;
  await sql`insert into owner_agreements (id, owner_id, kind, agreement_number, agreement_date, status) values (${agr}, ${owner}, 'enrollment', ${`EA-${t}`}, current_date - 3, 'signed')`;
  const vin = `2T3RWRFV4NW${t.padEnd(6, '7').slice(0, 6)}`;
  await sql`insert into vehicles (id, owner_id, fleet_number, year, make, model, vin, plate, class, status, management_mode, onboarding_method, colour, body_type, odometer_km)
            values (${car}, ${owner}, ${`F-${t}`}, 2022, 'Toyota', 'RAV4', ${vin}, ${`CMK${t.slice(0, 4)}`}, 'standard', 'onboarding', 'managed', 'co_registrant', 'Blueprint', 'suv', 23115)`;
  await sql`insert into vehicle_schedules (vehicle_id, owner_agreement_id, schedule_number, vehicle_number, held_by, title_status, management_mode, onboarding_method,
              insurance_fee_cents, tracker_fee_cents, install_fee_cents, revenue_share_bps, signed_at)
            values (${car}, ${agr}, ${`VS-${t}`}, 1, 'individual', 'owned_outright', 'managed', 'co_registrant', 45000, 2500, 10000, 3500, now())`;
  await sql`insert into vehicle_onboardings (vehicle_id, government_forms) values (${car}, (select government_forms from onboarding_method_info where method = 'co_registrant'))`;
  await sql`select app.fill_vehicle_government_forms(${car}::uuid)`;
  return { user: u, owner, car, vin };
}

test('ServiceOntario forms: the Admin previews and uses the official PDFs; the owner downloads them filled, to print and sign in ink', async ({ browser }) => {
  test.skip(test.info().project.name !== 'desktop-1440', 'one run: the Admin on a desktop and the owner on a phone, in the same test');
  test.setTimeout(240_000);
  const sql = db();
  const before = await sql`select id, form_code, field_map, verified, mapped_by, file_key from pdf_templates where form_code in ('SR-LV-006', 'SR-LV-012') and is_current`;
  try {
    // the official PDFs, where the forms-fetch workflow stores them (the documents bucket, under each template's key)
    for (const t of before) { const to = path.join(STORE, 'documents', t.file_key as string); mkdirSync(path.dirname(to), { recursive: true }); copyFileSync(path.join(FIX, `${t.form_code}.pdf`), to); }
    const admin = await mkUser(sql, 'admin', 'Ada Admin');
    const o = await coRegistrantOwner(sql);
    const desk = await ctx(browser, false);
    const errors = watch(desk);
    await signIn(desk, admin.email, '/admin');
    await desk.goto('/admin/settings/forms', { waitUntil: 'networkidle' });
    const card = desk.getByTestId('form-SR-LV-006');
    await expect(card).toContainText('Mapping to check');
    await expect(card).toContainText('Mapping checked against the official PDF');
    // the preview for the owner's car: each value in its own box of the official form
    const map = desk.getByTestId('form-map-SR-LV-006');
    await map.getByLabel('Preview with').selectOption(o.car);
    const dl = desk.waitForEvent('download');
    await map.getByTestId('form-preview-SR-LV-006').click();
    const previewBytes = new Uint8Array(readFileSync((await (await dl).path())!));
    expect(prefix(previewBytes, readFileSync(path.join(FIX, 'SR-LV-006.pdf'))), 'the publisher\'s PDF first, byte for byte').toBe(true);
    const preview = await values(previewBytes);
    expect(preview[`${P1}personalInfo[0].#subform[0].lastName[2]`]).toBe('TREMBLAY, OLIVIA M');
    expect(preview[`${P1}personalInfo[0].#subform[0].lastName[0]`]).toBe('T6512-48390-85421');
    expect(preview[`${P1}personalInfo[0].#subform[0].streetName[0]`]).toBe('1204 Bay Street');
    expect(preview[`${P1}personalInfo[0].#subform[0].apt[0]`]).toBe('1807');
    expect(preview[`${P1}personalInfo[0].#subform[0].postalCode[0]`]).toBe('M5R 2A5');
    expect(preview[`${P1}businessInfo6[0].#field[0]`]).toBe(o.vin);
    expect(preview[`${P1}personalInfo[0].#subform[2].#field[12]`] ?? 'Off', 'checkboxes are ticked by hand at the counter').toBe('Off');
    await check(desk, 'admin settings forms 1440');
    for (const code of ['SR-LV-006', 'SR-LV-012']) {
      await desk.getByTestId(`form-verify-${code}`).click();
      await expect(desk.getByTestId(`form-${code}`).getByRole('status').filter({ hasText: 'Checked and in use' })).toBeVisible({ timeout: 20_000 });
    }
    expect(errors.filter((e) => !/favicon/.test(e))).toEqual([]);
    await desk.context().close();

    const phone = await ctx(browser, true);
    await signIn(phone, o.user.email, '/owner');
    await phone.goto('/owner/documents', { waitUntil: 'networkidle' });
    const forms = phone.getByTestId('owner-gov-forms');
    await expect(forms).toContainText('Official form, filled for you');
    // SR-LV-012: section 2, the owner and CarmaCars as the two registrants; the owner signs the first line on screen
    await forms.getByRole('link', { name: 'SR-LV-012' }).click();
    await phone.waitForURL(/\/owner\/documents\/forms\/[0-9a-f-]+\/official$/);
    await check(phone, 'owner official form 375');
    await expect(phone.getByTestId('official-ink')).toContainText('Print it and sign it in ink');
    await expect(phone.getByTestId('signature-pad')).toHaveCount(0);
    const dl2 = phone.waitForEvent('download');
    await phone.getByTestId('official-download').click();
    const filledBytes = new Uint8Array(readFileSync((await (await dl2).path())!));
    expect(prefix(filledBytes, readFileSync(path.join(FIX, 'SR-LV-012.pdf'))), 'the publisher\'s PDF first, byte for byte').toBe(true);
    const filled = await values(filledBytes);
    expect(filled[`${P1}personalInfo[0].#subform[0].lastName[3]`] ?? '', 'section 1 is not for this car').toBe('');
    expect(filled[`${P1}businessInfo[0].#subform[0].lastName[3]`]).toBe('TREMBLAY, OLIVIA M');
    expect(filled[`${P1}businessInfo[0].#subform[4].lastName[7]`]).toBe('18122211 CANADA INC.');
    expect(filled[`${P1}businessInfo[0].#subform[4].streetName[1]`]).toBe('2967 Dundas St W');
    await expect(phone.getByRole('status').filter({ hasText: 'Downloaded' })).toBeVisible();
    // signed in ink and recorded by an Admin, the form shows as signed
    await sql`update government_form_fills set status = 'signed', missing = '{}', signed_at = now(), signed_method = 'paper' where vehicle_id = ${o.car} and form_code = 'SR-LV-012' and superseded_at is null`;
    await phone.goto('/owner/documents', { waitUntil: 'networkidle' });
    await expect(phone.getByTestId('owner-gov-forms')).toContainText('Official form, signed');
    await phone.context().close();
  } finally {
    for (const t of before) await sql`update pdf_templates set field_map = ${sql.json(t.field_map)}, verified = ${t.verified}, verified_by = null, verified_at = null, mapped_by = ${t.mapped_by} where id = ${t.id}`;
    await sql.end();
  }
});

test('a generated investment agreement: sent from Admin, signed in the investor portal, and the signed copy is the whole agreement with the signature page', async ({ browser }) => {
  test.skip(test.info().project.name !== 'desktop-1440', 'one run');
  test.setTimeout(180_000);
  const sql = db();
  try {
    const admin = await mkUser(sql, 'admin', 'Ada Admin');
    const iu = await mkUser(sql, 'investor', `Marcus Chen ${tag()}`);
    const [inv] = await sql`insert into investors (user_id, legal_name, investor_type, address, email, phone, status) values (${iu.id}, ${iu.name}, 'individual', '77 Harbour Square, Suite 3110, Toronto, ON M5J 2S2', ${iu.email}, '+14165550177', 'prospect') returning id`;
    const ap = await ctx(browser, false);
    await signIn(ap, admin.email, '/admin');
    await ap.goto(`/admin/investors/${inv!.id}`, { waitUntil: 'networkidle' });
    const card = ap.getByTestId('investor-signing');
    await card.getByTestId('send-generated').click();
    const gen = card.getByTestId('send-generated-form');
    await gen.getByTestId('gen-invested').fill('$25,000.00');
    await gen.getByTestId('gen-yearly').fill('18%');
    await gen.getByTestId('gen-investment_date').fill('November 1, 2026');
    await gen.getByTestId('gen-lockup_end').fill('May 1, 2027');
    await gen.getByTestId('send-generated-submit').click();
    await expect(card.getByTestId('sign-requests')).toContainText('waiting for', { timeout: 30_000 });
    await ap.context().close();

    const ip = await ctx(browser, true);
    await signIn(ip, iu.email, '');
    await ip.goto('/investor/sign', { waitUntil: 'networkidle' });
    const unsigned = await ip.request.get((await ip.getByTestId('sign-read').first().getAttribute('href'))!);
    const unsignedPages = (await PDFDocument.load(await unsigned.body())).getPageCount();
    const f = ip.getByTestId('portal-sign-form');
    await f.getByRole('radio', { name: /chose not to/ }).check();
    // 0193: the code, the reading, Schedule C initialled, the consents, the drawn signature
    await strongSign(ip, f);
    await f.getByTestId('package-sign').click();
    await expect(ip.getByTestId('package-signed').or(ip.getByTestId('sign-done'))).toBeVisible({ timeout: 30_000 });
    // the signed copy is made by a background job within seconds
    await expect.poll(async () => (await sql`select count(*)::int n from sign_requests where investor_id = ${inv!.id} and signed_document_id is not null`)[0]!.n, { timeout: 60_000 }).toBe(1);
    await ip.goto('/investor/sign', { waitUntil: 'networkidle' });
    await check(ip, 'investor signed 375');
    const res = await ip.request.get((await ip.getByTestId('sign-done').getByRole('link', { name: 'Signed copy' }).first().getAttribute('href'))!);
    expect(res.status()).toBe(200);
    const body = await res.body();
    const pages = (await PDFDocument.load(body)).getPageCount();
    expect(pages, 'the agreement, then its signature page and record').toBeGreaterThan(unsignedPages);
    const words = await pdfText(body);
    expect(words).toMatch(/between 18122211 Canada Inc\. \(the " ?Company ?"\)/);
    expect(words, 'the party is the numbered company alone').not.toMatch(/operating as/);
    expect(words).toContain('$25,000.00');
    expect(words).toContain('Signature record');
    expect(words).toContain(iu.name);
    // 0193: the certificate of completion closes the signed copy
    expect(words).toContain('Certificate of completion');
    expect(words).toMatch(/Initialled: the risk acknowledgment \(Schedule C\)/);
    await ip.context().close();
  } finally { await sql.end(); }
});
