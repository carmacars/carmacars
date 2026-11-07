// The listing pipeline's worker (docs/blueprint/09-listing-pipeline.md section 5): claims due jobs from the
// queue of migration 0022 (through 0032's server_listing_claim), runs each with the providers, and reports
// the result (server_listing_result), which moves the intake on. Pure: every outside service is passed in,
// so the unit tests run it with fakes and the server wires the real ones (src/server/listing-worker.ts).
import type { TextGenerator } from '../../integrations/llm/types.ts';
import type { PhotoOut, PhotoProcessor } from '../../integrations/photos/types.ts';
import { DEFAULT_RULES, DRAFT_SCHEMA, PROMPT_VERSION, draftProblems, normalizeDraft, systemPrompt, userPrompt, type CopyRules, type Draft } from './prompt.ts';
import { plainDraft } from '../seo/copy.ts';
import { LETTERING, letteringPath, letteringPng } from './lettering.ts';
import { WINDOW_SHOTS, readAlpha, windowPlan, type WindowPlan } from './window-check.ts';
import { decodePng, frameSubject, placeSubject } from './subject-frame.ts';
import { enhanceValues, statsOf, type Enhance } from './enhance.ts';
import { cropAway, type MarkBox } from './photo-sort.ts';

// 0073: the sample cars' black studio with the model's name behind the car (was brand_background_v1, a light grey room).
// r28 (0567): studio_v3, the car framed to its own edges (subject-frame.ts): about 80% of the width, the wheels on the floor
// line, a contact shadow under the tyres, any mark or caption beside the car left out.
// r31 (0660): studio_v4, the car found at a firm alpha (the segmenter's haze and the floor's reflection no longer count as
// car, which left the car a quarter of the width and floating), and no model name lettered behind a real car: it showed
// as a large faint word around the car. The stand-ins (car/studio.ts) keep their lettering, as the sample cars.
export const PRESET = 'studio_v4';
/** r31: the model's name is not lettered behind real photos (lettering.ts stays for a later, quieter version). */
export const LETTER_REAL_PHOTOS = false;
export const BACKDROP_PATH = 'site/backdrop/studio_v2.png';
export const SHADOW_PATH = 'site/backdrop/shadow_v1.png';
/** The sizes the site uses (srcset of the car cards and the gallery); the master is 1800 wide. */
export const VARIANT_WIDTHS = [480, 800, 1200] as const;
const EXTERIOR = { width: 1800, height: 1200 };
const INTERIOR = { width: 1600, height: 1200 };
/** Paid rates, for the cost recorded above the free allowances. */
const MICROUSD_PER_NEURON = 11;              // US$0.011 per 1,000 neurons
const MICROUSD_PER_TRANSFORMATION = 500;     // US$0.50 per 1,000 unique transformations
const FREE_DAILY_NEURONS = 10_000;

export interface JobContext {
  id: string; kind: 'decode_vin' | 'draft_copy' | 'process_photo' | 'resize' | 'publish'; intake_id: string; vehicle_id: string;
  attempts: number; max_attempts: number; input: Record<string, unknown>; vin?: string | null;
  facts?: Record<string, unknown> | null; staff_notes?: string | null; classes?: string[] | null;
  copy_rules?: { headline_chars: [number, number]; description_words: [number, number]; features: [number, number]; faq: [number, number]; banned_phrases: string[] } | null;
  photo?: { id: string; shot_type: string; angle: string; original_path: string; processed_path: string | null; rebackground: boolean; is_public: boolean; file_base: string; model?: string | null;
    /** 0567: the photo is flagged "watermark" (the sorter saw a mark, or it is queued for the check) */
    watermark?: boolean;
    /** 0568: the light touch-up applies (Admin "Auto-enhance listing photos" on, the photo's "Use original colours" off) */
    enhance?: boolean } | null;
}
export interface Budget { ai_neurons_today: number; ai_neurons_limit: number; transformations_month: number; transformations_free: number;
  /** The usage guard (0080): the month's included image transformations are used and paid usage is not allowed. */
  images_paused?: boolean }
/** The fallback reason of a photo that kept its original because of the usage guard; the database retries it later. */
export const USAGE_PAUSED = 'usage_paused';
export interface Claim { jobs: JobContext[]; budget: Budget; held: { photos: boolean; copy: boolean }; due: number }

