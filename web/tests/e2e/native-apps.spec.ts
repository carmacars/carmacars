import AxeBuilder from '@axe-core/playwright';
import { expect, test, type BrowserContext, type Page } from '@playwright/test';
import { randomBytes, randomUUID, scryptSync } from 'node:crypto';
import { acceptCookies, db, noOverflow } from './helpers';

// The App Store and Google Play app (migration 0390) end to end, at 375 and 1440. A test browser is not the app, so the
// app's native bridge is a stand-in (below): the user agent token the shell adds, and window.Capacitor answering for the
// plugins the site calls (Firebase Messaging, Camera, Face ID, Preferences, the splash screen). The local server runs
// with PUSH_PROVIDER=fake, so the app's alerts card shows without a Firebase account and alerts are recorded as sent.
// In the app: the web-only footer parts are hidden, alerts turn on with the phone's token, Face ID unlock turns on and
// locks the app, a photo field opens the camera and gets the photo back, a deep link opens its page. In the app and in a
// browser: Delete my account opens the Admin's task and can be withdrawn. The universal links files answer 404 until
// the store ids are set.
const PW = 'correct horse battery';
type Sql = ReturnType<typeof db>;
const hash = (pw: string) => { const salt = randomBytes(16); return `scrypt$${salt.toString('base64')}$${scryptSync(pw, salt, 64).toString('base64')}`; };
const APP_UA = 'Mozilla/5.0 (iPhone; CPU iPhone OS 18_1 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Mobile/15E148 CarmaCarsApp/1 ios';

/** The app's native bridge, standing in for Capacitor's: plugin calls answered here and recorded in window.__cap. */
async function fakeApp(ctx: BrowserContext, o: { unlock?: boolean } = {}) {
  await ctx.addInitScript((opts) => {
    const KEY = 'e2e-cap';
    const load = (): { prefs: Record<string, string>; perm: string; token: string; authOk: boolean } => {
      try { return JSON.parse(sessionStorage.getItem(KEY) ?? ''); } catch { return { prefs: opts.unlock ? { 'cc.unlock': '1' } : {}, perm: 'prompt', token: 'e2e' + Math.random().toString(36).slice(2).padEnd(40, 'x'), authOk: !opts.unlock }; }
    };
    const save = (s: ReturnType<typeof load>) => sessionStorage.setItem(KEY, JSON.stringify(s));
    save(load());
    const calls: string[] = [];
    const listeners: Record<string, Array<(d: unknown) => void>> = {};
    const w = window as unknown as Record<string, unknown>;
    w.__cap = { calls, emit: (p: string, e: string, d: unknown) => (listeners[`${p}.${e}`] ?? []).forEach((cb) => cb(d)), allowAuth: () => save({ ...load(), authOk: true }), state: load };
    const answer = async (plugin: string, method: string, opt: Record<string, unknown> = {}): Promise<unknown> => {
      calls.push(`${plugin}.${method}`);
      const s = load();
      switch (`${plugin}.${method}`) {
        case 'FirebaseMessaging.checkPermissions': return { receive: s.perm };
        case 'FirebaseMessaging.requestPermissions': save({ ...s, perm: 'granted' }); return { receive: 'granted' };
        case 'FirebaseMessaging.getToken': return { token: s.token };
        case 'Preferences.get': return { value: s.prefs[String(opt.key)] ?? null };
        case 'Preferences.set': save({ ...s, prefs: { ...s.prefs, [String(opt.key)]: String(opt.value) } }); return undefined;
        case 'Preferences.remove': { const p = { ...s.prefs }; delete p[String(opt.key)]; save({ ...s, prefs: p }); return undefined; }
        case 'BiometricAuthNative.checkBiometry': return { isAvailable: true, biometryType: 2 };
        case 'BiometricAuthNative.internalAuthenticate': if (!s.authOk) throw new Error('User cancelled'); return undefined;
        case 'Camera.getPhoto': return { base64String: btoa('\xff\xd8\xff\xe0e2e-photo'), format: 'jpeg' };
        case 'Network.getStatus': return { connected: true };
        default: return undefined;
      }
    };
    w.Capacitor = {
      isNativePlatform: () => true,
      getPlatform: () => 'ios',
      PluginHeaders: ['App', 'Camera', 'Haptics', 'Network', 'Preferences', 'Share', 'SplashScreen', 'StatusBar', 'FirebaseMessaging', 'BiometricAuthNative'].map((name) => ({ name, methods: [] })),
      nativePromise: (p: string, m: string, opt?: Record<string, unknown>) => answer(p, m, opt),
      nativeCallback: (p: string, _m: string, opt: { eventName: string }, cb: (d: unknown) => void) => { (listeners[`${p}.${opt.eventName}`] ??= []).push(cb); return `${p}.${opt.eventName}.${Math.random()}`; }
    };
  }, o);
}

