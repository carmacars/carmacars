import { expect, test, type Page } from '@playwright/test';
import { randomBytes, randomUUID, scryptSync } from 'node:crypto';
import { acceptCookies, db } from './helpers';

// Migration 0812 end to end: an owner and a renter change their display name at once, see Change my password, and ask for
// a name change (the legal name on their agreements); an Admin approves it on the person's page and the name changes.
const PW = 'correct horse battery';
type Sql = ReturnType<typeof db>;
const tag = () => randomBytes(3).toString('hex');
const hash = (pw: string) => { const salt = randomBytes(16); return `scrypt$${salt.toString('base64')}$${scryptSync(pw, salt, 64).toString('base64')}`; };

async function mk(sql: Sql, who: 'owner' | 'renter' | 'admin', legal: string) {
  const id = randomUUID(); const email = `${who}.sp.${Date.now()}.${tag()}@example.test`;
  await sql`insert into local_auth.users (id, email, password_hash) values (${id}, ${email}, ${hash(PW)})`;
  if (who === 'renter') {
    await sql`select public.register_account(${id}, ${email}, ${legal}, null)`;
    const [r] = await sql`insert into renters (user_id, legal_name, email, mobile, date_of_birth) values (${id}, ${legal}, ${email}, '+14165550142', '1990-05-05') on conflict (user_id) do update set legal_name = excluded.legal_name returning id`;
    return { id, email, recordId: r!.id as string };
  }
  await sql`insert into users (id, email, full_name) values (${id}, ${email}, ${legal})`;
  await sql`insert into user_roles (user_id, role) values (${id}, ${who})`;
  if (who === 'owner') {
    const [o] = await sql`insert into owners (user_id, owner_type, legal_name, status, email) values (${id}, 'individual', ${legal}, 'active', ${email}) returning id`;
    return { id, email, recordId: o!.id as string };
  }
  return { id, email, recordId: id };
}
async function signIn(page: Page, email: string) {
  await page.goto('/sign-in', { waitUntil: 'networkidle' });
  await acceptCookies(page);
  await page.locator('input[type="email"]').fill(email);
  await page.locator('input[type="password"]').fill(PW);
  await page.getByRole('button', { name: 'Sign in' }).click();
  await page.waitForURL((u) => !u.pathname.startsWith('/sign-in'), { timeout: 20_000 });
}

test.describe.configure({ mode: 'serial' });

for (const who of ['owner', 'renter'] as const) {
  test(`${who}: display name, password link, a name change request approved by an Admin`, async ({ browser }) => {
    test.setTimeout(180_000);
    const sql = db();
    const legal = `Old ${who} ${tag()}`; const next = `New ${who} ${tag()}`;
    const p = await mk(sql, who, legal);
    const admin = await mk(sql, 'admin', `Ada Names ${tag()}`);
    const c = await browser.newContext({ baseURL: test.info().project.use.baseURL, viewport: { width: 1280, height: 900 } });
    const page = await c.newPage();
    await signIn(page, p.email);
    await page.goto(who === 'owner' ? '/owner/account' : '/account/profile', { waitUntil: 'networkidle' });
    const card = page.getByTestId('self-profile');
    await expect(card).toBeVisible();
    await expect(card.getByTestId('sp-password')).toHaveAttribute('href', '/reset-password');
    await card.getByTestId('sp-display').fill('Nicky');
    await card.getByTestId('sp-display-save').click();
    await expect(card.getByTestId('sp-display-msg')).toContainText('Nicky');
    expect((await sql`select display_name from users where id = ${p.id}`)[0]!.display_name).toBe('Nicky');
    // the legal name is not editable: it is asked for
    await expect(card.getByTestId('sp-legal')).toHaveText(legal);
    await card.getByTestId('sp-name-open').click();
    await card.getByTestId('sp-name').fill(next);
    await card.getByTestId('sp-reason').fill('Legal name change');
    await card.getByTestId('sp-name-send').click();
    await expect(card.getByTestId('sp-pending')).toContainText(next);
    expect((await sql`select legal_name from ${sql(who === 'owner' ? 'owners' : 'renters')} where user_id = ${p.id}`)[0]!.legal_name).toBe(legal);
    const [t] = await sql`select count(*)::int n from tasks where task_type = 'name_change_approve' and status = 'open' and related_id = (select id from name_change_requests where user_id = ${p.id} and status = 'requested')`;
    expect(t!.n).toBe(1);
    await c.close();

    const c2 = await browser.newContext({ baseURL: test.info().project.use.baseURL, viewport: { width: 1280, height: 900 } });
    const a = await c2.newPage();
    await signIn(a, admin.email);
    await a.goto(who === 'owner' ? `/admin/owners/${p.recordId}` : `/admin/renters/${p.recordId}`, { waitUntil: 'networkidle' });
    await expect(a.getByTestId('name-change-item')).toContainText(next);
    await a.getByTestId('name-change-approve').click();
    await expect.poll(async () => (await sql`select full_name from users where id = ${p.id}`)[0]!.full_name, { timeout: 20_000 }).toBe(next);
    expect((await sql`select legal_name from ${sql(who === 'owner' ? 'owners' : 'renters')} where user_id = ${p.id}`)[0]!.legal_name).toBe(next);
    await c2.close();
    await sql.end();
  });
}
