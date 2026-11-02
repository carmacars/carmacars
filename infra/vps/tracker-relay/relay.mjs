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
import net from 'node:net';
import { decode, split } from '../../../web/src/integrations/tracker/gt06.ts';
import { signedHeaders } from '../../../web/src/integrations/tracker/ingest.ts';

const URL_ = process.env.TRACKER_INGEST_URL, KEY = process.env.TRACKER_INGEST_KEY;
const PORT = Number(process.env.PORT ?? 5023), FLUSH_SECONDS = Number(process.env.FLUSH_SECONDS ?? 15);
const IDLE_MS = 10 * 60_000, MAX_HELD = 20_000;
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

net.createServer((sock) => {
  let buf = new Uint8Array(0), imei = null, status = {};
  sock.setTimeout(IDLE_MS, () => sock.destroy());
  sock.on('data', (chunk) => {
    const all = new Uint8Array(buf.length + chunk.length); all.set(buf); all.set(chunk, buf.length);
    const { frames, rest } = split(all);
    buf = rest.length > 4096 ? new Uint8Array(0) : rest;
    for (const f of frames) {
      let m;
      try { m = decode(f); } catch (e) { log('bad frame from', imei ?? sock.remoteAddress, e.message); continue; }
      if (m.ack) sock.write(m.ack);
      if (m.kind === 'login') { imei = m.imei; log('login', imei); continue; }
      if (!imei) continue; // a device must log in first
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
}).listen(PORT, () => log(`GT06 relay listening on ${PORT}`));
