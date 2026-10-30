import AxeBuilder from '@axe-core/playwright';
import { expect, test, type Browser, type Page } from '@playwright/test';
import { randomBytes, randomUUID, scryptSync } from 'node:crypto';
import { mkdirSync } from 'node:fs';
import { acceptCookies, db, noOverflow, watch } from './helpers';

// Migration 0044 end to end: the guide of every portal (the Guide link, the first-visit banner, the page with its
// contents, search and PDF); a payment received by e-Transfer and cheque recorded by an Admin, then voided; a signature
// on paper recorded from the owner checklist; and signing in the portals: Forms A and B (owner), an investment agreement
// (investor) and a staff agreement (VA). Every page is checked with axe, for overflow and for the copy rules.
const SHOTS = 'test-results/guides-manual';
const PW = 'correct horse battery';
const COPY_RULES: Array<[RegExp, string]> = [[/[—–]/, 'long dash'], [/\bCarma[ -]+Cars\b|\bCarmacars\b|\bCARMACARS\b|\bcarmaCars\b|\bCarmaCar\b(?!s)/, 'brand misspelled']];
const PDF = Buffer.from('%PDF-1.4\n1 0 obj<<>>endobj\ntrailer<<>>\n%%EOF\n');
type Sql = ReturnType<typeof db>;
mkdirSync(SHOTS, { recursive: true });

async function check(page: Page, where: string) {
  await noOverflow(page);
  const r = await new AxeBuilder({ page: page as never }).withTags(['wcag2a', 'wcag2aa', 'wcag21a', 'wcag21aa']).analyze();
  const bad = r.violations.filter((v) => v.impact === 'serious' || v.impact === 'critical');
  expect(bad.map((v) => `${where} ${v.id}: ${v.nodes.map((n) => n.target.join(' ')).slice(0, 3).join(', ')}`)).toEqual([]);
  const text = (await page.locator('body').innerText()).replace(/[\w.+-]+@[\w.-]*carmacars\.ca|https?:\/\/\S+|\bcarmacars\.ca\b/gi, ' ');
  for (const [re, what] of COPY_RULES) expect(text.match(re)?.[0], `${where}: ${what}`).toBeUndefined();
}
const hash = (pw: string) => { const salt = randomBytes(16); return `scrypt$${salt.toString('base64')}$${scryptSync(pw, salt, 64).toString('base64')}`; };
const vp = (phone: boolean) => (phone ? { width: 375, height: 812 } : { width: 1440, height: 900 });
const tag = () => randomBytes(3).toString('hex');

type Portal = 'renter' | 'owner' | 'admin' | 'va' | 'field' | 'investor';
const HOME: Record<Portal, string> = { renter: '/account', owner: '/owner', admin: '/admin', va: '/staff', field: '/staff/field', investor: '/investor' };
const NAME: Record<Portal, string> = { renter: 'Riley Renter', owner: 'Olive Owner', admin: 'Ada Admin', va: 'Val Assistant', field: 'Finn Field', investor: 'Ivy Investor' };

async function mkUser(sql: Sql, portal: Portal, extra: { va?: string; name?: string } = {}) {
  const id = randomUUID(); const email = `${portal}.gm.${Date.now()}.${tag()}@example.test`; const name = extra.name ?? NAME[portal];
  await sql`insert into local_auth.users (id, email, password_hash) values (${id}, ${email}, ${hash(PW)})`;
  if (portal === 'renter') { await sql`select public.register_account(${id}, ${email}, ${name}, null)`; return { id, email, name }; }
  await sql`insert into users (id, email, full_name) values (${id}, ${email}, ${name})`;
  if (portal === 'admin' || portal === 'va' || portal === 'field' || portal === 'owner') await sql`insert into user_roles (user_id, role) values (${id}, ${portal})`;
  if (portal === 'va') await sql`insert into staff_profiles (user_id, home_address, home_postal_code, staff_type, va_function) values (${id}, '1 Test Lane, Testville', 'X9X 9X9', 'va', ${extra.va ?? 'cs'})`;
  if (portal === 'field') await sql`insert into staff_profiles (user_id, home_address, home_postal_code, staff_type, field_function) values (${id}, '1 Test Lane, Testville', 'X9X 9X9', 'field', 'driver')`;
  if (portal === 'owner') await sql`insert into owners (user_id, owner_type, legal_name, status, email) values (${id}, 'individual', ${name}, 'active', ${email})`;
  if (portal === 'investor') await sql`insert into investors (user_id, legal_name, investor_type, email, status) values (${id}, ${name}, 'individual', ${email}, 'active')`;
  return { id, email, name };
}
// expectPath: where the person lands; '' for anywhere but the sign-in page (a person with several portals)
async function signIn(page: Page, email: string, expectPath: string) {
  await page.goto('/sign-in', { waitUntil: 'networkidle' });
  await acceptCookies(page);
  await page.locator('input[type="email"]').fill(email);
  await page.locator('input[type="password"]').fill(PW);
  await page.getByRole('button', { name: 'Sign in' }).click();
  await page.waitForURL((u) => (expectPath ? u.pathname.startsWith(expectPath) : !u.pathname.startsWith('/sign-in')), { timeout: 20_000 });
}
async function ctx(browser: Browser, phone: boolean) {
  const c = await browser.newContext({ viewport: vp(phone), hasTouch: phone, baseURL: test.info().project.use.baseURL });
  return c.newPage();
}
const today = () => new Intl.DateTimeFormat('en-CA', { timeZone: 'America/Toronto', year: 'numeric', month: '2-digit', day: '2-digit' }).format(new Date());

