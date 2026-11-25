// The fake media (CALLS_PROVIDER=fake, CI and local): no camera or microphone is opened. The site's own relay
// (/api/calls/fake, never in production) carries who is in the room and the data messages, so the slide sync, the chat
// and the raised hands work end to end between two people without a media server.
import { parseMsg, type MediaSession, type Msg, type Person, type Received, type Ticket } from './adapter';

interface Wire { n: number; k: 'hello' | 'here' | 'bye' | 'msg'; from: string; name: string; role: Person['role']; state?: Pick<Person, 'mic' | 'cam' | 'screen'>; msg?: unknown; at: number }

export function fakeSession(t: Ticket): MediaSession {
  const me: Person = { identity: t.identity, name: t.name, role: t.role, local: true, mic: false, cam: false, screen: false, speaking: false };
  const others = new Map<string, Person & { seen: number }>();
  let since = 0;
  let timer: ReturnType<typeof setInterval> | null = null;
  let beat = 0;
  let change: () => void = () => {};
  let message: (r: Received) => void = () => {};
  let ended: (why: string) => void = () => {};
  const post = (k: Wire['k'], msg?: unknown) => fetch('/api/calls/fake', { method: 'POST', headers: { 'content-type': 'application/json' },
    body: JSON.stringify({ room: t.room, wire: { k, from: me.identity, name: me.name, role: me.role, state: { mic: me.mic, cam: me.cam, screen: me.screen }, msg } }) }).catch(() => undefined);
  async function poll() {
    const r = await fetch(`/api/calls/fake?room=${encodeURIComponent(t.room)}&since=${since}`).then((x) => x.json() as Promise<{ n: number; wires: Wire[] }>).catch(() => null);
    if (!r) return;
    let changed = false;
    for (const w of r.wires) {
      since = Math.max(since, w.n);
      if (w.from === me.identity) continue;
      if (w.k === 'bye') { changed = others.delete(w.from) || changed; continue; }
      others.set(w.from, { identity: w.from, name: w.name, role: w.role, local: false, mic: !!w.state?.mic, cam: !!w.state?.cam, screen: !!w.state?.screen, speaking: false, seen: w.at });
      changed = true;
      if (w.k === 'hello') void post('here');
      if (w.k === 'msg') { const m = parseMsg(w.msg); if (m) message({ from: w.from, name: w.name, msg: m }); }
    }
    // someone who stopped saying they are here (closed the tab) is gone after 15 s
    for (const [id, p] of others) if (Date.now() - p.seen > 15_000) { others.delete(id); changed = true; }
    if (++beat % 8 === 0) void post('here');
    if (changed) change();
  }
  return {
    async connect() {
      // only what is said from now on: the room's history is skipped; everyone in it answers the hello
      const r = await fetch(`/api/calls/fake?room=${encodeURIComponent(t.room)}&since=${Number.MAX_SAFE_INTEGER}`).then((x) => x.json() as Promise<{ n: number }>).catch(() => ({ n: 0 }));
      since = r.n;
      await post('hello');
      timer = setInterval(() => void poll(), 600);
      await poll();
    },
    disconnect() { if (timer) clearInterval(timer); timer = null; void post('bye'); ended('left'); },
    async setMic(on) { me.mic = on; void post('here'); change(); },
    async setCam(on) { me.cam = on; void post('here'); change(); },
    async setScreen(on) { me.screen = on; void post('here'); change(); },
    send(m: Msg) { void post('msg', m); },
    people: () => [me, ...[...others.values()].map((p) => ({ identity: p.identity, name: p.name, role: p.role, local: false, mic: p.mic, cam: p.cam, screen: p.screen, speaking: false }))],
    attach: () => false,
    onChange(f) { change = f; },
    onMessage(f) { message = f; },
    onEnded(f) { ended = f; },
  };
}
