// Calls in the browser (release 44, migration 2790): staff place and take calls on the CarmaCars number from the staff and
// Admin portals with Twilio's Voice SDK (self-hosted under /vendor, loaded only on a staff page that needs it). Staff abroad
// never use their own international number. The server gives a token (an hour, renewed before it ends), checks every call
// and keeps it; a Sales person never receives a number masked for them (the call goes by its id).
// One phone a page: this module keeps it and its state; VoiceDock shows it, the Call buttons start calls through it.

export const VOICE_SDK = '/vendor/twilio-voice-sdk-2.18.5/twilio.min.js';

interface TwilioCall {
  on(ev: string, fn: (...a: unknown[]) => void): void;
  accept(): void; reject(): void; disconnect(): void; ignore?(): void;
  mute(m: boolean): void; isMuted(): boolean; sendDigits(d: string): void;
  customParameters?: Map<string, string>;
}
interface TwilioDevice {
  register(): Promise<void>; unregister(): Promise<void>; destroy(): void; updateToken(t: string): void;
  connect(o: { params: Record<string, string> }): Promise<TwilioCall>;
  on(ev: string, fn: (...a: unknown[]) => void): void;
}
type DeviceCtor = new (token: string, o: Record<string, unknown>) => TwilioDevice;

export type VoicePhase = 'idle' | 'starting' | 'calling' | 'ringing_in' | 'in_call' | 'problem';
export interface VoiceState { phase: VoicePhase; who?: string; since?: number; muted?: boolean; message?: string; ring?: boolean }

let state: VoiceState = { phase: 'idle' };
const subs = new Set<() => void>();
const set = (s: VoiceState) => { state = s; for (const f of subs) f(); };
export const voiceState = (): VoiceState => state;
export function subscribeVoice(f: () => void): () => void { subs.add(f); return () => { subs.delete(f); }; }

let device: TwilioDevice | null = null;
let deviceP: Promise<TwilioDevice | null> | null = null;
let current: TwilioCall | null = null;
let incoming: TwilioCall | null = null;
let beat: ReturnType<typeof setInterval> | null = null;
let ringing = false;

function loadSdk(): Promise<DeviceCtor> {
  const w = window as unknown as { Twilio?: { Device?: DeviceCtor } };
  if (w.Twilio?.Device) return Promise.resolve(w.Twilio.Device);
  return new Promise((resolve, reject) => {
    const s = document.createElement('script');
    s.src = VOICE_SDK; s.async = true;
    s.onload = () => (w.Twilio?.Device ? resolve(w.Twilio.Device) : reject(new Error('The phone did not load. Reload the page.')));
    s.onerror = () => reject(new Error('The phone did not load. Check your connection and reload the page.'));
    document.head.appendChild(s);
  });
}

type TokenAnswer = { ok: true; token: string; ring: boolean; ttl: number } | { ok: false; message: string };
async function token(): Promise<TokenAnswer> {
  try {
    const r = await fetch('/api/staff/phone?what=voice_token', { cache: 'no-store', credentials: 'same-origin', signal: AbortSignal.timeout(15_000) });
    const j = (await r.json().catch(() => null)) as TokenAnswer | { error?: string } | null;
    if (j && 'ok' in j) return j;
    return { ok: false, message: (j as { error?: string } | null)?.error ?? 'The phone could not start. Reload the page.' };
  } catch { return { ok: false, message: 'The phone could not start: the server did not answer. Try again in a moment.' }; }
}
async function post(action: string, p: Record<string, unknown>): Promise<Record<string, unknown>> {
  const r = await fetch('/api/staff/phone', { method: 'POST', headers: { 'content-type': 'application/json' }, credentials: 'same-origin', keepalive: true,
    body: JSON.stringify({ action, ...p }), signal: AbortSignal.timeout(20_000) });
  return ((await r.json().catch(() => ({}))) as Record<string, unknown>) ?? {};
}

const whoOf = (c: TwilioCall) => c.customParameters?.get('who') || 'A caller';

function watch(c: TwilioCall, who: string) {
  c.on('accept', () => set({ phase: 'in_call', who, since: Date.now(), muted: false, ring: ringing }));
  const end = () => { if (current === c) current = null; if (incoming === c) incoming = null; if (state.phase !== 'problem') set({ phase: 'idle', ring: ringing }); };
  c.on('disconnect', end); c.on('cancel', end); c.on('reject', end);
  c.on('error', (e: unknown) => { end(); set({ phase: 'problem', message: problemText(e), ring: ringing }); });
  c.on('mute', (m: unknown) => set({ ...state, muted: !!m }));
}