// ---------------------------------------------------------------- 1. the guide of every portal
for (const portal of ['renter', 'owner', 'admin', 'va', 'field', 'investor'] as Portal[]) {
  test(`guide: the ${portal} portal has the Guide link, the first-visit banner and the guide page`, async ({ browser }, info) => {
    test.setTimeout(120_000);
    const phone = info.project.name.startsWith('phone');
    const sql = db();
    await sql`delete from app.rate_limit_hits`;
    const published = await sql`select version from guides where portal = ${portal}`;
    test.skip(!(published[0]?.version > 0), `the ${portal} guide is not published on this database (npm run db:seed publishes the guides)`);
    const u = await mkUser(sql, portal);
    const page = await ctx(browser, phone);
    const errors = watch(page);
    await signIn(page, u.email, '');
    await page.goto(HOME[portal], { waitUntil: 'networkidle' });
    await expect(page.getByTestId('guide-link').first()).toBeVisible();
    await expect(page.getByTestId('guide-banner')).toContainText('New here? Read the');
    await check(page, `${portal} home with the banner`);

    // "Not now": recorded for the person, so another device does not show it either
    await page.getByTestId('guide-banner-dismiss').click();
    await expect(page.getByTestId('guide-banner')).toHaveCount(0);
    await expect.poll(async () => (await sql`select banner_dismissed_at is not null as d from guide_reads where user_id = ${u.id} and portal = ${portal}`)[0]?.d ?? false, { timeout: 10_000 }).toBe(true);
    const other = await ctx(browser, phone);
    await signIn(other, u.email, '');
    await other.goto(HOME[portal], { waitUntil: 'networkidle' });
    await expect(other.getByTestId('guide-link').first()).toBeVisible();
    await expect(other.getByTestId('guide-banner')).toHaveCount(0);
    await other.context().close();

    // the guide page: chapters with numbered steps, contents (a sidebar on a desktop, collapsible on a phone), search, PDF
    await page.getByTestId('guide-link').first().click();
    await page.waitForURL((x) => x.pathname.endsWith('/guide'), { timeout: 20_000 });
    await expect(page.getByTestId('guide')).toBeVisible();
    expect(await page.locator('[data-gd-section]').count()).toBeGreaterThan(2);
    const toc = page.getByTestId('guide-toc');
    await expect(toc).toBeAttached();
    if (phone) {
      await toc.locator('summary').click();
      await expect(toc.locator('nav a').first()).toBeVisible();
    } else {
      await expect(toc.locator('nav a').first()).toBeVisible();
    }
    await expect(page.getByTestId('guide-print')).toBeVisible();
    await expect(page.getByTestId('guide-pdf-note')).toBeVisible();
    const pdf = page.getByTestId('guide-pdf');
    if (await pdf.count()) {
      const r = await page.request.get(String(await pdf.getAttribute('href')), { maxRedirects: 0 });
      expect([200, 302], 'the stored PDF answers').toContain(r.status());
    }
    await page.getByTestId('guide-search').fill('zzqx nothing like this');
    await expect(page.getByTestId('guide-search-note')).toContainText('Nothing in this guide matches');
    const word = (await page.locator('[data-gd-section] .gd-sec-title').nth(1).innerText()).split(/\s+/).find((w) => w.length > 3) ?? 'the';
    await page.getByTestId('guide-search').fill(word);
    await expect(page.getByTestId('guide-search-note')).toContainText(/match/);
    await page.getByTestId('guide-search').fill('');
    await page.screenshot({ path: `${SHOTS}/guide-${portal}-${info.project.name}.png` });
    await check(page, `${portal} guide`);
    const opened = await sql`select last_version, opens from guide_reads where user_id = ${u.id} and portal = ${portal}`;
    expect(opened[0]?.last_version, 'the version the person opened is recorded').toBe(published[0]!.version);
    expect(errors.filter((e) => !/favicon|Failed to load resource.*404/.test(e))).toEqual([]);
    await page.context().close();
    await sql.end();
  });
}