export interface JobResult {
  ok: boolean; output?: Record<string, unknown>; provider?: string; cost_microusd?: number; duration_ms?: number;
  units?: number; unit?: 'neurons' | 'transformations' | 'requests'; error?: string; retryable?: boolean;
}

export interface VinAnswer { provider: string; result: { ok: boolean; error_code?: string } & Record<string, unknown> }

export interface WorkerDeps {
  claim(limit: number): Promise<Claim>;
  report(jobId: string, r: JobResult): Promise<unknown>;
  decodeVin(vin: string): Promise<VinAnswer>;
  text: TextGenerator;
  photos: PhotoProcessor;
  files: {
    /** A link the photo provider can fetch for a private original (a few minutes). */
    privateUrl(path: string): Promise<string>;
    publicUrl(path: string): string;
    getPrivate(path: string): Promise<Uint8Array | null>;
    putPrivate(path: string, bytes: Uint8Array, contentType: string): Promise<void>;
    putPublic(path: string, bytes: Uint8Array, contentType: string): Promise<void>;
    /** Whether a public file exists already (the model-name band is drawn once per model). */
    hasPublic?(path: string): Promise<boolean>;
  };
  /** 0567: where the overlaid marks (watermark, logo, caption) are on an edited inside or detail photo, as fractions;
   *  [] none; null the model could not be asked (the photo then stays flagged, off the site). */
  findMarks?(img: { bytes: Uint8Array; contentType: string; width: number; height: number; photoId: string }): Promise<MarkBox[] | null>;
  now?(): number;
  /** The car copy is written by the search job (0061, features/seo): the draft step stores a plain copy from the
   *  facts without calling the model, so no neurons are spent twice. */
  plainCopy?: boolean;
}

export interface RunSummary { claimed: number; succeeded: number; failed: number; held: { photos: boolean; copy: boolean }; due: number; errors: string[] }

const ext = (type: string) => (type === 'image/png' ? 'png' : type === 'image/webp' ? 'webp' : 'jpg');

/** Runs due jobs until none are left, the limit is reached or the time is up. */
export async function runListingWorker(d: WorkerDeps, o: { maxJobs?: number; batch?: number; deadlineMs?: number } = {}): Promise<RunSummary> {
  const now = d.now ?? (() => Date.now());
  const start = now();
  const deadline = o.deadlineMs ?? 25_000;
  const max = o.maxJobs ?? 12;
  const sum: RunSummary = { claimed: 0, succeeded: 0, failed: 0, held: { photos: false, copy: false }, due: 0, errors: [] };
  // the neurons and transformations used in this run, on top of what the claim reported
  const used = { neurons: 0, transformations: 0 };
  while (sum.claimed < max && now() - start < deadline) {
    const c = await d.claim(Math.min(o.batch ?? 4, max - sum.claimed));
    sum.held = c.held; sum.due = c.due;
    if (!c.jobs.length) break;
    sum.claimed += c.jobs.length;
    // the copy and the photos of one car run side by side; the reports go one at a time (each moves the intake on)
    let reports: Promise<unknown> = Promise.resolve();
    await Promise.all(c.jobs.map(async (j) => {
      const t0 = now();
      let r: JobResult;
      try {
        r = await runJob(d, j, c.budget, used);
      } catch (e) {
        r = { ok: false, error: e instanceof Error ? e.message : String(e), retryable: true };
      }
      r.duration_ms ??= Math.max(0, Math.round(now() - t0));
      if (r.ok) sum.succeeded++; else { sum.failed++; sum.errors.push(`${j.kind}: ${r.error ?? 'failed'}`); }
      const report = async () => {
        for (let attempt = 0; attempt < 3; attempt++) {
          try { await d.report(j.id, r); return; } catch (e) {
            const msg = e instanceof Error ? e.message : String(e);
            if (attempt === 2 || !/deadlock|could not serialize|lock/i.test(msg)) { sum.errors.push(`report ${j.kind}: ${msg}`); return; }
          }
        }
      };
      reports = reports.then(report);
      await reports;
    }));
  }
  return sum;
}

