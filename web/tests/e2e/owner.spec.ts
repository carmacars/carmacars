import AxeBuilder from '@axe-core/playwright';
import { expect, test, type Browser, type Page } from '@playwright/test';
import { createHmac, randomBytes, randomUUID, scryptSync } from 'node:crypto';
import { readFileSync } from 'node:fs';
import { acceptCookies, db, fillYmm, noOverflow, tapColour, watch } from './helpers';

// The owner billing path end to end, at 375 and 1440: an owner applies with three vehicles (the
// wizard, a VIN decoded, autosave), an Admin sets the terms on the standard grid and issues the three
// upfront invoices, the owner signs the Enrollment and Title-Holding agreements on the canvas, pays one
// invoice by card and one by pre-authorized debit (pending, then succeeded through a signed webhook
// event), and the Admin records an e-Transfer for the third. Every owner and admin page is checked
// with axe (no serious or critical issue), for horizontal overflow and with the copy rules.
const SHOTS = 'test-results/owner';
const PW = 'correct horse battery';
const COPY_RULES: Array<[RegExp, string]> = [[/[—–]/, 'long dash'], [/18122211(?! Canada Inc\.?,? (?:operating as|o\/a) CarmaCars)|Canada Inc\b(?!\.?,? (?:operating as|o\/a) CarmaCars)/i, 'numbered company name (the payee "<legal name>, operating as CarmaCars" is allowed)'], [/\bCarma[ -]+Cars\b|\bCarmacars\b|\bCARMACARS\b|\bcarmaCars\b|\bCarmaCar\b(?!s)/, 'brand misspelled']];

async function check(page: Page, where: string) {
  await noOverflow(page);
  const wide = await page.evaluate(() => [...document.querySelectorAll('body *')].filter((e) => e.getBoundingClientRect().right > innerWidth + 1 && !e.closest('.table-scroll, .agreement, .pt__nav, .ad-nav')).slice(0, 5).map((e) => `${e.tagName}.${e.className}`));
  expect(wide, `${where}: elements wider than the screen`).toEqual([]);
  const r = await new AxeBuilder({ page: page as never }).withTags(['wcag2a', 'wcag2aa', 'wcag21a', 'wcag21aa']).analyze();
  const bad = r.violations.filter((v) => v.impact === 'serious' || v.impact === 'critical');
  expect(bad.map((v) => `${where} ${v.id}: ${v.nodes.map((n) => n.target.join(' ')).slice(0, 3).join(', ')}`)).toEqual([]);
  const text = (await page.locator('body').innerText()).replace(/[\w.+-]+@[\w.-]*carmacars\.ca|https?:\/\/\S+|\bcarmacars\.ca\b/gi, ' ');
  for (const [re, what] of COPY_RULES) expect(text.match(re)?.[0], `${where}: ${what}`).toBeUndefined();
}

// the server's webhook secret: the environment, else .env.local, else the local fallback of the webhook route
const WHSEC = process.env.STRIPE_WEBHOOK_SECRET || (() => { try { return /^STRIPE_WEBHOOK_SECRET=(whsec_\S+)/m.exec(readFileSync('.env.local', 'utf8'))?.[1]; } catch { return undefined; } })() || 'whsec_local_fake';
const hash = (pw: string) => { const salt = randomBytes(16); return `scrypt$${salt.toString('base64')}$${scryptSync(pw, salt, 64).toString('base64')}`; };
const vin = (prefix: string) => { const ok = 'ABCDEFGHJKLMNPRSTUVWXYZ0123456789'; let s = prefix; while (s.length < 17) s += ok[Math.floor(Math.random() * ok.length)]; return s; };

