import AxeBuilder from '@axe-core/playwright';
import { expect, test, type BrowserContext, type Page } from '@playwright/test';
import { randomBytes, randomUUID, scryptSync } from 'node:crypto';
import { acceptCookies, db, noOverflow } from './helpers';

// Phone and browser alerts (migration 0300) end to end, at 375 and 1440. The local server runs with PUSH_PROVIDER=fake
// (a key pair made in memory, pushes recorded as sent). A test browser has no push service, so the browser's push
// side is a stand-in (below): it hands out a subscription with example.test addresses, as Chrome would. The renter is
// invited on Trips, turns alerts on, chooses topics on Profile, sends a test and turns them off; an iPhone that has not
// added CarmaCars to its Home Screen gets the steps instead; an Admin has Settings > My phone alerts. The manifest, the
// service worker and the policy that allows them are checked too. Every page with the card is checked with axe.
const PW = 'correct horse battery';
type Sql = ReturnType<typeof db>;
const hash = (pw: string) => { const salt = randomBytes(16); return `scrypt$${salt.toString('base64')}$${scryptSync(pw, salt, 64).toString('base64')}`; };
const IPHONE = 'Mozilla/5.0 (iPhone; CPU iPhone OS 17_5 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.5 Mobile/15E148 Safari/604.1';

/** The browser's push side, standing in for Chrome's (kept across pages in localStorage). Not a test browser to the
 *  invitation (it hides itself from automation). */
async function fakePush(ctx: BrowserContext | Page) {
  await ctx.addInitScript(() => {
    const KEY = 'e2e-push';
    const load = (): { perm: string; endpoint: string | null } => { try { return JSON.parse(localStorage.getItem(KEY) ?? '') as { perm: string; endpoint: string | null }; } catch { return { perm: 'default', endpoint: null }; } };
    const save = (s: { perm: string; endpoint: string | null }) => localStorage.setItem(KEY, JSON.stringify(s));
    const subOf = (endpoint: string) => ({
      endpoint, options: { applicationServerKey: null as ArrayBuffer | null },
      toJSON: () => ({ endpoint, keys: { p256dh: 'B' + 'A'.repeat(86), auth: 'Q'.repeat(22) } }),
      unsubscribe: async () => { save({ ...load(), endpoint: null }); return true; }
    });
    const pushManager = {
      getSubscription: async () => { const s = load(); return s.endpoint ? subOf(s.endpoint) : null; },
      subscribe: async (o: { applicationServerKey: Uint8Array }) => {
        const endpoint = `https://push.example.test/send/${Math.random().toString(36).slice(2)}`;
        save({ ...load(), endpoint });
        const s = subOf(endpoint); s.options.applicationServerKey = o.applicationServerKey.buffer as ArrayBuffer; return s;
      }
    };
    const reg = { pushManager, scope: `${location.origin}/` };
    Object.defineProperty(window, 'PushManager', { configurable: true, value: function PushManager() {} });
    Object.defineProperty(navigator, 'serviceWorker', { configurable: true, value: { register: async () => reg, getRegistration: async () => reg, ready: Promise.resolve(reg) } });
    class FakeNotification { static get permission() { return load().perm; } static async requestPermission() { save({ ...load(), perm: 'granted' }); return 'granted'; } }
    Object.defineProperty(window, 'Notification', { configurable: true, value: FakeNotification });
    Object.defineProperty(navigator, 'webdriver', { configurable: true, get: () => false });
  });
}