export async function runJob(d: WorkerDeps, j: JobContext, b: Budget, used = { neurons: 0, transformations: 0 }): Promise<JobResult> {
  switch (j.kind) {
    case 'decode_vin': return decode(d, j);
    case 'draft_copy': return draft(d, j, b, used);
    case 'process_photo': return processPhoto(d, j, b, used);
    case 'resize': return resize(d, j, b, used);
    case 'publish': return { ok: true, output: {}, provider: 'carmacars' };
  }
}

async function decode(d: WorkerDeps, j: JobContext): Promise<JobResult> {
  const vin = String(j.vin ?? j.input.vin ?? '');
  if (!/^[A-HJ-NPR-Z0-9]{17}$/.test(vin)) return { ok: true, provider: 'none', output: { ok: false, error_code: 'invalid_vin' } };
  const a = await d.decodeVin(vin);
  // the decoder could not be reached: try again later; any answer (even "not found") is final
  if (!a.result.ok && a.result.error_code === 'unreachable') return { ok: false, provider: a.provider, error: 'The VIN decoder did not answer', retryable: true, units: 1, unit: 'requests' };
  return { ok: true, provider: a.provider, output: { ...a.result, provider: a.provider }, units: 1, unit: 'requests' };
}

function rulesOf(j: JobContext): CopyRules {
  const r = j.copy_rules;
  if (!r) return DEFAULT_RULES;
  // the database gives inclusive ranges; the checks here take an exclusive upper bound
  const inc = (x: [number, number]): [number, number] => [x[0], x[1] + 1];
  return { headline_chars: inc(r.headline_chars), description_words: inc(r.description_words), features: inc(r.features), faq: inc(r.faq), banned_phrases: r.banned_phrases ?? [] };
}

async function draft(d: WorkerDeps, j: JobContext, b: Budget, used: { neurons: number }): Promise<JobResult> {
  const facts = j.facts ?? {};
  if (d.plainCopy) {
    const p = plainDraft(facts as Parameters<typeof plainDraft>[0]);
    return { ok: true, provider: 'carmacars', units: 0, unit: 'neurons', cost_microusd: 0,
      output: { ...p, faq: p.faq, model: 'plain', prompt_version: 'plain-v1', problems: [] } };
  }
  const rules = rulesOf(j);
  const classes = j.classes ?? [];
  let best: Draft | null = null;
  let problems: string[] = [];
  let neurons = 0;
  // one draft, and one rewrite when it breaks the rules; then it is stored as it is, flagged for a rewrite
  for (let attempt = 0; attempt < 2; attempt++) {
    const r = await d.text.generate<Record<string, unknown>>({ task: 'listing_draft', system: systemPrompt(), prompt: userPrompt(facts, j.staff_notes ?? null, classes, rules, problems), schema: DRAFT_SCHEMA as unknown as Record<string, unknown>, maxOutputTokens: 1400 });
    neurons += r.usage?.neurons ?? 0;
    if (!r.ok) {
      if (best) break;
      return { ok: false, provider: d.text.name, error: `${r.reason}: ${r.message}`, retryable: r.reason !== 'invalid_output' || j.attempts < j.max_attempts, ...cost(neurons, b, used) };
    }
    const dr = normalizeDraft(r.data);
    if (!dr) { problems = ['the answer was not a listing']; continue; }
    best = dr;
    problems = draftProblems(dr, facts, rules);
    if (!problems.length) break;
  }
  if (!best) return { ok: false, provider: d.text.name, error: 'invalid_output: the model did not write a listing', retryable: true, ...cost(neurons, b, used) };
  // drop classes not on the list (the database keeps only listed ones as well)
  best.classes = best.classes.filter((c) => !classes.length || classes.includes(c));
  return { ok: true, provider: d.text.name, ...cost(neurons, b, used),
    output: { ...best, faq: best.faq.map((q) => ({ question: q.question, answer: q.answer, check: !!q.check })), model: d.text.model, prompt_version: PROMPT_VERSION, problems } };
}

function cost(neurons: number, b: Budget, used: { neurons: number }) {
  const before = (b.ai_neurons_today ?? 0) + used.neurons;
  used.neurons += neurons;
  const paid = Math.max(0, before + neurons - Math.max(FREE_DAILY_NEURONS, before));
  return { units: neurons, unit: 'neurons' as const, cost_microusd: paid * MICROUSD_PER_NEURON };
}

