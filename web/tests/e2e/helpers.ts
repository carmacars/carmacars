import { expect, type Locator, type Page } from '@playwright/test';
import postgres from 'postgres';
import { mkdirSync, writeFileSync } from 'node:fs';
import path from 'node:path';

export const db = () => postgres(process.env.DATABASE_URL ?? 'postgresql://postgres@127.0.0.1:54322/carmacars', { max: 1, onnotice: () => {} });

/** Collects console errors and failed requests while a test runs. */
export function watch(page: Page) {
  const errors: string[] = [];
  page.on('console', (m) => { if (m.type() === 'error') errors.push(m.text()); });
  page.on('pageerror', (e) => errors.push(String(e)));
  return errors;
}

export async function noOverflow(page: Page) {
  const over = await page.evaluate(() => document.documentElement.scrollWidth - window.innerWidth);
  expect(over, 'horizontal overflow in px').toBeLessThanOrEqual(0);
}

/** Accepts the cookie banner so it does not cover what a test clicks. */
export async function acceptCookies(page: Page) {
  const b = page.getByRole('button', { name: 'Necessary only' }).first();
  if (await b.isVisible().catch(() => false)) await b.click();
}

export const PUBLIC_PAGES = ['/', '/cars', '/cars/mercedes-benz-c300', '/cars/tesla-model-3', '/cars/toyota/corolla', '/cars/toyota/corolla/2023', '/cars/volkswagen/jetta/2020/sportline', '/how-it-works', '/requirements', '/delivery', '/faq', '/contact', '/terms', '/privacy', '/cancellation-policy', '/list-your-car', '/investors', '/sign-in', '/create-account', '/reset-password', '/update-password', '/book', '/book/mercedes-benz-c300', '/book/sent/R-000001'];

/** The text of a PDF, one string with the whitespace collapsed (pdf.js, as the toll notices use it). */
export async function pdfText(body: Buffer | Uint8Array): Promise<string> {
  const pdfjs = await import('pdfjs-dist/legacy/build/pdf.mjs');
  const doc = await pdfjs.getDocument({ data: new Uint8Array(body), isEvalSupported: false, useSystemFonts: true }).promise;
  let out = '';
  for (let n = 1; n <= doc.numPages; n++) {
    const c = await (await doc.getPage(n)).getTextContent();
    out += ' ' + c.items.map((i) => ('str' in i ? i.str : '')).join(' ');
  }
  await doc.destroy();
  return out.replace(/\s+/g, ' ');
}

/** A fixture's stored file in the local storage the server reads (scripts/serve.mjs runs in web/): a one-page PDF, so
 *  a document row a test inserts opens like a real one (the crawl requests every document link it finds). */
export function storeFixturePdf(bucket: string, key: string) {
  const dir = process.env.LOCAL_STORAGE_DIR ?? path.join(process.cwd(), '.local-storage');
  const file = path.join(dir, bucket, key);
  mkdirSync(path.dirname(file), { recursive: true });
  writeFileSync(file, '%PDF-1.4\n1 0 obj<</Type/Catalog/Pages 2 0 R>>endobj 2 0 obj<</Type/Pages/Kids[3 0 R]/Count 1>>endobj 3 0 obj<</Type/Page/Parent 2 0 R/MediaBox[0 0 612 792]>>endobj\ntrailer<</Root 1 0 R>>\n%%EOF\n');
}

// ---------------------------------------------------------------- VIN-first entry (migration 0082)
/** Year, make and model from the lists (a VIN the decoder could not read, or a car added by its plate). */
export async function fillYmm(page: Page, prefix: string, c: { year: string; make: string; model: string }) {
  await page.getByTestId(`${prefix}-year`).selectOption(c.year);
  const make = page.getByTestId(`${prefix}-make`);
  if ((await make.evaluate((e) => e.tagName)) === 'SELECT') {
    if (await make.locator(`option[value="${c.make}"]`).count()) await make.selectOption(c.make);
    else { await make.selectOption('__other'); await page.getByTestId(`${prefix}-make`).fill(c.make); }
  } else await make.fill(c.make);
  const model = page.getByTestId(`${prefix}-model`);
  // the list of models loads for the make and year: a list, or a box to type in
  await expect(async () => {
    const tag = await model.evaluate((e) => e.tagName);
    if (tag === 'SELECT') expect(await model.isEnabled()).toBe(true);
  }).toPass({ timeout: 60_000 });
  if ((await model.evaluate((e) => e.tagName)) === 'SELECT') {
    if (await model.locator(`option[value="${c.model}"]`).count()) await model.selectOption(c.model);
    else { await model.selectOption('__other'); await page.getByTestId(`${prefix}-model`).fill(c.model); }
  } else await model.fill(c.model);
}

