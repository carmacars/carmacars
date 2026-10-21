import AxeBuilder from '@axe-core/playwright';
import { expect, test, type Page } from '@playwright/test';
import { randomBytes, randomUUID, scryptSync } from 'node:crypto';
import { acceptCookies, db, noOverflow } from './helpers';

// Migration 0078 end to end, at 375 and 1440: Admin > Today lists each piece of work as one line (what to do, why) whose
// pop-up does it in place, pre-filled: Insurer confirmed (one car, several at once, and on the car's checklist), rates and
// Publish now, renter documents, a payment received another way, a paper signature, an official form, a chat waiting, an
// assistant task while no assistant holds the function. Each line is gone once its work is done.
const PW = 'correct horse battery';
const hash = (pw: string) => { const salt = randomBytes(16); return `scrypt$${salt.toString('base64')}$${scryptSync(pw, salt, 64).toString('base64')}`; };
const tag = () => randomBytes(3).toString('hex');
type Sql = ReturnType<typeof db>;
const PDF = Buffer.from('%PDF-1.4\n1 0 obj<</Type/Catalog/Pages 2 0 R>>endobj 2 0 obj<</Type/Pages/Kids[3 0 R]/Count 1>>endobj 3 0 obj<</Type/Page/Parent 2 0 R/MediaBox[0 0 612 792]>>endobj\ntrailer<</Root 1 0 R>>\n%%EOF\n');

async function check(page: Page, where: string) {
  await noOverflow(page);
  const r = await new AxeBuilder({ page: page as never }).withTags(['wcag2a', 'wcag2aa', 'wcag21a', 'wcag21aa']).analyze();
  expect(r.violations.filter((v) => v.impact === 'serious' || v.impact === 'critical').map((v) => `${where} ${v.id}`)).toEqual([]);
  expect((await page.locator('body').innerText()).match(/[\u2014\u2013]/)?.[0], `${where}: long dash`).toBeUndefined();
}
async function admin(sql: Sql) {
  const id = randomUUID(); const email = `ga.admin.${Date.now()}.${tag()}@example.test`;
  await sql`insert into local_auth.users (id, email, password_hash) values (${id}, ${email}, ${hash(PW)})`;
  await sql`insert into users (id, email, full_name) values (${id}, ${email}, 'Gia Admin')`;
  await sql`insert into user_roles (user_id, role) values (${id}, 'admin')`;
  return { id, email };
}
async function signIn(page: Page, email: string) {
  await page.goto('/sign-in', { waitUntil: 'networkidle' });
  await acceptCookies(page);
  await page.locator('input[type="email"]').fill(email);
  await page.locator('input[type="password"]').fill(PW);
  await page.getByRole('button', { name: 'Sign in' }).click();
  await page.waitForURL((u) => u.pathname.startsWith('/admin'), { timeout: 20_000 });
}
async function owner(sql: Sql, name: string) {
  const [o] = await sql`insert into owners (owner_type, legal_name, status, email, phone) values ('individual', ${name}, 'active', ${`ga.owner.${tag()}@example.test`}, '416-555-0100') returning id`;
  return o!.id as string;
}
// a program owner's car in onboarding at a step (terms set: the insurer may confirm it)
async function onboardingCar(sql: Sql, ownerId: string, step = 'terms_set') {
  const id = randomUUID(); const model = `Jetta ${tag().toUpperCase()}`;
  await sql`insert into vehicles (id, owner_id, year, make, model, vin, plate, class, status, management_mode, onboarding_method, on_fleet_policy)
            values (${id}, ${ownerId}, 2021, 'Volkswagen', ${model}, ${('GA' + randomBytes(8).toString('hex').toUpperCase()).slice(0, 17)}, ${'GA' + tag().toUpperCase()},
                    'standard', 'onboarding', 'managed', 'transfer', false)`;
  await sql`insert into vehicle_onboardings (vehicle_id, status, terms_set_at) values (${id}, ${step}, now() - interval '3 days')`;
  return { id, name: `2021 Volkswagen ${model}` };
}
const prompt = (page: Page, key: string) => page.getByTestId(`prompt-${key}`);
async function today(page: Page) { await page.goto('/admin', { waitUntil: 'networkidle' }); await expect(page.getByTestId('todo-prompts')).toBeVisible(); }