function imageCost(n: number, b: Budget, used: { transformations: number }) {
  const before = (b.transformations_month ?? 0) + used.transformations;
  used.transformations += n;
  const paid = Math.max(0, before + n - Math.max(b.transformations_free ?? 5000, before));
  return { units: n, unit: 'transformations' as const, cost_microusd: paid * MICROUSD_PER_TRANSFORMATION };
}

async function processPhoto(d: WorkerDeps, j: JobContext, b: Budget, used: { transformations: number }): Promise<JobResult> {
  const p = j.photo;
  if (!p) return { ok: false, error: 'The photo is missing', retryable: false };
  // a photo that never goes on the website (the odometer) is kept as it was taken
  if (!p.is_public) return { ok: true, provider: 'carmacars', output: { used_original: true, flags: [], preset_version: 'original' } };
  // the usage guard (0080): no transformations while the allowance is used up; the original goes on the site now and the
  // database queues the studio background again once transformations may be used (app.usage_retry_photos)
  if (b.images_paused) return fallback(d, j, USAGE_PAUSED, `${USAGE_PAUSED}: the month's included image transformations are used`, 0, b, used);
  const src = await d.files.privateUrl(p.original_path);
  let n = 0;
  const fail = (o: Extract<PhotoOut, { ok: false }>): JobResult | null => o.retryable
    ? { ok: false, provider: d.photos.name, error: `${o.reason}: ${o.message}`, retryable: true, ...imageCost(n, b, used) } : null;
  let out: PhotoOut;
  let size = EXTERIOR;
  let windowsPlan: WindowPlan | null = null;
  let framed: Awaited<ReturnType<typeof frameSubject>> = null;
  let marksGone = false;
  let marks: MarkBox[] | null = null;
  if (p.rebackground) {
    const cut = await d.photos.cutout(src);
    if (!cut.ok) return fail(cut) ?? fallback(d, j, cut.reason, cut.message, n, b, used);
    n += cut.transformations;
    const cutPath = `vehicles/${j.vehicle_id}/work/${p.id}-cutout.png`;
    // r28: the car cropped to its edges with its contact shadow, marks and captions beside it left out; when the PNG
    // cannot be read, the cut-out is placed as before (studio_v2 framing)
    framed = await frameSubject(cut.bytes).catch(() => null);
    await d.files.putPrivate(cutPath, framed?.png ?? cut.bytes, 'image/png');
    // the model's name behind the car, as on the sample cars: one band per model, kept in the public bucket
    let lettering: { url: string; top: number; width: number } | null = null;
    if (p.model && LETTER_REAL_PHOTOS) {
      const lp = letteringPath(p.model);
      try {
        if (!(await d.files.hasPublic?.(lp))) await d.files.putPublic(lp, await letteringPng(p.model), 'image/png');
        lettering = { url: d.files.publicUrl(lp), top: LETTERING.top, width: LETTERING.width };
      } catch { lettering = null; /* the photo is still made, on the plain studio */ }
    }
    out = await d.photos.composite({ backdropUrl: d.files.publicUrl(BACKDROP_PATH), shadowUrl: d.files.publicUrl(SHADOW_PATH), cutoutUrl: await d.files.privateUrl(cutPath), lettering, ...EXTERIOR,
      place: framed ? placeSubject(framed, EXTERIOR.width, EXTERIOR.height) : null });
    // a mark on an outside photo is gone when the car was framed (it is not part of the car's piece); otherwise it stays flagged
    marksGone = !!framed;
  } else {
    size = INTERIOR;
    // 0521: a dashboard or seats photo: what shows through the windows is replaced by the studio when the cut-out
    // passes the quality check (window-check.ts), else blurred; a failed cut-out leaves the photo as edited before
    const w = WINDOW_SHOTS.includes(p.angle) || WINDOW_SHOTS.includes(p.shot_type) ? await windows(d, j, src) : null;
    if (w?.out) { n += w.n; out = w.out; windowsPlan = w.plan; }
    else { n += w?.n ?? 0; out = await d.photos.normalize({ sourceUrl: src, ...INTERIOR }); }
  }
  if (!out.ok) return fail(out) ?? fallback(d, j, out.reason, out.message, n, b, used);
  let done: Extract<PhotoOut, { ok: true }> = out;
  n += done.transformations;
  // 0567: an inside or detail photo flagged for a mark: the vision model says where; the edge band holding it is cut off
  if (!p.rebackground && p.watermark) {
    const r = await cleanMarks(d, j, done, size);
    n += r.n; marks = r.marks; marksGone = r.gone; if (r.out) done = r.out;
  }
  // 0568: the light touch-up, last (the photo as made so far is kept when any step of it fails)
  let enhance: Enhance | null = null;
  if (p.enhance) {
    const r = await touchUp(d, j, done, size, framed?.stats ?? null);
    n += r.n; if (r.out) { done = r.out; enhance = r.values; }
  }
  const path = `vehicles/${j.vehicle_id}/${p.file_base}.${ext(done.contentType)}`;
  await d.files.putPublic(path, done.bytes, done.contentType);
  return { ok: true, provider: d.photos.name, ...imageCost(n, b, used),
    output: { processed_path: path, width: size.width, height: size.height, preset_version: p.rebackground ? PRESET : windowsPlan ? `windows_${windowsPlan.action}_v1` : 'normalize_v1',
      // r31: an outside photo whose cut-out could not be framed is placed the old way (small): flagged so it is seen
      flags: [...(windowsPlan?.action === 'blur' ? ['windows_blurred'] : []), ...(p.rebackground && !framed ? ['not_framed'] : [])], ...(windowsPlan ? { windows: windowsPlan } : {}),
      ...(p.watermark ? { watermark_removed: marksGone, ...(marks ? { marks } : {}) } : {}),
      ...(framed ? { framing: { dropped: framed.dropped, share: framed.share } } : {}),
      ...(p.enhance !== undefined ? { enhance } : {}) } };
}