async function signIn(page: Page, email: string, next: string) {
  await page.goto(`/sign-in?next=${encodeURIComponent(next)}`, { waitUntil: 'networkidle' });
  await acceptCookies(page);
  await page.locator('input[type="email"]').fill(email);
  await page.locator('input[type="password"]').fill(PW);
  await page.getByRole('button', { name: 'Sign in' }).click();
  await page.waitForURL((u) => u.pathname.startsWith(next.split('?')[0]!));
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

async function adminPage(browser: Browser, viewport: { width: number; height: number }, email: string) {
  const ctx = await browser.newContext({ viewport, baseURL: test.info().project.use.baseURL });
  const page = await ctx.newPage();
  await signIn(page, email, '/admin/owners');
  return page;
}

test('owner billing: apply with three vehicles, terms and upfront invoices, sign, pay by card and by debit, offline payment', async ({ page, browser }, info) => {
  test.setTimeout(Number(process.env.OWNER_TIMEOUT ?? 480_000));
  const phone = info.project.name.startsWith('phone');
  const viewport = phone ? { width: 375, height: 812 } : { width: 1440, height: 900 };
  const errors = watch(page);
  const sql = db();
  await sql`delete from app.rate_limit_hits`;
  const stamp = `${info.project.name}.${Date.now()}`;
  const email = `owner.${stamp}@example.test`;
  const adminEmail = `admin.${stamp}@example.test`;
  const adminId = randomUUID();
  await sql`insert into local_auth.users (id, email, password_hash) values (${adminId}, ${adminEmail}, ${hash(PW)})`;
  await sql`insert into users (id, email, full_name) values (${adminId}, ${adminEmail}, 'Ada Admin')`;
  await sql`insert into user_roles (user_id, role) values (${adminId}, 'admin')`;
  const last = phone ? 'Phoneowner' : 'Deskowner';

  // ---------------------------------------------------------------- 1. the application
  await page.goto('/list-your-car', { waitUntil: 'networkidle' });
  await acceptCookies(page);
  await page.getByRole('link', { name: 'Apply to list your car' }).first().click();
  await page.waitForURL(/\/list-your-car\/apply$/);
  await check(page, 'apply step 1');
  await page.getByRole('button', { name: 'Continue to vehicles' }).click();
  await expect(page.locator('#ap-first-err')).toContainText('first name');
  await page.locator('label:has-text("An individual")').click();
  await page.locator('#ap-first').fill('Olivia');
  await page.locator('#ap-last').fill(last);
  await page.locator('#ap-addr').fill('union');
  await page.getByRole('option', { name: /Union Station/ }).click();
  await expect(page.locator('#ap-line1')).toHaveValue('65 Front Street West');
  await expect(page.locator('#ap-city')).toHaveValue('Toronto');
  await page.locator('#ap-postal').fill('m5j 1e6');
  await page.locator('#ap-email').fill(email);
  await page.locator('#ap-phone').fill('647-555-0101');
  await page.locator('#ap-lic').fill('O1234-56789-01234');
  await page.locator('#ap-dob').fill('1985-05-05');
  await expect(page.getByTestId('autosave')).toContainText('Saved', { timeout: 10_000 });
  await page.screenshot({ path: `${SHOTS}/wizard-1-${info.project.name}.png`, fullPage: true });
  await page.getByRole('button', { name: 'Continue to vehicles' }).click();

  const cars = [
    { vin: vin('2T1'), decoded: true, plate: `OA${String(Date.now()).slice(-5)}`, colour: 'White', odo: '20000', insurer: 'Intact', title: 'Owned outright' },
    { vin: vin('3FA'), year: '2021', make: 'Ford', model: 'Escape', plate: `OB${String(Date.now()).slice(-5)}`, colour: 'Blue', fuel: 'hybrid', odo: '41000', insurer: 'Aviva', title: 'Financed', lender: 'TD Auto Finance' },
    { vin: vin('5YJ'), decoded: true, plate: `OC${String(Date.now()).slice(-5)}`, colour: 'Red', odo: '9000', insurer: 'Belair', title: 'Owned outright' }
  ];
  for (const [i, c] of cars.entries()) {
    if (i > 0) await page.getByRole('button', { name: 'Add another vehicle' }).click();
    const id = (k: string) => `#ap-v${i}-${k}`;
    await page.locator(id('vin')).fill(c.vin);
    // looked up at the 17th character (0082): a decoded car shows one line; otherwise year, make and model from lists
    if (c.decoded) await expect(page.getByTestId('apply-vin-summary')).toBeVisible({ timeout: 20_000 });
    else { await expect(page.getByTestId('apply-ymm')).toBeVisible({ timeout: 20_000 }); await fillYmm(page, 'apply', { year: c.year!, make: c.make!, model: c.model! }); }
    await tapColour(page, 'apply', c.colour);
    await page.locator(id('plate')).fill(c.plate);
    await page.locator(id('odo')).fill(c.odo);
    await page.locator(id('ins')).fill(c.insurer);
    const editor = page.getByTestId('vehicle-editor');
    await editor.locator('label:has-text("Me personally")').click();
    await editor.locator(`label:has-text("${c.title}")`).click();
    if (c.lender) await page.locator(id('lender')).fill(c.lender);
    await editor.locator('fieldset:has-text("branded") label:has-text("No")').click();
    await editor.locator('fieldset:has-text("recall") label:has-text("No")').click();
    if (i === 1) { await check(page, 'apply step 2'); await page.screenshot({ path: `${SHOTS}/wizard-2-${info.project.name}.png`, fullPage: true }); }
  }
  await page.getByRole('button', { name: 'Continue', exact: true }).click();
  const plans = page.getByTestId('plan-vehicle');
  await expect(plans).toHaveCount(3);
  await plans.nth(2).locator('label:has-text("Self-Managed")').click();
  for (let i = 0; i < 3; i++) {
    const p = plans.nth(i);
    await expect(p.locator('input[name^="ap-method-"]').first()).toBeVisible();
    await p.locator(`label:has-text("${i === 1 ? 'Transfer' : 'Co-Registrant'}")`).click();
  }
  await plans.nth(1).locator('label:has-text("I do not have it yet")').click();
  await expect(plans.nth(0).getByTestId('estimate')).toContainText('You pay registry fees');
  await expect(plans.nth(0).getByTestId('estimate')).toContainText('Tracker Install Fee applies when trackers become available');
  await expect(plans.nth(0).getByTestId('estimate')).not.toContainText('$20');
  await check(page, 'apply step 3');
  await page.screenshot({ path: `${SHOTS}/wizard-3-${info.project.name}.png`, fullPage: true });
  await page.getByRole('button', { name: 'Review' }).click();
  await page.locator('#ap-pw').fill(PW);
  await check(page, 'apply review');
  await page.getByRole('button', { name: 'Submit application' }).click();
  await expect(page.getByTestId('apply-done')).toContainText('Application received', { timeout: 20_000 });
  const [owner] = await sql`select o.id from owners o where o.email = ${email}`;
  expect(owner, 'owner created').toBeTruthy();
  const vehicles = await sql`select v.id, ob.status from vehicles v join vehicle_onboardings ob on ob.vehicle_id = v.id where v.owner_id = ${owner!.id} order by v.created_at`;
  expect(vehicles.map((v) => v.status)).toEqual(['intake', 'intake', 'intake']);
  const pending = await sql`select count(*)::int n from vehicles where owner_id = ${owner!.id} and tracker_install_pending`;
  expect(pending[0]!.n, 'each vehicle waits for a tracker').toBe(3);
  // the application page asks to confirm the email; the link (local_auth.mailbox) signs in and opens the owner portal
  await expect(page.getByTestId('apply-confirm-email')).toContainText(email);
  const [confirm] = await sql`select link from local_auth.mailbox where to_email = ${email} order by id desc limit 1`;
  await page.goto(new URL(confirm!.link as string).pathname + new URL(confirm!.link as string).search);
  await page.waitForURL(/\/owner/);
  await expect(page.getByTestId('owner-vehicle')).toHaveCount(3);

  // ---------------------------------------------------------------- 2. terms and upfront invoices (admin)
  const admin = await adminPage(browser, viewport, adminEmail);
  await admin.goto(`/admin/owners/${owner!.id}`, { waitUntil: 'networkidle' });
  await check(admin, 'admin owner');
  const setButtons = admin.getByRole('button', { name: 'Set terms (standard grid)' });
  for (let left = 3; left > 0; left--) {
    await expect(setButtons).toHaveCount(left, { timeout: 15_000 });
    await setButtons.first().click();
    await expect(setButtons).toHaveCount(left - 1, { timeout: 15_000 });
  }
  await expect.poll(async () => (await sql`select count(*)::int n from vehicle_schedules s join vehicles v on v.id = s.vehicle_id where v.owner_id = ${owner!.id}`)[0]!.n, { timeout: 15_000 }).toBe(3);
  // 0077: the first and last month invoice follows the Admin's choice per car (here: Send invoice now); the owner page applies it
  await sql`update vehicle_onboardings ob set first_last_choice = 'send', first_last_choice_cents = 2 * s.insurance_fee_cents from vehicle_schedules s join vehicles v on v.id = s.vehicle_id where s.vehicle_id = ob.vehicle_id and s.superseded_by is null and v.owner_id = ${owner!.id}`;
  await admin.reload({ waitUntil: 'networkidle' });
  await admin.getByTestId('issue-upfront').click();
  await expect(admin.getByTestId('admin-owner-invoices').locator('li')).toHaveCount(3, { timeout: 15_000 });
  await admin.screenshot({ path: `${SHOTS}/admin-owner-${info.project.name}.png`, fullPage: true });
  const invoices = await sql`select i.id, i.invoice_number, i.total_cents, i.status from owner_invoices i where i.owner_id = ${owner!.id} order by i.invoice_number`;
  expect(invoices.map((i) => `${i.status}:${i.total_cents}`)).toEqual(['issued:90400', 'issued:90400', 'issued:90400']);

  // ---------------------------------------------------------------- 3. the owner signs: one package, one signature (0049)
  await page.goto('/owner', { waitUntil: 'networkidle' });
  await expect(page.getByTestId('owner-next-step')).toContainText('Sign your documents');
  await check(page, 'owner home');
  await page.screenshot({ path: `${SHOTS}/owner-home-${info.project.name}.png`, fullPage: true });
  await page.getByRole('link', { name: 'Check and sign' }).click();
  await page.waitForURL(/\/owner\/sign/);
  const opened = Date.now();
  await expect(page.locator('summary', { hasText: 'Vehicle Enrollment Agreement' })).toBeVisible();
  await expect(page.locator('summary', { hasText: 'Title-Holding and Lease Agreement' })).toBeVisible();
  await expect(page.getByTestId('sign-progress-count')).toContainText(/^0 of \d+ signed$/);
  // 0077: the documents are prepared in their own requests; the sign form appears once they are open
  await expect(page.getByTestId('package-sign')).toBeVisible({ timeout: 45_000 });
  await expect(page.getByTestId('sign-summary-values')).toContainText('VIN');
  await expect(page.getByTestId('sign-fix').first()).toHaveAttribute('href', '/owner/profile');
  await check(page, 'owner sign');
  const total = await page.getByTestId('package-docs').innerText().then((t) => Number(/these (\d+) documents/.exec(t)?.[1] ?? '1'));
  // the three statements in one tap, the initials filled in from the name, the name adopted as the signature (phone) or drawn (desktop)
  await page.getByTestId('package-tick-all').check();
  await expect(page.getByTestId('package-initials')).not.toHaveValue('');
  if (info.project.name.includes('desktop')) { await page.getByTestId('signature-mode').click(); await drawSignature(page); }
  await page.getByTestId('package-sign').click();
  await page.waitForURL(/\/owner\?signed=1/, { timeout: 60_000 });
  const pkg = await sql`select k.method, k.seconds_to_sign, (select count(*)::int from signing_package_documents d where d.package_id = k.id) n
    from signing_packages k join owners o on o.user_id = k.signer_user_id where o.id = ${owner!.id} order by k.signed_at desc limit 1`;
  expect(`${pkg[0]!.method}/${pkg[0]!.n}`).toBe(`${info.project.name.includes('desktop') ? 'drawn' : 'typed'}/${total}`);
  console.log(`owner package (${info.project.name}): ${total} documents, ${info.project.name.includes('desktop') ? 3 : 2} taps after opening, ${Math.round((Date.now() - opened) / 1000)} s in the test, ${pkg[0]!.seconds_to_sign} s recorded`);
  const signed = await sql`select string_agg(status, ',' order by kind) s from owner_agreements where owner_id = ${owner!.id}`;
  expect(signed[0]!.s).toBe('signed,signed');
  // 0077: the signed copies are made by background jobs, within seconds
  await expect.poll(async () => (await sql`select count(*)::int n from signature_requests r join owner_agreements a on a.signature_request_id = r.id where a.owner_id = ${owner!.id} and r.signed_document_id is not null`)[0]!.n,
    { timeout: 60_000, message: 'signed copies stored' }).toBe(2);

  // ---------------------------------------------------------------- 4. pay the first invoice by card
  await page.goto(`/owner/invoices/${invoices[0]!.invoice_number}`, { waitUntil: 'networkidle' });
  await expect(page.getByTestId('invoice-total')).toHaveText('$904.00');
  await page.locator('label:has-text("Card")').first().click();
  await expect(page.getByTestId('fake-card')).toBeVisible();
  await check(page, 'invoice pay card');
  await page.screenshot({ path: `${SHOTS}/invoice-pay-${info.project.name}.png`, fullPage: true });
  await page.locator('#ow-cname').fill('Olivia ' + last);
  await page.locator('#ow-cnumber').fill('4000 0000 0000 0002');
  await page.locator('#ow-cexp').fill('12 / 31');
  await page.locator('#ow-ccvc').fill('123');
  await page.getByRole('button', { name: /^Pay \$904\.00$/ }).click();
  await expect(page.locator('.alert--error')).toContainText('declined');
  await page.locator('#ow-cnumber').fill('4242 4242 4242 4242');
  await page.getByRole('button', { name: /^Pay \$904\.00$/ }).click();
  await expect(page.getByTestId('invoice-paid')).toContainText('Payment received', { timeout: 20_000 });
  await check(page, 'invoice paid');

  // ---------------------------------------------------------------- 5. the second by pre-authorized debit
  await page.goto(`/owner/invoices/${invoices[1]!.invoice_number}`, { waitUntil: 'networkidle' });
  await page.locator('label:has-text("Pre-authorized debit")').click();
  await expect(page.getByTestId('fake-bank')).toBeVisible();
  await check(page, 'invoice pay debit');
  await page.screenshot({ path: `${SHOTS}/invoice-debit-${info.project.name}.png`, fullPage: true });
  await page.locator('#ow-bname').fill('Olivia ' + last);
  await page.locator('#ow-binst').fill('004');
  await page.locator('#ow-btransit').fill('12345');
  await page.locator('#ow-bacct').fill('1234567');
  await page.getByRole('button', { name: /Authorize debit/ }).click();
  // two boxes (the legal review, 0053): the one-time debit is required; the recurring debit is ticked and can be unticked
  await expect(page.locator('#ow-agree-err')).toContainText('Tick the first box to authorize this one-time debit.');
  await expect(page.getByTestId('pad-one-time')).toContainText('I waive pre-notification and any waiting period for this one-time debit.');
  await expect(page.getByTestId('pad-recurring').locator('input')).toBeChecked();
  await page.getByTestId('pad-one-time').locator('input').check();
  await page.getByRole('button', { name: /Authorize debit/ }).click();
  await expect(page.getByTestId('invoice-pending')).toContainText('processing', { timeout: 20_000 });
  const [pend] = await sql`select d.processor_payment_id pid, p.status from payments p join payment_processor_details d on d.payment_id = p.id where p.owner_invoice_id = ${invoices[1]!.id}`;
  expect(pend!.status).toBe('pending');
  // days later: the bank clears it, and Stripe sends payment_intent.succeeded
  const settle = await page.request.post('/api/dev/fake-payments', { data: { intentId: pend!.pid, ok: true } });
  expect((await settle.json()).status).toBe('succeeded');
  const body = JSON.stringify({ id: `evt_${randomUUID()}`, type: 'payment_intent.succeeded', created: Math.floor(Date.now() / 1000), data: { object: { id: pend!.pid, object: 'payment_intent', metadata: { purpose: 'owner_invoice', owner_invoice_id: invoices[1]!.id } } } });
  const t = Math.floor(Date.now() / 1000);
  const sig = `t=${t},v1=${createHmac('sha256', WHSEC).update(`${t}.${body}`).digest('hex')}`;
  const hook = await page.request.post('/api/webhooks/stripe', { data: body, headers: { 'stripe-signature': sig, 'content-type': 'application/json' } });
  expect(hook.status(), await hook.text()).toBe(200);
  const replay = await page.request.post('/api/webhooks/stripe', { data: body, headers: { 'stripe-signature': sig, 'content-type': 'application/json' } });
  expect((await replay.json()).replay).toBe(true);
  await page.reload({ waitUntil: 'networkidle' });
  await expect(page.getByTestId('invoice-paid')).toBeVisible();
  const mandate = await sql`select s.processor_mandate_id m from owner_payment_methods m join owner_payment_method_secrets s on s.owner_payment_method_id = m.id where m.owner_id = ${owner!.id} and m.kind = 'pre_authorized_debit'`;
  expect(mandate[0]?.m, 'the debit authorization is saved for the 15th').toMatch(/^mandate_/);

  // ---------------------------------------------------------------- 6. the third by e-Transfer, recorded by the admin
  await admin.reload({ waitUntil: 'networkidle' });
  await admin.getByTestId(`offline-${invoices[2]!.invoice_number}`).click();
  await admin.locator(`#ad-off-${invoices[2]!.invoice_number}-ref`).fill('CA9XKT2');
  await check(admin, 'admin offline payment');
  await admin.locator(`li[data-invoice="${invoices[2]!.invoice_number}"]`).getByRole('button', { name: 'Record payment' }).click();
  await expect(admin.locator(`li[data-invoice="${invoices[2]!.invoice_number}"] [data-testid="admin-invoice-status"]`)).toHaveText('Paid', { timeout: 15_000 });
  await admin.goto('/admin/invoices?status=paid', { waitUntil: 'networkidle' });
  await check(admin, 'admin invoices');
  await admin.goto('/admin/owners', { waitUntil: 'networkidle' });
  await check(admin, 'admin owners');
  await admin.context().close();

  const after = await sql`select i.status, (select count(*) from audit_log a where a.action = 'record_manual_payment' and a.entity_id = i.id::text)::int audited from owner_invoices i where i.owner_id = ${owner!.id} order by i.invoice_number`;
  expect(after.map((r) => r.status)).toEqual(['paid', 'paid', 'paid']);
  expect(after[2]!.audited).toBe(1);
  const ob = await sql`select string_agg(ob.status::text, ',') s from vehicles v join vehicle_onboardings ob on ob.vehicle_id = v.id where v.owner_id = ${owner!.id}`;
  expect(ob[0]!.s).toBe('upfront_paid,upfront_paid,upfront_paid');
  // the two paid online get "payment received"; the one recorded by hand gets its own receipt (owner_payment_recorded, 0044)
  const receipts = await sql`select count(*)::int n from app_events e where e.code = 'owner_payment_received' and e.entity_id in ${sql(invoices.map((i) => i.id as string))}`;
  expect(receipts[0]!.n).toBe(2);
  const recorded = await sql`select count(*)::int n from app_events e where e.code = 'owner_payment_recorded' and e.entity_id in (select m.id from manual_payments m where m.owner_invoice_id = ${invoices[2]!.id})`;
  expect(recorded[0]!.n).toBe(1);

  // ---------------------------------------------------------------- 7. every owner page renders with real data
  await page.goto('/owner/invoices', { waitUntil: 'networkidle' });
  await expect(page.getByTestId('invoice-status')).toHaveText(['Paid', 'Paid', 'Paid']);
  await check(page, 'owner invoices');
  await page.goto('/owner', { waitUntil: 'networkidle' });
  await expect(page.getByTestId('owner-due')).toHaveText('$0.00');
  await page.screenshot({ path: `${SHOTS}/owner-home-paid-${info.project.name}.png`, fullPage: true });
  await check(page, 'owner home paid');
  for (const path of ['/owner/vehicles', `/owner/vehicles/${vehicles[0]!.id}`, '/owner/bookings', '/owner/statements', '/owner/payouts', '/owner/documents', '/owner/banking', '/owner/notifications', '/owner/profile']) {
    await page.goto(path, { waitUntil: 'networkidle' });
    await expect(page.locator('h1')).toBeVisible();
    await check(page, path);
  }
  // the ownership permit, from the phone camera or a file
  await page.goto(`/owner/vehicles/${vehicles[0]!.id}`, { waitUntil: 'networkidle' });
  const png = await page.screenshot({ clip: { x: 0, y: 0, width: 300, height: 200 } });
  await page.getByTestId('owner-upload-ownership_permit').locator('input[type="file"]').setInputFiles({ name: 'permit.png', mimeType: 'image/png', buffer: png });
  await expect(page.getByTestId('owner-upload-ownership_permit')).toContainText('Received', { timeout: 15_000 });
  await expect.poll(async () => (await sql`select count(*)::int n from documents where vehicle_id = ${vehicles[0]!.id} and kind = 'ownership_permit'`)[0]!.n).toBe(1);
  await page.goto('/owner/documents', { waitUntil: 'networkidle' });
  // the five files, and the signed copies of the forms signed in the same package (Forms A and B)
  const [forms] = await sql`select count(*)::int n from documents where owner_id = ${owner!.id} and kind in ('form_a_trust_declaration', 'form_b_lease_summary')`;
  await expect(page.getByTestId('owner-docs').locator('li')).toHaveCount(5 + forms!.n);
  const pdf = await page.request.get(await page.getByTestId('owner-docs').locator('a').first().getAttribute('href') as string);
  expect(pdf.status()).toBe(200);
  await page.goto('/owner/banking', { waitUntil: 'networkidle' });
  await page.locator('label:has-text("e-Transfer")').first().click();
  await page.locator('#ow-po-email').fill(email);
  await page.getByRole('button', { name: 'Submit payout details' }).click();
  await expect(page.getByTestId('payout-verifying')).toBeVisible({ timeout: 15_000 });

  // ---------------------------------------------------------------- 8. trackers arrive: a separate invoice per vehicle
  expect((await sql`select count(*)::int n from owner_invoices where owner_id = ${owner!.id} and kind = 'tracker_install'`)[0]!.n, 'no tracker invoice before trackers arrive').toBe(0);
  const admin2 = await adminPage(browser, viewport, adminEmail);
  await admin2.goto(`/admin/owners/${owner!.id}`, { waitUntil: 'networkidle' });
  await admin2.getByTestId(`tracker-invoice-${String(vehicles[0]!.id).slice(0, 8)}`).click();
  // the three vehicles share one creation instant, so the page's order among them is not fixed: find the one invoiced
  await expect(admin2.getByTestId('admin-tracker').filter({ hasText: /Install invoice/ })).toHaveCount(1, { timeout: 15_000 });
  await check(admin2, 'admin tracker');
  await admin2.context().close();
  await page.goto('/owner/invoices', { waitUntil: 'networkidle' });
  const trk = page.locator('[data-testid="invoice-row"]', { hasText: 'Tracker install' });
  await expect(trk).toHaveCount(1);
  await expect(trk).toContainText('$113.00');
  await expect(trk.getByTestId('invoice-status')).toHaveText('Due');
  expect(errors.filter((e) => !/favicon|Failed to load resource.*404/.test(e))).toEqual([]);
  await sql.end();
});

test('owner portal and admin refuse the wrong people', async ({ page }) => {
  await page.goto('/owner');
  await expect(page).toHaveURL(/\/sign-in\?next=%2Fowner/);
  await page.goto('/admin/owners');
  await expect(page).toHaveURL(/\/sign-in\?next=%2Fadmin/);
  const sql = db();
  const email = `renter.${Date.now()}.${Math.random().toString(36).slice(2, 6)}@example.test`;
  const id = randomUUID();
  await sql`insert into local_auth.users (id, email, password_hash) values (${id}, ${email}, ${hash(PW)})`;
  await sql`select public.register_account(${id}, ${email}, 'Rita Renter', null)`;
  await signIn(page, email, '/account');
  await page.goto('/owner');
  await expect(page).toHaveURL(/\/owner\/not-an-owner/);
  await check(page, 'not an owner');
  await page.goto('/admin/owners');
  await expect(page).toHaveURL(/\/admin\/no-access/);
  const r = await page.request.post('/api/dev/fake-payments', { data: { intentId: 'pi_nope' } });
  expect(r.status()).toBe(404);
  await sql.end();
});
