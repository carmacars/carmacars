import { expect, test, type Browser, type Page } from '@playwright/test';
import { randomBytes, randomUUID, scryptSync } from 'node:crypto';
import { acceptCookies, db, noOverflow } from './helpers';

// The investor Documents library and What's new for investors (r50, migrations 4300 and 4301), end to end: an Admin adds a
// business plan as a PDF in Admin > Investors > Documents and replaces it; the investor sees the latest version with its
// date under Documents > Business documents, opens it through a short signed link, and is told by email and in the portal;
// someone signed out is sent to sign in. The dashboard and Updates show What's new at CarmaCars. Fictional people only.
const PW = 'correct horse battery';
type Sql = ReturnType<typeof db>;
const hash = (pw: string) => { const salt = randomBytes(16); return `scrypt$${salt.toString('base64')}$${scryptSync(pw, salt, 64).toString('base64')}`; };
const isPhone = () => (test.info().project.use.viewport?.width ?? 1440) < 600;
const pdf = (label: string) => Buffer.from(`%PDF-1.4\n% ${label}\n1 0 obj << /Type /Catalog >> endobj\ntrailer << /Root 1 0 R >>\n%%EOF\n`);

async function mkPerson(sql: Sql, kind: 'investor' | 'admin', name: string) {
  const id = randomUUID(); const email = `${kind}.library.${Date.now()}.${randomBytes(2).toString('hex')}@example.test`;
  await sql`insert into local_auth.users (id, email, password_hash) values (${id}, ${email}, ${hash(PW)})`;
  await sql`insert into users (id, email, full_name) values (${id}, ${email}, ${name})`;
  if (kind === 'admin') await sql`insert into user_roles (user_id, role) values (${id}, 'admin')`;
  else await sql`insert into investors (user_id, legal_name, investor_type, status, email) values (${id}, ${name}, 'individual', 'active', ${email})`;
  return { id, email };
}
async function signIn(page: Page, email: string) {
  await page.goto('/sign-in', { waitUntil: 'networkidle' }).catch(() => page.goto('/sign-in', { waitUntil: 'networkidle' }));
  await acceptCookies(page);
  await page.locator('input[type="email"]').fill(email);
  await page.locator('input[type="password"]').fill(PW);
  await page.getByRole('button', { name: 'Sign in' }).click();
  await page.waitForURL((u) => !u.pathname.startsWith('/sign-in'), { timeout: 60_000 });
  await page.waitForLoadState('networkidle');
}
async function ctx(browser: Browser) {
  const c = await browser.newContext({ viewport: isPhone() ? { width: 375, height: 812 } : { width: 1440, height: 900 }, hasTouch: isPhone(), baseURL: test.info().project.use.baseURL, reducedMotion: 'reduce' });
  return c.newPage();
}

test.describe('investor documents library', () => {
  let sql: Sql;
  test.beforeAll(() => { sql = db(); });
  test.afterAll(async () => { await sql.end(); });

  test('an Admin adds and replaces a document; the investor sees the latest, opens it privately and is told', async ({ browser }) => {
    test.setTimeout(180_000);
    const title = `CarmaCars business plan ${randomBytes(3).toString('hex')}`;
    const admin = await mkPerson(sql, 'admin', 'Sam Example');
    const inv = await mkPerson(sql, 'investor', 'Jordan Example');

    // Admin > Investors > Documents: add the business plan as a PDF
    const a = await ctx(browser);
    await signIn(a, admin.email);
    await a.goto('/admin/investors', { waitUntil: 'networkidle' });
    await a.getByTestId('admin-library-link').click();
    await a.waitForURL('**/admin/investors/documents');
    await a.getByTestId('library-new-kind').selectOption('business_plan');
    await a.getByTestId('library-new-title').fill(title);
    await a.getByTestId('library-new-file').setInputFiles({ name: 'plan.pdf', mimeType: 'application/pdf', buffer: pdf('v1') });
    await a.getByTestId('library-new-save').click();
    await expect(a.getByTestId('library-new-msg')).toContainText('version 1');
    const item = a.getByTestId('admin-library-item').filter({ hasText: title });
    await expect(item).toContainText('Version 1');
    await noOverflow(a);

    // replace it: version 2, the history keeps both
    const id = (await sql<Array<{ id: string }>>`select id from investor_library_items where title = ${title}`)[0]!.id;
    await a.getByTestId(`library-replace-${id}`).click();
    await a.getByTestId(`library-replace-${id}-file`).setInputFiles({ name: 'plan2.pdf', mimeType: 'application/pdf', buffer: pdf('v2') });
    await a.getByTestId(`library-replace-${id}-save`).click();
    await expect(item).toContainText('Version 2', { timeout: 20_000 });
    expect((await sql`select version from investor_library_versions where item_id = ${id} order by version`).map((r) => r.version)).toEqual([1, 2]);
    // the investor is told once per version
    const told = await sql<Array<{ n: number }>>`select count(*)::int as n from app_events where code = 'investor_document_updated' and entity_id = ${id} and payload ->> 'investor_id' = (select id::text from investors where user_id = ${inv.id})`;
    expect(told[0]!.n).toBe(2);
    await a.context().close();

    // the investor: Documents > Business documents, the latest version with its date
    const p = await ctx(browser);
    await signIn(p, inv.email);
    await p.goto('/investor', { waitUntil: 'networkidle' });
    await expect(p.getByTestId('investor-whats-new')).toContainText("What's new at CarmaCars");
    await p.goto('/investor/documents?tab=library', { waitUntil: 'networkidle' });
    const row = p.getByTestId(`library-item-${id}`);
    await expect(row).toContainText(title);
    await expect(row.getByTestId('library-version')).toContainText('Version 2, updated');
    await noOverflow(p);
    // opening it: a short signed link to the latest version
    const res = await p.request.get(`/investor/documents/library/${id}`, { maxRedirects: 0 });
    expect(res.status()).toBe(302);
    expect(res.headers()['cache-control']).toContain('no-store');
    expect(res.headers().location ?? '').not.toContain('/sign-in');
    const file = await p.request.get(res.headers().location!);
    expect((await file.body()).toString('latin1')).toContain('% v2');
    await p.goto('/investor/updates', { waitUntil: 'networkidle' });
    await expect(p.getByTestId('investor-whats-new')).toBeVisible();
    await p.context().close();

    // signed out: sent to sign in
    const anon = await ctx(browser);
    const r2 = await anon.request.get(`/investor/documents/library/${id}`, { maxRedirects: 0 });
    expect(r2.status()).toBe(302);
    expect(r2.headers().location ?? '').toContain('/sign-in');
    await anon.context().close();
  });
});
