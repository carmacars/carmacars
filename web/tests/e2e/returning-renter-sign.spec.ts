import { expect, test, type Page } from '@playwright/test';
import { randomBytes, randomUUID, scryptSync } from 'node:crypto';
import { mkdirSync, writeFileSync } from 'node:fs';
import path from 'node:path';
import { acceptCookies, claimReady, completeAgreementDetails, db, giveLicence, noOverflow, watch } from './helpers';

// Release 48 (docs/changes/2026-11-14-r48-signing.md): a returning renter signs in one tap. Their signature and initials
// from the last booking are on their profile (migration 2911); the signing page offers "Initial all with your saved
// initials" and "Sign with your saved signature", and the agreement is signed with that signature, no drawing and no
// "does not match" error. At both widths. Fictional people only.
const PW = 'correct horse battery';
const STAFF = '00000000-0000-4000-8000-0000000000c5';
const PNG = Buffer.from('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg==', 'base64');
const hash = (pw: string) => { const salt = randomBytes(16); return `scrypt$${salt.toString('base64')}$${scryptSync(pw, salt, 64).toString('base64')}`; };
function storePng(key: string) {
  const file = path.join(process.env.LOCAL_STORAGE_DIR ?? path.join(process.cwd(), '.local-storage'), 'agreements', key);
  mkdirSync(path.dirname(file), { recursive: true });
  writeFileSync(file, PNG);
}
async function signIn(page: Page, email: string, next: string) {
  await page.goto(`/sign-in?next=${encodeURIComponent(next)}`, { waitUntil: 'networkidle' });
  await acceptCookies(page);
  await page.locator('input[type="email"]').fill(email);
  await page.locator('input[type="password"]').fill(PW);
  await page.getByRole('button', { name: 'Sign in' }).click();
}

