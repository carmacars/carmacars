import { expect, test, type Page } from '@playwright/test';
import { mkdirSync } from 'node:fs';
import { randomBytes, randomUUID, scryptSync } from 'node:crypto';
import { acceptCookies, db, noOverflow, watch } from './helpers';
import { PW, seedOwner } from './portal-design-seed';

// Release 48 RW (docs/changes/2026-11-20-r48-rewards-calendar-notify.md), at 375 and 1440, and every screen checked for
// sideways scroll at 320, 375, 768, 1280 and 1440 (RW_SHOTS=<folder> also saves a screenshot of each):
//   3262: the owner's Rewards tab; a merch kit is redeemed by button with the address, the Admin gets a To do and an
//         alert in the queue, marks it shipped, and the owner sees Shipped and is emailed.
//   3260: notification preferences: a switch is saved, the locked kinds have no switch, Turn every optional one off.
//   3261: My rewards on the staff first page: an in-person seller in Canada has a code, a remote one is told why not.
//   3263: the content calendar: write the month, nothing is queued until a post is approved, reject asks why.
const hash = (pw: string) => { const salt = randomBytes(16); return `scrypt$${salt.toString('base64')}$${scryptSync(pw, salt, 64).toString('base64')}`; };
const WIDTHS = [320, 375, 768, 1280, 1440];
type Sql = ReturnType<typeof db>;

async function signIn(page: Page, email: string, next: string) {
  await page.goto(`/sign-in?next=${encodeURIComponent(next)}`, { waitUntil: 'networkidle' }).catch(() => page.goto(`/sign-in?next=${encodeURIComponent(next)}`, { waitUntil: 'networkidle' }));
  await acceptCookies(page);
  await page.locator('input[type="email"]').fill(email);
  await page.locator('input[type="password"]').fill(PW);
  await page.getByRole('button', { name: 'Sign in' }).click();
  await page.waitForURL((u) => u.pathname.startsWith(next.split('?')[0]!), { timeout: 60_000 });
  await page.waitForLoadState('networkidle');
}

/** The screen at the five widths: nothing runs off the side; a screenshot of each when RW_SHOTS is set. Only the 1440
 *  project walks the widths (the 375 project checks its own), so the suite does not do it twice. */
async function widths(page: Page, name: string, project: string) {
  await noOverflow(page);
  if (!project.startsWith('desktop')) return;
  const back = page.viewportSize();
  const dir = process.env.RW_SHOTS;
  if (dir) mkdirSync(dir, { recursive: true });
  for (const w of WIDTHS) {
    await page.setViewportSize({ width: w, height: w < 700 ? 720 : 900 });
    await page.waitForTimeout(150);
    await noOverflow(page);
    if (dir) await page.screenshot({ path: `${dir}/${name}-${w}.png`, fullPage: true });
  }
  if (back) await page.setViewportSize(back);
}

async function person(sql: Sql, name: string, role: string) {
  const id = randomUUID();
  const email = `${name.toLowerCase().replace(/[^a-z]+/g, '.')}.${Date.now()}.${Math.floor(Math.random() * 1e6)}@example.test`;
  await sql`insert into local_auth.users (id, email, password_hash) values (${id}, ${email}, ${hash(PW)})`;
  await sql`insert into users (id, email, full_name) values (${id}, ${email}, ${name})`;
  await sql`insert into user_roles (user_id, role) values (${id}, ${role})`;
  return { id, email };
}
async function seller(sql: Sql, name: string, country: string, mode: string) {
  const u = await person(sql, name, 'va');
  await sql`insert into staff_profiles (user_id, staff_type, va_function, home_address, home_postal_code, onboarding_exempt, whatsapp_joined, whatsapp_joined_at, onboarding_approved_at)
    values (${u.id}, 'va', 'sales', '1 Test Lane, Testville', 'X9X 9X9', true, '{team}', now(), now())`;
  await sql`update staff_profiles set location_country = ${country}, sales_work_mode = ${mode}, agreement_waived_at = now() where user_id = ${u.id}`;
  return u;
}