test('Insurer confirmed: from Today for one car, for several at once, and on the car checklist', async ({ page }) => {
  test.setTimeout(150_000);
  const sql = db();
  const a = await admin(sql);
  const o = await owner(sql, `Ida Insured ${tag()}`);
  const one = await onboardingCar(sql, o);
  const two = await onboardingCar(sql, o, 'documents_sent');
  const three = await onboardingCar(sql, o);
  const four = await onboardingCar(sql, o);
  await signIn(page, a.email);
  await today(page);
  const line = prompt(page, `insurer:${one.id}`);
  await expect(line).toContainText(`Insurer has not confirmed ${one.name}: mark it insured`);
  await expect(line).toContainText('cannot be handed over');
  await check(page, 'Today');
  // one car: the pop-up, pre-filled with today's date
  await line.getByTestId(`todo-act-insurer:${one.id}`).click();
  const form = page.getByTestId(`todo-act-insurer:${one.id}-form`);
  await expect(form.locator('input[type="date"]')).toHaveValue(/\d{4}-\d{2}-\d{2}/);
  await check(page, 'Insurer confirmed pop-up');
  await form.getByRole('textbox', { name: /Reference/ }).fill('Broker email');
  await page.getByTestId(`todo-act-insurer:${one.id}-submit`).click();
  await expect(prompt(page, `insurer:${one.id}`)).toHaveCount(0, { timeout: 20_000 });
  const [v1] = await sql`select v.on_fleet_policy p, v.enrollment_date is not null e, ob.status::text s from vehicles v join vehicle_onboardings ob on ob.vehicle_id = v.id where v.id = ${one.id}`;
  expect([v1!.p, v1!.e, v1!.s]).toEqual([true, true, 'enrolled']);
  // several at once: untick one car, confirm the others
  await expect(prompt(page, 'insurer_bulk')).toBeVisible();
  await page.getByTestId('insurer-bulk').click();
  const dlg = page.getByTestId('insurer-bulk-dialog');
  await expect(dlg.getByTestId(`insurer-bulk-car-${two.id}`)).toBeChecked();
  await dlg.getByTestId(`insurer-bulk-car-${four.id}`).uncheck();
  await check(page, 'Insurer confirmed, several cars');
  // only this test's cars: untick any other car waiting on the shared database
  for (const box of await dlg.locator('input[type="checkbox"]').all()) {
    const tid = await box.getAttribute('data-testid');
    if (tid && ![two.id, three.id].some((x) => tid.endsWith(x))) await box.uncheck();
  }
  await dlg.getByTestId('insurer-bulk-submit').click();
  await expect(prompt(page, `insurer:${two.id}`)).toHaveCount(0, { timeout: 20_000 });
  await expect(prompt(page, `insurer:${three.id}`)).toHaveCount(0);
  await expect(prompt(page, `insurer:${four.id}`)).toBeVisible();
  // on the car itself: the checklist item has the button
  await page.goto(`/admin/vehicles/${four.id}?tab=listing`, { waitUntil: 'networkidle' });
  await expect(page.getByTestId('check-insurance')).toContainText('press Insurer confirmed');
  await page.getByTestId('checklist-insurer-confirm').click();
  await check(page, 'car checklist pop-up');
  await page.getByTestId('checklist-insurer-confirm-submit').click();
  await expect(page.getByTestId('check-insurance')).toHaveCount(0, { timeout: 20_000 });
  expect((await sql`select count(*)::int n from vehicles where id in (${two.id}, ${three.id}, ${four.id}) and on_fleet_policy`)[0]!.n).toBe(3);
  await sql.end();
});