async function mkPerson(sql: Sql, role: 'renter' | 'admin') {
  const id = randomUUID(); const email = `push.${role}.${Date.now()}.${randomBytes(2).toString('hex')}@example.test`;
  await sql`insert into local_auth.users (id, email, password_hash) values (${id}, ${email}, ${hash(PW)})`;
  if (role === 'renter') {
    await sql`select public.register_account(${id}, ${email}, 'Petra Push', null)`;
    await sql`update users set email_verified_at = now() where id = ${id}`;
  } else {
    await sql`insert into users (id, email, full_name) values (${id}, ${email}, 'Ada Alerts')`;
    await sql`insert into user_roles (user_id, role) values (${id}, 'admin')`;
  }
  return { id, email };
}
async function signIn(page: Page, email: string, next: string) {
  await page.goto(`/sign-in?next=${encodeURIComponent(next)}`, { waitUntil: 'networkidle' });
  await acceptCookies(page);
  const useEmail = page.getByTestId('use-email');
  if (await useEmail.isVisible().catch(() => false)) await useEmail.click();
  await page.locator('input[type="email"]').fill(email);
  await page.locator('input[type="password"]').fill(PW);
  await page.getByRole('button', { name: 'Sign in' }).click();
  await page.waitForURL((u) => u.pathname.startsWith(next));
}
async function check(page: Page, where: string) {
  await noOverflow(page);
  const r = await new AxeBuilder({ page: page as never }).include('[data-testid="push-card"], [data-testid="push-prompt"]').withTags(['wcag2a', 'wcag2aa', 'wcag21a', 'wcag21aa']).analyze();
  const bad = r.violations.filter((v) => v.impact === 'serious' || v.impact === 'critical');
  expect(bad.map((v) => `${where} ${v.id}: ${v.nodes.map((n) => n.target.join(' ')).slice(0, 3).join(', ')}`)).toEqual([]);
  expect((await page.locator('body').innerText()).match(/[–—]/)?.[0], `${where}: long dash`).toBeUndefined();
}