test('owner rewards: the tab, a merch kit redeemed by button, shipped by the Admin; notification preferences', async ({ page, browser }, info) => {
  test.setTimeout(300_000);
  const sql = db();
  await sql`delete from app.rate_limit_hits`;
  const errors = watch(page);
  const o = await seedOwner(sql);
  await sql`select app.owner_reward_sync(${o.ownerId})`.catch(() => undefined);

  await signIn(page, o.email, '/owner/rewards');
  const r = page.getByTestId('owner-rewards');
  await expect(r).toBeVisible();
  await expect(page.getByTestId('or-fleet')).toContainText('20%');
  await expect(page.getByTestId('or-ff-code')).toHaveText(/\S{4,}/);
  await expect(page.getByTestId('or-ff-qr')).toBeVisible();
  await expect(page.getByTestId('or-refer')).toContainText('$100');
  await widths(page, 'owner-rewards', info.project.name);

  // the kit is never sent by itself: nothing asked for yet, then the button, the address, and it is with the Admin
  const before = await sql`select count(*)::int as n from owner_reward_requests where owner_id = ${o.ownerId}`;
  expect(before[0]!.n).toBe(0);
  await page.getByTestId('or-redeem-merch_kit').click();
  const form = page.getByTestId('or-redeem-form-merch_kit');
  await page.getByTestId('or-redeem-confirm-merch_kit').click();
  await expect(page.getByTestId('or-redeem-error-merch_kit')).toBeVisible();
  await page.getByTestId('or-name-merch_kit').fill('Olivia Premium-Featherstonehaugh');
  await page.getByTestId('or-line1-merch_kit').fill('1200 Bay Street');
  await page.getByTestId('or-city-merch_kit').fill('Toronto');
  await page.getByTestId('or-postal-merch_kit').fill('M5R 2A5');
  await widths(page, 'owner-rewards-redeem', info.project.name);
  await page.getByTestId('or-redeem-confirm-merch_kit').click();
  await expect(form).toBeHidden({ timeout: 30_000 });
  await expect(page.getByTestId('or-ms-state-merch_kit')).toContainText('Getting ready');
  const [req] = await sql`select id, status, ship_line1, ship_city, ship_postal_code from owner_reward_requests where owner_id = ${o.ownerId} and kind = 'merch_kit'`;
  expect(req!.status).toBe('requested');
  expect([req!.ship_line1, req!.ship_city]).toEqual(['1200 Bay Street', 'Toronto']);
  expect(String(req!.ship_postal_code).replace(/\s/g, '')).toBe('M5R2A5');
  // the Admins are told: the alert is in the queue
  const ev = await sql`select count(*)::int as n from app_events where payload ->> 'rule' = 'owner_merch_to_ship' and created_at > now() - interval '5 minutes'`;
  expect(ev[0]!.n).toBeGreaterThan(0);

  // notification preferences: a switch is saved; the locked kinds have no switch
  await page.goto('/owner/account?tab=notifications', { waitUntil: 'networkidle' });
  const prefs = page.getByTestId('np-owner-prefs');
  await expect(prefs).toBeVisible();
  const sw = page.getByTestId('np-owner-owner_new_bookings-email');
  await expect(sw).not.toBeChecked();
  const bookingNote = page.getByTestId('np-owner-booking-note-owner_new_bookings');
  await expect(bookingNote).not.toBeVisible();
  await sw.check();
  await expect(bookingNote).toBeVisible();
  await expect(bookingNote).toContainText('count on a booking only once it');
  await expect(page.getByTestId('np-owner-status')).toHaveText('Saved.');
  const [pref] = await sql`select email from notify_prefs where subject_kind = 'user' and subject_id = ${o.userId} and type = 'owner_new_bookings'`;
  expect(pref!.email).toBe(true);
  const locked = page.getByTestId('np-owner-locked');
  await expect(locked).toContainText('Always on');
  await expect(locked.locator('input[type="checkbox"]')).toHaveCount(0);
  await expect(page.getByTestId('np-owner-type-tracker_theft')).toBeVisible();
  await widths(page, 'owner-notifications', info.project.name);
  await page.getByTestId('np-owner-all-off').check();
  await expect(page.getByTestId('np-owner-status')).toHaveText('Every optional notification is off.');
  await page.getByTestId('np-owner-all-off').uncheck();
  await expect(page.getByTestId('np-owner-status')).toHaveText('Your own choices are back on.');

  // the Admin: the kit is on Owner rewards; marked shipped, the owner is emailed and sees Shipped
  const admin = await person(sql, 'Ada Rewards', 'admin');
  const ctx = await browser.newContext({ viewport: page.viewportSize() ?? undefined, hasTouch: info.project.name.startsWith('phone'), baseURL: info.project.use.baseURL });
  const ap = await ctx.newPage();
  await signIn(ap, admin.email, '/admin/owners/rewards');
  await expect(ap.getByRole('heading', { name: 'Owner rewards', level: 1 })).toBeVisible();
  await expect(ap.locator('body')).toContainText('1200 Bay Street');
  await widths(ap, 'admin-owner-rewards', info.project.name);
  // marked shipped as the Admin (app.owner_rewards_admin_do takes the Admin; the cost in cents)
  await sql`select app.owner_rewards_admin_do(${admin.id}, 'owner_reward_ship', ${sql.json({ id: req!.id, tracking: 'CP123456789CA', cost_cents: 4200 })})`;
  // the owner is told (the event is the owner's, owner_reward_notify)
  const mail = await sql`select count(*)::int as n from app_events where code = 'owner_reward_update' and created_at > now() - interval '5 minutes' and payload ->> 'owner_id' = ${o.ownerId}`;
  expect(mail[0]!.n).toBeGreaterThan(0);
  await ap.goto('/admin/settings/notifications', { waitUntil: 'networkidle' });
  await expect(ap.getByRole('heading', { name: 'Notification preferences', level: 1 })).toBeVisible();
  await widths(ap, 'admin-notification-preferences', info.project.name);
  await ap.goto('/admin/staff/rewards', { waitUntil: 'networkidle' });
  await expect(ap.getByRole('heading', { name: 'Staff rewards', level: 1 })).toBeVisible();
  await widths(ap, 'admin-staff-rewards', info.project.name);
  await ctx.close();

  await page.goto('/owner/rewards', { waitUntil: 'networkidle' });
  await expect(page.getByTestId('or-ms-state-merch_kit')).toContainText('Shipped');
  await expect(page.getByTestId('or-ms-merch_kit')).toContainText('CP123456789CA');
  expect(errors.filter((e) => !/favicon|Download the React DevTools/.test(e))).toEqual([]);
  await sql.end();
});