// ---------------------------------------------------------------- an owner with two cars and their upfront invoices
async function mkOwnerWithInvoices(sql: Sql, admin: string) {
  const u = await mkUser(sql, 'owner', { name: `Olivia Paper ${tag()}` });
  await sql`delete from owners where user_id = ${u.id}`;
  const vin = (n: string) => randomBytes(9).toString('hex').toUpperCase().slice(0, 16) + n;
  const app = { source: 'web', owner: { owner_type: 'individual', legal_name: u.name, first_name: 'Olivia', last_name: 'Paper', email: u.email, phone: '+16475550177', address_line1: '20 Bay Street',
    city: 'Toronto', province: 'ON', postal_code: 'M5J 2N8', licence_number: 'P1234-56789-01234', date_of_birth: '1984-04-04' },
  vehicles: [
    { vin: vin('1'), plate: `GM${tag().toUpperCase()}`.slice(0, 7), year: 2022, make: 'Toyota', model: 'Camry', colour: 'White', odometer_km: 20000, title_status: 'owned_outright', management_mode: 'managed', onboarding_method: 'transfer', current_insurer: 'Intact', title_brand_clear: true },
    { vin: vin('2'), plate: `GN${tag().toUpperCase()}`.slice(0, 7), year: 2023, make: 'Honda', model: 'Accord', colour: 'Black', odometer_km: 15000, title_status: 'owned_outright', management_mode: 'managed', onboarding_method: 'transfer', current_insurer: 'Aviva', title_brand_clear: true }] };
  const [r] = await sql`select public.server_submit_owner_application(${sql.json(app)}, ${u.id}) v`;
  const owner = (r!.v as { owner_id: string }).owner_id;
  await sql`update owners set user_id = ${u.id} where id = ${owner}`;
  const cars = await sql`select id from vehicles where owner_id = ${owner} order by created_at, plate`;
  for (const c of cars) await sql`select public.admin_set_vehicle_terms(${c.id}, ${admin}, '{}')`;
  // the second car under a Lease method, so the owner signs Form B as well as Form A
  await sql`update vehicle_schedules set onboarding_method = 'lease_new_owner_corporation', owners_lien = 'not_available' where vehicle_id = ${cars[1]!.id} and superseded_by is null`;
  await sql`update vehicle_onboardings ob set first_last_choice = 'send', first_last_choice_cents = 2 * s.insurance_fee_cents from vehicle_schedules s join vehicles v on v.id = s.vehicle_id where s.vehicle_id = ob.vehicle_id and s.superseded_by is null and v.owner_id = ${owner}`; // 0077: the Admin's choice
  await sql`select public.admin_issue_upfront_invoices(${owner}, ${admin})`;
  const invoices = await sql`select id, invoice_number, total_cents from owner_invoices where owner_id = ${owner} order by invoice_number`;
  return { user: u, owner, cars: cars.map((c) => c.id as string), invoices };
}

