import { expect, test, type Page } from '@playwright/test';
import { randomBytes, randomUUID, scryptSync } from 'node:crypto';
import { acceptCookies, db } from './helpers';

// Release 50: every micro-interaction (docs/changes/2026-11-25-r50-motion-complete.md, src/portable/motion/interact.ts).
// With motion on: an invalid submit shakes the first invalid field and puts the focus in it; a pressed button scales down;
// a save shows the success morph on its button ("Saved" and a tick) and the tick on its status line. With reduced motion:
// no shake and no press scale, only the colour and the focus; the success is still said.
const PW = 'correct horse battery';
const hash = (pw: string) => { const salt = randomBytes(16); return `scrypt$${salt.toString('base64')}$${scryptSync(pw, salt, 64).toString('base64')}`; };

// every element that got the shake class, recorded as it happens (the class is gone again after 280 ms)
const recordShakes = (page: Page) => page.addInitScript(() => {
  const w = window as unknown as { __shakes: string[] };
  w.__shakes = [];
  new MutationObserver((ms) => ms.forEach((m) => {
    const t = m.target as HTMLElement;
    if (t.classList?.contains('mo-shake')) w.__shakes.push(t.id || t.getAttribute('name') || t.tagName);
  })).observe(document, { subtree: true, attributes: true, attributeFilter: ['class'] });
});
const shakes = (page: Page) => page.evaluate(() => (window as unknown as { __shakes: string[] }).__shakes);

async function invalidSubmit(page: Page) {
  await page.goto('/sign-in', { waitUntil: 'networkidle' });
  await acceptCookies(page);
  await page.getByRole('button', { name: 'Sign in' }).click();
  const email = page.locator('input[type="email"]');
  await expect(email).toBeFocused();
  return email;
}

test.describe('with motion', () => {
  test.use({ contextOptions: { reducedMotion: 'no-preference' } });

  test('an invalid submit shakes the first invalid field and focuses it', async ({ page }) => {
    await recordShakes(page);
    const email = await invalidSubmit(page);
    const id = await email.getAttribute('id');
    await expect.poll(() => shakes(page)).toContain(id ?? 'INPUT');
    expect((await shakes(page)).length).toBeLessThanOrEqual(2); // the first field only (one per attempt)
  });

  test('a pressed button scales down, then springs back', async ({ page }, info) => {
    test.skip(info.project.name.includes('phone'), 'a mouse press');
    await page.goto('/sign-in', { waitUntil: 'networkidle' });
    await acceptCookies(page);
    const b = page.getByRole('button', { name: 'Sign in' });
    const box = (await b.boundingBox())!;
    await page.mouse.move(box.x + box.width / 2, box.y + box.height / 2);
    await page.mouse.down();
    await expect.poll(() => b.evaluate((el) => getComputedStyle(el).scale)).not.toBe('none');
    await page.mouse.move(0, 0); await page.mouse.up();
    await expect.poll(() => b.evaluate((el) => getComputedStyle(el).scale)).toBe('none');
  });

  test('a save shows the success morph on its button and the tick on its status', async ({ browser }, info) => {
    // one project only: both would save the same settings row at once (the phone's morph is the same code)
    test.skip(info.project.name.includes('phone'), 'one save of the shared settings row');
    const sql = db();
    const id = randomUUID(); const email = `admin.r50mo.${Date.now()}.${randomBytes(3).toString('hex')}@example.test`;
    await sql`insert into local_auth.users (id, email, password_hash) values (${id}, ${email}, ${hash(PW)})`;
    await sql`insert into users (id, email, full_name) values (${id}, ${email}, 'Mo Motion')`;
    await sql`insert into user_roles (user_id, role) values (${id}, 'admin')`;
    const [before] = await sql`select promo_default_valid_days v from program_settings limit 1`;
    const ctx = await browser.newContext({ baseURL: info.project.use.baseURL, viewport: info.project.use.viewport, hasTouch: info.project.use.hasTouch, reducedMotion: 'no-preference' });
    const page = await ctx.newPage();
    try {
      await page.goto('/sign-in', { waitUntil: 'networkidle' });
      await acceptCookies(page);
      await page.locator('input[type="email"]').fill(email);
      await page.locator('input[type="password"]').fill(PW);
      await page.getByRole('button', { name: 'Sign in' }).click();
      await page.waitForURL((u) => u.pathname.startsWith('/admin'), { timeout: 20_000 });
      await page.goto('/admin/settings/promo-codes', { waitUntil: 'networkidle' });
      const form = page.getByTestId('promo-rules-form');
      const days = form.locator('input[id$="-promo_default_valid_days"]');
      const now = Number(await days.inputValue() || 30);
      let next = String(now);
      while (next === String(now)) next = String(20 + Math.floor(Math.random() * 40));
      await days.fill(next);
      const save = page.getByTestId('promo-rules-form-save');
      await save.click();
      await expect(save).toHaveAttribute('data-mo-result', 'ok', { timeout: 15_000 });
      await expect(save).toHaveAttribute('data-mo-done', 'Saved');
      await expect(form.locator('[role="status"][data-mo-saved]')).toBeVisible();
      // the morph shows the word over the button and keeps it (r50 hotfix2, c4482770: "Sent only when saved"); it goes
      // when the person changes something in the form
      expect(await save.evaluate((el) => getComputedStyle(el, '::after').content)).toContain('Saved');
      await page.waitForTimeout(1500);
      await expect(save).toHaveAttribute('data-mo-result', 'ok');
      await days.fill(String(Number(next) + 1));
      await expect(save).not.toHaveAttribute('data-mo-result', /./, { timeout: 4000 });
    } finally {
      await sql`update program_settings set promo_default_valid_days = ${before!.v}`;
      await sql`delete from user_roles where user_id = ${id}`;
      await ctx.close(); await sql.end();
    }
  });
});

test.describe('with reduced motion', () => {
  test.use({ contextOptions: { reducedMotion: 'reduce' } });

  test('no shake and no press scale: the colour and the focus only', async ({ page }) => {
    await recordShakes(page);
    const email = await invalidSubmit(page);
    await expect(email).toHaveAttribute('aria-invalid', 'true');
    await page.waitForTimeout(500);
    expect(await shakes(page)).toEqual([]);
    const b = page.getByRole('button', { name: 'Sign in' });
    const box = (await b.boundingBox())!;
    await page.mouse.move(box.x + box.width / 2, box.y + box.height / 2);
    await page.mouse.down(); await page.waitForTimeout(200);
    expect(await b.evaluate((el) => getComputedStyle(el).scale)).toBe('none');
    await page.mouse.up();
  });

  test('the footer pause control stops the shake too', async ({ page }) => {
    await recordShakes(page);
    await page.addInitScript(() => { try { localStorage.setItem('mo-motion', 'reduced'); } catch { /* private */ } });
    await page.emulateMedia({ reducedMotion: 'no-preference' });
    await invalidSubmit(page);
    await page.waitForTimeout(500);
    expect(await shakes(page)).toEqual([]);
  });
});
