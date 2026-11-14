import AxeBuilder from '@axe-core/playwright';
import { expect, test, type Browser, type Page } from '@playwright/test';
import { createHmac, randomBytes, randomUUID, scryptSync } from 'node:crypto';
import { readFileSync } from 'node:fs';
import path from 'node:path';
import { acceptCookies, db, noOverflow, watch } from './helpers';

// Release 27 (migration 0380, docs/changes/2026-11-07-ai-interviews.md) and release 30 (migration 0585, video), at both
// widths, with the fake AI and the fake speech to text, in a Chrome with a fake camera and microphone (its own browser,
// launched with --use-fake-device-for-media-stream): a remote assistant applies and passes, gets "Start my interview"
// (the email too, never the booking link), agrees to the video recording, checks the camera and the microphone (the
// preview and the level), then answers every question on video: the question is read, the clock starts, Record, Stop
// and send (the video and its audio track uploaded to private storage); one answer is left to run to 0:00, where the
// clock turns red, recording stops by itself and the answer goes. A follow-up after a vague answer. The interviews job
// transcribes and scores it; the Admin sees the recommendation, plays each video (a byte range, video/webm), watches
// them all, reads the transcript, sees the interview settings, and invites the candidate to a live call. Never the word
// "test" on the candidate's pages. Fictional people only.
const PW = 'correct horse battery';
type Sql = ReturnType<typeof db>;
const hash = (pw: string) => { const salt = randomBytes(16); return `scrypt$${salt.toString('base64')}$${scryptSync(pw, salt, 64).toString('base64')}`; };
const tag = () => randomBytes(3).toString('hex');
const quiet = (errors: string[]) => errors.filter((x) => !/favicon|Failed to load resource|net::ERR/.test(x));
// what the fake speech to text hears in a recording without its marker (integrations/transcribe/fake.ts)
const FAKE_SENTENCE = 'I worked two years in customer support for a company in the United States, answering calls and chats every day with Zendesk.';

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
  const c = await browser.newContext({ viewport: phone ? { width: 375, height: 812 } : { width: 1440, height: 900 }, hasTouch: phone, baseURL: test.info().project.use.baseURL,
    permissions: ['camera', 'microphone'] });
  // the browser's voice is quick and always says it is done (the clock then starts), whatever the machine has
  await c.addInitScript(() => {
    const synth = { speaking: false, cancel() {}, speak(u: { onend?: (() => void) | null }) { setTimeout(() => u.onend?.(), 200); }, getVoices: () => [] };
    Object.defineProperty(window, 'speechSynthesis', { configurable: true, value: synth });
  });
  return c.newPage();
}
/** Wait for the question's clock to start, then record for a moment and stop: the answer goes. */
async function recordAnswer(page: Page, ms = 1500) {
  await expect(page.getByTestId('iv-record')).toBeVisible({ timeout: 40_000 });
  await page.getByTestId('iv-record').click();
  await expect(page.getByTestId('iv-question')).toHaveAttribute('data-phase', 'recording');
  await page.waitForTimeout(ms);
  await page.getByTestId('iv-stop').click();
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

test('AI interview on video: apply, consent, the camera check, answers recorded and uploaded, one stopped by the clock at 0:00, a follow-up, scored by the job; the Admin watches them and invites to a live call', async ({ playwright }, info) => {
  test.setTimeout(600_000);
  const phone = info.project.name.startsWith('phone');
  const sql = db();
  await sql`delete from app.rate_limit_hits where key like 'hire:%'`;
  const a = await mkAdmin(sql);
  const email = `ivy.${tag()}@example.test`;
  await sql`update hiring_roles set active = true where slug = 'va-finance-billing'`;
  await sql`update program_settings set hiring_ai_interviews = true, hiring_ai_answer_seconds = 60, hiring_ai_retakes = 0 where id = (select id from app.settings())`;
  // 1060 (r35): customer service, fleet and finance applicants are referred to Sales by default (hiring_refer_va_to_sales);
  // this test is the finance role's own interview, so the referral is off while it runs
  const [refer] = await sql`select hiring_refer_va_to_sales v from program_settings where id = (select id from app.settings())`;
  await sql`update program_settings set hiring_refer_va_to_sales = false where id = (select id from app.settings())`;
  // 2590 (r41): a scored interview is decided by itself by default; this test is the Admin watching and inviting, so that is off while it runs
  const [auto] = await sql`select hiring_ai_auto_decide v from program_settings where id = (select id from app.settings())`;
  await sql`update program_settings set hiring_ai_auto_decide = false where id = (select id from app.settings())`;
  // a Chrome of its own with a fake camera and microphone (PW_CHROMIUM: another build of Chrome, for a local run)
  const browser = await playwright.chromium.launch({ args: ['--no-proxy-server', '--use-fake-device-for-media-stream', '--use-fake-ui-for-media-stream', '--autoplay-policy=no-user-gesture-required'],
    ...(process.env.PW_CHROMIUM ? { executablePath: process.env.PW_CHROMIUM } : {}) });
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
    await expect(page.getByTestId('iv-consent')).toContainText('This interview is recorded on video');
    await expect(page.getByTestId('iv-start')).toBeDisabled();
    await check(page, 'interview intro');
    await noTestWord(page, 'interview intro');
    await page.getByTestId('iv-agree').check();
    await page.getByTestId('iv-start').click();

    // 3. the camera and microphone check: the preview and the level, before the first question
    await expect(page.getByTestId('iv-check')).toBeVisible({ timeout: 30_000 });
    expect((await sql`select consent_at from ai_interviews where application_id = ${app!.id}`)[0]!.consent_at).not.toBeNull();
    await page.getByTestId('iv-check-start').click();
    await expect(page.getByTestId('iv-preview')).toBeVisible({ timeout: 30_000 });
    await expect(page.getByTestId('iv-level')).toBeVisible();
    await expect.poll(() => page.getByTestId('iv-preview').evaluate((v: HTMLVideoElement) => v.videoWidth), { timeout: 20_000 }).toBeGreaterThan(0);
    await check(page, 'camera check');
    await noTestWord(page, 'camera check');
    await page.getByTestId('iv-check-go').click();

    // 4. question 1: read, then the clock (1:00 here); Record, Stop and send: the video and its audio track are uploaded
    await expect(page.getByTestId('iv-question')).toHaveAttribute('data-seq', '1', { timeout: 30_000 });
    await expect(page.getByTestId('iv-timer')).toContainText(/1:00|0:5\d/, { timeout: 30_000 });
    await check(page, 'question');
    await recordAnswer(page);
    await expect(page.getByTestId('iv-question')).toHaveAttribute('data-seq', '2', { timeout: 60_000 });
    const [w1] = await sql`select w.mode, w.audio_key, w.video_key, w.video_bytes, w.transcript, w.transcript_state from ai_interview_answers w join ai_interviews i on i.id = w.interview_id where i.application_id = ${app!.id} and w.seq = 1`;
    expect(w1!.mode).toBe('voice');
    expect(w1!.video_key).toMatch(/^hiring\/interviews\/[0-9a-f-]+\/1-[a-z0-9]+-v\.(webm|mp4)$/);
    expect(w1!.audio_key).toMatch(/^hiring\/interviews\/[0-9a-f-]+\/1-[a-z0-9]+\.(webm|m4a|ogg)$/);
    expect(Number(w1!.video_bytes)).toBeGreaterThan(1000);
    expect(w1!.transcript_state).toBe('done');
    // the fake speech to text hears its plain sentence in the fake microphone's tone: short, so a follow-up comes
    await expect(page.getByTestId('iv-question')).toHaveAttribute('data-kind', 'followup');
    await expect(page.getByTestId('iv-text')).toContainText('specific example');
    await noTestWord(page, 'follow-up');

    // 5. the follow-up: Record and let the clock run out: red for the last 15 seconds, recording stops at 0:00, the answer goes
    await expect(page.getByTestId('iv-record')).toBeVisible({ timeout: 40_000 });
    await page.getByTestId('iv-record').click();
    await expect(page.getByTestId('iv-timer')).toHaveAttribute('data-low', '1', { timeout: 60_000 });
    await expect(page.getByTestId('iv-timer')).toHaveClass(/is-low/);
    await expect(page.getByTestId('iv-question')).toHaveAttribute('data-phase', 'recording');
    await check(page, 'the last seconds');
    await expect(page.getByTestId('iv-question')).toHaveAttribute('data-seq', '3', { timeout: 60_000 });
    const [w2] = await sql`select w.kind, w.mode, w.video_key, w.audio_seconds from ai_interview_answers w join ai_interviews i on i.id = w.interview_id where i.application_id = ${app!.id} and w.seq = 2`;
    expect(`${w2!.kind}/${w2!.mode}/${w2!.video_key ? 'video' : 'none'}`).toBe('followup/voice/video');
    expect(Number(w2!.audio_seconds)).toBeGreaterThan(40);

    // 6. the rest, every answer recorded on video (2680: nothing is typed, the written question is spoken too); follow-ups may come (up to 4)
    for (let i = 0; i < 25 && await page.getByTestId('iv-question').isVisible(); i++) {
      const seq = await page.getByTestId('iv-question').getAttribute('data-seq');
      expect(await page.getByTestId('iv-typed').count(), 'no typing').toBe(0);
      await recordAnswer(page, 1000);
      await expect.poll(async () => (await page.getByTestId('iv-done').isVisible()) || (await page.getByTestId('iv-question').getAttribute('data-seq').catch(() => seq)) !== seq, { timeout: 120_000 }).toBe(true);
    }
    await expect(page.getByTestId('iv-done')).toBeVisible({ timeout: 60_000 });
    await check(page, 'interview done');
    const [st] = await sql`select a.status, i.state, (select count(*)::int from ai_interview_answers w where w.interview_id = i.id) n from job_applications a join ai_interviews i on i.application_id = a.id where a.id = ${app!.id}`;
    expect(`${st!.status}/${st!.state}`).toBe('interviewed/submitted');
    // nine questions and the reliability and written ones (2590), then the follow-ups (at most 4)
    expect(st!.n).toBeGreaterThanOrEqual(11);
    expect(st!.n).toBeLessThanOrEqual(15);
    expect((await sql`select count(*)::int n from ai_interview_answers w join ai_interviews i on i.id = w.interview_id where i.application_id = ${app!.id} and w.mode = 'typed'`)[0]!.n).toBe(0);
    expect((await sql`select count(*)::int n from ai_interview_answers w join ai_interviews i on i.id = w.interview_id where i.application_id = ${app!.id} and (w.video_key is null or w.mode <> 'voice')`)[0]!.n).toBe(0);

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
    await expect(page.getByTestId('cand-ai-answers')).toContainText(FAKE_SENTENCE);
    await expect(page.getByTestId('cand-ai-answers')).toContainText('Follow-up');
    // release 43: every answer is a video, the English one included
    await expect(page.getByTestId('cand-ai-video')).toHaveCount(st!.n);
    await expect(page.getByTestId('cand-ai-hint')).toContainText('You decide');
    const src = await page.getByTestId('cand-ai-video').first().getAttribute('src');
    expect(src).toBeTruthy();
    const video = await page.request.get(src!, { headers: { range: 'bytes=0-9' } });
    expect(video.status()).toBe(206);
    expect(video.headers()['content-type']).toMatch(/^video\/(webm|mp4)$/);
    await page.getByTestId('cand-ai-watch-all').click();
    await expect(page.getByTestId('cand-ai-watch-video')).toBeVisible();
    await page.getByTestId('cand-ai-watch-next').click();
    await expect(page.getByTestId('cand-ai-watch')).toContainText('Follow-up');
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
    await expect(page.getByTestId('hiring-ai-setting')).toContainText('Answer time');
    await expect(page.getByTestId('hiring-ai-setting')).toContainText('Keep interview videos');
    await check(page, 'roles');
    expect(quiet(errors)).toEqual([]);
    await sql`update job_applications set status = 'withdrawn' where id = ${app!.id}`;
  } finally {
    await sql`update program_settings set hiring_refer_va_to_sales = ${refer!.v as boolean}, hiring_ai_auto_decide = ${auto!.v as boolean} where id = (select id from app.settings())`;
    await browser.close();
    await sql`update program_settings set hiring_ai_answer_seconds = 120, hiring_ai_retakes = 0 where id = (select id from app.settings())`;
    await sql`update hiring_roles set active = false where slug = 'va-finance-billing'`;
    await sql.end();
  }
});
