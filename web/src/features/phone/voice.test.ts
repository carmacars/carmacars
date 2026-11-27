import { test } from 'node:test';
import assert from 'node:assert/strict';

// r50 hotfix 2: the browser phone's call flow with a stand-in Twilio SDK and server. An ended call never connects after
// a new call starts; a double tap places one call; pagehide leaves a connected call alone and ends one still starting.

type Body = Record<string, unknown>;
interface Deferred<T> { promise: Promise<T>; resolve(v: T): void }
const deferred = <T>(): Deferred<T> => { let resolve!: (v: T) => void; const promise = new Promise<T>((r) => { resolve = r; }); return { promise, resolve }; };

class FakeCall {
  h: Record<string, Array<(...a: unknown[]) => void>> = {};
  disconnects = 0;
  readonly id: string;
  constructor(id: string) { this.id = id; }
  on(e: string, f: (...a: unknown[]) => void) { (this.h[e] ||= []).push(f); }
  emit(e: string, ...a: unknown[]) { for (const f of this.h[e] ?? []) f(...a); }
  accept() { this.emit('accept'); }
  reject() { this.emit('reject'); }
  disconnect() { this.disconnects++; this.emit('disconnect'); }
  mute() {}
  isMuted() { return false; }
  sendDigits() {}
}
const calls: FakeCall[] = [];
let holdConnect: Deferred<void> | null = null;
class FakeDevice {
  on() {}
  async register() {}
  async unregister() {}
  destroy() {}
  updateToken() {}
  async connect(o: { params: Record<string, string> }) {
    if (holdConnect) await holdConnect.promise;
    const c = new FakeCall(o.params.call ?? ''); calls.push(c); return c;
  }
}

// the server: each phone_call waits until the test answers it
const posts: Body[] = [];
const answers: Array<Deferred<Body>> = [];
const g = globalThis as unknown as Record<string, unknown>;
g.window = globalThis;
g.addEventListener = () => undefined;
g.Twilio = { Device: FakeDevice };
g.fetch = async (url: string, init?: { body?: string }) => {
  if (String(url).includes('what=voice_token')) return { ok: true, json: async () => ({ ok: true, token: 'fake-token', ring: false, ttl: 3600 }) };
  const b = JSON.parse(init?.body ?? '{}') as Body;
  posts.push(b);
  if (b.action !== 'phone_call') return { ok: true, json: async () => ({ ok: true }) };
  const d = deferred<Body>(); answers.push(d);
  const j = await d.promise;
  return { ok: true, json: async () => j };
};

const voice = await import('./voice.ts');
const at = <T>(a: T[], i: number): T => { const v = a[i]; assert.ok(v, `item ${i}`); return v; };
const phoneCalls = () => posts.filter((p) => p.action === 'phone_call');
const tick = () => new Promise((r) => setTimeout(r, 0));
const reset = () => { voice.hangUp(); voice.dismiss(); calls.length = 0; posts.length = 0; answers.length = 0; holdConnect = null; };

test('a call ended while the server answers never connects after the next call starts', async () => {
  reset();
  const first = voice.placeCall({ number: '+16475550101' });
  assert.equal(voice.voiceState().phase, 'starting');
  voice.hangUp();
  assert.equal(voice.voiceState().phase, 'idle');
  const second = voice.placeCall({ number: '+16475550102' });
  await tick();
  assert.equal(answers.length, 2);
  at(answers, 0).resolve({ ok: true, id: 'call-1', t: 't1' });
  await first;
  at(answers, 1).resolve({ ok: true, id: 'call-2', t: 't2' });
  await second;
  assert.deepEqual(calls.map((c) => c.id), ['call-2']);
  assert.equal(voice.voiceState().phase, 'calling');
  assert.equal(voice.voiceState().number, '+16475550102');
});

test('a call ended while Twilio connects is dropped, and the next call stays on the screen', async () => {
  reset();
  holdConnect = deferred<void>();
  const first = voice.placeCall({ number: '+16475550103' });
  await tick();
  at(answers, 0).resolve({ ok: true, id: 'call-3', t: 't3' });
  await tick(); await tick();
  voice.hangUp();
  const second = voice.placeCall({ number: '+16475550104' });
  await tick();
  at(answers, 1).resolve({ ok: true, id: 'call-4', t: 't4' });
  holdConnect.resolve();
  await first; await second;
  const c3 = calls.find((c) => c.id === 'call-3');
  assert.equal(c3?.disconnects, 1, 'the ended call is hung up as soon as it connects');
  assert.equal(voice.voiceState().phase, 'calling', 'its disconnect does not close the new call');
  assert.equal(voice.voiceState().number, '+16475550104');
});

test('a double tap places one call', async () => {
  reset();
  const a = voice.placeCall({ number: '+16475550105' });
  const b = voice.placeCall({ number: '+16475550105' });
  await tick();
  assert.equal(phoneCalls().length, 1);
  at(answers, 0).resolve({ ok: true, id: 'call-5', t: 't5' });
  await a; await b;
  await voice.placeCall({ number: '+16475550106' });
  assert.equal(phoneCalls().length, 1, 'no second call while one rings');
  assert.equal(calls.length, 1);
});

test('pagehide: a connected call stays on; a call still starting ends unless the page is kept', async () => {
  reset();
  const p = voice.placeCall({ number: '+16475550107' });
  await tick();
  at(answers, 0).resolve({ ok: true, id: 'call-7', t: 't7' });
  await p;
  at(calls, 0).emit('accept');
  assert.equal(voice.voiceState().phase, 'in_call');
  voice.onPageHide({ persisted: false });
  assert.equal(voice.voiceState().phase, 'in_call');
  assert.equal(at(calls, 0).disconnects, 0);
  voice.hangUp();
  assert.equal(at(calls, 0).disconnects, 1);

  void voice.placeCall({ number: '+16475550108' });
  assert.equal(voice.voiceState().phase, 'starting');
  voice.onPageHide({ persisted: true });
  assert.equal(voice.voiceState().phase, 'starting', 'a page kept for going back keeps its call');
  voice.onPageHide({ persisted: false });
  assert.equal(voice.voiceState().phase, 'idle');
  await tick();
  answers.at(-1)?.resolve({ ok: true, id: 'call-8', t: 't8' });
  await tick(); await tick();
  assert.equal(calls.length, 1, 'the call ended on pagehide never connects');
});
