#!/usr/bin/env node
// The fixed references of the generated listing views (release 47, migration 2900; src/features/listing/r48.ts):
//   1. the composition guides: the sample cars' drawing of each angle (src/features/car/studio.ts carShot) for each body
//      type, rendered once to JPEG and stored at site/r48/guides/<body>-<shot>.jpg (vehicle-public). Gemini copies only
//      the camera position and framing from them.
//   2. the background plates (front, side, rear): a photorealistic empty showroom made by Gemini's image model from
//      r48.ts platePrompt, kept only when a second Gemini look (PLATE_CHECK_PROMPT) says it looks like a real photograph
//      with no text, logo, car or person and a free floor; up to 3 tries a family. Stored at site/r48/plates/<family>.jpg and
//      saved in listing_r48_plates (source gemini). A plate an Admin uploaded is kept unless --replace.
// The worker makes a missing plate itself on first need, so running this is optional; it lets the plates be made and
// looked at before the fleet run. Without --write nothing is stored: the files go to --out for a look.
//
//   node --experimental-strip-types scripts/r48-references.mjs [--guides] [--plates] [--write] [--replace] [--out DIR]
//     --write   store and save (STORAGE_URL, SERVICE_KEY, GEMINI_API_KEY, and SQL_API_URL or SUPABASE_PROJECT_REF + SUPABASE_ACCESS_TOKEN)
//     neither --guides nor --plates: both
import { mkdirSync, writeFileSync } from 'node:fs';
import path from 'node:path';
import { PLATE_CHECK_PROMPT, PLATE_CHECK_SCHEMA, PLATE_CHECK_SYSTEM, PLATE_FAMILIES, R48_ANGLES, judgePlate, platePath, platePrompt } from '../src/features/listing/r48.ts';

const args = process.argv.slice(2);
const flag = (k) => args.includes(`--${k}`);
const opt = (k, d = null) => { const i = args.indexOf(`--${k}`); return i >= 0 && args[i + 1] && !args[i + 1].startsWith('--') ? args[i + 1] : d; };
const WRITE = flag('write'), REPLACE = flag('replace');
const ONLY_G = flag('guides'), ONLY_P = flag('plates');
const DO_G = ONLY_G || !ONLY_P, DO_P = ONLY_P || !ONLY_G;
const OUT = opt('out', path.resolve('r48-references-out'));
const STORAGE = process.env.STORAGE_URL, KEY = process.env.SERVICE_KEY, GEMINI = process.env.GEMINI_API_KEY;
const IMAGE_MODEL = process.env.GEMINI_IMAGE_MODEL || 'gemini-2.5-flash-image', CHECK_MODEL = process.env.GEMINI_CHECK_MODEL || 'gemini-2.5-flash';
const BASE = 'https://generativelanguage.googleapis.com/v1beta/models';
// the body types of app.sample_body_key and the studio drawing's shape of each (as scripts/gen-sample-photos.mjs)
const BODIES = { sedan: 'sedan', suv: 'suv', truck: 'suvlg', van: 'van', coupe: 'fastback', hatchback: 'compact', ev: 'sedan' };

async function put(p, bytes, type = 'image/jpeg') {
  const r = await fetch(`${STORAGE}/object/vehicle-public/${p}`, { method: 'POST', headers: { authorization: `Bearer ${KEY}`, apikey: KEY, 'content-type': type, 'x-upsert': 'true' },
    body: bytes, signal: AbortSignal.timeout(120_000) });
  if (!r.ok) throw new Error(`store ${p}: ${r.status} ${(await r.text()).slice(0, 200)}`);
}
async function sql(query) {
  const api = process.env.SQL_API_URL, ref = process.env.SUPABASE_PROJECT_REF, token = process.env.SUPABASE_ACCESS_TOKEN;
  if (!api && (!ref || !token)) throw new Error('SQL_API_URL, or SUPABASE_PROJECT_REF and SUPABASE_ACCESS_TOKEN, are needed');
  const r = await fetch(api ?? `https://api.supabase.com/v1/projects/${ref}/database/query`, { method: 'POST',
    headers: { ...(api ? {} : { authorization: `Bearer ${token}` }), 'content-type': 'application/json' }, body: JSON.stringify({ query }), signal: AbortSignal.timeout(120_000) });
  const text = await r.text();
  if (!r.ok) throw new Error(`SQL failed (${r.status}): ${text.slice(0, 400)}`);
  const rows = JSON.parse(text);
  return Array.isArray(rows) ? rows : rows?.result ?? [];
}
const q = (v) => (v === null || v === undefined ? 'null' : `'${String(v).replace(/'/g, "''")}'`);
const save = (p, bytes) => { mkdirSync(path.dirname(path.join(OUT, p)), { recursive: true }); writeFileSync(path.join(OUT, p), bytes); };

async function gemini(model, body) {
  const r = await fetch(`${BASE}/${model}:generateContent`, { method: 'POST', headers: { 'content-type': 'application/json', 'x-goog-api-key': GEMINI },
    body: JSON.stringify(body), signal: AbortSignal.timeout(120_000) });
  const j = await r.json().catch(() => null);
  if (!r.ok) throw new Error(`Gemini ${model}: ${r.status} ${j?.error?.message ?? ''}`.slice(0, 300));
  return j;
}

