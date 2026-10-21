// Screens for the investor deck that the guides' screenshots do not have (docs/changes/2026-10-21-investor-deck.md):
// signs in on the local stack as fictional people (example.com) and photographs the sample-car pages at 1440 x 900.
// Writes JPEGs to public/deck/. The rest of the deck's screens are the guides' (docs/guides/src/img).
//
//   BASE_URL=http://localhost:3000 DATABASE_URL=postgresql://postgres@127.0.0.1:54322/carmacars node scripts/deck-shots.mjs
//
// Local stack only (DATA_BACKEND=local): it adds two sign-ins.
import { randomBytes, randomUUID, scryptSync } from 'node:crypto';
import fs from 'node:fs';
import path from 'node:path';
import { chromium } from '@playwright/test';
import postgres from 'postgres';

if (!process.env.PLAYWRIGHT_BROWSERS_PATH && fs.existsSync('/opt/pw-browsers')) process.env.PLAYWRIGHT_BROWSERS_PATH = '/opt/pw-browsers';
const BASE = (process.env.BASE_URL ?? 'http://localhost:3000').replace(/\/$/, '');
const OUT = path.resolve(path.dirname(new URL(import.meta.url).pathname), '../public/deck');
const PW = 'deck screens password 1';
const sql = postgres(process.env.DATABASE_URL ?? 'postgresql://postgres@127.0.0.1:54322/carmacars', { max: 2, onnotice: () => {} });
const hash = (pw) => { const s = randomBytes(16); return `scrypt$${s.toString('base64')}$${scryptSync(pw, s, 64).toString('base64')}`; };

async function person(kind, name) {
  const email = `${name.toLowerCase().replace(/ /g, '.')}.${randomBytes(2).toString('hex')}@example.com`;
  const id = randomUUID();
  await sql`insert into local_auth.users (id, email, password_hash) values (${id}, ${email}, ${hash(PW)})`;
  await sql`insert into users (id, email, full_name) values (${id}, ${email}, ${name})`;
  if (kind === 'admin') await sql`insert into user_roles (user_id, role) values (${id}, 'admin')`;
  if (kind === 'investor') await sql`insert into investors (user_id, legal_name, investor_type, status, email) values (${id}, ${name}, 'individual', 'active', ${email})`;
  return email;
}
async function signIn(page, email) {
  await page.goto(`${BASE}/sign-in`, { waitUntil: 'networkidle' });
  const nb = page.getByRole('button', { name: 'Necessary only' }).first();
  if (await nb.isVisible().catch(() => false)) await nb.click();
  await page.locator('input[type="email"]').fill(email);
  await page.locator('input[type="password"]').fill(PW);
  await page.getByRole('button', { name: 'Sign in' }).click();
  await page.waitForURL((u) => !u.pathname.startsWith('/sign-in'), { timeout: 30_000 });
}
const save = async (page, name, clip) => {
  await page.waitForTimeout(400);
  await page.screenshot({ path: path.join(OUT, name), type: 'jpeg', quality: 80, ...(clip ? { clip } : {}) });
  console.log('deck shot', name);
};

const browser = await chromium.launch({ args: ['--no-proxy-server'] });
try {
  const ctx = await browser.newContext({ viewport: { width: 1440, height: 900 }, deviceScaleFactor: 1, reducedMotion: 'reduce' });
  const page = await ctx.newPage();
  // public pages: a landing page, a car page's add-ons, the chat
  await page.goto(`${BASE}/car-rental/toronto`, { waitUntil: 'networkidle' });
  const nb = page.getByRole('button', { name: 'Necessary only' }).first();
  if (await nb.isVisible().catch(() => false)) await nb.click();
  await save(page, 'landing.jpg');
  const car = (await sql`select l.slug from vehicle_listings l where l.status = 'published' order by l.slug limit 1`)[0]?.slug;
  await page.goto(`${BASE}/cars/${car}`, { waitUntil: 'networkidle' });
  const add = page.getByRole('heading', { name: /add-ons/i }).first();
  if (await add.count()) {
    await add.scrollIntoViewIfNeeded();
    await page.evaluate(() => window.scrollBy(0, -120));
  }
  await save(page, 'addons.jpg');
  await page.goto(`${BASE}/`, { waitUntil: 'networkidle' });
  const open = page.getByTestId('chat-open');
  await open.waitFor({ timeout: 20_000 });
  await open.click();
  const box = page.locator('#ccw-input');
  await box.fill('Is the C300 free next weekend, and what would 3 days cost?');
  await box.press('Enter');
  await page.getByTestId('chat-log').locator('[data-sender="ai"]').last().waitFor({ timeout: 30_000 }).catch(() => {});
  await save(page, 'chat.jpg');

  // the Admin: calendar sync
  const admin = await person('admin', 'Sam Rivera');
  const a = await (await browser.newContext({ viewport: { width: 1440, height: 900 }, deviceScaleFactor: 1, reducedMotion: 'reduce' })).newPage();
  await signIn(a, admin);
  await a.goto(`${BASE}/admin/calendar-sync`, { waitUntil: 'networkidle' });
  await save(a, 'calendar-sync.jpg');

  // an investor: the guide
  const inv = await person('investor', 'Daniel Okafor');
  const i = await (await browser.newContext({ viewport: { width: 1440, height: 900 }, deviceScaleFactor: 1, reducedMotion: 'reduce' })).newPage();
  await signIn(i, inv);
  await i.goto(`${BASE}/investor/guide`, { waitUntil: 'networkidle' });
  await save(i, 'guide.jpg');
} finally {
  await browser.close();
  await sql.end();
}
