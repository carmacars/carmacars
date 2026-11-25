import AxeBuilder from '@axe-core/playwright';
import { expect, test, type Page } from '@playwright/test';
import { randomBytes, randomUUID, scryptSync } from 'node:crypto';
import { acceptCookies, db, noOverflow, watch } from './helpers';

// The owner pipeline (r50, migrations 4510 to 4512), the Transfer route end to end at 375 and 1440: the owner's car goes
// from its terms to Listed. The owner portal shows one step and its one button (upload, book ServiceOntario, Transfer
// done); the Admin's owner page shows the same car, whose turn it is, and advances the last steps (audited).
const PW = 'correct horse battery';
const hash = (pw: string) => { const salt = randomBytes(16); return `scrypt$${salt.toString('base64')}$${scryptSync(pw, salt, 64).toString('base64')}`; };

async function check(page: Page, where: string) {
  await noOverflow(page);
  const r = await new AxeBuilder({ page: page as never }).withTags(['wcag2a', 'wcag2aa', 'wcag21a', 'wcag21aa']).analyze();
  const bad = r.violations.filter((v) => v.impact === 'serious' || v.impact === 'critical');
  expect(bad.map((v) => `${where} ${v.id}: ${v.nodes.map((n) => n.target.join(' ')).slice(0, 3).join(', ')}`)).toEqual([]);
}
async function signIn(page: Page, email: string, next: string) {
  await page.goto(`/sign-in?next=${encodeURIComponent(next)}`, { waitUntil: 'networkidle' });
  await acceptCookies(page);
  await page.locator('input[type="email"]').fill(email);
  await page.locator('input[type="password"]').fill(PW);
  await page.getByRole('button', { name: 'Sign in' }).click();
}
// a VIN with a valid check digit, unique per run
function vin(n: number): string {
  const map: Record<string, number> = { A: 1, B: 2, C: 3, D: 4, E: 5, F: 6, G: 7, H: 8, J: 1, K: 2, L: 3, M: 4, N: 5, P: 7, R: 9, S: 2, T: 3, U: 4, V: 5, W: 6, X: 7, Y: 8, Z: 9 };
  const w = [8, 7, 6, 5, 4, 3, 2, 10, 0, 9, 8, 7, 6, 5, 4, 3, 2];
  const base = `KMHL14JA0MA${String(n % 1_000_000).padStart(6, '0')}`;
  const sum = [...base].reduce((s, c, i) => s + (/\d/.test(c) ? Number(c) : map[c]!) * w[i]!, 0) % 11;
  return base.slice(0, 8) + (sum === 10 ? 'X' : String(sum)) + base.slice(9);
}
const doc = (sql: ReturnType<typeof db>, owner: string, car: string, kind: string, review: string) =>
  sql`insert into documents (kind, title, storage_bucket, storage_path, mime_type, sha256, retention, owner_id, vehicle_id, review_status)
      values (${kind}::document_kind, ${kind}, 'documents', ${`owners/${owner}/vehicles/${car}/${kind}-${randomUUID()}.jpg`}, 'image/jpeg', ${'c'.repeat(64)}, 'records_7y', ${owner}, ${car}, ${review})`;