// ---------------------------------------------------------------- 1. the composition guides
async function guides() {
  const { chromium } = await import('@playwright/test');
  const { carShot } = await import('../src/features/car/studio.ts');
  const browser = await chromium.launch(process.env.CHROME ? { executablePath: process.env.CHROME } : {});
  const page = await browser.newPage({ viewport: { width: 1200, height: 800 } });
  let n = 0;
  for (const [body, shape] of Object.entries(BODIES)) {
    for (const a of R48_ANGLES.filter((x) => x.guide)) {
      const svg = carShot({ year: '', name: '', model: '', colour: 'grey', shape, paint: 'grey' }, a.guide, 1200, 800, '').replace(/\n\s+/g, '\n');
      await page.setContent(`<!doctype html><html><body style="margin:0">${svg}</body></html>`);
      const jpg = await page.screenshot({ type: 'jpeg', quality: 80, clip: { x: 0, y: 0, width: 1200, height: 800 } });
      const p = `site/r48/guides/${body}-${a.guide}.jpg`;
      if (WRITE) await put(p, jpg); else save(p, jpg);
      n++;
    }
  }
  await browser.close();
  console.log(`r48-references: ${n} composition guides ${WRITE ? 'stored' : `written to ${OUT}`}`);
}

// ---------------------------------------------------------------- 2. the plates
async function plate(f) {
  const blank = Buffer.from(await (await import('sharp')).default({ create: { width: 48, height: 32, channels: 3, background: { r: 200, g: 200, b: 200 } } }).jpeg().toBuffer()).toString('base64');
  for (let k = 1; k <= 3; k++) {
    const made = await gemini(IMAGE_MODEL, { contents: [{ role: 'user', parts: [{ text: `${platePrompt(f)} Ignore the plain grey image: it is only a blank canvas.` },
      { inline_data: { mime_type: 'image/jpeg', data: blank } }] }], generationConfig: { responseModalities: ['IMAGE'], imageConfig: { aspectRatio: '3:2' } } });
    const part = made?.candidates?.[0]?.content?.parts?.find((x) => x.inlineData?.data || x.inline_data?.data);
    const data = part?.inlineData?.data ?? part?.inline_data?.data;
    if (!data) { console.log(`  ${f} try ${k}: no image`); continue; }
    const jpg = await (await import('sharp')).default(Buffer.from(data, 'base64')).resize(1800, 1200, { fit: 'cover' }).jpeg({ quality: 90 }).toBuffer();
    const checked = await gemini(CHECK_MODEL, { systemInstruction: { parts: [{ text: PLATE_CHECK_SYSTEM }] },
      contents: [{ role: 'user', parts: [{ text: PLATE_CHECK_PROMPT }, { inline_data: { mime_type: 'image/jpeg', data: jpg.toString('base64') } }] }],
      generationConfig: { temperature: 0, responseMimeType: 'application/json', responseSchema: PLATE_CHECK_SCHEMA } });
    let answer = null;
    try { answer = JSON.parse(checked?.candidates?.[0]?.content?.parts?.map((x) => x.text ?? '').join('') ?? ''); } catch { /* refused below */ }
    const v = judgePlate(answer);
    console.log(`  ${f} try ${k}: ${v.pass ? 'looks real' : `refused (${v.reasons.join(', ')})`}`);
    if (v.pass) return { jpg, check: { pass: true, model: `gemini:${CHECK_MODEL}`, issues: Array.isArray(answer?.issues) ? answer.issues.slice(0, 5) : [] } };
  }
  return null;
}
async function plates() {
  if (!GEMINI) throw new Error('GEMINI_API_KEY is needed to make the plates');
  const have = WRITE ? await sql('select family, source from listing_r48_plates') : [];
  for (const f of PLATE_FAMILIES) {
    const row = have.find((r) => r.family === f);
    if (row && (row.source === 'admin' || !REPLACE)) { console.log(`  ${f}: kept (${row.source})`); continue; }
    const made = await plate(f);
    if (!made) { console.log(`  ${f}: not made (refused three times); the worker tries again on first need`); continue; }
    const p = platePath(f);
    if (!WRITE) { save(p, made.jpg); continue; }
    await put(p, made.jpg);
    await sql(`insert into listing_r48_plates (family, path, source, model, "check") values (${q(f)}, ${q(p)}, 'gemini', ${q(IMAGE_MODEL)}, ${q(JSON.stringify(made.check))}::jsonb)
      on conflict (family) do update set path = excluded.path, source = 'gemini', model = excluded.model, "check" = excluded."check", made_by = null, made_at = now()
      where listing_r48_plates.source <> 'admin'`);
  }
  console.log(`r48-references: plates ${WRITE ? 'stored' : `written to ${OUT}`}`);
}

if (import.meta.url === `file://${process.argv[1]}`) {
  if (WRITE && (!STORAGE || !KEY)) throw new Error('STORAGE_URL and SERVICE_KEY are needed to write');
  if (DO_G) await guides();
  if (DO_P) await plates();
}
