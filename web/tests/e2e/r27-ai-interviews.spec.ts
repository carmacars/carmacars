import AxeBuilder from '@axe-core/playwright';
import { expect, test, type Browser, type Page } from '@playwright/test';
import { createHmac, randomBytes, randomUUID, scryptSync } from 'node:crypto';
import { readFileSync } from 'node:fs';
import path from 'node:path';
import { acceptCookies, db, noOverflow, watch } from './helpers';

// Release 27 (migration 0380, docs/changes/2026-11-07-ai-interviews.md), at both widths, with the fake AI and the fake
// speech to text: a remote assistant applies and passes, gets "Start my interview" (the email too, never the booking
// link), agrees to the recording, answers out loud (a stand-in microphone whose recording the fake hears) and in writing,
// gets a follow-up after a vague answer, finishes; the interviews job transcribes nothing left and scores it; the Admin
// sees the recommendation, plays the answer and reads the transcript, and invites the candidate to a live call. Never the
// word "test" on the candidate's pages. Fictional people only.
const PW = 'correct horse battery';
type Sql = ReturnType<typeof db>;
const hash = (pw: string) => { const salt = randomBytes(16); return `scrypt$${salt.toString('base64')}$${scryptSync(pw, salt, 64).toString('base64')}`; };
const tag = () => randomBytes(3).toString('hex');
const quiet = (errors: string[]) => errors.filter((x) => !/favicon|Failed to load resource|net::ERR/.test(x));
const SPOKEN = 'I worked two years as a chat and phone agent for an internet provider in Texas, about sixty chats a day in Zendesk, with refunds, outages and billing questions every shift.';
const LONG = 'I have done this kind of work every day for two years for a company in the United States, with clear notes in the ticket, a reply inside fifteen minutes and the office told at once when something is unclear.';