// ---------------------------------------------------------------- 2. a payment received another way, in part, then voided
test('manual payment: an Admin records an e-Transfer in part and a cheque for the rest, the owner sees how it was paid, then the cheque is voided', async ({ browser }, info) => {
  test.setTimeout(180_000);
  const phone = info.project.name.startsWith('phone');
  const sql = db();
  await sql`delete from app.rate_limit_hits`;
  const admin = await mkUser(sql, 'admin');
  const o = await mkOwnerWithInvoices(sql, admin.id);
  const inv = o.invoices[0]!;
  const part = Math.round(Number(inv.total_cents) / 2);
  const ap = await ctx(browser, phone);
  await signIn(ap, admin.email, '/admin');
  await ap.goto(`/admin/owners/${o.owner}`, { waitUntil: 'networkidle' });
  const row = ap.locator(`li[data-invoice="${inv.invoice_number}"]`);
  await row.getByTestId(`offline-${inv.invoice_number}`).click();
  const form = row.getByTestId('manual-payment-form');
  await form.locator(`#ad-off-${inv.invoice_number}-ref`).fill('CA9XKT2');
  await form.locator(`#ad-off-${inv.invoice_number}-amt`).fill((part / 100).toFixed(2));
  await check(ap, 'admin owner, payment form');
  await form.getByRole('button', { name: 'Record payment' }).click();
  await expect(form.getByTestId('manual-payment-done')).toContainText('still owing', { timeout: 15_000 });
  await expect(row.getByTestId('admin-invoice-status')).toHaveText('Partly paid', { timeout: 15_000 });
  // the rest by cheque, with a photo of the cheque
  await ap.reload({ waitUntil: 'networkidle' });
  await row.getByTestId(`offline-${inv.invoice_number}`).click();
  await form.locator(`#ad-off-${inv.invoice_number}-m`).selectOption('cheque');
  await form.locator(`#ad-off-${inv.invoice_number}-ref`).fill('000123');
  await form.locator(`#ad-off-${inv.invoice_number}-proof`).setInputFiles({ name: 'cheque.pdf', mimeType: 'application/pdf', buffer: PDF });
  await form.getByRole('button', { name: 'Record payment' }).click();
  await expect(row.getByTestId('admin-invoice-status')).toHaveText('Paid', { timeout: 15_000 });
  await expect(row.getByTestId('manual-payments').locator('li')).toHaveCount(2);
  const st = await sql`select status, paid_cents, payment_method from owner_invoices where id = ${inv.id}`;
  expect([st[0]!.status, Number(st[0]!.paid_cents), st[0]!.payment_method]).toEqual(['paid', Number(inv.total_cents), 'cheque']);
  const ev = await sql`select count(*)::int n from app_events where code = 'owner_payment_recorded' and entity_id in (select id from manual_payments where owner_invoice_id = ${inv.id})`;
  expect(ev[0]!.n, 'a receipt for each payment').toBe(2);
  expect((await sql`select count(*)::int n from audit_log where action = 'record_manual_payment' and entity_id = ${inv.id}::text`)[0]!.n).toBeGreaterThanOrEqual(2);

  // the owner sees "Paid by Cheque on <date>"
  const op = await ctx(browser, phone);
  await signIn(op, o.user.email, '');
  await op.goto(`/owner/invoices/${inv.invoice_number}`, { waitUntil: 'networkidle' });
  await expect(op.getByTestId('invoice-paid-by')).toContainText(/Paid by cheque on/i);
  await check(op, 'owner invoice paid by cheque');

  // the cheque bounced: void it with the reason; the invoice owes that amount again
  await row.getByTestId('manual-payments').locator('li').filter({ hasText: 'Cheque' }).getByTestId('void-payment').click();
  await row.getByPlaceholder(/Why\?/).fill('The cheque was returned by the bank');
  await row.getByRole('button', { name: 'Void the payment' }).click();
  await expect(row.getByTestId('admin-invoice-status')).toHaveText('Partly paid', { timeout: 15_000 });
  const after = await sql`select status, paid_cents from owner_invoices where id = ${inv.id}`;
  expect([after[0]!.status, Number(after[0]!.paid_cents)]).toEqual(['issued', part]);
  expect((await sql`select count(*)::int n from app_events where code = 'owner_payment_reversed' and entity_id in (select id from manual_payments where owner_invoice_id = ${inv.id})`)[0]!.n).toBe(1);
  await op.reload({ waitUntil: 'networkidle' });
  await expect(op.getByTestId('invoice-status')).toHaveText('Partly paid');
  await check(op, 'owner invoice after the void');
  await ap.goto('/admin/reconciliation', { waitUntil: 'networkidle' });
  await expect(ap.getByTestId('manual-month')).toContainText('CA9XKT2');
  await check(ap, 'admin reconciliation');
  await ap.context().close(); await op.context().close();
  await sql.end();
});

