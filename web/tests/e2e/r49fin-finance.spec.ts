import AxeBuilder from '@axe-core/playwright';
import { expect, test, type Page } from '@playwright/test';
import { randomBytes, randomUUID, scryptSync } from 'node:crypto';
import { mkdirSync } from 'node:fs';
import { acceptCookies, db, noOverflow } from './helpers';

// r49 (3480): the Finance dashboard and the bank lines, end to end.
//   1. An Admin imports an RBC CSV on Company > Finance, Bank lines: the Stripe payout matches by itself, a line no record
//      fits waits (an old one is a To do for Finance with the notice queued), and the same file again adds nothing.
//   2. The Admin sets the bank fee aside with its reason: its To do closes.
//   3. Finance opens Money > Finance: the overview with the bank balance; customer service gets no page.
// axe and no overflow; screenshots of both tabs at 320, 375, 768, 1280 and 1440 (no squished text).
const PW = 'correct horse battery';
const WIDTHS = [320, 375, 768, 1280, 1440];
const SHOTS = process.env.SHOTS_DIR ?? 'test-results/r49fin';
const hash = (pw: string) => { const salt = randomBytes(16); return `scrypt$${salt.toString('base64')}$${scryptSync(pw, salt, 64).toString('base64')}`; };
const tag = () => randomBytes(3).toString('hex');
type Sql = ReturnType<typeof db>;

async function signIn(page: Page, email: string, to: RegExp) {
  await page.goto('/sign-in', { waitUntil: 'networkidle' });
  await acceptCookies(page);
  await page.locator('input[type="email"]').fill(email);
  await page.locator('input[type="password"]').fill(PW);
  await page.getByRole('button', { name: 'Sign in' }).click();
  await page.waitForURL((u) => to.test(u.pathname), { timeout: 60_000 });
}
async function mkUser(sql: Sql, role: 'admin' | 'va', name: string, va?: string) {
  const id = randomUUID(), email = `fin.${role}.${Date.now()}.${tag()}@example.test`;
  await sql`insert into local_auth.users (id, email, password_hash) values (${id}, ${email}, ${hash(PW)})`;
  await sql`insert into users (id, email, full_name, phone) values (${id}, ${email}, ${name}, '+14165550142')`;
  await sql`insert into user_roles (user_id, role) values (${id}, ${role})`;
  if (role === 'va') await sql`insert into staff_profiles (user_id, home_address, home_postal_code, staff_type, va_function) values (${id}, '1 Test Lane, Toronto, ON', 'M5V 1A1', 'va', ${va!})`;
  return { id, email };
}
async function axe(page: Page, where: string) {
  await noOverflow(page);
  const r = await new AxeBuilder({ page: page as never }).withTags(['wcag2a', 'wcag2aa', 'wcag21a', 'wcag21aa']).analyze();
  expect(r.violations.filter((v) => v.impact === 'serious' || v.impact === 'critical').map((x) => `${where} ${x.id}`)).toEqual([]);
}
async function shots(page: Page, name: string, sel: string, back: { width: number; height: number }) {
  mkdirSync(SHOTS, { recursive: true });
  for (const w of WIDTHS) {
    await page.setViewportSize({ width: w, height: 900 });
    // a page opened at 1440 and narrowed: the menus fold to their phone form a render after the resize, so the check waits for it
    await expect(async () => noOverflow(page)).toPass({ timeout: 10_000 });
    // a chart's visually hidden summary (.vh, 1px wide for screen readers) is not squished text
    const thin = await page.evaluate((s) => [...document.querySelectorAll(`${s} p, ${s} .ad-tile__k, ${s} .ad-tile__s, ${s} button`)]
      .filter((e) => !e.closest('.vh') && (e.textContent ?? '').trim().length > 12 && e.getBoundingClientRect().width > 0 && e.getBoundingClientRect().width < 110).map((e) => (e.textContent ?? '').trim().slice(0, 40)), sel);
    expect(thin, `${name} at ${w}`).toEqual([]);
    await page.screenshot({ path: `${SHOTS}/${name}-${w}.png`, fullPage: true });
  }
  await page.setViewportSize(back);
}
const day = (n: number) => { const d = new Date(Date.now() - n * 86400000); return `${d.getUTCMonth() + 1}/${d.getUTCDate()}/${d.getUTCFullYear()}`; };
const iso = (n: number) => new Date(Date.now() - n * 86400000).toISOString().slice(0, 10);

test.describe.configure({ mode: 'serial' });

