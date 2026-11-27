import { expect, test, type Page } from '@playwright/test';
import { randomBytes, randomUUID, scryptSync } from 'node:crypto';
import { acceptCookies, db, noOverflow } from './helpers';

// R50 hotfix 2: the call screen (VoiceDock). Twilio is mocked in the page: the token, the call's start on our server and the
// Voice SDK itself (a fake Device whose call connects, mutes and disconnects like the real one). An Admin opens the keypad,
// dials a number, the call connects (name, number, timer), Mute and Hold toggle, End ends it; End also works while the call
// is still starting (the owner: "no way to hang up once a call starts"), and pagehide (a phone switching apps) leaves a
// connected call on. 5092: the
// contacts tab calls a person by their record.
const PW = 'correct horse battery';
const hash = (pw: string) => { const salt = randomBytes(16); return `scrypt$${salt.toString('base64')}$${scryptSync(pw, salt, 64).toString('base64')}`; };

const FAKE_SDK = `
window.__voice = { connects: 0, disconnects: 0, digits: '', muted: false };
class FakeCall {
  constructor() { this.h = {}; this.m = false; }
  on(e, f) { (this.h[e] ||= []).push(f); }
  emit(e, ...a) { for (const f of this.h[e] || []) f(...a); }
  accept() { this.emit('accept'); }
  reject() { this.emit('reject'); }
  disconnect() { window.__voice.disconnects++; this.emit('disconnect'); }
  mute(m) { this.m = m; window.__voice.muted = m; this.emit('mute', m); }
  isMuted() { return this.m; }
  sendDigits(d) { window.__voice.digits += d; }
  getRemoteStream() { return undefined; }
}
class FakeDevice {
  constructor(token) { this.token = token; this.h = {}; this.audio = { availableInputDevices: new Map([['mic1', { deviceId: 'mic1', label: 'Desk microphone', kind: 'audioinput' }]]),
    availableOutputDevices: new Map(), isOutputSelectionSupported: false, inputDevice: null, setInputDevice: async () => {} }; }
  on(e, f) { (this.h[e] ||= []).push(f); }
  async register() {}
  async unregister() {}
  destroy() {}
  updateToken() {}
  async connect() {
    window.__voice.connects++;
    if (window.__voiceSlow) await new Promise((r) => setTimeout(r, 1500));
    const c = new FakeCall();
    if (!window.__voiceSlow) setTimeout(() => c.emit('accept'), 150);
    return c;
  }
}
window.Twilio = { Device: FakeDevice };
`;

// 5092: a contact as Sales sees it: the number masked, the lead to call it by
const MASKED = '(416) \u2022\u2022\u2022-\u2022\u202281';
const LEAD = randomUUID();
async function mockTwilio(page: Page) {
  const calls: Array<Record<string, unknown>> = [];
  const searches: string[] = [];
  await page.route('**/vendor/twilio-voice-sdk-*/twilio.min.js', (r) => r.fulfill({ contentType: 'application/javascript', body: FAKE_SDK }));
  await page.route('**/api/staff/phone?what=voice_token', (r) => r.fulfill({ json: { ok: true, token: 'fake-token', ring: false, ttl: 3600 } }));
  await page.route(/\/api\/staff\/phone\?what=voice_contacts/, (r) => {
    const q = new URL(r.request().url()).searchParams.get('q') ?? '';
    searches.push(q);
    return r.fulfill({ json: q === 'nobody' ? [] : [{ name: 'Lee Lead', number: MASKED, shown: MASKED, lead: LEAD, renter: null }] });
  });
  await page.route('**/api/staff/phone', async (r) => {
    const b = r.request().postDataJSON() as { action?: string } | null;
    if (b?.action === 'phone_call') { calls.push(b); return r.fulfill({ json: { ok: true, id: randomUUID(), t: 'fake-call-token', who: 'Dana Driver' } }); }
    if (b?.action === 'voice_presence') return r.fulfill({ json: { ok: true } });
    return r.continue();
  });
  return { calls, searches };
}