test('staff: My rewards for an in-person seller and for a remote one; their notification preferences', async ({ page, browser }, info) => {
  test.setTimeout(240_000);
  const sql = db();
  await sql`delete from app.rate_limit_hits`;
  const errors = watch(page);
  const here = await seller(sql, 'Sara Inperson', 'CA', 'in_person');
  const away = await seller(sql, 'Remo Remote', 'PH', 'remote');

  await signIn(page, here.email, '/staff');
  const card = page.getByTestId('my-rewards-card');
  await expect(card).toBeVisible();
  await expect(card).toContainText('15%');
  await widths(page, 'staff-home-my-rewards', info.project.name);
  await page.getByTestId('my-rewards-open').click();
  await page.waitForURL(/\/staff\/rewards/);
  await expect(page.getByTestId('my-rewards-code')).toHaveText(/\S{4,}/);
  await expect(page.getByTestId('my-rewards-rules')).toContainText('driver');
  await widths(page, 'staff-my-rewards', info.project.name);

  await page.goto('/staff/profile', { waitUntil: 'networkidle' });
  await expect(page.getByTestId('np-staff-prefs')).toBeVisible();
  const lockedStaff = page.getByTestId('np-staff-locked');
  await expect(lockedStaff.getByTestId('np-staff-type-staff_jobs')).toContainText('Always on');
  await page.getByTestId('np-staff-cadence-daily').check();
  await expect(page.getByTestId('np-staff-status')).toHaveText('Saved.');
  const [prof] = await sql`select cadence from notify_profiles where subject_kind = 'user' and subject_id = ${here.id}`;
  expect(prof!.cadence).toBe('daily');
  await widths(page, 'staff-notifications', info.project.name);

  const ctx = await browser.newContext({ viewport: page.viewportSize() ?? undefined, hasTouch: info.project.name.startsWith('phone'), baseURL: info.project.use.baseURL });
  const rp = await ctx.newPage();
  await signIn(rp, away.email, '/staff/rewards');
  await expect(rp.getByTestId('my-rewards-why')).toContainText(/in person|Canada/i);
  await expect(rp.getByTestId('my-rewards-code')).toHaveCount(0);
  await widths(rp, 'staff-my-rewards-remote', info.project.name);
  await ctx.close();
  expect(errors.filter((e) => !/favicon|Download the React DevTools/.test(e))).toEqual([]);
  await sql.end();
});

