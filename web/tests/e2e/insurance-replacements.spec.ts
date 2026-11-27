import AxeBuilder from '@axe-core/playwright';
import { expect, test, type Browser, type Page } from '@playwright/test';
import { randomBytes, randomUUID, scryptSync } from 'node:crypto';
import { acceptCookies, db, noOverflow } from './helpers';

// Insurance replacements (migration 5120) end to end, in the staff portal as Finance: the short entry filled from a pasted
// adjuster email (checked, then used) with a car not in the fleet; the invoice edited (the winter tire fee) and sent, edited
// again and sent again as version 2 with what changed; a payment recorded; an unfinished rental discarded and restored.
// Each page is checked with axe and for overflow at 375 and 1440 pixels.
const PW = 'correct horse battery';
type Sql = ReturnType<typeof db>;
const tag = () => randomBytes(3).toString('hex');
const hash = (pw: string) => { const salt = randomBytes(16); return `scrypt$${salt.toString('base64')}$${scryptSync(pw, salt, 64).toString('base64')}`; };
const isPhone = () => (test.info().project.use.viewport?.width ?? 1440) < 600;

async function check(page: Page, where: string) {
  await noOverflow(page);
  const r = await new AxeBuilder({ page: page as never }).withTags(['wcag2a', 'wcag2aa', 'wcag21a', 'wcag21aa']).analyze();
  expect(r.violations.filter((v) => v.impact === 'serious' || v.impact === 'critical').map((v) => `${where} ${v.id}`)).toEqual([]);
}
async function finance(sql: Sql) {
  const id = randomUUID(); const email = `va.ins.${Date.now()}.${tag()}@example.test`;
  await sql`insert into local_auth.users (id, email, password_hash) values (${id}, ${email}, ${hash(PW)})`;
  await sql`insert into users (id, email, full_name) values (${id}, ${email}, ${`Fin Example ${tag()}`})`;
  await sql`insert into user_roles (user_id, role) values (${id}, 'va')`;
  await sql`insert into staff_profiles (user_id, home_address, home_postal_code, staff_type, va_function) values (${id}, '1 Test Lane, Testville', 'X9X 9X9', 'va', 'finance')`;
  return { id, email };
}
async function signedIn(browser: Browser, email: string) {
  const c = await browser.newContext({ viewport: isPhone() ? { width: 375, height: 812 } : { width: 1440, height: 900 }, hasTouch: isPhone(), baseURL: test.info().project.use.baseURL });
  const page = await c.newPage();
  page.on('dialog', (d) => void d.accept());
  await page.goto('/sign-in', { waitUntil: 'networkidle' });
  await acceptCookies(page);
  await page.locator('input[type="email"]').fill(email);
  await page.locator('input[type="password"]').fill(PW);
  await page.getByRole('button', { name: 'Sign in' }).click();
  await page.waitForURL((u) => u.pathname.startsWith('/staff'), { timeout: 20_000 });
  return { c, page };
}