async function mkRenter(sql: Sql) {
  const id = randomUUID(); const email = `app.renter.${Date.now()}.${randomBytes(2).toString('hex')}@example.test`;
  await sql`insert into local_auth.users (id, email, password_hash) values (${id}, ${email}, ${hash(PW)})`;
  await sql`select public.register_account(${id}, ${email}, 'Andie App', null)`;
  await sql`update users set email_verified_at = now() where id = ${id}`;
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
async function check(page: Page, where: string, include: string) {
  await noOverflow(page);
  const r = await new AxeBuilder({ page: page as never }).include(include).withTags(['wcag2a', 'wcag2aa', 'wcag21a', 'wcag21aa']).analyze();
  const bad = r.violations.filter((v) => v.impact === 'serious' || v.impact === 'critical');
  expect(bad.map((v) => `${where} ${v.id}: ${v.nodes.map((n) => n.target.join(' ')).slice(0, 3).join(', ')}`)).toEqual([]);
  expect((await page.locator('body').innerText()).match(/[–—]/)?.[0], `${where}: long dash`).toBeUndefined();
}
const appContext = (browser: import('@playwright/test').Browser, viewport: { width: number; height: number } | null) =>
  browser.newContext({ userAgent: APP_UA, viewport: viewport ?? { width: 375, height: 812 }, hasTouch: true, reducedMotion: 'reduce' });

test('the universal links and app links files answer 404 until the store ids are set', async ({ request }) => {
  for (const p of ['/.well-known/apple-app-site-association', '/apple-app-site-association', '/.well-known/assetlinks.json']) expect((await request.get(p)).status(), p).toBe(404);
});

test('in a browser: no app layer, the full footer, and Delete my account on the profile', async ({ page }) => {
  const sql = db();
  try {
    await page.goto('/', { waitUntil: 'networkidle' });
    await expect(page.locator('html')).not.toHaveAttribute('data-shell', 'app');
    await expect(page.locator('.footer-browse').first()).toBeVisible();
    const me = await mkRenter(sql);
    await signIn(page, me.email, '/account');
    await page.goto('/account/profile', { waitUntil: 'networkidle' });
    await expect(page.getByTestId('app-unlock-card')).toHaveCount(0);
    const del = page.getByTestId('delete-account');
    await del.getByTestId('delete-start').click();
    await expect(del.getByTestId('delete-confirm')).toBeVisible();
    await check(page, '/account/profile delete (browser)', '[data-testid="delete-account"]');
    await del.locator('textarea').fill('Moving away');
    await del.getByTestId('delete-confirm-btn').click();
    await expect(del.getByTestId('delete-asked')).toContainText('within 30 days');
    const [t] = await sql`select t.queue, t.task_type, t.status, d.status as req, d.reason from account_deletion_requests d join tasks t on t.id = d.task_id where d.user_id = ${me.id}`;
    expect(t).toMatchObject({ queue: 'admin', task_type: 'account_deletion', status: 'open', req: 'open', reason: 'Moving away' });
    await del.getByTestId('delete-withdraw').click();
    await expect(del.getByTestId('delete-start')).toBeVisible();
    const [w] = await sql`select t.status, d.status as req from account_deletion_requests d join tasks t on t.id = d.task_id where d.user_id = ${me.id}`;
    expect(w).toMatchObject({ status: 'cancelled', req: 'withdrawn' });
  } finally { await sql.end(); }
});

test('in the app: the web-only footer is hidden, alerts use the phone, Face ID unlock, the camera and deep links', async ({ browser }, info) => {
  const sql = db();
  const ctx = await appContext(browser, info.project.use.viewport ?? null);
  try {
    await fakeApp(ctx);
    const page = await ctx.newPage();
    await page.goto('/', { waitUntil: 'networkidle' });
    await expect(page.locator('html')).toHaveAttribute('data-shell', 'app');
    await expect(page.locator('.footer-browse').first()).toBeHidden();
    await expect(page.locator('.footer-legal')).toBeVisible();
    await expect.poll(() => page.evaluate(() => (window as unknown as { __cap: { calls: string[] } }).__cap.calls)).toContain('SplashScreen.hide');

    const me = await mkRenter(sql);
    await signIn(page, me.email, '/account');
    await page.goto('/account/profile', { waitUntil: 'networkidle' });
    const card = page.getByTestId('push-card');
    await expect(card).toHaveAttribute('data-status', 'ready');
    await expect(card).toContainText('even with the app closed');
    await card.getByTestId('push-on').click();
    await expect(card).toHaveAttribute('data-status', 'on');
    const [sub] = await sql`select kind, platform, device, portal, p256dh, endpoint from push_subscriptions where user_id = ${me.id}`;
    expect(sub).toMatchObject({ kind: 'fcm', platform: 'ios', device: 'CarmaCars app on iPhone', portal: 'renter', p256dh: null });
    expect(String(sub!.endpoint)).toMatch(/^fcm:e2e/);
    await card.getByTestId('push-test').click();
    await expect(card.getByTestId('push-msg')).toContainText('Test alert sent');
    await expect.poll(async () => (await sql`select status from push_outbox where user_id = ${me.id} and code = 'push_test'`)[0]?.status).toBe('sent');

    const lock = page.getByTestId('app-unlock-card');
    await expect(lock).toContainText('Unlock with Face ID');
    await check(page, '/account/profile (app)', '[data-testid="push-card"], [data-testid="app-unlock-card"], [data-testid="delete-account"]');
    await lock.getByTestId('app-unlock-switch').check();
    await expect(lock).toContainText('CarmaCars asks for Face ID when it opens');
    expect(await page.evaluate(() => (window as unknown as { __cap: { state: () => { prefs: Record<string, string> } } }).__cap.state().prefs['cc.unlock'])).toBe('1');

    // a photo field: the phone's camera, and the photo back in the same input
    const got = await page.evaluate(() => new Promise<string>((done) => {
      const i = document.createElement('input');
      i.type = 'file'; i.accept = 'image/*'; i.setAttribute('capture', 'environment');
      i.addEventListener('change', () => done(`${i.files?.[0]?.name}|${i.files?.[0]?.type}`));
      document.body.append(i); i.click();
    }));
    expect(got).toMatch(/^photo-\d+\.jpg\|image\/jpeg$/);

    // a universal link that opened the app: its page; another site's link: nothing
    await page.evaluate(() => (window as unknown as { __cap: { emit: (p: string, e: string, d: unknown) => void } }).__cap.emit('App', 'appUrlOpen', { url: 'https://evil.example.test/account' }));
    await page.waitForTimeout(300);
    expect(new URL(page.url()).pathname).toBe('/account/profile');
    await page.evaluate(() => (window as unknown as { __cap: { emit: (p: string, e: string, d: unknown) => void } }).__cap.emit('App', 'appUrlOpen', { url: 'https://carmacars.ca/account/documents' }));
    await page.waitForURL((u) => u.pathname === '/account/documents');
  } finally { await ctx.close(); await sql.end(); }
});

test('in the app with unlock on: locked until Face ID passes', async ({ browser }, info) => {
  const ctx = await appContext(browser, info.project.use.viewport ?? null);
  try {
    await fakeApp(ctx, { unlock: true });
    const page = await ctx.newPage();
    await page.goto('/', { waitUntil: 'networkidle' });
    const lock = page.getByTestId('app-lock');
    await expect(lock).toBeVisible();
    await expect(lock).toContainText('CarmaCars is locked');
    await expect(page.locator('main')).toHaveJSProperty('inert', true);
    await check(page, '/ locked', '[data-testid="app-lock"]');
    await page.evaluate(() => (window as unknown as { __cap: { allowAuth: () => void } }).__cap.allowAuth());
    await lock.getByTestId('app-unlock').click();
    await expect(lock).toHaveCount(0);
    await expect(page.locator('main')).toHaveJSProperty('inert', false);
  } finally { await ctx.close(); }
});
