import AxeBuilder from '@axe-core/playwright';
import { expect, test, type Page } from '@playwright/test';
import { randomBytes } from 'node:crypto';
import { acceptCookies, db, noOverflow, watch } from './helpers';

// Migration 0344 end to end, at 375 and 1440: the owner application starts with the name, mobile and email and the car
// (here handed over by the owner earnings calculator: its car and estimate). What is typed becomes an owner lead in the
// pipeline as they go; left unfinished it is chased, and the "finish your application" email's link opens the saved
// draft on another device. Every screen is checked with axe and for overflow and long dashes.
const tag = () => randomBytes(3).toString('hex');
async function check(page: Page, where: string) {
  await noOverflow(page);
  const r = await new AxeBuilder({ page: page as never }).withTags(['wcag2a', 'wcag2aa', 'wcag21a', 'wcag21aa']).analyze();
  const bad = r.violations.filter((v) => v.impact === 'serious' || v.impact === 'critical');
  expect(bad.map((v) => `${where} ${v.id}: ${v.nodes.map((n) => n.target.join(' ')).slice(0, 3).join(', ')}`)).toEqual([]);
  expect((await page.locator('body').innerText()).match(/[—–]/)?.[0], `${where}: long dash`).toBeUndefined();
}
const benign = (e: string) => /Failed to load resource|favicon|the server responded/.test(e);

test('owner application: the first step makes a lead as they type; unfinished, the emailed link opens the draft', async ({ page, browser }) => {
  test.setTimeout(240_000);
  const sql = db();
  await sql`delete from app.rate_limit_hits`;
  const t = tag();
  const email = `r26start.${t}@example.test`;
  // a number of its own: the lead is matched by email and phone
  const mobile = `416-${String(200 + (parseInt(t.slice(0, 2), 16) % 700)).padStart(3, '0')}-${String(parseInt(t.slice(2), 16) % 10000).padStart(4, '0')}`;
  const errors = watch(page);
  await page.goto('/list-your-car/apply?year=2021&make=Toyota&model=RAV4&est=145000', { waitUntil: 'networkidle' });
  await acceptCookies(page);
  const start = page.getByTestId('apply-start');
  await expect(start).toBeVisible({ timeout: 30_000 });
  await expect(start).toContainText('So we can save your progress and send your quote. We keep your details private.');
  await expect(page.getByTestId('apply-calc')).toContainText('2021 Toyota RAV4');
  // nothing typed: each field says what it needs
  await start.getByTestId('apply-start-next').click();
  await expect(start.getByText('Enter your first name.')).toBeVisible();
  await expect(start.getByText('Enter your mobile number', { exact: false })).toBeVisible();
  await check(page, 'first step, errors');
  await start.getByTestId('apply-first').fill('Rita');
  await start.getByTestId('apply-last').fill(`Start ${t}`);
  await start.getByTestId('apply-phone').fill(mobile);
  await start.getByTestId('apply-email').fill(email);
  await start.getByTestId('apply-first').click();
  await check(page, 'first step, filled');
  // the lead appears as they type (the capture after a field is left, the draft after a pause)
  let lead: { id: string; kind: string; pipeline_source: string; vehicle_text: string | null; est: string | null; draft: string | null } | undefined;
  for (let i = 0; i < 40 && !(lead?.vehicle_text && lead?.draft); i++) {
    [lead] = await sql`select id, kind, pipeline_source, vehicle_text, payload #>> '{calculator,estimate_cents}' est, payload ->> 'draft_id' draft
                         from leads where lower(email) = ${email} order by created_at desc limit 1`;
    if (!(lead?.vehicle_text && lead?.draft)) await page.waitForTimeout(500);
  }
  expect([lead?.kind, lead?.pipeline_source, lead?.vehicle_text, lead?.est]).toEqual(['owner_program', 'unfinished_form', '2021 Toyota RAV4', '145000']);
  await start.getByTestId('apply-start-next').click();
  await expect(page.getByTestId('apply-you')).toContainText(`Rita Start ${t}`);
  await check(page, 'about you after the first step');
  await expect(page.getByTestId('autosave')).toContainText('Saved', { timeout: 20_000 });
  await page.waitForTimeout(1500);

  // left unfinished: chased, and the email's link opens the draft on another device
  await sql`alter table form_drafts disable trigger form_drafts_before_write`;
  await sql`update form_drafts set updated_at = now() - interval '31 minutes' where id = ${lead!.draft!}::uuid`;
  await sql`alter table form_drafts enable trigger form_drafts_before_write`;
  await sql`update contact_captures set last_at = now() - interval '31 minutes' where lead_id = ${lead!.id}::uuid`;
  await sql`select app.owner_unfinished_chase()`;
  await sql`select app.owner_followup_send(${lead!.id}::uuid)`;
  const [mail] = await sql`select payload ->> 'subject_line' subject, payload ->> 'message_body' body from notification_outbox
                             where entity_id = ${lead!.id}::uuid and code = 'owner_recruit_outreach' order by created_at desc limit 1`;
  expect(mail!.subject).toBe('Finish your application to list 2021 Toyota RAV4');
  const link = /\/list-your-car\/apply\/resume\?t=[\w-]+/.exec(mail!.body)?.[0];
  expect(link).toBeTruthy();
  const other = await browser.newContext({ viewport: page.viewportSize() ?? undefined, baseURL: test.info().project.use.baseURL });
  const p2 = await other.newPage();
  const errors2 = watch(p2);
  await p2.goto(link!, { waitUntil: 'networkidle' });
  await acceptCookies(p2);
  await expect(p2.getByTestId('resumed')).toBeVisible({ timeout: 30_000 });
  await expect(p2.getByTestId('apply-you')).toContainText(`Rita Start ${t}`);
  await check(p2, 'resumed on another device');
  expect([...errors, ...errors2].filter((e) => !benign(e))).toEqual([]);
  await other.close();
  await sql.end();
});
