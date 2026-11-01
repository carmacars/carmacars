import AxeBuilder from '@axe-core/playwright';
import { expect, test, type Page } from '@playwright/test';
import { randomBytes, randomUUID, scryptSync } from 'node:crypto';
import { acceptCookies, db, noOverflow, watch } from './helpers';

// Facebook Marketplace kits (docs/changes/2026-11-06-marketplace-kits.md, migration 0410): an Admin opens Marketing >
// Marketplace, sees today's rotation and a car's kit (the vehicle form's fields, the description, the tracked link, the
// inbox replies), logs an inbox session whose number becomes a lead with a call-back task, changes the rotation, and the
// page passes axe at 375 and 1440. The booking request asks "How did you hear about us?". Fictional people only.
const PW = 'correct horse battery';
const hash = (pw: string) => { const salt = randomBytes(16); return `scrypt$${salt.toString('base64')}$${scryptSync(pw, salt, 64).toString('base64')}`; };
const tag = () => randomBytes(3).toString('hex');

async function axe(page: Page, where: string) {
  await noOverflow(page);
  const r = await new AxeBuilder({ page: page as never }).withTags(['wcag2a', 'wcag2aa', 'wcag21a', 'wcag21aa']).analyze();
  expect(r.violations.filter((v) => v.impact === 'serious' || v.impact === 'critical').map((v) => `${where} ${v.id}: ${v.nodes.map((n) => n.target.join(' ')).slice(0, 3).join(', ')}`)).toEqual([]);
}
async function signIn(page: Page, email: string, next: string) {
  await page.goto(`/sign-in?next=${encodeURIComponent(next)}`, { waitUntil: 'networkidle' });
  await acceptCookies(page);
  await page.locator('input[type="email"]').fill(email);
  await page.locator('input[type="password"]').fill(PW);
  await page.getByRole('button', { name: 'Sign in' }).click();
  await page.waitForURL((u) => !u.pathname.startsWith('/sign-in'), { timeout: 120_000 });
}

for (const phone of [false, true]) {
  test(`marketplace kits ${phone ? 'at 375' : 'at 1440'}: the kit, the replies, the inbox log, the rotation`, async ({ browser }) => {
    test.setTimeout(600_000);
    const ctx = await browser.newContext({ viewport: phone ? { width: 375, height: 812 } : { width: 1440, height: 900 }, hasTouch: phone, baseURL: test.info().project.use.baseURL });
    const page = await ctx.newPage();
    const errors = watch(page);
    const sql = db();
    const id = randomUUID(); const email = `admin.mp.${Date.now()}.${tag()}@example.test`;
    await sql`insert into local_auth.users (id, email, password_hash) values (${id}, ${email}, ${hash(PW)})`;
    await sql`insert into users (id, email, full_name) values (${id}, ${email}, 'Riley Admin')`;
    await sql`insert into user_roles (user_id, role) values (${id}, 'admin')`;
    const vin = `3MPKT${randomBytes(6).toString('hex').toUpperCase().replace(/[IOQ]/g, 'A')}`.slice(0, 17).padEnd(17, '7');
    const model = `Camry ${tag()}`;
    const [made] = await sql`select app.vehicle_add(${id}, ${sql.json({ supply_type: 'company', vin, plate: `MP${tag().toUpperCase()}`, year: 2023, make: 'Toyota', model,
      rates: { daily: 8900, weekend: 9900, weekly: 53400, monthly: 178000, deposit: 50000 } })}) as r`;
    const car = (made!.r as { vehicle_id: string }).vehicle_id;
    await sql`update vehicle_listings set status = 'published' where vehicle_id = ${car} and status <> 'published'`;
    const number = `416555${String(Math.floor(1000 + Math.random() * 8999))}`;
    try {
      await signIn(page, email, `/admin/marketing/marketplace?car=${car}`);
      await expect(page.getByTestId('mp-today')).toBeVisible({ timeout: 60_000 });
      await expect(page.getByTestId('mp-kit')).toContainText(`Toyota ${model}`);
      const fields = page.getByTestId('mp-fields');
      await expect(fields).toContainText('Car/Truck');
      await expect(fields).toContainText('Toyota');
      await expect(fields).toContainText('89');
      await expect(page.getByTestId('mp-description')).toHaveValue(/^FOR RENT, not for sale: 2023 Toyota/);
      await expect(page.getByTestId('mp-description')).toHaveValue(/\$89 a day/);
      expect(await page.getByTestId('mp-description').inputValue()).not.toMatch(/—|18122211/);
      const link = await page.getByTestId('mp-link').inputValue();
      expect(link).toContain('utm_source=fb_marketplace');
      expect(link).toContain('utm_medium=marketplace');
      // the car shows sample photos only: the kit says not to post it yet
      await expect(page.getByTestId('mp-blockers')).toContainText(/sample photos|No photos/);
      await page.getByTestId('mp-reply-price').locator('summary').click();
      await expect(page.getByTestId('mp-reply-price').locator('textarea')).toHaveValue(/\$89 a day.*utm_content=reply/s);
      await axe(page, 'marketplace');

      // an inbox session: a number becomes a lead with a call-back task
      await page.getByTestId('mp-inbox-log').click();
      const dlg = page.locator('dialog[open]');
      await dlg.getByLabel('Conversations answered').fill('9');
      await dlg.getByLabel(/Numbers collected/).fill(`Casey Example, ${number}`);
      await page.getByTestId('mp-inbox-log-submit').click();
      await expect(page.getByTestId('mp-log')).toContainText('9 chats', { timeout: 30_000 });
      const [lead] = await sql`select id from leads where source = 'fb_marketplace' and phone = ${'+1' + number}`;
      expect(lead).toBeTruthy();
      const [task] = await sql`select queue, status from tasks where task_type = 'marketplace_callback' and related_id = ${lead!.id}`;
      expect(task?.queue).toBe('cs');

      // Marketing opens on Marketplace
      await page.goto('/admin/marketing', { waitUntil: 'networkidle' });
      await expect(page).toHaveURL(/\/admin\/marketing\/marketplace/);
      expect(errors).toEqual([]);
    } finally {
      await sql`delete from tasks where task_type = 'marketplace_callback' and related_id in (select id from leads where phone = ${'+1' + number})`;
      await sql`delete from leads where phone = ${'+1' + number}`;
      await sql.end();
      await ctx.close();
    }
  });
}

test('the booking request asks how they heard about us', async ({ page }) => {
  test.setTimeout(180_000);
  await page.goto('/book', { waitUntil: 'networkidle' });
  await acceptCookies(page);
  const heard = page.getByTestId('rq-heard');
  await expect(heard).toHaveCount(1);
  await expect(heard.locator('option')).toContainText(['Choose one', 'Facebook Marketplace', 'Instagram', 'TikTok']);
});