test('Finance: import the RBC download, matched by itself, To do for the rest, set aside; Finance sees the dashboard', async ({ browser }, info) => {
  test.setTimeout(300_000);
  const phone = info.project.name.startsWith('phone');
  const size = phone ? { width: 375, height: 812 } : { width: 1440, height: 900 };
  const sql = db();
  const t = tag();
  const last4 = String(1000 + Math.floor(Math.random() * 8999));
  const admin = await mkUser(sql, 'admin', 'Ada Admin');
  const fin = await mkUser(sql, 'va', 'Marie-Christine Beauchemin-Lavallée', 'finance');
  const cs = await mkUser(sql, 'va', 'Cy Service', 'cs');
  const payoutCents = 100000 + Math.floor(Math.random() * 90000);
  await sql`insert into payout_reconciliations (processor, processor_payout_ref, paid_on, amount_cents) values ('stripe', ${`po_e2e_${t}`}, ${iso(3)}::date, ${payoutCents})`;
  const csv = ['"Account Type","Account Number","Transaction Date","Cheque Number","Description 1","Description 2","CAD$","USD$"',
    `Chequing,00102-99${last4},${day(3)},,"STRIPE","PAYOUT ${t}",${(payoutCents / 100).toFixed(2)},`,
    `Chequing,00102-99${last4},${day(6)},,"DEPOSIT","UNKNOWN ${t}",41.17,`,
    `Chequing,00102-99${last4},${day(5)},,"MONTHLY FEE ${t}",,-6.00,`].join('\r\n');

  try {
    const ap = await (await browser.newContext({ viewport: size, baseURL: info.project.use.baseURL })).newPage();
    await signIn(ap, admin.email, /^\/admin/);
    await ap.goto('/admin/finance?tab=bank', { waitUntil: 'networkidle' });
    await ap.getByTestId('bank-import-file').setInputFiles({ name: 'rbc.csv', mimeType: 'text/csv', buffer: Buffer.from(csv) });
    await expect(ap.getByTestId('bank-import-preview')).toContainText(`ending ${last4}`);
    await ap.getByLabel('Balance shown in online banking ($)').fill('12,345.67');
    await ap.getByTestId('bank-import-run').click();
    await expect(ap.getByTestId('bank-import-done')).toContainText('3 new, 0 already in, 1 matched by themselves, 2 to match');
    const lines = await sql`select l.description, l.status, l.todo_task_id is not null as todo from bank_lines l join bank_accounts a on a.id = l.bank_account_id where a.account_last4 = ${last4} order by l.posted_on`;
    expect(lines.map((l) => `${l.status}:${l.todo}`)).toEqual(['unmatched:true', 'unmatched:true', 'matched:false']);
    const [ev] = await sql`select count(*)::int n from app_events e join bank_lines l on l.id = e.entity_id join bank_accounts a on a.id = l.bank_account_id where e.code = 'staff_bank_line_unmatched' and a.account_last4 = ${last4}`;
    expect(ev!.n).toBe(2);
    await ap.reload({ waitUntil: 'networkidle' });
    await axe(ap, 'admin bank lines');
    await shots(ap, 'admin-bank', '[data-testid="bank-lines"]', size);

    // the same file again adds nothing
    await ap.getByTestId('bank-import-file').setInputFiles({ name: 'rbc.csv', mimeType: 'text/csv', buffer: Buffer.from(csv) });
    await ap.getByTestId('bank-import-run').click();
    await expect(ap.getByTestId('bank-import-done')).toContainText('already imported');

    // set the bank fee aside with its reason: its To do closes
    const [fee] = await sql`select l.id from bank_lines l join bank_accounts a on a.id = l.bank_account_id where a.account_last4 = ${last4} and l.amount_cents = -600`;
    await ap.getByTestId(`bank-ignore-${fee!.id}`).click();
    await ap.getByTestId(`bank-ignore-${fee!.id}-form`).getByLabel(/What it is/).fill('RBC monthly fee'); // each line without a match has its own Set aside dialog
    await ap.getByTestId(`bank-ignore-${fee!.id}-submit`).click();
    await expect.poll(async () => (await sql`select l.status, t.status ts from bank_lines l join tasks t on t.id = l.todo_task_id where l.id = ${fee!.id}`)[0]).toMatchObject({ status: 'ignored', ts: 'done' });

    await ap.goto('/admin/finance', { waitUntil: 'networkidle' });
    await expect(ap.getByTestId('finance-cash')).toContainText('$12,345.67');
    await expect(ap.getByTestId('finance-recon')).toBeVisible();
    await axe(ap, 'admin finance');
    await shots(ap, 'admin-overview', '[data-testid="finance-overview"]', size);

    // Finance: the same page under Money; customer service: none
    const fp = await (await browser.newContext({ viewport: size, baseURL: info.project.use.baseURL })).newPage();
    await signIn(fp, fin.email, /^\/staff/);
    await fp.goto('/staff/finance', { waitUntil: 'networkidle' });
    await expect(fp.getByTestId('finance-cash')).toContainText('$12,345.67');
    await fp.goto('/staff/finance?tab=bank', { waitUntil: 'networkidle' });
    await expect(fp.getByTestId('bank-lines')).toContainText(`UNKNOWN ${t}`);
    await axe(fp, 'staff finance');
    await shots(fp, 'staff-bank', '[data-testid="bank-lines"]', size);
    const cp = await (await browser.newContext({ viewport: size, baseURL: info.project.use.baseURL })).newPage();
    await signIn(cp, cs.email, /^\/staff/);
    const res = await cp.goto('/staff/finance');
    expect(res?.status()).toBe(404);
  } finally {
    await sql.end();
  }
});