test('owner pipeline: a Transfer car goes from its terms to Listed, one clear step at a time', async ({ page, browser }, info) => {
  test.setTimeout(240_000);
  const errors = watch(page);
  const sql = db();
  await sql`delete from app.rate_limit_hits`;
  const stamp = `${info.project.name}.${Date.now()}`;
  const ownerEmail = `owner.transfer.${stamp}@example.test`;
  const adminEmail = `admin.transfer.${stamp}@example.test`;
  const [ownerUser, adminId] = [randomUUID(), randomUUID()];
  for (const [id, email, role, name] of [[ownerUser, ownerEmail, 'owner', 'Tina Transfer'], [adminId, adminEmail, 'admin', 'Ada Admin']] as const) {
    await sql`insert into local_auth.users (id, email, password_hash) values (${id}, ${email}, ${hash(PW)})`;
    await sql`insert into users (id, email, full_name) values (${id}, ${email}, ${name})`;
    await sql`insert into user_roles (user_id, role) values (${id}, ${role})`;
  }
  const [o] = await sql`insert into owners (user_id, owner_type, legal_name, first_name, last_name, address_line1, city, province, postal_code, email, phone, status)
    values (${ownerUser}, 'individual', 'Tina Transfer', 'Tina', 'Transfer', '1 Example Way', 'Toronto', 'ON', 'M5V 1A1', ${ownerEmail}, '+16475550166', 'active') returning id`;
  const owner = String(o!.id);
  const v = vin(Date.now() + (info.project.name.includes('375') ? 1 : 2));
  const [ap] = await sql`select app.submit_owner_application(${sql.json({ owner_id: owner, source: 'web', vehicles: [{ vin: v, plate: `T${v.slice(-6)}`, year: 2021, make: 'Hyundai', model: 'Sonata',
    colour: 'Blue', odometer_km: 20000, held_by: 'individual', title_status: 'owned_outright', management_mode: 'managed', onboarding_method: 'transfer', current_insurer: 'Example' }] })}::jsonb, ${ownerUser}::uuid) r`;
  const r = ap!.r as { application_id: string; vehicles: Array<{ vehicle_id: string }> };
  const car = r.vehicles[0]!.vehicle_id;
  await sql`select app.application_approve(${adminId}::uuid, ${sql.json({ id: r.application_id,
    cars: [{ vehicle_id: car, terms: { management_mode: 'managed', onboarding_method: 'transfer' }, invoices: [], first_last: { action: 'none' } }] })}::jsonb)`;
  // the e-signature is its own suite (owner-sign-first, owner-signing): an Admin records it here
  await sql`select app.owner_stage_do(${adminId}::uuid, ${sql.json({ vehicle_id: car, op: 'advance', note: 'Signed at the office' })}::jsonb)`;

  // ---------------------------------------------------------------- the owner: Documents uploaded
  await signIn(page, ownerEmail, '/owner');
  await page.waitForURL(/\/owner/);
  const stages = page.getByTestId('owner-stages');
  await expect(stages.getByTestId('os-car')).toHaveAttribute('data-stage', 'documents');
  await expect(stages.getByTestId('os-now')).toContainText('Your turn');
  await expect(stages.getByTestId('os-step')).toHaveCount(9);
  await expect(stages.getByTestId('os-route')).toContainText('Transfer');
  await check(page, 'owner documents step');
  await stages.getByTestId('os-cta').click();
  await page.waitForURL(new RegExp(`/owner/vehicles/${car}`));
  await expect(page.getByTestId('owner-stage-uploads')).toBeVisible();
  await expect(page.getByTestId('owner-upload-owner_id')).toBeVisible();
  await check(page, 'owner car documents');
  for (const k of ['owner_id', 'ownership_permit', 'owner_insurance_proof', 'safety_certificate', 'uvip']) await doc(sql, owner, car, k, 'approved');

  // ---------------------------------------------------------------- the owner: Ownership transfer at ServiceOntario
  await page.goto('/owner', { waitUntil: 'networkidle' });
  await expect(stages.getByTestId('os-car')).toHaveAttribute('data-stage', 'transfer');
  await expect(stages.getByTestId('os-now')).toContainText('Bring');
  await expect(stages.getByTestId('os-finder')).toHaveAttribute('href', /ontario\.ca\/locations\/serviceontario/);
  await stages.getByTestId('os-booked-open').click();
  const local = new Intl.DateTimeFormat('sv-SE', { timeZone: 'America/Toronto', year: 'numeric', month: '2-digit', day: '2-digit', hour: '2-digit', minute: '2-digit' })
    .format(new Date(Date.now() + 3 * 864e5)).replace(' ', 'T');
  await stages.getByTestId('os-at').fill(local);
  await stages.getByTestId('os-place').fill('ServiceOntario Scarborough');
  await check(page, 'owner appointment');
  await stages.getByTestId('os-save').click();
  await expect(stages.getByTestId('os-visited')).toBeVisible();
  await stages.getByTestId('os-visited-save').click();
  await expect(stages.getByTestId('os-visited')).toContainText('Tick that the registry fees are paid');
  await stages.getByTestId('os-fees').check();
  await stages.getByTestId('os-visited-save').click();
  await expect(stages.getByTestId('os-car')).toHaveAttribute('data-stage', 'registration');
  await doc(sql, owner, car, 'new_registration', 'waiting');
  await page.goto('/owner', { waitUntil: 'networkidle' });
  await expect(stages.getByTestId('os-car')).toHaveAttribute('data-stage', 'fleet_policy');
  await expect(stages.getByTestId('os-now')).toContainText('With CarmaCars');
  await expect(stages.getByTestId('os-cta')).toHaveCount(0);

  // ---------------------------------------------------------------- the Admin: Fleet's steps, then Listed
  await sql`update vehicles set on_fleet_policy = true, fleet_policy_added_on = current_date where id = ${car}`;
  const ctx = await browser.newContext({ viewport: page.viewportSize()!, baseURL: info.project.use.baseURL });
  const admin = await ctx.newPage();
  await signIn(admin, adminEmail, `/admin/owners/${owner}`);
  await admin.waitForURL(/\/admin\/owners\//);
  const at = admin.getByTestId('owner-stages');
  await expect(at.getByTestId('os-car')).toHaveAttribute('data-stage', 'inspection');
  await expect(at.getByTestId('os-script')).toBeVisible();
  await check(admin, 'admin owner stages');
  await at.getByTestId('os-inspected').click();
  await admin.getByTestId('os-inspected-submit').click();
  await expect.poll(async () => (await sql`select (inspected_at is not null) ok from owner_pipeline where vehicle_id = ${car}`)[0]?.ok).toBe(true);
  for (const why of ['Photos done in the studio', 'Published']) {
    await admin.reload({ waitUntil: 'networkidle' });
    await at.getByTestId('os-advance').click();
    await admin.getByTestId('os-advance-form').getByLabel('Why (kept in the audit log)').fill(why);
    await admin.getByTestId('os-advance-submit').click();
    await expect.poll(async () => (await sql`select count(*)::int n from audit_log where action = 'owner_stage_override' and entity_id = ${car} and after ->> 'note' = ${why}`)[0]!.n).toBe(1);
  }
  await expect.poll(async () => (await sql`select (finished_at is not null) ok from owner_pipeline where vehicle_id = ${car}`)[0]?.ok).toBe(true);
  await ctx.close();
  expect(errors.filter((e) => !/favicon|Failed to load resource.*404/.test(e)), 'no console errors').toEqual([]);
});