test('a returning renter initials and signs with one tap each, with the signature saved last time', async ({ page }) => {
  test.setTimeout(180_000);
  const errors = watch(page);
  const sql = db();
  try {
    await sql`delete from app.rate_limit_hits`;
    await sql`insert into users (id, email, full_name) values (${STAFF}, 'e2e.staff@example.test', 'Casey Staff') on conflict do nothing`;
    await sql`insert into user_roles (user_id, role) values (${STAFF}, 'va') on conflict do nothing`;
    await sql`insert into staff_profiles (user_id, home_address, home_postal_code, staff_type, va_function) values (${STAFF}, '1 Test Lane, Testville', 'X9X 9X9', 'va', 'cs') on conflict do nothing`;
    const stamp = `${Date.now()}${Math.floor(Math.random() * 1e4)}`;
    const email = `r48.${stamp}@example.test`;
    const user = randomUUID();
    await sql`insert into local_auth.users (id, email, password_hash) values (${user}, ${email}, ${hash(PW)})`;
    await sql`select public.register_account(${user}, ${email}, 'Robin Returning', null)`;
    const [car] = await sql`select v.id from vehicles v join vehicle_listings l on l.vehicle_id = v.id
      where l.status = 'published' and app.vehicle_bookable(v.id) and exists (select 1 from public_vehicle_listings pv where pv.vehicle_id = v.id) and v.partner_id is null and (not v.is_sample or v.sample_bookable) and app.vehicle_on_policy(v.id)
      order by random() limit 1`;
    type Bk = { ok: boolean; booking_id: string; booking_number: string; message?: string };
    let bk = null as Bk | null;
    for (let i = 0; i < 12 && !bk?.ok; i++) {
      const from = new Date(Date.now() + (60 + Math.floor(Math.random() * 300)) * 86_400_000); const to = new Date(from.getTime() + 3 * 86_400_000);
      const ymd = (d: Date) => d.toISOString().slice(0, 10);
      const req = {
        request_key: randomUUID(), vehicle_id: car!.id, pickup_at: `${ymd(from)}T10:00:00-04:00`, return_at: `${ymd(to)}T10:00:00-04:00`, booking_type: 'standard',
        pickup_method: 'collected', return_method: 'returned', pickup_location: { kind: 'our_location' }, return_location: { kind: 'our_location' }, coverage_option: 2, extras: { winter_tire: false, baby_seats: 0 },
        renter: { email, full_name: 'Robin Returning', mobile: '+16475550148', date_of_birth: '1989-06-12', licence_class: 'G', licence_issuer: 'ON' }, additional_drivers: [],
        consents: { terms: { accepted: true, version: 'e2e', text: 'I agree.' }, privacy: { accepted: true, version: 'e2e', text: 'I agree.' }, marketing: { opted_in: false, version: 'e2e', text: 'No.' } }, details: { source: 'e2e' }
      };
      const [r] = await sql`select public.submit_booking_request(${sql.json(req)}, '203.0.113.9', 'e2e', ${user}) v`;
      bk = r!.v as Bk;
    }
    expect(bk?.ok, bk?.message).toBe(true);
    await sql`update bookings set request_details = request_details || '{"source":"e2e"}' where id = ${bk!.booking_id}`;
    await sql`select app.send_offer(${bk!.booking_id}, ${STAFF}, null, null)`;
    await giveLicence(sql, bk!.booking_id);
    await claimReady(sql, bk!.booking_id);
    // the last booking left the signature and the initials on the profile (as signing does, 2911)
    const old = randomUUID();
    const sig = `esign/${old}/signature-${randomUUID()}.png`;
    const ini = `esign/${old}/initials-damage-${randomUUID()}.png`;
    storePng(sig); storePng(ini);
    await sql`update renters set saved_signature_path = ${sig}, saved_initials_path = ${ini}, saved_signature_at = now() where user_id = ${user}`;

    await signIn(page, email, `/account/bookings/${bk!.booking_number}/offer`);
    await page.waitForURL(/\/offer$/, { timeout: 30_000 });
    await page.getByRole('button', { name: 'Approve and continue' }).click();
    await page.waitForURL(/\/checkout$/, { timeout: 30_000 });
    await completeAgreementDetails(page);
    await page.getByTestId('consents-all').check();
    const flow = page.getByTestId('esign-flow');
    await expect(flow.getByTestId('esign-send').or(flow.getByTestId('esign-code-open'))).toBeVisible({ timeout: 20_000 });
    if (await flow.getByTestId('esign-send').count()) {
      await flow.getByTestId('esign-send').click();
      const dev = flow.getByTestId('esign-dev-code');
      await expect(dev).toBeVisible({ timeout: 15_000 });
      await flow.getByTestId('esign-code').fill(((await dev.textContent()) ?? '').replace(/\D/g, '').slice(-6));
      await flow.getByTestId('esign-confirm').click();
      await expect(flow.getByTestId('esign-verified')).toBeVisible({ timeout: 15_000 });
    }
    await flow.getByTestId('esign-viewed').click();
    await expect(flow.getByTestId('esign-viewed')).toBeChecked({ timeout: 10_000 });
    // one tap: every key term initialled with the saved initials
    await flow.getByTestId('esign-saved-initials').click();
    await expect(flow.locator('canvas[data-testid^="initials-"]')).toHaveCount(0, { timeout: 15_000 });
    for (let n = 0; n < 4; n++) {
      const c = flow.locator('input[data-testid^="esign-consent-"]:not(:checked)').first();
      if (!(await c.count())) break;
      const id = await c.getAttribute('data-testid');
      await c.click();
      await expect(flow.getByTestId(id!)).toBeChecked({ timeout: 10_000 });
    }
    // one tap: the saved signature, no drawing
    await flow.getByTestId('esign-saved-signature').click();
    await expect(flow.getByTestId('esign-saved-signature')).toHaveText('Your saved signature is in', { timeout: 15_000 });
    await expect(flow).toHaveAttribute('data-complete', 'true', { timeout: 15_000 });
    await noOverflow(page);
    await page.getByTestId('rental-sign').click();
    await page.waitForURL(/\?signed=1/, { timeout: 30_000 });
    const [rec] = await sql`select s.provider_signature p from rental_agreements a join rental_agreement_signers g on g.agreement_id = a.id join signature_records s on s.id = g.signature_record_id
      where a.booking_id = ${bk!.booking_id} and g.signer_role = 'renter'`;
    expect(rec?.p).toBe(sig);
    await expect(page.getByText(/does not match/i)).toHaveCount(0);
    expect(errors).toEqual([]);
  } finally {
    await sql.end();
  }
});