/** The car's year, make and model by hand on staff Add a car, whatever the decoder answered: decoded, Edit and type
 *  them; not decoded, choose them from the lists. */
export async function carByHand(page: Page, prefix: string, c: { year: string; make: string; model: string }) {
  const sum = page.getByTestId(`${prefix}-summary`);
  const fb = page.getByTestId(`${prefix}-ymm`);
  await expect(sum.or(fb)).toBeVisible({ timeout: 90_000 });
  if (await sum.isVisible()) {
    await page.getByTestId(`${prefix}-edit`).click();
    await page.getByTestId(`${prefix}-edit-year`).fill(c.year);
    await page.getByTestId(`${prefix}-edit-make`).fill(c.make);
    await page.getByTestId(`${prefix}-edit-model`).fill(c.model);
  } else await fillYmm(page, prefix, c);
}

/** One tap on a colour swatch. */
export async function tapColour(page: Page, prefix: string, colour: string) {
  await page.getByTestId(`${prefix}-colour`).locator('label', { hasText: new RegExp(`^${colour}$`) }).click();
}

/** The day's AI allowance is shared by the whole site: the usage guard tests (assistant-usage.spec.ts) push it to the
 *  cap for a while, and a car added meanwhile keeps its plain copy (the search job claims nothing past the cap). Those
 *  tests take this lock alone; the tests that wait for a car's AI copy take it shared. A session lock on its own
 *  connection, released when the connection ends. */
export async function aiAllowanceLock(mode: 'alone' | 'shared'): Promise<() => Promise<void>> {
  const c = db();
  await c.unsafe(mode === 'alone' ? 'select pg_advisory_lock(73110087)' : 'select pg_advisory_lock_shared(73110087)');
  return async () => { await c.end(); };
}

/** The renter's licence on file (front, back, selfie and an expiry after the return), as the licence step leaves it
 *  (0130): needed before an offer is accepted. Call it once the request exists (requested or offered). */
/** A finished e-signature session (migration 0143) for a signer signed through the database functions: the code, the
 *  reading, the five initials, the consents and a drawn signature. Returns the signature's path, which the signing
 *  function must be given as the drawn signature. */
export async function readyEsign(sql: ReturnType<typeof db>, signerId: string, context = 'rental_agreement'): Promise<string> {
  const [s] = await sql`select (public.server_esign_start(jsonb_build_object('context', ${context}::text, 'signer_ref', ${signerId}::uuid, 'ip', '203.0.113.9', 'user_agent', 'e2e')) ->> 'id') id`;
  const id = s!.id as string;
  await sql`select public.server_esign_code_set(${id}::uuid, 'email', ${'c'.repeat(64)})`;
  await sql`select public.server_esign_code_check(${id}::uuid, ${'c'.repeat(64)})`;
  await sql`select public.server_esign_step(${id}::uuid, 'viewed', '{}')`;
  for (const k of ['damage', 'charges', 'fees', 'coverage', 'cancellation']) await sql`select public.server_esign_step(${id}::uuid, 'initial', ${sql.json({ code: k, path: `esign/${id}/initials-${k}.png` })})`;
  for (const k of ['esign', 'erecords', 'card']) await sql`select public.server_esign_step(${id}::uuid, 'consent', ${sql.json({ code: k, text: 'I agree' })})`;
  const path = `esign/${id}/signature.png`;
  await sql`select public.server_esign_step(${id}::uuid, 'signature', ${sql.json({ method: 'drawn', path })})`;
  return path;
}