test('installable: the manifest, the icons, the alerts service worker and the policy that allows them', async ({ request }) => {
  const m = await request.get('/manifest.webmanifest');
  expect(m.status()).toBe(200);
  expect(m.headers()['content-type']).toContain('application/manifest+json');
  const j = await m.json() as { name: string; start_url: string; scope: string; display: string; theme_color: string; icons: Array<{ src: string; purpose: string }> };
  expect([j.name, j.start_url, j.scope, j.display, j.theme_color]).toEqual(['CarmaCars', '/app', '/', 'standalone', '#000000']);
  expect(j.icons.map((i) => i.purpose)).toEqual(['any', 'any', 'maskable']);
  for (const i of j.icons) expect((await request.get(i.src)).status(), i.src).toBe(200);
  const sw = await request.get('/push-sw.js');
  expect(sw.status()).toBe(200);
  const code = await sw.text();
  expect(code).toContain("addEventListener('push'");
  expect(code, 'the service worker caches nothing and handles no page loads').not.toMatch(/addEventListener\('fetch'|caches\./);
  const home = await request.get('/');
  const csp = home.headers()['content-security-policy'] ?? '';
  expect(csp).toContain("worker-src 'self'");
  expect(csp).toContain("manifest-src 'self'");
  expect(await home.text()).toContain('rel="manifest" href="/manifest.webmanifest"');
  const app = await request.get('/app', { maxRedirects: 0 });
  expect(app.status()).toBe(302);
  expect(new URL(app.headers().location!, 'http://x').pathname).toBe('/');
});

test('a renter is invited on Trips, turns alerts on, chooses what alerts and turns them off', async ({ page }) => {
  const sql = db();
  try {
    const me = await mkPerson(sql, 'renter');
    await fakePush(page);
    await signIn(page, me.email, '/account');
    const prompt = page.getByTestId('push-prompt');
    await expect(prompt).toContainText('Get alerts on this device');
    await check(page, '/account invitation');
    await prompt.getByTestId('push-prompt-on').click();
    await expect(prompt).toContainText('Alerts are on for this device');
    const [sub] = await sql`select portal, device from push_subscriptions where user_id = ${me.id}`;
    expect(sub).toMatchObject({ portal: 'renter' });

    await page.goto('/account/profile', { waitUntil: 'networkidle' });
    const card = page.getByTestId('push-card');
    await expect(card).toHaveAttribute('data-status', 'on');
    await expect(card.getByTestId('push-badge')).toHaveText('On on this device');
    await expect(card.locator('input[type="checkbox"]:checked')).toHaveCount(7);
    await check(page, '/account/profile alerts on');
    await card.getByTestId('push-topic-payments').uncheck();
    await expect(card.getByTestId('push-saved')).toHaveText('Saved');
    const [pref] = await sql`select topics from push_preferences where user_id = ${me.id}`;
    expect(pref!.topics).not.toContain('payments');

    await card.getByTestId('push-test').click();
    await expect(card.getByTestId('push-msg')).toContainText('Test alert sent');
    await expect.poll(async () => (await sql`select status from push_outbox where user_id = ${me.id} and code = 'push_test'`)[0]?.status).toBe('sent');

    // a real notice of a topic she keeps queues one alert for her device; one she turned off does not
    await sql`insert into notifications (user_id, code, title, url, dedupe_key) values (${me.id}, 'renter_offer_ready', 'Your offer is ready', '/account', ${`e2e-push:${me.id}:offer`}),
      (${me.id}, 'renter_payment_receipt', 'Payment received', '/account', ${`e2e-push:${me.id}:pay`})`;
    const codes = (await sql`select code from push_outbox where user_id = ${me.id} and code <> 'push_test' order by code`).map((r) => r.code);
    expect(codes).toEqual(['renter_offer_ready']);

    await card.getByTestId('push-off').click();
    await expect(card).toHaveAttribute('data-status', 'ready');
    await expect(card.getByTestId('push-badge')).toHaveText('Off on this device');
    expect((await sql`select count(*)::int n from push_subscriptions where user_id = ${me.id}`)[0]!.n).toBe(0);
  } finally { await sql.end(); }
});

test('an iPhone not on the Home Screen gets the steps, not a button', async ({ browser }) => {
  const sql = db();
  const ctx = await browser.newContext({ userAgent: IPHONE, viewport: { width: 375, height: 812 }, hasTouch: true, isMobile: true, reducedMotion: 'reduce' });
  try {
    await ctx.addInitScript(() => Object.defineProperty(navigator, 'webdriver', { configurable: true, get: () => false }));
    const page = await ctx.newPage();
    const me = await mkPerson(sql, 'renter');
    await signIn(page, me.email, '/account');
    await expect(page.getByTestId('push-prompt')).toContainText('Add to Home Screen');
    await expect(page.getByTestId('push-prompt-on')).toHaveCount(0);
    await page.goto('/account/profile', { waitUntil: 'networkidle' });
    const card = page.getByTestId('push-card');
    await expect(card).toHaveAttribute('data-status', 'ios_install');
    await expect(card.getByTestId('push-ios-steps').locator('li')).toHaveCount(3);
    await expect(card.getByTestId('push-on')).toHaveCount(0);
    await check(page, '/account/profile iPhone');
  } finally { await ctx.close(); await sql.end(); }
});

test('an Admin has Settings > My phone alerts with the Admin topics', async ({ page }) => {
  const sql = db();
  try {
    const me = await mkPerson(sql, 'admin');
    await fakePush(page);
    await signIn(page, me.email, '/admin');
    await page.goto('/admin/alerts?tab=settings', { waitUntil: 'networkidle' });
    const card = page.getByTestId('push-card');
    await expect(card).toHaveAttribute('data-status', 'ready');
    await expect(card.locator('input[type="checkbox"]')).toHaveCount(5);
    await expect(card.locator('input[type="checkbox"]:checked')).toHaveCount(4);
    await check(page, '/admin/alerts');
    await card.getByTestId('push-on').click();
    await expect(card).toHaveAttribute('data-status', 'on');
    expect((await sql`select portal from push_subscriptions where user_id = ${me.id}`)[0]?.portal).toBe('admin');
  } finally { await sql.end(); }
});