test('a real car not on the site: rates and Publish now in one pop-up, the suggested rate filled in', async ({ page }) => {
  test.setTimeout(120_000);
  const sql = db();
  const a = await admin(sql);
  const id = randomUUID(); const model = `Civic ${tag().toUpperCase()}`;
  await sql`insert into vehicles (id, year, make, model, vin, plate, class, status, management_mode, onboarding_method, on_fleet_policy, supply_type)
            values (${id}, 2020, 'Honda', ${model}, ${('GP' + randomBytes(8).toString('hex').toUpperCase()).slice(0, 17)}, ${'GP' + tag().toUpperCase()}, 'standard', 'ready_to_list', 'managed', 'none', true, 'company')`;
  await signIn(page, a.email);
  await today(page);
  const line = prompt(page, `publish:${id}`);
  await expect(line).toContainText(`2020 Honda ${model} is not on the site: check its rates and publish it`);
  await line.getByTestId(`todo-act-publish:${id}`).click();
  const form = page.getByTestId(`todo-act-publish:${id}-form`);
  await expect(form.getByRole('textbox', { name: /Daily rate/ })).not.toHaveValue('');
  await expect(form).toContainText('Suggested:');
  await check(page, 'publish pop-up');
  await form.getByRole('textbox', { name: /Daily rate/ }).fill('61');
  await page.getByTestId(`todo-act-publish:${id}-submit`).click();
  await expect(prompt(page, `publish:${id}`)).toHaveCount(0, { timeout: 20_000 });
  const [l] = await sql`select l.status::text s, (select daily_rate_cents from rate_cards r where r.vehicle_id = l.vehicle_id and r.effective_to is null) d from vehicle_listings l where l.vehicle_id = ${id}`;
  expect([l!.s, Number(l!.d)]).toEqual(['published', 6100]);
  // off the shared fleet again for the other specs
  await sql`update vehicle_listings set status = 'unpublished', unpublished_at = now(), unpublished_reason = 'e2e' where vehicle_id = ${id}`;
  await sql.end();
});

test('renter documents: the proof of coverage approved in the pop-up from Today, and the review card on the booking', async ({ page }) => {
  test.setTimeout(120_000);
  const sql = db();
  const a = await admin(sql);
  const [b] = await sql`select b.id, b.booking_number, r.user_id from bookings b join renters r on r.id = b.renter_id
                         where b.status = 'confirmed' and b.pickup_at > now() + interval '1 day' and r.user_id is not null and b.booking_type <> 'owner'
                           and not exists (select 1 from coverage_proofs c where c.booking_id = b.id and c.status in ('submitted', 'confirmed'))
                         order by random() limit 1`;
  test.skip(!b, 'no confirmed booking to use');
  await sql`update bookings set coverage_option = 1, coverage_confirmed_at = null where id = ${b!.id}`;
  await sql`select app.register_verification_upload(${b!.id}, ${b!.user_id}, 'coverage_proof', null, ${`renters/ga/${tag()}.pdf`}, ${tag()}, 'application/pdf',
              jsonb_build_object('coverage_option', 1, 'insurer_name', 'Maple Mutual', 'policy_number', 'MM-77', 'policy_expiry', (select app.local_date(return_at) + 60 from bookings where id = ${b!.id})))`;
  await signIn(page, a.email);
  await page.goto(`/admin/bookings/${b!.booking_number}?tab=overview`, { waitUntil: 'networkidle' });
  await expect(page.getByTestId('booking-doc-review')).toContainText('the proof of coverage');
  await today(page);
  const line = prompt(page, `documents:${b!.id}`);
  await expect(line).toContainText(`documents for booking ${b!.booking_number}`);
  await line.getByTestId('doc-review-open').click();
  const dlg = page.getByTestId('doc-review-dialog').filter({ visible: true });
  await expect(dlg.getByTestId('doc-review-coverage')).toContainText('Maple Mutual');
  await check(page, 'document review pop-up');
  await expect(dlg.getByTestId('coverage-approve')).toBeDisabled();
  for (const c of await dlg.getByTestId('doc-review-coverage').locator('input[type="checkbox"]').all()) await c.check();
  await dlg.getByTestId('coverage-approve').click();
  await expect.poll(async () => (await sql`select coverage_confirmed_at is not null c from bookings where id = ${b!.id}`)[0]!.c, { timeout: 20_000 }).toBe(true);
  await page.goto('/admin', { waitUntil: 'networkidle' });
  await expect(prompt(page, `documents:${b!.id}`)).toHaveCount(0);
  await sql.end();
});