/** 0568: measure the photo (an outside photo: the car's own pixels from the framed cut-out, free; any other: a small
 *  PNG preview, one transformation), work out the touch-up (enhance.ts) and apply it (one transformation). */
async function touchUp(d: WorkerDeps, j: JobContext, out: Extract<PhotoOut, { ok: true }>, size: { width: number; height: number }, carStats: ReturnType<typeof statsOf> | null):
  Promise<{ out: Extract<PhotoOut, { ok: true }> | null; values: Enhance | null; n: number }> {
  const p = j.photo!;
  if (!d.photos.enhance) return { out: null, values: null, n: 0 };
  const workPath = `vehicles/${j.vehicle_id}/work/${p.id}-base.${ext(out.contentType)}`;
  await d.files.putPrivate(workPath, out.bytes, out.contentType);
  const src = await d.files.privateUrl(workPath);
  let n = 0;
  let stats = carStats;
  if (!stats && d.photos.preview) {
    const pv = await d.photos.preview({ sourceUrl: src, width: 160 });
    if (pv.ok) { n += pv.transformations; const px = await decodePng(pv.bytes).catch(() => null); if (px) stats = statsOf(px, 1); }
  }
  const values = stats ? enhanceValues(stats, { exterior: !!carStats }) : null;
  if (!values) return { out: null, values: null, n };
  const e = await d.photos.enhance({ sourceUrl: src, ...size, values });
  if (!e.ok) return { out: null, values: null, n };
  return { out: e, values, n: n + e.transformations };
}

/** 0567: the overlaid marks of an edited inside or detail photo: none found, gone; found at the edges, cut off (trim) and
 *  the photo framed again; in the middle, or the model not asked, kept flagged (off the site until a person replaces it). */
async function cleanMarks(d: WorkerDeps, j: JobContext, out: Extract<PhotoOut, { ok: true }>, size: { width: number; height: number }): Promise<{ out: PhotoOut & { ok: true } | null; n: number; marks: MarkBox[] | null; gone: boolean }> {
  const p = j.photo!;
  const marks = d.findMarks ? await d.findMarks({ bytes: out.bytes, contentType: out.contentType, width: size.width, height: size.height, photoId: p.id }).catch(() => null) : null;
  if (!marks) return { out: null, n: 0, marks: null, gone: false };
  if (!marks.length) return { out: null, n: 0, marks, gone: true };
  const cut = cropAway(marks);
  if (!cut) return { out: null, n: 0, marks, gone: false };
  const workPath = `vehicles/${j.vehicle_id}/work/${p.id}-marks.${ext(out.contentType)}`;
  await d.files.putPrivate(workPath, out.bytes, out.contentType);
  const px = { top: Math.round(cut.top * size.height), right: Math.round(cut.right * size.width), bottom: Math.round(cut.bottom * size.height), left: Math.round(cut.left * size.width) };
  const again = await d.photos.normalize({ sourceUrl: await d.files.privateUrl(workPath), ...size, trim: px });
  if (!again.ok) return { out: null, n: 0, marks, gone: false };
  return { out: again, n: again.transformations, marks, gone: true };
}