async function check(page: Page, where: string) {
  await noOverflow(page);
  const r = await new AxeBuilder({ page: page as never }).withTags(['wcag2a', 'wcag2aa', 'wcag21a', 'wcag21aa']).analyze();
  expect(r.violations.filter((v) => v.impact === 'serious' || v.impact === 'critical').map((v) => `${where} ${v.id}: ${v.nodes.map((n) => n.target.join(' ')).slice(0, 3).join(', ')}`)).toEqual([]);
  const text = await page.locator('main').innerText();
  expect(text.match(/[–—]/)?.[0], `${where}: long dash`).toBeUndefined();
  expect(text, `${where}: a raw database error`).not.toMatch(/violates|constraint "|relation "|invalid input syntax/);
}
async function mkAdmin(sql: Sql) {
  const id = randomUUID(); const email = `r27.admin.${Date.now()}.${tag()}@example.test`;
  await sql`insert into local_auth.users (id, email, password_hash) values (${id}, ${email}, ${hash(PW)})`;
  await sql`insert into users (id, email, full_name) values (${id}, ${email}, 'Ada Admin')`;
  await sql`insert into user_roles (user_id, role) values (${id}, 'admin')`;
  return { id, email };
}
async function signIn(page: Page, email: string, next: string) {
  await page.goto(`/sign-in?next=${encodeURIComponent(next)}`, { waitUntil: 'networkidle' });
  await acceptCookies(page);
  await page.locator('input[type="email"]').fill(email);
  await page.locator('input[type="password"]').fill(PW);
  await page.getByRole('button', { name: 'Sign in' }).click();
  await page.waitForURL((u) => !u.pathname.startsWith('/sign-in'), { timeout: 120_000 });
}
function jobToken() {
  const env = readFileSync(path.join(process.cwd(), '.env.local'), 'utf8');
  return createHmac('sha256', /^LINK_SIGNING_KEY=(.*)$/m.exec(env)![1]!.trim()).update('carmacars-listing-worker-v1').digest('hex');
}
async function ctx(browser: Browser, phone: boolean) {
  const c = await browser.newContext({ viewport: phone ? { width: 375, height: 812 } : { width: 1440, height: 900 }, hasTouch: phone, baseURL: test.info().project.use.baseURL });
  // a stand-in microphone: the recording carries the words the fake speech to text "hears" (window.__say)
  await c.addInitScript(() => {
    const w = window as unknown as { __say: string; MediaRecorder: unknown };
    w.__say = '';
    class FakeRecorder {
      mimeType = 'audio/webm;codecs=opus'; state = 'inactive';
      ondataavailable: ((e: { data: Blob }) => void) | null = null; onstop: (() => void) | null = null;
      static isTypeSupported(t: string) { return t.startsWith('audio/webm'); }
      start() { this.state = 'recording'; }
      stop() {
        this.state = 'inactive';
        this.ondataavailable?.({ data: new Blob([`OggS${'.'.repeat(400)}FAKE-TRANSCRIPT:${w.__say}`], { type: 'audio/webm;codecs=opus' }) });
        this.onstop?.();
      }
    }
    w.MediaRecorder = FakeRecorder;
    Object.defineProperty(navigator, 'mediaDevices', { configurable: true, value: { getUserMedia: async () => ({ getTracks: () => [{ stop() {} }] }) } });
  });
  return c.newPage();
}
const VA_PASS = {
  schedule: 'Yes, I can work this schedule every week', pay: 'Yes, I understand the rate is firm and I accept it', internet: 'Fiber or cable, 25 Mbps or faster, plus a backup connection',
  speed: '80 down, 40 up', backup: 'A generator, inverter or power station', english: 'Fluent: I handle calls on my own every day', years: '5 years or more',
  experience: 'Five years billing North American clients at an accounting firm: invoices, statements, reconciliations and payouts every day, in Excel and QuickBooks.',
  tools: ['QuickBooks', 'Stripe'], social: ['Designing posts in Canva'], skills: 'Accuracy to the cent, spreadsheets, clear written English.',
  business: 'Rents cars to customers in Toronto',
  role: 'I will price the charges after each rental, settle deposits, match tolls to bookings, bill the owners on the 15th and build their statements and payouts for the 10th.',
  scenario: 'Change nothing, verify by a phone number we already have and wait for written approval', other_jobs: 'No, this would be my only job', clients: 'No',
  school: 'No', education: 'College degree', career: 'A long-term career, growing with one company', canada: 'Maybe', start: '2026-11-09'
};
async function answer(page: Page, a: Record<string, string | string[]>) {
  for (const [k, v] of Object.entries(a)) {
    const q = page.getByTestId(`q-${k}`);
    if (Array.isArray(v)) { for (const c of v) await q.getByText(c, { exact: true }).click(); }
    else if (await q.evaluate((el) => el.tagName === 'FIELDSET')) await q.getByText(v, { exact: true }).click();
    else await q.fill(v);
  }
}
async function noTestWord(page: Page, where: string) {
  expect((await page.locator('main').innerText()).match(/\b(test|tests|exam|quiz)\b/i)?.[0], `${where}: never a test`).toBeUndefined();
}

