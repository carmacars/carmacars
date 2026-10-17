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

export const PUBLIC_PAGES = ['/', '/cars', '/cars/mercedes-benz-c300', '/cars/tesla-model-3', '/rent/toyota-corolla', '/how-it-works', '/requirements', '/delivery', '/faq', '/contact', '/terms', '/privacy', '/cancellation-policy', '/list-your-car', '/investors', '/sign-in', '/create-account', '/reset-password', '/update-password', '/book', '/book/mercedes-benz-c300', '/book/sent/R-000001'];

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