/** 0521: the windows of an interior photo. The interior is cut out; its transparency (what the segmenter saw through the
 *  windows) passes the quality check or not: the studio behind the windows, or the photo itself blurred behind them. No
 *  window seen, or no cut-out: null out, and the photo is edited as before. */
async function windows(d: WorkerDeps, j: JobContext, src: string): Promise<{ out: PhotoOut | null; n: number; plan: WindowPlan | null }> {
  const p = j.photo!;
  const cut = await d.photos.cutout(src);
  if (!cut.ok) return { out: null, n: 0, plan: null };
  const plan = windowPlan(await readAlpha(cut.bytes));
  if (plan.action === 'none') return { out: null, n: cut.transformations, plan: null };
  const cutPath = `vehicles/${j.vehicle_id}/work/${p.id}-interior.png`;
  await d.files.putPrivate(cutPath, cut.bytes, 'image/png');
  const out = await d.photos.layer(plan.action === 'replace'
    ? { baseUrl: d.files.publicUrl(BACKDROP_PATH), overlayUrl: await d.files.privateUrl(cutPath), ...INTERIOR }
    : { baseUrl: src, baseBlur: 40, overlayUrl: await d.files.privateUrl(cutPath), ...INTERIOR });
  return { out: out.ok ? out : null, n: cut.transformations, plan: out.ok ? plan : null };
}

/** Transformations are off (or found no car): keep the original on the site and flag it for staff. */
async function fallback(d: WorkerDeps, j: JobContext, reason: string, message: string, n: number, b: Budget, used: { transformations: number }): Promise<JobResult> {
  const p = j.photo!;
  const bytes = await d.files.getPrivate(p.original_path);
  if (!bytes) return { ok: false, provider: d.photos.name, error: `The original photo could not be read (${message})`, retryable: true };
  const type = bytes[0] === 0x89 ? 'image/png' : 'image/jpeg';
  const path = `vehicles/${j.vehicle_id}/${p.file_base}.${ext(type)}`;
  await d.files.putPublic(path, bytes, type);
  const flag = reason === 'no_subject' ? 'bad_cutout' : 'background_not_replaced';
  return { ok: true, provider: `${d.photos.name}:fallback`, ...imageCost(n, b, used),
    output: { processed_path: path, used_original: true, preset_version: 'original', flags: [flag], fallback_reason: message } };
}

async function resize(d: WorkerDeps, j: JobContext, b: Budget, used: { transformations: number }): Promise<JobResult> {
  const p = j.photo;
  if (!p?.processed_path || !p.is_public) return { ok: true, provider: 'carmacars', output: { variants: [] } };
  if (b.images_paused) return { ok: true, provider: 'carmacars', output: { variants: [], flags: ['no_variants'], fallback_reason: `${USAGE_PAUSED}: no size variants this month` } };
  const src = d.files.publicUrl(p.processed_path);
  const variants: { width: number; format: string; path: string }[] = [];
  let n = 0;
  for (const w of VARIANT_WIDTHS) {
    const o = await d.photos.resize({ sourceUrl: src, width: w });
    if (!o.ok) {
      if (o.retryable) return { ok: false, provider: d.photos.name, error: `${o.reason}: ${o.message}`, retryable: true, ...imageCost(n, b, used) };
      // no transformations: the site uses the master file alone
      return { ok: true, provider: `${d.photos.name}:fallback`, ...imageCost(n, b, used), output: { variants: [], flags: ['no_variants'] } };
    }
    n += o.transformations;
    const path = `vehicles/${j.vehicle_id}/${p.file_base}-${w}.${ext(o.contentType)}`;
    await d.files.putPublic(path, o.bytes, o.contentType);
    variants.push({ width: w, format: ext(o.contentType), path });
  }
  return { ok: true, provider: d.photos.name, ...imageCost(n, b, used), output: { variants } };
}
