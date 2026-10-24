import { expect, type Page } from '@playwright/test';
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
function storeFixture(bucket: string, key: string, body: string | Buffer) {
  const dir = process.env.LOCAL_STORAGE_DIR ?? path.join(process.cwd(), '.local-storage');
  const file = path.join(dir, bucket, key);
  mkdirSync(path.dirname(file), { recursive: true });
  writeFileSync(file, body);
}
/** A small valid JPEG (8x8 grey) in local storage, so a row a test inserts points at a real file (the crawl opens it). */
export const FIXTURE_JPEG = Buffer.from('/9j/2wBDABALDA4MChAODQ4SERATGCgaGBYWGDEjJR0oOjM9PDkzODdASFxOQERXRTc4UG1RV19iZ2hnPk1xeXBkeFxlZ2P/2wBDARESEhgVGC8aGi9jQjhCY2NjY2NjY2NjY2NjY2NjY2NjY2NjY2NjY2NjY2NjY2NjY2NjY2NjY2NjY2NjY2NjY2P/wAARCAAIAAgDASIAAhEBAxEB/8QAFQABAQAAAAAAAAAAAAAAAAAAAAP/xAAUEAEAAAAAAAAAAAAAAAAAAAAA/8QAFAEBAAAAAAAAAAAAAAAAAAAAAP/EABQRAQAAAAAAAAAAAAAAAAAAAAD/2gAMAwEAAhEDEQA/AKAA/9k=', 'base64');
export function storeFixtureJpeg(bucket: string, key: string) { storeFixture(bucket, key, FIXTURE_JPEG); }
export function storeFixturePdf(bucket: string, key: string) {
  storeFixture(bucket, key, '%PDF-1.4\n1 0 obj<</Type/Catalog/Pages 2 0 R>>endobj 2 0 obj<</Type/Pages/Kids[3 0 R]/Count 1>>endobj 3 0 obj<</Type/Page/Parent 2 0 R/MediaBox[0 0 612 792]>>endobj\ntrailer<</Root 1 0 R>>\n%%EOF\n');
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
export async function giveLicence(sql: ReturnType<typeof db>, booking: string) {
  await sql`update booking_drivers set licence_expiry = coalesce(licence_expiry, date '2031-01-01') where booking_id = ${booking}::uuid and role = 'renter'`;
  for (const k of ['licence_front', 'licence_back', 'selfie']) {
    // the file too: each upload is a documents row the Admin's Documents tab links and the VA's verify page shows
    storeFixtureJpeg('identity', `e2e/${booking}/${k}.jpg`);
    await sql`select app.register_verification_upload(${booking}::uuid, null, ${k}, d.driver_id, ${`e2e/${booking}/${k}.jpg`}, null, 'image/jpeg', null, 'identity')
                from booking_drivers d where d.booking_id = ${booking}::uuid and d.role = 'renter'
                 and not exists (select 1 from verification_uploads u where u.booking_id = d.booking_id and u.driver_id = d.driver_id and u.kind = ${k} and u.status in ('submitted', 'approved'))`;
  }
}
