// Calls in the browser (release 44, migration 2790): staff place and take calls on the CarmaCars number from the staff and
// Admin portals with Twilio's Voice SDK (self-hosted under /vendor, loaded only on a staff page that needs it). Staff abroad
// never use their own international number. The server gives a token (an hour, renewed before it ends), checks every call
// and keeps it; a Sales person never receives a number masked for them (the call goes by its id).
// One phone a page: this module keeps it and its state; VoiceDock shows it, the Call buttons start calls through it.

import { voiceErrorText } from './twilio';

export const VOICE_SDK = '/vendor/twilio-voice-sdk-2.18.5/twilio.min.js';

interface TwilioCall {
  on(ev: string, fn: (...a: unknown[]) => void): void;
  accept(): void; reject(): void; disconnect(): void; ignore?(): void;
  mute(m: boolean): void; isMuted(): boolean; sendDigits(d: string): void;
  customParameters?: Map<string, string>;
  getRemoteStream?(): MediaStream | undefined;
}
// r50 hotfix 2: the device's audio (the microphone and, where the browser allows it, the speaker)
interface TwilioAudio {
  availableInputDevices?: Map<string, MediaDeviceInfo>; availableOutputDevices?: Map<string, MediaDeviceInfo>;
  isOutputSelectionSupported?: boolean; inputDevice?: MediaDeviceInfo | null;
  setInputDevice?(id: string): Promise<void>;
  speakerDevices?: { set(ids: string | string[]): Promise<void>; get?(): Set<MediaDeviceInfo> };
}
interface TwilioDevice {
  register(): Promise<void>; unregister(): Promise<void>; destroy(): void; updateToken(t: string): void;
  connect(o: { params: Record<string, string> }): Promise<TwilioCall>;
  on(ev: string, fn: (...a: unknown[]) => void): void;
  audio?: TwilioAudio;
}
type DeviceCtor = new (token: string, o: Record<string, unknown>) => TwilioDevice;

export type VoicePhase = 'idle' | 'dialing' | 'starting' | 'calling' | 'ringing_in' | 'in_call' | 'problem';
/** r50 hotfix 2: number (what the call screen shows under the name), held (on hold: their voice and ours paused) */
export interface VoiceState { phase: VoicePhase; who?: string; number?: string; since?: number; muted?: boolean; held?: boolean; message?: string; ring?: boolean }

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
// r50 hotfix 2: End pressed before the call was connected (the server, the microphone prompt or Twilio still on their way)
let cancelled = false;

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

function watch(c: TwilioCall, who: string, number?: string) {
  c.on('accept', () => set({ phase: 'in_call', who, number, since: Date.now(), muted: false, held: false, ring: ringing }));
  const end = () => { if (current === c) current = null; if (incoming === c) incoming = null; if (state.phase !== 'problem') set({ phase: 'idle', ring: ringing }); };
  c.on('disconnect', end); c.on('cancel', end); c.on('reject', end);
  c.on('error', (e: unknown) => { end(); set({ phase: 'problem', message: problemText(e), ring: ringing }); });
  c.on('mute', (m: unknown) => { if (!state.held) set({ ...state, muted: !!m }); });
}