test('the content calendar: written, nothing queued until approved, approve schedules it, reject asks why', async ({ page }, info) => {
  test.setTimeout(300_000);
  const sql = db();
  await sql`delete from app.rate_limit_hits`;
  const errors = watch(page);
  const u = await seller(sql, 'Mara Marketing', 'CA', 'in_person');
  await signIn(page, u.email, '/staff/marketing/calendar');
  await expect(page.getByTestId('content-calendar')).toBeVisible();
  if (await page.getByTestId('cal-empty').count()) {
    await page.getByTestId('cal-write').first().click();
    await expect(page.getByTestId('cal-posts')).toBeVisible({ timeout: 90_000 });
  }
  const month = (await page.getByTestId('content-calendar').getAttribute('data-month')) ?? '';
  const drafts = await sql`select d.id, d.slot_no, d.format from social_drafts d where d.source = 'calendar' and d.status = 'draft' ${month ? sql`and to_char(d.month, 'YYYY-MM') = ${month.slice(0, 7)}` : sql``} order by d.slot_no`;
  expect(drafts.length).toBeGreaterThan(3);
  // nothing publishes without approval: no draft of the calendar has a place in the queue
  const early = await sql`select count(*)::int as n from social_queue q join social_drafts d on d.id = q.draft_id where d.source = 'calendar' and d.status = 'draft'`;
  expect(early[0]!.n).toBe(0);
  await widths(page, 'content-calendar', info.project.name);

  const photo = drafts.find((d) => d.format === 'photo') ?? drafts.find((d) => d.format !== 'reel')!;
  // 3701: only studio renders are public, and the seed's cars are examples, so a calendar written here may have no car photo
  // for its photo post (approving it is refused, rightly): the post gets a photo, as editing it to a car with photos would
  await sql`update social_drafts set photos = jsonb_build_array((select processed_path from vehicle_photos where processed_path like 'vehicles/%' and status = 'approved' order by processed_path limit 1))
            where id = ${photo.id} and jsonb_array_length(photos) = 0`;
  const post = page.getByTestId(`cal-post-${photo.slot_no}`);
  await post.scrollIntoViewIfNeeded();
  await page.getByTestId(`cal-approve-${photo.slot_no}`).click();
  const dialog = page.getByRole('dialog');
  await expect(dialog).toBeVisible();
  await dialog.getByRole('button', { name: 'Approve and schedule' }).click();
  await expect(page.getByTestId(`cal-post-${photo.slot_no}`)).toHaveAttribute('data-status', 'approved', { timeout: 30_000 });
  const queued = await sql`select channel, status, by_hand from social_queue where draft_id = ${photo.id}`;
  expect(queued.length).toBeGreaterThan(0);
  expect(queued.every((q) => q.status === 'queued' || q.status === 'scheduled')).toBe(true);
  await expect(page.getByTestId(`cal-queue-${photo.slot_no}`)).toBeVisible();

  const other = drafts.find((d) => d.id !== photo.id && d.format !== 'reel')!;
  await page.getByTestId(`cal-post-${other.slot_no}`).scrollIntoViewIfNeeded();
  await page.getByTestId(`cal-reject-${other.slot_no}`).click();
  const rd = page.getByRole('dialog');
  await rd.locator('textarea, input[type="text"]').first().fill('Too close to last week\'s post');
  await rd.locator('button[type="submit"]').click();
  await expect(page.getByTestId(`cal-post-${other.slot_no}`)).toHaveAttribute('data-status', 'rejected', { timeout: 30_000 });
  await expect(page.getByTestId(`cal-reason-${other.slot_no}`)).toContainText('Too close');
  const none = await sql`select count(*)::int as n from social_queue where draft_id = ${other.id}`;
  expect(none[0]!.n).toBe(0);
  await widths(page, 'content-calendar-decided', info.project.name);
  expect(errors.filter((e) => !/favicon|Download the React DevTools/.test(e))).toEqual([]);
  await sql.end();
});