// ---------------------------------------------------------------- 3. a signature on paper, from the owner checklist
test('paper signature: an Admin records the debit agreement signed on paper from the checklist, it counts as signed, then it is voided', async ({ browser }, info) => {
  test.setTimeout(150_000);
  const phone = info.project.name.startsWith('phone');
  const sql = db();
  await sql`delete from app.rate_limit_hits`;
  const admin = await mkUser(sql, 'admin');
  const o = await mkOwnerWithInvoices(sql, admin.id);
  const ap = await ctx(browser, phone);
  await signIn(ap, admin.email, '/admin');
  // the bulk view: this owner has things open, with the quick actions
  await ap.goto('/admin/owners?view=checklist', { waitUntil: 'networkidle' });
  const line = ap.locator(`[data-testid="owner-checklists"] li[data-owner="${o.owner}"]`);
  await expect(line).toContainText('open');
  await check(ap, 'admin owners checklist');
  await ap.goto(`/admin/owners/${o.owner}#checklist`, { waitUntil: 'networkidle' });
  const ck = ap.locator('#checklist');
  await expect(ck.locator('li[data-code="debit_agreement"]')).toHaveAttribute('data-status', 'open');
  await ck.getByTestId('paper-signature').click();
  const form = ck.getByTestId('paper-signature-form');
  await form.getByLabel('Document', { exact: true }).selectOption({ label: 'Pre-authorized debit agreement' });
  await form.getByLabel('Scan of the signed document').setInputFiles({ name: 'debit-signed.pdf', mimeType: 'application/pdf', buffer: PDF });
  await form.getByLabel('Note (optional)').fill('Signed at the office');
  // the pointer last rested on a button (its hover colours): move it away and let the transition settle before the contrast check
  await ap.mouse.move(0, 0);
  await ap.waitForTimeout(400);
  await check(ap, 'admin paper signature form');
  await form.getByRole('button', { name: 'Record signature' }).click();
  await expect(form.getByTestId('paper-signature-done')).toBeVisible({ timeout: 15_000 });
  await expect(ck.locator('li[data-code="debit_agreement"]')).toHaveAttribute('data-status', 'done', { timeout: 15_000 });
  await expect(ck.locator('li[data-code="debit_agreement"] [data-testid="checklist-status"]')).toContainText('Signed on paper');
  const ps = await sql`select id, document_id, signed_on::text from paper_signatures where owner_id = ${o.owner} and doc_type = 'debit_agreement' and voided_at is null`;
  expect(ps.length).toBe(1);
  expect(ps[0]!.signed_on).toBe(today());
  const doc = await sql`select storage_bucket, owner_id from documents where id = ${ps[0]!.document_id}`;
  expect([doc[0]!.storage_bucket, doc[0]!.owner_id]).toEqual(['agreements', o.owner]);
  // void it: the item is open again
  await ck.getByTestId('paper-signatures').getByTestId('void-signature').click();
  await ck.getByPlaceholder(/Why\?/).fill('Wrong form scanned');
  await ck.getByRole('button', { name: 'Void the signature' }).click();
  await expect(ck.locator('li[data-code="debit_agreement"]')).toHaveAttribute('data-status', 'open', { timeout: 15_000 });
  expect((await sql`select count(*)::int n from audit_log where action like '%paper_signature%' and entity_id = ${ps[0]!.id}::text`)[0]!.n).toBeGreaterThanOrEqual(1);
  await ap.context().close();
  await sql.end();
});