function problemText(e: unknown): string {
  const x = e as { code?: number; message?: string } | null;
  if (x?.code === 31401 || x?.code === 31402 || /permission|NotAllowed/i.test(x?.message ?? '')) return 'The browser did not allow the microphone. Allow it for this site (the icon in the address bar) and call again.';
  if (x?.code === 31005 || x?.code === 31009 || x?.code === 53000) return 'The call dropped: the connection to the phone service was lost. Check your internet and call again.';
  return 'The call did not go through. Try again; if it happens again, tell an Admin.';
}

/** The phone of this page: made once (and registered for incoming calls when this person rings). */
async function ensureDevice(first?: TokenAnswer): Promise<TwilioDevice | null> {
  if (device) return device;
  deviceP ??= (async () => {
    const t = first ?? await token();
    if (!t.ok) { set({ phase: state.phase === 'starting' ? 'problem' : state.phase, message: t.message }); deviceP = null; return null; }
    let Ctor: DeviceCtor;
    try { Ctor = await loadSdk(); } catch (e) { set({ phase: 'problem', message: e instanceof Error ? e.message : 'The phone did not load.' }); deviceP = null; return null; }
    const d = new Ctor(t.token, { closeProtection: 'A call is on: leaving this page ends it.', codecPreferences: ['opus', 'pcmu'], appName: 'carmacars-staff', tokenRefreshMs: 120_000 });
    d.on('tokenWillExpire', () => { void token().then((n) => { if (n.ok) d.updateToken(n.token); }); });
    d.on('incoming', (c: unknown) => {
      const call = c as TwilioCall;
      if (current || incoming) { call.reject(); return; }  // already on a call: the others online take it
      incoming = call; watch(call, whoOf(call));
      set({ phase: 'ringing_in', who: whoOf(call), ring: ringing });
    });
    d.on('error', (e: unknown) => { if (state.phase === 'starting' || state.phase === 'calling') set({ phase: 'problem', message: problemText(e), ring: ringing }); });
    ringing = t.ring;
    if (t.ring) {
      await d.register().catch(() => undefined);
      beat ??= setInterval(() => { if (document.visibilityState !== 'hidden' || ringing) void post('voice_presence', { online: true }).catch(() => undefined); }, 60_000);
      addEventListener('pagehide', () => { void post('voice_presence', { online: false }).catch(() => undefined); }, { once: true });
    }
    device = d;
    set({ ...state, ring: ringing });
    return d;
  })();
  return deviceP;
}

/** On a staff page: get ready to ring for incoming calls (only the people the database says ring). */
export function startVoice(): void {
  if (typeof window === 'undefined' || device || deviceP) return;
  // the phone itself (the SDK, about 300 KB) loads now only for a person incoming calls ring; the others load it on their
  // first call
  void token().then((t) => { if (t.ok && t.ring) void ensureDevice(t); });
}

/** A call to a person, placed in the browser with the CarmaCars number as caller ID. */
export async function placeCall(o: { number: string; booking?: string | null; name?: string | null }): Promise<void> {
  if (current || incoming) return;
  set({ phase: 'starting', who: o.name?.trim() || 'the customer', ring: ringing });
  let r: Record<string, unknown>;
  try { r = await post('phone_call', { via: 'browser', number: o.number, ...(o.booking ? { booking_number: o.booking } : {}), ...(o.name ? { name: o.name } : {}) }); }
  catch { set({ phase: 'problem', message: 'The server did not answer. Try again in a moment.', ring: ringing }); return; }
  if (r.ok !== true || typeof r.id !== 'string' || typeof r.t !== 'string') {
    set({ phase: 'problem', message: String(r.message ?? r.error ?? 'The call did not start. Try again in a moment.'), ring: ringing }); return;
  }
  const who = typeof r.who === 'string' && r.who ? r.who : o.name?.trim() || 'the customer';
  const d = await ensureDevice();
  if (!d) return;
  try {
    const c = await d.connect({ params: { call: r.id, t: r.t } });
    current = c; watch(c, who);
    set({ phase: 'calling', who, ring: ringing });
  } catch (e) { set({ phase: 'problem', message: problemText(e), ring: ringing }); }
}

export function answer(): void { if (incoming) { current = incoming; incoming = null; current.accept(); } }
export function decline(): void { if (incoming) { incoming.reject(); incoming = null; set({ phase: 'idle', ring: ringing }); } }
export function hangUp(): void { (current ?? incoming)?.disconnect(); }
export function toggleMute(): void { if (current) current.mute(!current.isMuted()); }
export function sendDigit(d: string): void { if (current && /^[0-9*#]$/.test(d)) current.sendDigits(d); }
export function dismiss(): void { if (state.phase === 'problem') set({ phase: 'idle', ring: ringing }); }
