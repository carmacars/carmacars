#!/usr/bin/env node
// The tracker relay (migration 0400, docs/tracker-ingest.md): a small TCP server for trackers that speak GT06 (binary).
// Each device connects, logs in with its IMEI and sends positions and heartbeats; the relay answers each frame the
// protocol asks it to, turns positions into the generic JSON and posts signed batches to the website's ingest every
// FLUSH_SECONDS (or sooner at 500 points). A failed post is kept and retried with the next batch (at most 20,000 points
// held; the ingest ignores a point it already has, so a retry is safe).
//
// Not running yet: CarmaCars' own tracker's protocol document is needed first (see gt06.ts for what to check). Then, on
// the server: node 22 or later, this repository checked out, and the systemd unit next to this file:
//   TRACKER_INGEST_URL=https://carmacars.ca/api/tracker/ingest TRACKER_INGEST_KEY=trk_... PORT=5023 \
//     node --experimental-strip-types infra/vps/tracker-relay/relay.mjs
// and the port open in the firewall. Each tracker is set (by SMS command, per its manual) to report to the server's
// address and port, with an interval of 10 to 30 seconds while moving.
//
// GT06 has no device password: whoever reaches the port can name any IMEI. So the relay keeps to the trackers it knows
// and to a modest load: TRACKER_IMEIS (comma separated; set it on the server, a login with another IMEI is closed), at
// most MAX_CONNECTIONS sockets and MAX_PER_ADDRESS from one address, LOGIN_SECONDS to log in, and at most
// MAX_FRAMES_PER_MINUTE frames a socket. The ingest still decides which devices exist (it ignores an unknown one).
import net from 'node:net';
import { decode, split } from '../../../web/src/integrations/tracker/gt06.ts';
import { signedHeaders } from '../../../web/src/integrations/tracker/ingest.ts';

const URL_ = process.env.TRACKER_INGEST_URL, KEY = process.env.TRACKER_INGEST_KEY;
const PORT = Number(process.env.PORT ?? 5023), FLUSH_SECONDS = Number(process.env.FLUSH_SECONDS ?? 15);
const IDLE_MS = 10 * 60_000, MAX_HELD = 20_000;
const ALLOWED = new Set((process.env.TRACKER_IMEIS ?? '').split(',').map((s) => s.trim()).filter(Boolean));
const num = (v, d) => { const n = Number(v); return Number.isFinite(n) && n > 0 ? n : d; };
const MAX_CONNECTIONS = num(process.env.MAX_CONNECTIONS, 500), MAX_PER_ADDRESS = num(process.env.MAX_PER_ADDRESS, 20);
const LOGIN_MS = num(process.env.LOGIN_SECONDS, 30) * 1000, MAX_FRAMES_PER_MINUTE = num(process.env.MAX_FRAMES_PER_MINUTE, 240);
const perAddress = new Map();
if (!URL_ || !KEY) { console.error('Set TRACKER_INGEST_URL and TRACKER_INGEST_KEY'); process.exit(2); }

let held = [];
const log = (...a) => console.log(new Date().toISOString(), ...a);

async function flush() {
  if (!held.length) return;
  const out = held.splice(0, 5000);
  const raw = JSON.stringify({ points: out });
  try {
    const r = await fetch(URL_, { method: 'POST', headers: await signedHeaders(raw, KEY), body: raw, signal: AbortSignal.timeout(20_000) });
    if (r.status >= 500 || r.status === 429) throw new Error(`HTTP ${r.status}`);
    if (!r.ok) log('refused', r.status, await r.text()); // a 4xx is not retried (a bad key, a bad batch): fix and restart
    else log('sent', out.length, await r.text());
  } catch (e) {
    held = out.concat(held).slice(-MAX_HELD);
    log('not sent, kept for the next batch:', e.message);
  }
}
setInterval(() => void flush(), FLUSH_SECONDS * 1000);

const server = net.createServer((sock) => {
  let buf = new Uint8Array(0), imei = null, status = {}, frames = 0, windowAt = Date.now();
  const from = sock.remoteAddress ?? '?';
  const open = (perAddress.get(from) ?? 0) + 1;
  if (open > MAX_PER_ADDRESS) { sock.destroy(); return; }
  perAddress.set(from, open);
  sock.once('close', () => { const n = (perAddress.get(from) ?? 1) - 1; if (n > 0) perAddress.set(from, n); else perAddress.delete(from); });
  sock.setTimeout(IDLE_MS, () => sock.destroy());
  // a connection that has not logged in soon is closed
  const loginTimer = setTimeout(() => { if (!imei) sock.destroy(); }, LOGIN_MS);
  sock.once('close', () => clearTimeout(loginTimer));
  sock.on('data', (chunk) => {
    const all = new Uint8Array(buf.length + chunk.length); all.set(buf); all.set(chunk, buf.length);
    const { frames: list, rest } = split(all);
    buf = rest.length > 4096 ? new Uint8Array(0) : rest;
    for (const f of list) {
      const now = Date.now();
      if (now - windowAt > 60_000) { windowAt = now; frames = 0; }
      if (++frames > MAX_FRAMES_PER_MINUTE) { log('too many frames, closed', imei ?? from); sock.destroy(); return; }
      let m;
      try { m = decode(f); } catch (e) { log('bad frame from', imei ?? from, String(e?.message ?? e).slice(0, 120)); continue; }
      if (m.kind === 'login') {
        const id = String(m.imei ?? '');
        if (!/^\d{14,17}$/.test(id) || (ALLOWED.size > 0 && !ALLOWED.has(id))) { log('login refused from', from); sock.destroy(); return; }
        if (m.ack) sock.write(m.ack);
        imei = id; log('login', imei); continue;
      }
      if (!imei) continue; // a device must log in first (nothing is answered before)
      if (m.ack) sock.write(m.ack);
      if (m.kind === 'status' || m.kind === 'alarm') status = m.status;
      if (m.kind === 'location' || m.kind === 'alarm') {
        if (!m.fix.positioned) continue;
        held.push({ device: imei, at: m.fix.at, lat: m.fix.lat, lng: m.fix.lng, speed: m.fix.speed, heading: m.fix.heading,
          ignition: m.fix.ignition ?? status.ignition ?? null, odometer: m.fix.odometer ?? null, battery: status.battery ?? null, power: status.power ?? null });
        if (held.length >= 500) void flush();
      }
    }
  });
  sock.on('error', () => sock.destroy());
});
server.maxConnections = MAX_CONNECTIONS;
server.listen(PORT, () => log(`GT06 relay listening on ${PORT}; ${ALLOWED.size ? `${ALLOWED.size} trackers allowed` : 'TRACKER_IMEIS is not set: any IMEI may log in'}`));