// 3270, 3272: an Owner Booking's charge is billed to the owner (no card on file: due now with the pay link), the owner is
// told, the Admin sees it on the booking's Money tab and the owner sees the invoice in the portal.
test('owner-use charges: billed to the owner, the notice queued, on the Money tab and the owner\'s invoices', async ({ page, browser }, info) => {
  test.setTimeout(240_000);
  const sql = db();
  await sql`delete from app.rate_limit_hits`;
  const errors = watch(page);
  const o = await seedOwner(sql);
  const car = o.cars[1]!;
  const number = `OU-${Date.now().toString(36).toUpperCase()}`;
  const [renter] = await sql`select id from renters order by created_at limit 1`;
  const [b] = await sql`insert into bookings (booking_number, booking_type, status, vehicle_id, renter_id, owner_id, booked_at, pickup_at, return_at, original_return_at, billable_days,
      daily_rate_cents, weekend_rate_cents, weekly_rate_cents, monthly_rate_cents, rate_applied, daily_days, weekend_days, rental_charge_cents, discount_cents, km_allowance_per_day, km_allowance_total, overage_cents_per_km, deposit_cents,
      subtotal_at_booking_cents, hst_at_booking_cents, total_due_at_booking_cents)
    values (${number}, 'owner', 'returned', ${car.id}, ${renter!.id}, ${o.ownerId}, now() - interval '9 days', now() - interval '6 days', now() - interval '4 days', now() - interval '4 days', 2,
      0, 0, 0, 0, 'daily', 2, 0, 0, 0, 250, 500, 25, 0, 0, 0, 0) returning id`;
  await sql`insert into booking_line_items (booking_id, charge_type, description, quantity, unit_amount_cents, amount_cents, hst_applies, hst_cents, revenue_class, charged_to_renter, stage)
    select ${b!.id}, f.code, f.label, 1, 6500, 6500, f.hst_applies, case when f.hst_applies then public.calc_hst(6500) else 0 end, f.revenue_class, true, 'after_return' from fee_types f where f.code = 'fuel'`;
  await sql`update program_settings set fee_evidence_gate = false where id = (app.settings()).id`;
  const [bill] = await sql`select app.owner_use_bill(${b!.id}) as r`;
  expect((bill!.r as { collect?: string }).collect).toBe('pay_now');
  const [inv] = await sql`select id, invoice_number from owner_invoices where owner_use_booking_id = ${b!.id}`;
  // the notice is queued: the event, and the owner's in-app notice of it
  const [ev] = await sql`select count(*)::int as n from app_events where code = 'owner_use_charges' and entity_id = ${inv!.id}`;
  expect(ev!.n).toBeGreaterThan(0);

  const admin = await person(sql, 'Ada Owneruse', 'admin');
  await signIn(page, admin.email, `/admin/bookings/${number}`);
  await page.goto(`/admin/bookings/${number}?tab=money`, { waitUntil: 'networkidle' });
  const card = page.getByTestId('bm-owner-use');
  await expect(card).toBeVisible();
  await expect(card.getByTestId('bm-ou-invoice')).toContainText(inv!.invoice_number as string);
  await expect(card.getByTestId('bm-ou-state')).toHaveText('Waiting for the owner');
  await expect(card.getByTestId('bm-ou-text')).toContainText('deducted from the next statement');
  await widths(page, 'admin-owner-use-money', info.project.name);

  const op = await (await browser.newContext({ viewport: page.viewportSize() ?? undefined })).newPage();
  await signIn(op, o.email, '/owner/invoices');
  await expect(op.locator('body')).toContainText(inv!.invoice_number as string);
  await widths(op, 'owner-use-invoices', info.project.name);
  expect(errors.filter((e) => !/favicon|Download the React DevTools/.test(e))).toEqual([]);
  await sql.end();
});