test('AI interview: apply, consent, answer out loud and typed, a follow-up, scored by the job; the Admin plays it and invites to a live call', async ({ browser }, info) => {
  test.setTimeout(420_000);
  const phone = info.project.name.startsWith('phone');
  const sql = db();
  await sql`delete from app.rate_limit_hits where key like 'hire:%'`;
  const a = await mkAdmin(sql);
  const email = `ivy.${tag()}@example.test`;
  await sql`update hiring_roles set active = true where slug = 'va-finance-billing'`;
  await sql`update program_settings set hiring_ai_interviews = true where id = (select id from app.settings())`;
  try {
    const page = await ctx(browser, phone);
    const errors = watch(page);

    // 1. apply and pass: the next step is the interview, by email too (never the booking link)
    await page.goto('/careers/va-finance-billing/apply?src=onlinejobs', { waitUntil: 'networkidle' });
    await acceptCookies(page);
    await page.getByTestId('ap-full_name').fill('Ivy Example');
    await page.getByTestId('ap-email').fill(email);
    await page.getByTestId('ap-phone').fill('+63 917 555 0142');
    await answer(page, VA_PASS);
    await page.getByTestId('ap-submit').click();
    await expect(page.getByTestId('apply-done')).toHaveAttribute('data-outcome', 'invited', { timeout: 60_000 });
    await expect(page.getByTestId('apply-interview')).toBeVisible();
    await expect(page.getByTestId('apply-book')).toHaveCount(0);
    await check(page, 'apply done');
    await expect.poll(async () => { await sql`select app.process_events(1000)`; return (await sql`select count(*)::int n from notification_outbox where code = 'applicant_ai_interview' and to_address = ${email}`)[0]!.n; }, { timeout: 30_000 }).toBe(1);
    expect((await sql`select count(*)::int n from notification_outbox where code = 'applicant_invited' and to_address = ${email}`)[0]!.n).toBe(0);
    const [app] = await sql`select id, token from job_applications where email = ${email}`;

    // the booking link opens the interview
    await page.goto(`/careers/book/${app!.token}`, { waitUntil: 'networkidle' });
    await page.waitForURL(/\/careers\/interview\//);

    // 2. the consent before anything is recorded
    await expect(page.getByTestId('iv-intro')).toBeVisible();
    await expect(page.getByTestId('iv-consent')).toContainText('This interview is recorded');
    await expect(page.getByTestId('iv-start')).toBeDisabled();
    await check(page, 'interview intro');
    await noTestWord(page, 'interview intro');
    await page.getByTestId('iv-agree').check();
    await page.getByTestId('iv-start').click();
    await expect(page.getByTestId('iv-question')).toHaveAttribute('data-seq', '1', { timeout: 30_000 });
    expect((await sql`select consent_at from ai_interviews where application_id = ${app!.id}`)[0]!.consent_at).not.toBeNull();

    // 3. question 1 out loud: record, stop, listen back, send; the fake hears it
    await page.evaluate((s) => { (window as unknown as { __say: string }).__say = s; }, SPOKEN);
    await page.getByTestId('iv-record').click();
    await expect(page.getByTestId('iv-stop')).toBeVisible();
    await check(page, 'recording');
    await page.getByTestId('iv-stop').click();
    await expect(page.getByTestId('iv-send')).toBeVisible();
    await page.getByTestId('iv-send').click();
    await expect(page.getByTestId('iv-question')).toHaveAttribute('data-seq', '2', { timeout: 60_000 });
    const [w1] = await sql`select w.audio_key, w.transcript, w.transcript_state from ai_interview_answers w join ai_interviews i on i.id = w.interview_id where i.application_id = ${app!.id} and w.seq = 1`;
    expect(w1!.audio_key).toMatch(/^hiring\/interviews\/[0-9a-f-]+\/1-[a-z0-9]+\.webm$/);
    expect(`${w1!.transcript_state}: ${w1!.transcript}`).toBe(`done: ${SPOKEN}`);

    // 4. question 2 typed and vague: a follow-up comes next
    await page.getByTestId('iv-toggle').click();
    await page.getByTestId('iv-typed').fill('Excel.');
    await page.getByTestId('iv-send-typed').click();
    await expect(page.getByTestId('iv-question')).toHaveAttribute('data-kind', 'followup', { timeout: 60_000 });
    await expect(page.getByTestId('iv-text')).toContainText('specific example');
    await check(page, 'follow-up');
    await noTestWord(page, 'follow-up');
    await page.getByTestId('iv-typed').fill(LONG);
    await page.getByTestId('iv-send-typed').click();
    await expect(page.getByTestId('iv-question')).toHaveAttribute('data-seq', '4', { timeout: 60_000 });
    await expect(page.getByTestId('iv-question')).toHaveAttribute('data-kind', 'question');

    // 5. the other seven typed, in full: no more follow-ups; then done
    for (let i = 0; i < 7; i++) {
      await page.getByTestId('iv-typed').fill(LONG);
      await page.getByTestId('iv-send-typed').click();
      if (i < 6) await expect(page.getByTestId('iv-question')).toHaveAttribute('data-seq', String(5 + i), { timeout: 60_000 });
    }
    await expect(page.getByTestId('iv-done')).toBeVisible({ timeout: 60_000 });
    await check(page, 'interview done');
    const [st] = await sql`select a.status, i.state, (select count(*)::int from ai_interview_answers w where w.interview_id = i.id) n from job_applications a join ai_interviews i on i.application_id = a.id where a.id = ${app!.id}`;
    expect(`${st!.status}/${st!.state}/${st!.n}`).toBe('interviewed/submitted/10');

    // 6. the interviews job scores it (the fake model), and the AI decides nothing
    const token = jobToken();
    await expect.poll(async () => {
      await page.request.post('/api/jobs/interviews', { headers: { authorization: `Bearer ${token}` } });
      return (await sql`select state from ai_interviews where application_id = ${app!.id}`)[0]!.state;
    }, { timeout: 120_000, intervals: [1000, 2000, 3000] }).toBe('scored');
    expect((await page.request.post('/api/jobs/interviews')).status()).toBe(403);
    const [r] = await sql`select recommendation, interview_score, result from ai_interviews where application_id = ${app!.id}`;
    expect(['live_call', 'hire', 'decline', 'sales']).toContain(r!.recommendation);
    expect((await sql`select status from job_applications where id = ${app!.id}`)[0]!.status).toBe('interviewed');
    expect((await sql`select count(*)::int n from hiring_decisions where application_id = ${app!.id}`)[0]!.n).toBe(0);

    // 7. the Admin: the recommendation, the recording and the transcript; Invite to a live call
    await signIn(page, a.email, `/admin/hiring/${app!.id}`);
    await page.goto(`/admin/hiring/${app!.id}`, { waitUntil: 'networkidle' });
    await expect(page.getByTestId('cand-ai-rec')).toContainText('AI recommends');
    await expect(page.getByTestId('cand-ai-topics')).toBeVisible();
    await expect(page.getByTestId('cand-ai-answers')).toContainText(SPOKEN);
    await expect(page.getByTestId('cand-ai-answers')).toContainText('Follow-up');
    await expect(page.getByTestId('cand-ai-hint')).toContainText('You decide');
    const src = await page.getByTestId('cand-ai-audio').first().getAttribute('src');
    expect(src).toBeTruthy();
    const audio = await page.request.get(src!, { headers: { range: 'bytes=0-9' } });
    expect(audio.status()).toBe(206);
    expect(audio.headers()['content-type']).toBe('audio/webm');
    await check(page, 'candidate');
    await page.goto(`/admin/hiring?tab=pipeline&role=va-finance-billing`, { waitUntil: 'networkidle' });
    await expect(page.getByTestId(`app-ai-${app!.id}`)).toContainText('AI interview done');
    await check(page, 'applications');
    await page.goto(`/admin/hiring/${app!.id}`, { waitUntil: 'networkidle' });
    await page.getByTestId('cand-ai-live').click();
    await page.getByTestId('cand-ai-live-submit').click();
    await expect(page.getByTestId('cand-ai-live-sent')).toBeVisible({ timeout: 30_000 });
    expect((await sql`select status from job_applications where id = ${app!.id}`)[0]!.status).toBe('invited');
    await page.goto('/admin/hiring?tab=roles', { waitUntil: 'networkidle' });
    await expect(page.getByTestId('hiring-ai-setting')).toContainText('On');
    await check(page, 'roles');
    expect(quiet(errors)).toEqual([]);
    await sql`update job_applications set status = 'withdrawn' where id = ${app!.id}`;
  } finally {
    await sql`update hiring_roles set active = false where slug = 'va-finance-billing'`;
    await sql.end();
  }
});