test('owner money and paperwork: a payment received by e-Transfer and a paper signature, each in its pop-up', async ({ page }) => {
  test.setTimeout(150_000);
  const sql = db();
  const a = await admin(sql);
  const o = await owner(sql, `Pat Paper ${tag()}`);
  const car = await onboardingCar(sql, o, 'documents_sent');
  await sql`update vehicle_onboardings set documents_sent_at = now() - interval '3 days' where vehicle_id = ${car.id}`;
  await sql`insert into owner_agreements (owner_id, kind, agreement_number, agreement_date, status) values (${o}, 'enrollment', ${`EA-GA-${tag()}`}, current_date, 'sent')`;
  const [inv] = await sql`insert into owner_invoices (owner_id, vehicle_id, kind, billing_date, status, fees_cents, issued_at) values (${o}, ${car.id}, 'upfront', current_date, 'issued', 60000, now()) returning id, invoice_number, balance_cents`;
  await signIn(page, a.email);
  await today(page);
  const pay = prompt(page, `invoice:${inv!.id}`);
  await expect(pay).toContainText(`${inv!.invoice_number} from`);
  await expect(pay).toContainText('Record it if paid by e-Transfer, cash or cheque');
  await pay.getByTestId(`todo-act-invoice:${inv!.id}`).click();
  const pd = page.getByTestId(`todo-act-invoice:${inv!.id}-dialog`);
  await expect(pd.getByTestId('manual-payment-form')).toBeVisible();
  await check(page, 'record payment pop-up');
  await pd.getByLabel('Reference').fill('ET-998877');
  await pd.getByRole('button', { name: 'Record payment' }).click();
  await expect.poll(async () => (await sql`select status::text s from owner_invoices where id = ${inv!.id}`)[0]!.s, { timeout: 20_000 }).toBe('paid');
  await page.goto('/admin', { waitUntil: 'networkidle' });
  await expect(prompt(page, `invoice:${inv!.id}`)).toHaveCount(0);
  // the paper signature
  const paper = prompt(page, `paper:${o}`);
  await expect(paper).toContainText('record a paper signature if they signed on paper');
  await paper.getByTestId(`todo-act-paper:${o}`).click();
  const sd = page.getByTestId(`todo-act-paper:${o}-dialog`);
  await expect(sd.getByTestId('paper-signature-form')).toBeVisible();
  await expect(sd.getByLabel('Signed by')).toHaveValue(/Pat Paper/);
  await check(page, 'paper signature pop-up');
  await sd.getByLabel('Scan of the signed document').setInputFiles({ name: 'signed.pdf', mimeType: 'application/pdf', buffer: PDF });
  await sd.getByRole('button', { name: 'Record signature' }).click();
  await expect(sd.getByTestId('paper-signature-done')).toBeVisible({ timeout: 20_000 });
  expect((await sql`select count(*)::int n from paper_signatures where target_id = ${o} and voided_at is null`)[0]!.n).toBeGreaterThan(0);
  await sql.end();
});

test('a chat waiting for a person opens the chat; an assistant task with nobody to do it comes to the Admin and closes from its pop-up', async ({ page }) => {
  test.setTimeout(120_000);
  const sql = db();
  const a = await admin(sql);
  const [c] = await sql`insert into chat_conversations (visitor_id, name, status, human_requested_at, human_reason) values (${randomUUID()}, ${`Gus ${tag()}`}, 'waiting', now(), 'price question') returning id, number`;
  const staffed = (await sql`select app.va_function_staffed('cs') s`)[0]!.s as boolean;
  const [t] = await sql`select app.raise_task(p_type => 'check_owner_document', p_title => ${`Check an owner document ${tag()}`}, p_dedupe => ${`ga:${tag()}`}) id`;
  await signIn(page, a.email);
  await today(page);
  await expect(prompt(page, `chat:${c!.id}`)).toContainText(`asked for a person in live chat ${c!.number}: reply`);
  if (!staffed) {
    const line = prompt(page, `task:${t!.id}`);
    await expect(line).toContainText('no assistant holds that function yet');
    await line.getByTestId(`todo-act-task:${t!.id}`).click();
    await check(page, 'task pop-up');
    await page.getByTestId(`todo-act-task:${t!.id}-done`).click();
    await page.getByTestId(`todo-act-task:${t!.id}-done-submit`).click();
    await expect(prompt(page, `task:${t!.id}`)).toHaveCount(0, { timeout: 20_000 });
  }
  await prompt(page, `chat:${c!.id}`).getByTestId(`todo-act-chat:${c!.id}`).click();
  await page.waitForURL((u) => u.pathname === '/admin/chat' && u.searchParams.get('id') === c!.id);
  await sql`update chat_conversations set status = 'closed' where id = ${c!.id}`;
  await sql.end();
});

