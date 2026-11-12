// The Realtime connection of the live updates (hub.ts): Supabase Realtime's websocket (the Phoenix protocol, vsn 1.0.0)
// spoken directly, so no page carries the Supabase client for it. Public broadcast channels only, named by the server's
// opaque topics; a broadcast carries nothing but the fact of a change. When the server has no Realtime (the socket fails
// before it ever opens, twice), it gives up, says "not joined" and the hub reads every 2 seconds instead; the give-up is
// remembered for the tab's session for 10 minutes (sessionStorage), so the next pages do not try again at once.
// No imports: the message helpers are unit tested in Node (socket.test.ts).

import type { LiveSocket, Timers } from './hub';

export const HEARTBEAT_MS = 25_000;
export const RETRY_MS = [1000, 2000, 5000, 10_000, 30_000];
export const OFF_KEY = 'cc-live-rt-off';
export const OFF_MS = 10 * 60_000;

export type PhxMessage = { topic: string; event: string; payload: Record<string, unknown>; ref: string | null; join_ref?: string | null };

/** The websocket address of Realtime behind the Supabase API address. */
export function socketUrl(apiUrl: string, apiKey: string): string | null {
  if (!apiUrl || !apiKey) return null;
  let u: URL;
  try { u = new URL(apiUrl); } catch { return null; }
  u.protocol = u.protocol === 'http:' ? 'ws:' : 'wss:';
  u.pathname = `${u.pathname.replace(/\/$/, '')}/realtime/v1/websocket`;
  u.search = `?apikey=${encodeURIComponent(apiKey)}&vsn=1.0.0`;
  return u.toString();
}

export const channelOf = (topic: string) => `realtime:${topic}`;

export function joinMessage(topic: string, ref: string): PhxMessage {
  return { topic: channelOf(topic), event: 'phx_join', ref, join_ref: ref,
    payload: { config: { broadcast: { self: false, ack: false }, presence: { key: '', enabled: false }, postgres_changes: [], private: false } } };
}
export const leaveMessage = (topic: string, ref: string): PhxMessage => ({ topic: channelOf(topic), event: 'phx_leave', ref, payload: {} });
export const heartbeatMessage = (ref: string): PhxMessage => ({ topic: 'phoenix', event: 'heartbeat', ref, payload: {} });

/** What a received frame means for the hub: a broadcast on a topic, a join's answer, or nothing. */
export function readFrame(raw: unknown): { kind: 'bump'; topic: string } | { kind: 'joined'; topic: string; ok: boolean } | null {
  if (typeof raw !== 'string') return null;
  let m: PhxMessage;
  try { m = JSON.parse(raw) as PhxMessage; } catch { return null; }
  if (!m || typeof m.topic !== 'string' || !m.topic.startsWith('realtime:')) return null;
  const topic = m.topic.slice('realtime:'.length);
  if (m.event === 'broadcast' || m.event === 'postgres_changes') return { kind: 'bump', topic };
  if (m.event === 'phx_reply' && m.ref && m.ref === m.join_ref) return { kind: 'joined', topic, ok: (m.payload as { status?: string })?.status === 'ok' };
  if (m.event === 'phx_error' || m.event === 'phx_close') return { kind: 'joined', topic, ok: false };
  return null;
}

/** Whether this tab gave up on Realtime lately. */
export function realtimeOff(store: Pick<Storage, 'getItem'> | null, now: number): boolean {
  try { const at = Number(store?.getItem(OFF_KEY) ?? 0); return at > 0 && now - at < OFF_MS; } catch { return false; }
}

export type WsLike = { readyState: number; send(d: string): void; close(): void; onopen: (() => void) | null; onclose: (() => void) | null; onerror: (() => void) | null; onmessage: ((e: { data: unknown }) => void) | null };

export function createSocket(o: {
  url: string;
  ws: (url: string) => WsLike;
  onBump: (topic: string) => void;
  onJoined: (joined: boolean) => void;
  timers?: Timers;
  giveUp?: () => void;
}): LiveSocket {
  const timers = o.timers ?? { set: (f: () => void, ms: number) => setTimeout(f, ms), clear: (t: unknown) => clearTimeout(t as ReturnType<typeof setTimeout>) };
  let ws: WsLike | null = null;
  let want: string[] = [];
  const joined = new Map<string, boolean>();
  let ref = 0;
  let hb: unknown;
  let retry: unknown;
  let tries = 0;
  let everOpen = false;
  let closed = false;
  let told = false;

  const say = () => {
    const all = want.length > 0 && want.every((t) => joined.get(t) === true);
    if (all !== told) { told = all; o.onJoined(all); }
  };
  const send = (m: PhxMessage) => { if (ws && ws.readyState === 1) ws.send(JSON.stringify(m)); };
  const join = (t: string) => { joined.set(t, false); send(joinMessage(t, String(++ref))); };

  const open = () => {
    if (closed) return;
    try { ws = o.ws(o.url); } catch { ws = null; fail(); return; }
    ws.onopen = () => {
      everOpen = true; tries = 0;
      for (const t of want) join(t);
      const beat = () => { send(heartbeatMessage(String(++ref))); hb = timers.set(beat, HEARTBEAT_MS); };
      hb = timers.set(beat, HEARTBEAT_MS);
    };
    ws.onmessage = (e) => {
      const f = readFrame(e.data);
      if (!f || !want.includes(f.topic)) return;
      if (f.kind === 'bump') o.onBump(f.topic);
      else { joined.set(f.topic, f.ok); say(); }
    };
    ws.onerror = () => { /* onclose follows */ };
    ws.onclose = () => { ws = null; fail(); };
  };
  const fail = () => {
    if (hb !== undefined) { timers.clear(hb); hb = undefined; }
    joined.clear(); say();
    if (closed) return;
    tries++;
    // no Realtime on this server: stop trying after two failures that never opened
    if (!everOpen && tries >= 2) { o.giveUp?.(); return; }
    retry = timers.set(open, RETRY_MS[Math.min(tries - 1, RETRY_MS.length - 1)]!);
  };

  open();
  return {
    set(topics) {
      const next = [...new Set(topics)];
      for (const t of want) if (!next.includes(t)) { send(leaveMessage(t, String(++ref))); joined.delete(t); }
      const add = next.filter((t) => !want.includes(t));
      want = next;
      for (const t of add) join(t);
      say();
    },
    close() {
      closed = true;
      if (hb !== undefined) timers.clear(hb);
      if (retry !== undefined) timers.clear(retry);
      try { ws?.close(); } catch { /* closed already */ }
      ws = null;
    }
  };
}