export async function giveLicence(sql: ReturnType<typeof db>, booking: string) {
  await sql`update booking_drivers set licence_expiry = coalesce(licence_expiry, date '2031-01-01') where booking_id = ${booking}::uuid and role = 'renter'`;
  for (const k of ['licence_front', 'licence_back', 'selfie']) {
    await sql`select app.register_verification_upload(${booking}::uuid, null, ${k}, d.driver_id, ${`e2e/${booking}/${k}.jpg`}, null, 'image/jpeg', null, 'identity')
                from booking_drivers d where d.booking_id = ${booking}::uuid and d.role = 'renter'
                 and not exists (select 1 from verification_uploads u where u.booking_id = d.booking_id and u.driver_id = d.driver_id and u.kind = ${k} and u.status in ('submitted', 'approved'))`;
  }
}

/** A stroke across a canvas (a signature or initials pad). */
export async function drawOn(page: Page, pad: Locator, points = 24) {
  await pad.scrollIntoViewIfNeeded();
  // the page scrolls smoothly and the steps above it change height as they finish: draw once the pad stands still
  let b = (await pad.boundingBox())!;
  for (let i = 0; i < 20; i++) {
    await page.waitForTimeout(150);
    const n = (await pad.boundingBox())!;
    if (Math.abs(n.x - b.x) < 0.5 && Math.abs(n.y - b.y) < 0.5) break;
    b = n;
  }
  // and nothing lies over it (a toast, such as the cookie choice's "Saved", stays a few seconds)
  const handle = await pad.elementHandle();
  for (let i = 0; i < 40; i++) {
    if (await page.evaluate(([x, y, el]) => document.elementFromPoint(x as number, y as number) === el, [b.x + 12, b.y + b.height * 0.6, handle] as const)) break;
    await page.waitForTimeout(250);
  }
  await page.mouse.move(b.x + 12, b.y + b.height * 0.6);
  await page.mouse.down();
  for (let i = 1; i <= points; i++) await page.mouse.move(b.x + 12 + i * ((b.width - 30) / points), b.y + b.height * (0.55 + 0.25 * Math.sin(i / 2)), { steps: 2 });
  await page.mouse.up();
}

/** The signature that holds up (migration 0143), on any signing page: the code (shown on the page by the local fake
 *  line), the reading, each key term initialled, each consent, the drawn signature; resolves once the page's Sign
 *  button may be pressed. */
export async function strongSign(page: Page, scope: Page | Locator = page, channel: 'sms' | 'email' = 'sms') {
  const flow = scope.getByTestId('esign-flow');
  await expect(flow).toBeVisible({ timeout: 20_000 });
  const ch = flow.getByTestId(`esign-channel-${channel}`);
  if (await ch.count()) await ch.check();
  await flow.getByTestId('esign-send').click();
  const dev = flow.getByTestId('esign-dev-code');
  await expect(dev).toBeVisible({ timeout: 15_000 });
  const code = ((await dev.textContent()) ?? '').replace(/\D/g, '').slice(-6);
  await flow.getByTestId('esign-code').fill(code);
  await flow.getByTestId('esign-confirm').click();
  await expect(flow.getByTestId('esign-verified')).toBeVisible({ timeout: 15_000 });
  // the boxes follow the record: each tick is saved first, then shown ticked (so a click, then the wait)
  await flow.getByTestId('esign-viewed').click();
  await expect(flow.getByTestId('esign-viewed')).toBeChecked({ timeout: 10_000 });
  for (let n = 0; n < 6; n++) {
    const pad = flow.locator('canvas[data-testid^="initials-"]').first();
    if (!(await pad.count())) break;
    const id = await pad.getAttribute('data-testid');
    await drawOn(page, pad, 10);
    await expect(flow.locator(`canvas[data-testid="${id}"]`)).toHaveCount(0, { timeout: 15_000 });
  }
  for (let n = 0; n < 4; n++) {
    const c = flow.locator('input[data-testid^="esign-consent-"]:not(:checked)').first();
    if (!(await c.count())) break;
    const id = await c.getAttribute('data-testid');
    await c.click();
    await expect(flow.getByTestId(id!)).toBeChecked({ timeout: 10_000 });
  }
  await expect(flow.locator('input[data-testid^="esign-consent-"]:not(:checked)')).toHaveCount(0, { timeout: 15_000 });
  await drawOn(page, flow.getByTestId('signature-pad'), 30);
  await expect(flow).toHaveAttribute('data-ready', 'true', { timeout: 15_000 });
  // the page's Sign button takes the session once the drawn signature is stored
  await expect(flow).toHaveAttribute('data-complete', 'true', { timeout: 15_000 });
  await page.waitForTimeout(300);
}
