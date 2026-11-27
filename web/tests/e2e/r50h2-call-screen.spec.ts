import { expect, test, type Page } from '@playwright/test';
import { randomBytes, randomUUID, scryptSync } from 'node:crypto';
import { acceptCookies, db, noOverflow } from './helpers';

// R50 hotfix 2: the call screen (VoiceDock). Twilio is mocked in the page: the token, the call's start on our server and the
// Voice SDK itself (a fake Device whose call connects, mutes and disconnects like the real one). An Admin opens the keypad,
// dials a number, the call connects (name, number, timer), Mute and Hold toggle, End ends it; End also works while the call
// is still starting (the owner: "no way to hang up once a call starts"), and leaving the page ends the call.
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

async function mockTwilio(page: Page) {
  await page.route('**/vendor/twilio-voice-sdk-*/twilio.min.js', (r) => r.fulfill({ contentType: 'application/javascript', body: FAKE_SDK }));
  await page.route('**/api/staff/phone?what=voice_token', (r) => r.fulfill({ json: { ok: true, token: 'fake-token', ring: false, ttl: 3600 } }));
  await page.route('**/api/staff/phone', async (r) => {
    const b = r.request().postDataJSON() as { action?: string } | null;
    if (b?.action === 'phone_call') return r.fulfill({ json: { ok: true, id: randomUUID(), t: 'fake-call-token', who: 'Dana Driver' } });
    if (b?.action === 'voice_presence') return r.fulfill({ json: { ok: true } });
    return r.continue();
  });
}

test('call screen: dial any number, connect, mute, hold, keypad, end; End while starting; page leave ends it', async ({ page }) => {
  const sql = db();
  const id = randomUUID(); const email = `admin.vc.${Date.now()}.${randomBytes(3).toString('hex')}@example.test`;
  await sql`insert into local_auth.users (id, email, password_hash) values (${id}, ${email}, ${hash(PW)})`;
  await sql`insert into users (id, email, full_name) values (${id}, ${email}, ${'Val Caller'})`;
  await sql`insert into user_roles (user_id, role) values (${id}, 'admin')`;
  try {
    await mockTwilio(page);
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

    // leaving the page ends a call that is on
    await page.evaluate(() => { (window as unknown as { __voiceSlow: boolean }).__voiceSlow = false; });
    await page.getByTestId('voice-launch').click();
    await page.getByTestId('voice-number').fill('6475550125');
    await page.getByTestId('voice-call').click();
    await expect(page.getByTestId('voice-dock')).toHaveAttribute('data-phase', 'in_call');
    const before = await page.evaluate(() => (window as unknown as { __voice: { disconnects: number } }).__voice.disconnects);
    await page.evaluate(() => dispatchEvent(new PageTransitionEvent('pagehide')));
    expect(await page.evaluate(() => (window as unknown as { __voice: { disconnects: number } }).__voice.disconnects)).toBe(before + 1);
  } finally {
    await sql`delete from user_roles where user_id = ${id}`.catch(() => undefined);
    await sql`update users set status = 'inactive' where id = ${id}`.catch(() => undefined);
    await sql.end();
  }
});