test('Finance adds an insurance replacement from a pasted email, edits and resends the invoice, records a payment', async ({ browser }) => {
  test.setTimeout(180_000);
  const sql = db();
  const t = tag().toUpperCase();
  const insurer = `Example Mutual ${t}`;
  await sql`insert into insurers (name, billing_email) values (${insurer}, ${`claims.${t.toLowerCase()}@example.test`})`;
  const me = await finance(sql);
  const { c, page } = await signedIn(browser, me.email);
  try {
    await page.goto('/staff/insurance-replacements/new', { waitUntil: 'networkidle' });
    await check(page, 'add');
    const claim = `E2E-${t}-01`;
    await page.getByTestId('ins-paste').fill(`From: Pat Example <pat.${t.toLowerCase()}@example.test>\nSubject: Rental for claim ${claim}\n\nInsured: Dana Example ${t}\nPhone: 416-555-0199\nInsurer: ${insurer}\nStart date: 2027-03-01\nEnd date: 2027-03-11\nWe authorized 10 days at $65.00 per day.\n\nRegards,\nPat Example`);
    await page.getByTestId('ins-read').click();
    await expect(page.getByTestId('ins-found')).toContainText(claim);
    await page.getByTestId('ins-use').click();
    await expect(page.getByTestId('ins-renter_name')).toHaveValue(`Dana Example ${t}`);
    await expect(page.getByTestId('ins-claim_number')).toHaveValue(claim);
    await expect(page.getByTestId('ins-daily_rate')).toHaveValue('65.00');
    await page.getByTestId('ins-car-outside').check();
    await page.getByTestId('ins-car_year').fill('2026');
    await page.getByTestId('ins-car_make').fill('Hyundai');
    await page.getByTestId('ins-car_model').fill('Palisade');
    await page.getByTestId('ins-car_plate').fill(`E2E${t.slice(0, 4)}`);
    await expect(page.getByTestId('ins-bypass')).toBeChecked();
    await page.getByTestId('ins-submit').click();
    await page.waitForURL(/\/staff\/insurance-replacements\/CC-\d+\?added=1/, { timeout: 30_000 });
    await expect(page.getByTestId('ins-added')).toBeVisible();
    await expect(page.getByTestId('ins-bypass-state')).toContainText('Off the calendar');
    await check(page, 'rental');
    const number = new URL(page.url()).pathname.split('/').pop()!;

    // the invoice: the winter tire fee added, saved, sent another way (version 1)
    await page.getByTestId('inv-add-winter').click();
    await page.getByTestId('inv-amount').last().fill('50.00');
    await page.getByTestId('inv-save').click();
    await expect(page.getByTestId('inv-msg')).toContainText('Saved');
    await page.getByTestId('inv-mark-sent').click();
    await expect(page.getByTestId('inv-msg')).toContainText('Version 1 sent');
    await expect(page.getByTestId('ins-version')).toHaveCount(1);

    // edited again: 12 days; the changes show before sending; sent as version 2 with its differences
    await page.getByTestId('inv-qty').first().fill('12');
    await expect(page.getByTestId('inv-changes')).toContainText('Total');
    await page.getByTestId('inv-mark-sent').click();
    await expect(page.getByTestId('inv-msg')).toContainText('Version 2 sent');
    await expect(page.getByTestId('ins-version')).toHaveCount(2);
    await expect(page.getByTestId('ins-version-diff').first()).toContainText('12 x $65.00');
    const [v] = await sql`select ii.version, ii.total_cents, (select count(*)::int from insurer_invoice_versions x where x.invoice_id = ii.id) n
      from insurer_invoices ii join bookings b on b.id = ii.booking_id where b.booking_number = ${number}`;
    // total_cents is a bigint: the driver returns it as a string
    expect({ ...v!, total_cents: Number(v!.total_cents) }).toMatchObject({ version: 2, total_cents: (12 * 6500 + 5000) * 113 / 100, n: 2 });

    // a part payment by cheque
    await page.getByTestId('ins-pay').click();
    const dlg = page.getByRole('dialog');
    await dlg.getByLabel('Amount received').fill('500.00');
    await dlg.getByLabel('Reference (cheque or transfer number)').fill(`CHQ ${t}`);
    await dlg.getByRole('button', { name: 'Record a payment' }).click();
    await expect(page.getByTestId('ins-paid')).toHaveText('$500.00');

    // the list shows it with its stage and versions
    await page.goto(`/staff/insurance-replacements?q=${claim}`, { waitUntil: 'networkidle' });
    await expect(page.getByTestId('ins-list')).toContainText(claim);
    await expect(page.getByTestId('ins-stage').first()).toContainText('Invoiced');
    await check(page, 'list');
  } finally { await c.close(); await sql.end(); }
});

test('an unfinished insurance replacement is saved as typed, and a discarded one is restored', async ({ browser }) => {
  test.skip(isPhone(), 'the draft flow is the same at every width; the first test covers the phone layout');
  const sql = db();
  const me = await finance(sql);
  const { c, page } = await signedIn(browser, me.email);
  try {
    const t = tag();
    await page.goto('/staff/insurance-replacements/new', { waitUntil: 'networkidle' });
    await page.getByTestId('ins-renter_name').fill(`Marl Example ${t}`);
    await page.getByTestId('ins-claim_number').fill(`DRAFT-${t}`);
    await expect(page.getByTestId('ins-draft-status')).toContainText('Saved as a draft at', { timeout: 15_000 });
    const [d] = await sql`select id from rental_drafts where created_by = ${me.id} and status = 'open' and data #>> '{f,claim_number}' = ${`DRAFT-${t}`}`;
    expect(d).toBeTruthy();
    await page.getByTestId('ins-discard').click();
    await page.goto(`/staff/insurance-replacements/new?draft=${d!.id}`, { waitUntil: 'networkidle' });
    await expect(page.getByTestId('draft-gone')).toContainText('discarded');
    await page.getByTestId('draft-restore').click();
    await expect(page.getByTestId('ins-renter_name')).toHaveValue(`Marl Example ${t}`, { timeout: 15_000 });
    const [o] = await sql`select status from rental_drafts where id = ${d!.id}`;
    expect(o!.status).toBe('open');
  } finally { await c.close(); await sql.end(); }
});
