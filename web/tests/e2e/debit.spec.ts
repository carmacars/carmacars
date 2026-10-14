import AxeBuilder from '@axe-core/playwright';
import { expect, test, type Page } from '@playwright/test';
import { createHmac, randomBytes, randomUUID, scryptSync } from 'node:crypto';
import { mkdirSync, readFileSync, writeFileSync } from 'node:fs';
import { acceptCookies, db, noOverflow, watch } from './helpers';

// The automatic monthly owner debit (migration 0037), at 375 and 1440: an owner sets up a pre-authorized debit from
// Banking (Stripe's bank form; the fake adapter here), an Admin sends the pre-debit notice from Owner debits, the
// debit day comes (the owner-debit run is played here as the Edge Function plays it: claim, one PaymentIntent per
// invoice, recorded), one debit clears and one is returned through Stripe's signed webhook events, the owner sees
// each status and the retry, the Admin sees the results and the run log, the company statement shows its sections
// and its PDF, and a mandate cancelled at the bank takes the debit away. Every page is checked with axe and for
// horizontal overflow.
const PW = 'correct horse battery';
const SHOTS = 'test-results/debit';
const WHSEC = process.env.STRIPE_WEBHOOK_SECRET || (() => { try { return /^STRIPE_WEBHOOK_SECRET=(whsec_\S+)/m.exec(readFileSync('.env.local', 'utf8'))?.[1]; } catch { return undefined; } })() || 'whsec_local_fake';
const hash = (pw: string) => { const salt = randomBytes(16); return `scrypt$${salt.toString('base64')}$${scryptSync(pw, salt, 64).toString('base64')}`; };
const vin = (prefix: string) => { const ok = 'ABCDEFGHJKLMNPRSTUVWXYZ0123456789'; let s = prefix; while (s.length < 17) s += ok[Math.floor(Math.random() * ok.length)]; return s; };

async function check(page: Page, where: string) {
  await noOverflow(page);
  const r = await new AxeBuilder({ page: page as never }).withTags(['wcag2a', 'wcag2aa', 'wcag21a', 'wcag21aa']).analyze();
  const bad = r.violations.filter((v) => v.impact === 'serious' || v.impact === 'critical');
  expect(bad.map((v) => `${where} ${v.id}: ${v.nodes.map((n) => n.target.join(' ')).slice(0, 3).join(', ')}`)).toEqual([]);
  const text = await page.locator('body').innerText();
  expect(text.match(/[—–]/)?.[0], `${where}: long dash`).toBeUndefined();
}
async function signIn(page: Page, email: string, next: string) {
  await page.goto(`/sign-in?next=${encodeURIComponent(next)}`, { waitUntil: 'networkidle' });
  await acceptCookies(page);
  await page.locator('input[type="email"]').fill(email);
  await page.locator('input[type="password"]').fill(PW);
  await page.getByRole('button', { name: 'Sign in' }).click();
  await page.waitForURL((u) => u.pathname.startsWith(next.split('?')[0]!));
}
async function hook(page: Page, type: string, object: Record<string, unknown>) {
  const body = JSON.stringify({ id: `evt_${randomUUID()}`, type, created: Math.floor(Date.now() / 1000), data: { object } });
  const t = Math.floor(Date.now() / 1000);
  const sig = `t=${t},v1=${createHmac('sha256', WHSEC).update(`${t}.${body}`).digest('hex')}`;
  const r = await page.request.post('/api/webhooks/stripe', { data: body, headers: { 'stripe-signature': sig, 'content-type': 'application/json' } });
  expect(r.status(), await r.text()).toBe(200);
  return r.json();
}

