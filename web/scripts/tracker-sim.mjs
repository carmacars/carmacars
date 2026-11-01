#!/usr/bin/env node
// The tracker simulator (migration 0400): fake cars drive the GTA's highways and report to the ingest exactly as the relay
// will (signed batches of the generic JSON). For local work and tests only; it never runs in production.
//
//   node --experimental-strip-types scripts/tracker-sim.mjs --key trk_... [--url http://localhost:3000] [--cars 6]
//        [--every 10] [--batch 30] [--once 600]
//
//   --key    the ingest key (Admin > Cars > Fleet tracking > Settings > Make the ingest key), or TRACKER_INGEST_KEY
//   --cars   how many cars (devices SIM-0001, SIM-0002, ...); pair them in Fleet tracking (they show under
//            "Reporting, not on a car yet" after the first batch)
//   --every  seconds between two positions of a car (10)
//   --batch  seconds between two batches (30), as a relay would send them
//   --once   send one batch of the last N seconds and stop (the tests)
import { simFleet, simPoints } from '../src/features/tracking/sim.ts';
import { signedHeaders } from '../src/integrations/tracker/ingest.ts';

const arg = (name, dflt) => { const i = process.argv.indexOf(`--${name}`); return i > 0 ? process.argv[i + 1] : dflt; };
const key = arg('key', process.env.TRACKER_INGEST_KEY);
const url = `${arg('url', process.env.SITE_URL ?? 'http://localhost:3000').replace(/\/$/, '')}/api/tracker/ingest`;
const n = Number(arg('cars', 6)), every = Number(arg('every', 10)), batch = Number(arg('batch', 30)), once = arg('once', null);
if (!key) { console.error('Give the ingest key: --key trk_... (Admin > Cars > Fleet tracking > Settings)'); process.exit(2); }
if (/carmacars\.ca/.test(url)) { console.error('The simulator never reports to the live site.'); process.exit(2); }

const cars = simFleet(Array.from({ length: n }, (_, i) => `SIM-${String(i + 1).padStart(4, '0')}`));
async function send(from, to) {
  const raw = JSON.stringify({ points: simPoints(cars, from, to, every) });
  const r = await fetch(url, { method: 'POST', headers: await signedHeaders(raw, key), body: raw });
  const j = await r.json().catch(() => ({}));
  console.log(new Date().toISOString(), r.status, JSON.stringify(j));
  return r.ok;
}

if (once) {
  const now = Date.now();
  process.exit((await send(now - Number(once) * 1000, now)) ? 0 : 1);
}
let last = Date.now() - batch * 1000;
for (;;) {
  const now = Date.now();
  await send(last + 1, now).catch((e) => console.error('not sent:', e.message));
  last = now;
  await new Promise((r) => setTimeout(r, batch * 1000));
}