test('an owner who paid another way: the first and last month recorded per car, a draft voided; the terms agreed entered in their pop-up', async ({ page }) => {
  test.setTimeout(150_000);
  const sql = db();
  const a = await admin(sql);
  const o = await owner(sql, `Fay Firstlast ${tag()}`);
  const car = await onboardingCar(sql, o);
  const [inv] = await sql`insert into owner_invoices (owner_id, vehicle_id, kind, billing_date, status, fees_cents) values (${o}, ${car.id}, 'upfront', current_date, 'issued', 80000) returning id`;
  await sql`update owner_invoices set status = 'void', voided_at = now() where id = ${inv!.id}`;
  const [draft] = await sql`insert into owner_invoices (owner_id, vehicle_id, kind, billing_date, status, fees_cents) values (${o}, ${car.id}, 'upfront', current_date, 'draft', 60000) returning id, invoice_number`;
  await signIn(page, a.email);
  await today(page);
  const line = prompt(page, `first_last_paid:${o}`);
  await expect(line).toContainText('Record the first and last month paid by Fay Firstlast');
  await line.getByTestId(`todo-act-first_last_paid:${o}`).click();
  const dlg = page.getByTestId(`todo-act-first_last_paid:${o}-dialog`);
  await expect(dlg.getByTestId(`todo-act-first_last_paid:${o}-draft`)).toContainText(draft!.invoice_number as string);
  await check(page, 'first and last month pop-up');
  await dlg.getByLabel(`${car.name} ($)`).fill('678');
  await dlg.getByLabel('Reference').fill('ET-55');
  await dlg.getByTestId(`todo-act-first_last_paid:${o}-draft-void`).check();
  await dlg.getByTestId(`todo-act-first_last_paid:${o}-submit`).click();
  await expect(prompt(page, `first_last_paid:${o}`)).toHaveCount(0, { timeout: 20_000 });
  const [paid] = await sql`select i.total_cents::int t, (select count(*)::int from vehicle_prepaids p where p.vehicle_id = ${car.id}) pre from owner_invoices i where i.vehicle_id = ${car.id} and i.status = 'paid'`;
  expect([paid!.t, paid!.pre]).toEqual([67800, 2]);
  expect((await sql`select status::text s from owner_invoices where id = ${draft!.id}`)[0]!.s).toBe('void');
  // the terms agreed
  const terms = prompt(page, `terms:${o}`);
  await expect(terms).toContainText('Enter the terms agreed with Fay Firstlast');
  await terms.getByTestId(`todo-act-terms:${o}`).click();
  const td = page.getByTestId(`todo-act-terms:${o}-dialog`);
  const share = td.getByLabel('Management fee (Revenue Share) (%)').first();
  await expect(share).not.toHaveValue('');
  await check(page, 'terms pop-up');
  await share.fill('27.5');
  await td.getByTestId(`todo-act-terms:${o}-submit`).click();
  await expect(prompt(page, `terms:${o}`)).toHaveCount(0, { timeout: 20_000 });
  expect((await sql`select revenue_share_bps n from owner_terms where owner_id = ${o} and vehicle_id = ${car.id}`)[0]!.n).toBe(2750);
  await sql.end();
});