test('owner debit: set up banking, notice, the debit day, one cleared and one returned, the run log, the company statement PDF', async ({ page, browser }, info) => {
  test.setTimeout(240_000);
  const errors = watch(page);
  const sql = db();
  await sql`delete from app.rate_limit_hits`;
  const stamp = `${info.project.name}.${Date.now()}`;
  const ownerId = randomUUID(), adminId = randomUUID();
  const email = `debit.owner.${stamp}@example.test`, adminEmail = `debit.admin.${stamp}@example.test`;
  const last = (info.project.name.startsWith('phone') ? 'Phonedebit' : 'Deskdebit') + Math.random().toString(36).replace(/[^a-z]/g, '').slice(0, 5);
  for (const [id, e] of [[ownerId, email], [adminId, adminEmail]] as const) await sql`insert into local_auth.users (id, email, password_hash) values (${id}, ${e}, ${hash(PW)})`;
  await sql`insert into users (id, email, full_name) values (${ownerId}, ${email}, ${'Dora ' + last}), (${adminId}, ${adminEmail}, 'Dan Admin')`;
  await sql`insert into user_roles (user_id, role) values (${adminId}, 'admin')`;
  // an owner with two vehicles, terms set and both upfront invoices issued (the owner portal's own path is in owner.spec.ts)
  const [app] = await sql`select public.server_submit_owner_application(${sql.json({
    source: 'web', owner: { owner_type: 'individual', legal_name: `Dora ${last}`, first_name: 'Dora', last_name: last, email, phone: '+16475550199',
      address_line1: '10 King Street West', city: 'Toronto', province: 'ON', postal_code: 'M5H 1A1', licence_number: 'D1234-56789-01234', date_of_birth: '1980-02-02' },
    vehicles: [
      { vin: vin('2T1'), plate: `DA${String(Date.now()).slice(-5)}`, year: 2022, make: 'Toyota', model: 'Corolla', colour: 'White', odometer_km: 20000, title_status: 'owned_outright', management_mode: 'managed', onboarding_method: 'transfer', current_insurer: 'Intact' },
      { vin: vin('3FA'), plate: `DB${String(Date.now()).slice(-5)}`, year: 2021, make: 'Ford', model: 'Escape', colour: 'Blue', odometer_km: 30000, title_status: 'owned_outright', management_mode: 'managed', onboarding_method: 'transfer', current_insurer: 'Aviva' }]
  } as never)}, ${ownerId}) r`;
  const owner = (app!.r as { owner_id: string }).owner_id;
  for (const v of await sql`select id from vehicles where owner_id = ${owner}`) await sql`select public.admin_set_vehicle_terms(${v.id}, ${adminId}, '{}')`;
  await sql`select public.admin_issue_upfront_invoices(${owner}, ${adminId})`;
  const invoices = await sql`select id, invoice_number, total_cents from owner_invoices where owner_id = ${owner} order by invoice_number`;
  expect(invoices).toHaveLength(2);

  // ---------------------------------------------------------------- 1. the owner sets up the pre-authorized debit
  await signIn(page, email, '/owner/banking');
  await expect(page.getByTestId('debit-missing')).toBeVisible();
  await check(page, 'banking before');
  await page.getByTestId('debit-setup-open').click();
  await page.getByTestId('debit-setup-submit').click();
  await expect(page.locator('.alert--error')).toContainText('accept the pre-authorized debit');
  await page.getByTestId('debit-setup-agree').check();
  await page.getByTestId('debit-setup-submit').click();
  await expect(page.getByTestId('fake-debit-setup')).toBeVisible();
  await check(page, 'banking setup form');
  await page.locator('#ds-name').fill(`Dora ${last}`);
  await page.locator('#ds-institution').fill('004');
  await page.locator('#ds-transit').fill('12345');
  await page.locator('#ds-account').fill('000123456789');
  await page.getByTestId('debit-setup-submit').click();
  await expect(page.getByTestId('owner-auto-debit')).toContainText('ending 6789', { timeout: 20_000 });
  await page.screenshot({ path: `${SHOTS}/banking-${info.project.name}.png`, fullPage: true });
  await check(page, 'banking after');
  const [m] = await sql`select s.processor_mandate_id mandate from owner_payment_methods m join owner_payment_method_secrets s on s.owner_payment_method_id = m.id where m.owner_id = ${owner} and m.status = 'active'`;
  expect(m?.mandate).toMatch(/^mandate_fake_/);

  // ---------------------------------------------------------------- 2. an Admin sends the notice
  const ctx = await browser.newContext({ viewport: page.viewportSize()!, baseURL: test.info().project.use.baseURL });
  const admin = await ctx.newPage();
  await signIn(admin, adminEmail, '/admin/debits');
  await check(admin, 'admin debits');
  const row = admin.getByTestId('debit-owners').locator('tr', { hasText: `Dora ${last}` });
  await expect(row).toContainText('Active, ending 6789');
  await row.getByRole('button', { name: 'Send a notice now' }).click();
  await admin.locator('dialog[open]').getByRole('button', { name: 'Send a notice now' }).click();
  await expect(admin.getByTestId('debit-upcoming')).toContainText(invoices[0]!.invoice_number as string, { timeout: 15_000 });
  await expect(admin.getByTestId('debit-upcoming')).toContainText(invoices[1]!.invoice_number as string);
  await admin.screenshot({ path: `${SHOTS}/admin-scheduled-${info.project.name}.png`, fullPage: true });
  const notice = await sql`select debit_on::text d, cardinality(invoice_ids)::int n from owner_debit_notices where owner_id = ${owner}`;
  expect(notice[0]!.n).toBe(2);
  expect((await sql`select count(*)::int n from app_events where code = 'owner_debit_notice' and entity_id in (select id from owner_debit_notices where owner_id = ${owner})`)[0]!.n).toBe(1);
  await page.goto('/owner/invoices', { waitUntil: 'networkidle' });
  await expect(page.getByTestId('invoice-debit').first()).toContainText('will be debited on');
  await check(page, 'owner invoices scheduled');

  // ---------------------------------------------------------------- 3. the debit day: the owner-debit run, as the Edge Function plays it
  await sql`update owner_debit_attempts set debit_on = app.today() where owner_id = ${owner} and status = 'scheduled'`;
  const [claimed] = await sql`select app.owner_debit_claim((app.today() + time '12:00') at time zone 'America/Toronto', 200) as claim`;
  const mine = (claimed!.claim as Array<{ attempt_id: string; amount_cents: number; metadata: Record<string, string>; idempotency_key: string }>).filter((c) => c.metadata.owner_id === owner);
  expect(mine).toHaveLength(2);
  for (const c of mine) {
    const id = `pi_e2e_${c.attempt_id.slice(0, 8)}_${Date.now()}`;
    const reg = await page.request.post('/api/dev/fake-payments', { data: { register: { id, amountCents: c.amount_cents, metadata: c.metadata } } });
    expect(reg.status()).toBe(200);
    await sql`select app.owner_debit_submitted(${c.attempt_id}::uuid, ${sql.json({ intent_id: id, status: 'processing' } as never)})`;
  }
  const sent = await sql`select a.processor_intent_id pid, a.owner_invoice_id inv, a.id from owner_debit_attempts a where a.owner_id = ${owner} and a.status = 'processing' order by (select invoice_number from owner_invoices i where i.id = a.owner_invoice_id)`;
  expect(sent).toHaveLength(2);
  await page.goto('/owner/invoices', { waitUntil: 'networkidle' });
  await expect(page.getByTestId('invoice-status')).toHaveText(['Payment processing', 'Payment processing']);
  await expect(page.getByTestId('invoice-debit').first()).toContainText('sent on');

  // days later: the first clears, the second is returned by the bank
  for (const [k, ok] of [[0, true], [1, false]] as const) {
    const s = sent[k]!;
    const settled = await page.request.post('/api/dev/fake-payments', { data: { intentId: s.pid, ok } });
    expect((await settled.json()).status).toBe(ok ? 'succeeded' : 'requires_payment_method');
    await hook(page, ok ? 'payment_intent.succeeded' : 'payment_intent.payment_failed',
      { id: s.pid, object: 'payment_intent', metadata: { purpose: 'owner_invoice', owner_invoice_id: s.inv, debit_attempt_id: s.id } });
  }
  const after = await sql`select i.status, i.late_fee_cents::int late, (select count(*)::int from owner_debit_attempts a where a.owner_invoice_id = i.id and a.status = 'scheduled') retry
    from owner_invoices i where i.owner_id = ${owner} order by i.invoice_number`;
  expect(after.map((r) => r.status)).toEqual(['paid', 'failed']);
  expect(after[1]!.late).toBeGreaterThan(0);
  expect(after[1]!.retry, 'the retry is scheduled').toBe(1);
  await page.goto('/owner/invoices', { waitUntil: 'networkidle' });
  const rowOf = (n: unknown) => page.locator(`li[data-invoice="${String(n)}"]`);
  await expect(rowOf(invoices[0]!.invoice_number).getByTestId('invoice-status')).toHaveText('Paid');
  await expect(rowOf(invoices[1]!.invoice_number).getByTestId('invoice-status')).toHaveText('Payment failed');
  await expect(rowOf(invoices[1]!.invoice_number).getByTestId('invoice-debit')).toContainText('(retry)');
  await page.screenshot({ path: `${SHOTS}/owner-results-${info.project.name}.png`, fullPage: true });
  await check(page, 'owner invoices results');
  await page.goto(`/owner/invoices/${invoices[1]!.invoice_number}`, { waitUntil: 'networkidle' });
  await expect(page.getByTestId('invoice-debit')).toContainText('will be debited on');
  await check(page, 'owner invoice retry');

  // ---------------------------------------------------------------- 4. the Admin sees the results and the run log
  await sql`select app.owner_debit_run_close(now())`;
  await admin.goto('/admin/debits', { waitUntil: 'networkidle' });
  await expect(admin.getByTestId('debit-recent')).toContainText('Cleared');
  await expect(admin.getByTestId('debit-recent')).toContainText('Returned');
  await expect(admin.getByTestId('debit-runs')).toContainText('Debits');
  await admin.screenshot({ path: `${SHOTS}/admin-results-${info.project.name}.png`, fullPage: true });
  await check(admin, 'admin debits results');

  // ---------------------------------------------------------------- 5. the company statement: sections and the PDF
  const month = new Date().toISOString().slice(0, 7);
  await admin.goto(`/admin/reports?month=${month}`, { waitUntil: 'networkidle' });
  await admin.getByTestId('company-build').click();
  // (the other width may be building the same month at the same moment: the page is read again once one build is in)
  await expect.poll(async () => (await sql`select jsonb_array_length(sections)::int n from company_statements where statement_month = ${month + '-01'}`)[0]?.n ?? 0, { timeout: 60_000 }).toBe(12);
  await admin.reload({ waitUntil: 'networkidle' });
  await expect(admin.getByTestId('company-sections')).toContainText('Income summary', { timeout: 30_000 });
  await expect(admin.getByTestId('company-sections')).toContainText('Owner fees and debits');
  await check(admin, 'company statement');
  const pdf = await admin.request.get(await admin.getByTestId('company-pdf').getAttribute('href') as string);
  expect(pdf.status(), (await pdf.text()).slice(0, 300)).toBe(200);
  expect(pdf.headers()['content-type']).toContain('application/pdf');
  expect((await pdf.body()).subarray(0, 4).toString()).toBe('%PDF');
  mkdirSync(SHOTS, { recursive: true });
  writeFileSync(`${SHOTS}/company-statement-${info.project.name}.pdf`, await pdf.body());
  for (const k of ['company_owners', 'company_vehicles']) {
    const other = await admin.request.get((await admin.getByTestId('company-pdf').getAttribute('href') as string).replace('company_statement', k));
    expect(other.status(), k).toBe(200);
    writeFileSync(`${SHOTS}/${k}-${info.project.name}.pdf`, await other.body());
  }
  await admin.getByTestId('company-email').click();
  await expect.poll(async () => (await sql`select count(*)::int n from app_events where code = 'staff_monthly_statements_pdfs' and payload ->> 'recipient_user_id' = ${adminId}`)[0]!.n).toBe(1);

  // ---------------------------------------------------------------- 6. the mandate is cancelled at the bank
  await hook(page, 'mandate.updated', { id: m!.mandate, object: 'mandate', status: 'inactive' });
  await page.goto('/owner/banking', { waitUntil: 'networkidle' });
  await expect(page.getByTestId('debit-missing')).toBeVisible();
  await ctx.close();
  expect(errors.filter((e) => !/favicon|Failed to load resource.*404/.test(e))).toEqual([]);
  await sql.end();
});