function problemText(e: unknown): string {
  // r48 CM: the code is named (the Admin's Test call finds the step behind it)
  return voiceErrorText(e as { code?: number; message?: string } | null);
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
export async function placeCall(o: { number: string; booking?: string | null; name?: string | null; lead?: string | null; renter?: string | null }): Promise<void> {
  if (current || incoming) return;
  cancelled = false;
  // the number shown under the name: never a number masked for Sales in full (it stays as given)
  const shown = o.number;
  set({ phase: 'starting', who: o.name?.trim() || shown || 'the customer', number: shown, ring: ringing });
  let r: Record<string, unknown>;
  try { r = await post('phone_call', { via: 'browser', number: o.number, ...(o.booking ? { booking_number: o.booking } : {}), ...(o.name ? { name: o.name } : {}),
    ...(o.lead ? { lead: o.lead } : {}), ...(o.renter ? { renter: o.renter } : {}) }); }
  catch { if (!cancelled) set({ phase: 'problem', message: 'The server did not answer. Try again in a moment.', ring: ringing }); return; }
  if (cancelled) return;
  if (r.ok !== true || typeof r.id !== 'string' || typeof r.t !== 'string') {
    set({ phase: 'problem', message: String(r.message ?? r.error ?? 'The call did not start. Try again in a moment.'), ring: ringing }); return;
  }
  const who = typeof r.who === 'string' && r.who ? r.who : o.name?.trim() || shown || 'the customer';
  const d = await ensureDevice();
  if (!d || cancelled) return;
  try {
    const c = await d.connect({ params: { call: r.id, t: r.t } });
    if (cancelled) { c.disconnect(); return; }
    current = c; watch(c, who, shown);
    set({ phase: 'calling', who, number: shown, ring: ringing });
  } catch (e) { if (!cancelled) set({ phase: 'problem', message: problemText(e), ring: ringing }); }
}

export function answer(): void { if (incoming) { current = incoming; incoming = null; current.accept(); } }
export function decline(): void { if (incoming) { incoming.reject(); incoming = null; set({ phase: 'idle', ring: ringing }); } }
/** End: always ends what is on the screen, also a call still starting (it is dropped as soon as it connects). */
export function hangUp(): void {
  const c = current ?? incoming;
  if (c) { try { c.disconnect(); } catch { /* already gone */ } }
  if (state.phase === 'starting' || state.phase === 'calling' || state.phase === 'in_call') {
    if (!c || state.phase === 'starting') cancelled = true;
    current = null; incoming = null;
    set({ phase: 'idle', ring: ringing });
  }
}
// leaving or closing the page ends the call (Twilio's own leave warning asks first while it is on)
if (typeof window !== 'undefined') addEventListener('pagehide', () => { if (current || state.phase === 'starting') hangUp(); });
export function toggleMute(): void { if (current && !state.held) current.mute(!current.isMuted()); }
export function sendDigit(d: string): void { if (current && /^[0-9*#]$/.test(d)) current.sendDigits(d); }
export function dismiss(): void { if (state.phase === 'problem' || state.phase === 'dialing') set({ phase: 'idle', ring: ringing }); }

// ================================================================ r50 hotfix 2: the call screen (dialer, hold, audio)
/** r50 hotfix 2 (5092): the call screen's contacts. No search: the people this person called last; a search: renters and
 *  leads (Sales: their own leads, the number masked; the call goes by the lead or renter). */
export interface VoiceContact { name: string; number: string; shown: string; lead: string | null; renter: string | null }
export async function voiceContacts(q: string): Promise<VoiceContact[] | null> {
  try {
    const r = await fetch(`/api/staff/phone?what=voice_contacts&q=${encodeURIComponent(q.trim().slice(0, 60))}`, { cache: 'no-store', credentials: 'same-origin', signal: AbortSignal.timeout(15_000) });
    const j = (await r.json().catch(() => null)) as unknown;
    return r.ok && Array.isArray(j) ? (j as VoiceContact[]) : null;
  } catch { return null; }
}

/** The keypad to call any number (the call screen's dialer). */
export function openDialer(): void { if (state.phase === 'idle' || state.phase === 'problem') set({ phase: 'dialing', ring: ringing }); }

/** Hold: our microphone and their voice are paused in this browser (they hear silence), the call stays connected.
 *  Pressed again: both come back, and the microphone as it was before. */
let mutedBeforeHold = false;
export function toggleHold(): void {
  if (!current || state.phase !== 'in_call') return;
  const on = !state.held;
  if (on) { mutedBeforeHold = current.isMuted(); current.mute(true); } else current.mute(mutedBeforeHold);
  for (const t of current.getRemoteStream?.()?.getAudioTracks() ?? []) t.enabled = !on;
  set({ ...state, held: on, muted: on ? true : mutedBeforeHold });
}

export interface AudioChoice { id: string; label: string }
export interface AudioDevices { inputs: AudioChoice[]; outputs: AudioChoice[]; input: string | null; output: string | null; outputSupported: boolean }
const listOf = (m?: Map<string, MediaDeviceInfo>): AudioChoice[] =>
  [...(m?.values() ?? [])].map((d, i) => ({ id: d.deviceId, label: d.label || (d.kind === 'audioinput' ? `Microphone ${i + 1}` : `Speaker ${i + 1}`) }));
/** The microphones and speakers this browser offers for the call (speakers only where the browser lets a page choose). */
export function audioDevices(): AudioDevices {
  const a = device?.audio;
  const out = a?.speakerDevices?.get?.();
  return { inputs: listOf(a?.availableInputDevices), outputs: a?.isOutputSelectionSupported ? listOf(a?.availableOutputDevices) : [],
    input: a?.inputDevice?.deviceId ?? null, output: out ? ([...out][0]?.deviceId ?? null) : null, outputSupported: !!a?.isOutputSelectionSupported };
}
export async function chooseMicrophone(id: string): Promise<boolean> {
  try { await device?.audio?.setInputDevice?.(id); return true; } catch { return false; }
}
export async function chooseSpeaker(id: string): Promise<boolean> {
  try { await device?.audio?.speakerDevices?.set(id); return true; } catch { return false; }
}

// ================================================================ r48 CM: the Admin's test call (Settings > Calls)
export type TestStep = { step: string; ok: boolean; detail: string };

/** A real call through every part (the SDK in this page, the token, Twilio's connection, the TwiML App, our client
 *  webhook), which only plays a short message: each step's result in order, stopping at the first that fails. */
export async function testCall(token: string, t: string, onStep: (s: TestStep) => void): Promise<boolean> {
  let Ctor: DeviceCtor;
  try { Ctor = await loadSdk(); onStep({ step: 'Phone loaded in this page', ok: true, detail: 'Twilio Voice SDK 2.18.5 (self-hosted).' }); }
  catch (e) { onStep({ step: 'Phone loaded in this page', ok: false, detail: e instanceof Error ? e.message : 'The SDK did not load (blocked by the page\'s security policy or the network).' }); return false; }
  const d = new Ctor(token, { codecPreferences: ['opus', 'pcmu'], appName: 'carmacars-test' });
  try {
    const c = await d.connect({ params: { test: '1', t } });
    onStep({ step: 'Connected to Twilio', ok: true, detail: 'The token was accepted and the call started (microphone allowed).' });
    return await new Promise<boolean>((resolve) => {
      let accepted = false;
      const stop = setTimeout(() => { c.disconnect(); onStep({ step: 'Our call handler answered', ok: false, detail: 'Nothing answered in 20 seconds: the TwiML App\'s Voice URL did not reach this site.' }); resolve(false); }, 20_000);
      c.on('accept', () => { accepted = true; onStep({ step: 'Our call handler answered', ok: true, detail: 'You hear the test message; it hangs up by itself.' }); });
      c.on('disconnect', () => { clearTimeout(stop); d.destroy(); if (accepted) onStep({ step: 'Call ended', ok: true, detail: 'The whole path works.' }); resolve(accepted); });
      c.on('error', (e: unknown) => { clearTimeout(stop); d.destroy(); onStep({ step: 'Call', ok: false, detail: voiceErrorText(e as { code?: number; message?: string }) }); resolve(false); });
    });
  } catch (e) {
    d.destroy();
    onStep({ step: 'Connected to Twilio', ok: false, detail: voiceErrorText(e as { code?: number; message?: string }) });
    return false;
  }
}