// ---------------------------------------------------------------- 4. signing in the portals, every document type
test('portal signing: the owner signs Forms A and B on screen, an investor signs the investment agreement, a VA signs the staff agreement', async ({ browser }, info) => {
  test.setTimeout(300_000);
  const phone = info.project.name.startsWith('phone');
  const sql = db();
  await sql`delete from app.rate_limit_hits`;
  const admin = await mkUser(sql, 'admin');
  const o = await mkOwnerWithInvoices(sql, admin.id);

  // Forms A and B: listed in Documents, filled in, and signed on screen in one package with one signature (0049); CarmaCars countersigns
  const op = await ctx(browser, phone);
  await signIn(op, o.user.email, '');
  await op.goto('/owner/documents', { waitUntil: 'networkidle' });
  await expect(op.getByTestId('screen-form-status')).toHaveText(['To sign', 'To sign']);
  await check(op, 'owner documents');
  await op.goto('/owner/documents/screen/a', { waitUntil: 'networkidle' });
  await expect(op.locator('#form-a')).toBeVisible();
  await check(op, 'owner form a');
  await op.goto('/owner/sign', { waitUntil: 'networkidle' });
  await expect(op.locator('summary', { hasText: 'Form A: trust declaration' })).toBeVisible();
  await expect(op.locator('summary', { hasText: 'Form B: lease summary' })).toBeVisible();
  await expect(op.getByTestId('sign-progress')).toContainText('in this package');
  await check(op, 'owner signing package');
  // 0077: the documents are prepared in their own requests; the sign form appears when they are open
  await expect(op.getByTestId('package-sign')).toBeVisible({ timeout: 45_000 });
  const t0 = Date.now();
  if (await op.getByTestId('package-tick-all').isVisible()) await op.getByTestId('package-tick-all').check();
  await expect(op.getByTestId('signature-adopted')).toContainText(o.user.name);
  await op.getByTestId('package-sign').click();
  await op.waitForURL(/\/owner\?signed=1/, { timeout: 60_000 });
  console.log(`forms A and B package (${info.project.name}): signed in ${Math.round((Date.now() - t0) / 1000)} s after the first tap`);
  await op.goto('/owner/documents', { waitUntil: 'networkidle' });
  await expect(op.getByTestId('screen-form-status')).toHaveText(['Signed on screen', 'Signed on screen']);
  // 0077: the signed records are made by background jobs, within seconds
  await expect.poll(async () => (await sql`select count(*)::int n from sign_requests where owner_id = ${o.owner} and status = 'signed' and signed_document_id is not null`)[0]!.n, { timeout: 60_000 }).toBe(2);
  const forms = await sql`select r.doc_type, r.status, r.signed_document_id is not null as copy,
      (select string_agg(x.signer_role || ':' || x.method, ',' order by x.signer_role) from signature_records x where x.signature_request_id = r.signature_request_id) recs
    from sign_requests r where r.owner_id = ${o.owner} and r.status = 'signed' order by r.doc_type`;
  expect(forms.map((f) => `${f.doc_type}/${f.status}/${f.copy}/${f.recs}`)).toEqual(['form_a/signed/true/carmacars:automatic,owner_individual:typed', 'form_b/signed/true/carmacars:automatic,owner_individual:typed']);
  await op.goto('/owner/documents/screen/a', { waitUntil: 'networkidle' });
  await expect(op.getByTestId('screen-form-signed')).toContainText('Signed on screen');
  await op.context().close();

  // the investment agreement: generated from the investor's record (no PDF to upload, 0049); the investor (a prospect) signs it in the investor portal
  const iu = await mkUser(sql, 'investor', { name: `Ivy Investor ${tag()}` });
  await sql`update investors set status = 'prospect' where user_id = ${iu.id}`;
  const [inv] = await sql`select id from investors where user_id = ${iu.id}`;
  const ap = await ctx(browser, phone);
  await signIn(ap, admin.email, '/admin');
  await ap.goto(`/admin/investors/${inv!.id}`, { waitUntil: 'networkidle' });
  const card = ap.getByTestId('investor-signing');
  await card.getByTestId('send-generated').click();
  const gen = card.getByTestId('send-generated-form');
  await gen.getByTestId('gen-invested').fill('$25,000.00');
  await gen.getByTestId('gen-yearly').fill('30%');
  await gen.getByTestId('gen-investment_date').fill('November 1, 2026');
  await gen.getByTestId('gen-lockup_end').fill('May 1, 2027');
  await check(ap, 'admin investor agreement from the record');
  await gen.getByTestId('send-generated-submit').click();
  await expect(card.getByTestId('sign-requests')).toContainText('waiting for', { timeout: 30_000 });
  const [genReq] = await sql`select r.template_version, r.extra ->> 'generated' g, r.extra #>> '{summary,2,value}' amount from sign_requests r where r.investor_id = ${inv!.id} and r.status = 'sent'`;
  expect(`${genReq!.template_version.startsWith('person-')}/${genReq!.g}/${genReq!.amount}`).toBe('true/true/$25,000.00');
  const ip = await ctx(browser, phone);
  await signIn(ip, iu.email, '');
  await ip.goto('/investor/sign', { waitUntil: 'networkidle' });
  await expect(ip.getByTestId('sign-summary-values')).toContainText('$25,000.00');
  await expect(ip.getByTestId('sign-progress-count')).toHaveText('0 of 1 signed');
  await check(ip, 'investor documents to sign');
  const doc = await ip.request.get(await ip.getByTestId('sign-read').first().getAttribute('href') as string);
  expect((await doc.body()).subarray(0, 4).toString()).toBe('%PDF');
  const f2 = ip.getByTestId('portal-sign-form');
  await f2.getByRole('radio', { name: /chose not to/ }).check();
  await f2.locator('input[name="statement"]').check();
  await expect(f2.getByTestId('package-initials')).toHaveValue(/^[A-Z]{2,4}$/);
  await check(ip, 'investor signing page');
  await f2.getByTestId('package-sign').click();
  await expect(ip.getByTestId('package-signed').or(ip.getByTestId('sign-done'))).toBeVisible({ timeout: 30_000 });
  await ip.goto('/investor/sign', { waitUntil: 'networkidle' });
  await expect(ip.getByTestId('sign-progress-count')).toHaveText('1 of 1 signed');
  const ia = await sql`select r.status, r.extra ->> 'legal_advice_choice' adv from sign_requests r where r.investor_id = ${inv!.id} order by r.sent_at desc limit 1`;
  expect([ia[0]!.status, ia[0]!.adv]).toEqual(['signed', 'declined']);
  await ip.context().close();

  // the staff agreement: sent from Admin > Settings > Staff, signed by drawing in the VA portal
  const va = await mkUser(sql, 'va', { va: 'cs', name: `Val Assistant ${tag()}` });
  await ap.goto('/admin/settings/staff', { waitUntil: 'networkidle' });
  const srow = ap.locator(`[data-testid="staff-agreements"] li[data-staff="${va.email}"]`);
  await srow.getByTestId('send-to-sign').click();
  await srow.getByLabel('The PDF to sign').setInputFiles({ name: 'staff.pdf', mimeType: 'application/pdf', buffer: PDF });
  await srow.getByRole('button', { name: 'Send to sign' }).click();
  await expect(srow.getByTestId('staff-agreement-status')).toContainText('waiting for their signature', { timeout: 15_000 });
  await check(ap, 'admin staff agreements');
  const vp2 = await ctx(browser, phone);
  await signIn(vp2, va.email, '/staff');
  await vp2.goto('/staff', { waitUntil: 'networkidle' });
  await vp2.getByTestId('va-to-sign').getByRole('link').click();
  await vp2.waitForURL(/\/staff\/sign$/);
  // the documents to sign are one package on this page: the PDF to read, the signature drawn, one button
  await expect(vp2.getByTestId('sign-read')).toBeVisible();
  await vp2.getByTestId('portal-sign-form').getByTestId('signature-mode').click();
  const canvas = vp2.locator('[data-testid="portal-sign-form"] canvas');
  await canvas.evaluate((e) => e.scrollIntoView({ block: 'center', behavior: 'instant' }));
  const b = (await canvas.boundingBox())!;
  await vp2.mouse.move(b.x + 20, b.y + b.height * 0.6); await vp2.mouse.down();
  for (let i = 1; i <= 30; i++) await vp2.mouse.move(b.x + 20 + i * ((b.width - 60) / 30), b.y + b.height * (0.6 + 0.25 * Math.sin(i / 2.5)), { steps: 2 });
  await vp2.mouse.up();
  await check(vp2, 'va signing page');
  await vp2.getByTestId('portal-sign-form').getByTestId('package-sign').click();
  await expect(vp2.getByTestId('package-signed').or(vp2.getByTestId('sign-done'))).toBeVisible({ timeout: 30_000 });
  const sa = await sql`select r.status, r.method, (select agreement_document_id from staff_profiles where user_id = ${va.id}) in (r.document_id, r.signed_document_id) as on_file from sign_requests r where r.staff_user_id = ${va.id}`;
  expect([sa[0]!.status, sa[0]!.method, sa[0]!.on_file]).toEqual(['signed', 'drawn', true]);
  await vp2.goto('/staff/sign', { waitUntil: 'networkidle' });
  await expect(vp2.getByTestId('sign-done')).toContainText('Signed here');
  await check(vp2, 'va documents signed');
  await vp2.context().close(); await ap.context().close();
  await sql.end();
});