test('call screen: dial any number, connect, mute, hold, keypad, end; End while starting; pagehide keeps a connected call', async ({ page }) => {
  const sql = db();
  const id = randomUUID(); const email = `admin.vc.${Date.now()}.${randomBytes(3).toString('hex')}@example.test`;
  await sql`insert into local_auth.users (id, email, password_hash) values (${id}, ${email}, ${hash(PW)})`;
  await sql`insert into users (id, email, full_name) values (${id}, ${email}, ${'Val Caller'})`;
  await sql`insert into user_roles (user_id, role) values (${id}, 'admin')`;
  try {
    const mock = await mockTwilio(page);
    await page.goto('/sign-in', { waitUntil: 'networkidle' });
    await acceptCookies(page);
    await page.locator('input[type="email"]').fill(email);
    await page.locator('input[type="password"]').fill(PW);
    await page.getByRole('button', { name: 'Sign in' }).click();
    await page.waitForURL((u) => u.pathname.startsWith('/admin'), { timeout: 20_000 });

    // the keypad: Call stays off until the number is one we can call
    await page.getByTestId('voice-launch').click();
    const dock = page.getByTestId('voice-dock');
    await expect(dock).toHaveAttribute('data-phase', 'dialing');
    await expect(page.getByTestId('voice-call')).toBeDisabled();
    for (const k of '647555012') await page.getByTestId('voice-keypad').getByRole('button', { name: k, exact: true }).click();
    await page.getByTestId('voice-number').pressSequentially('3');
    await expect(page.getByTestId('voice-number')).toHaveValue('6475550123');
    await noOverflow(page);
    await page.getByTestId('voice-call').click();

    // connected: the name, the number, the timer and the controls
    await expect(dock).toHaveAttribute('data-phase', 'in_call');
    await expect(page.getByTestId('voice-who')).toHaveText('Dana Driver');
    await expect(dock).toContainText('647-555-0123');
    await expect(page.getByTestId('voice-status')).toHaveText(/^0:0\d$/);
    await page.getByTestId('voice-mute').click();
    await expect(page.getByTestId('voice-mute')).toHaveAttribute('aria-pressed', 'true');
    expect(await page.evaluate(() => (window as unknown as { __voice: { muted: boolean } }).__voice.muted)).toBe(true);
    await page.getByTestId('voice-mute').click();
    await page.getByTestId('voice-hold').click();
    await expect(page.getByTestId('voice-status')).toHaveText('On hold');
    await page.getByTestId('voice-hold').click();
    await page.getByTestId('voice-audio').click();
    await expect(page.getByTestId('voice-mic')).toContainText('Desk microphone');
    await page.getByTestId('voice-pad').click();
    await page.getByTestId('voice-dtmf').getByRole('button', { name: '5', exact: true }).click();
    expect(await page.evaluate(() => (window as unknown as { __voice: { digits: string } }).__voice.digits)).toBe('5');
    await noOverflow(page);

    // End: always on the screen, ends the call
    await expect(page.getByTestId('voice-hangup')).toBeVisible();
    await page.getByTestId('voice-hangup').click();
    await expect(dock).toHaveCount(0);
    await expect(page.getByTestId('voice-launch')).toBeVisible();
    expect(await page.evaluate(() => (window as unknown as { __voice: { disconnects: number } }).__voice.disconnects)).toBe(1);

    // End while the call is still starting: nothing rings on afterwards
    await page.evaluate(() => { (window as unknown as { __voiceSlow: boolean }).__voiceSlow = true; });
    await page.getByTestId('voice-launch').click();
    await page.getByTestId('voice-number').fill('+16475550124');
    await page.getByTestId('voice-call').click();
    await expect(page.getByTestId('voice-hangup')).toBeEnabled();
    await page.getByTestId('voice-hangup').click();
    await expect(page.getByTestId('voice-launch')).toBeVisible();
    await page.waitForTimeout(1800);
    await expect(page.getByTestId('voice-dock')).toHaveCount(0);
    expect(await page.evaluate(() => (window as unknown as { __voice: { disconnects: number } }).__voice.disconnects)).toBe(2);

    // pagehide (a phone switching apps) leaves a connected call on
    await page.evaluate(() => { (window as unknown as { __voiceSlow: boolean }).__voiceSlow = false; });
    await page.getByTestId('voice-launch').click();
    await page.getByTestId('voice-number').fill('6475550125');
    await page.getByTestId('voice-call').click();
    await expect(page.getByTestId('voice-dock')).toHaveAttribute('data-phase', 'in_call');
    const before = await page.evaluate(() => (window as unknown as { __voice: { disconnects: number } }).__voice.disconnects);
    await page.evaluate(() => dispatchEvent(new PageTransitionEvent('pagehide', { persisted: false })));
    await expect(page.getByTestId('voice-dock')).toHaveAttribute('data-phase', 'in_call');
    expect(await page.evaluate(() => (window as unknown as { __voice: { disconnects: number } }).__voice.disconnects)).toBe(before);
    await page.getByTestId('voice-hangup').click();
    await expect(page.getByTestId('voice-launch')).toBeVisible();

    // contacts (5092): the people called last, a search, and a tap that calls by the record (the masked number and the lead)
    await page.getByTestId('voice-launch').click();
    await page.getByTestId('voice-tab-contacts').click();
    await expect(page.getByTestId('voice-tab-contacts')).toHaveAttribute('aria-selected', 'true');
    await expect(page.getByTestId('voice-contact')).toHaveCount(1);
    await expect(page.getByTestId('voice-contacts')).toContainText('Lee Lead');
    await page.getByTestId('voice-find').fill('nobody');
    await expect(page.getByTestId('voice-contacts')).toContainText('Nobody found.');
    expect(mock.searches).toContain('nobody');
    await page.getByTestId('voice-find').fill('lee');
    await expect(page.getByTestId('voice-contact')).toHaveCount(1);
    await noOverflow(page);
    await page.getByTestId('voice-contact').click();
    await expect(page.getByTestId('voice-dock')).toHaveAttribute('data-phase', 'in_call');
    expect(mock.calls.at(-1)).toMatchObject({ action: 'phone_call', via: 'browser', number: MASKED, lead: LEAD, name: 'Lee Lead' });
    await page.getByTestId('voice-hangup').click();
    await expect(page.getByTestId('voice-launch')).toBeVisible();
  } finally {
    await sql`delete from user_roles where user_id = ${id}`.catch(() => undefined);
    await sql`update users set status = 'inactive' where id = ${id}`.catch(() => undefined);
    await sql.end();
  }
});
