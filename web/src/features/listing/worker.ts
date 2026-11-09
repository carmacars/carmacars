// The listing pipeline's worker (docs/blueprint/09-listing-pipeline.md section 5): claims due jobs from the
// queue of migration 0022 (through 0032's server_listing_claim), runs each with the providers, and reports
// the result (server_listing_result), which moves the intake on. Pure: every outside service is passed in,
// so the unit tests run it with fakes and the server wires the real ones (src/server/listing-worker.ts).
import type { TextGenerator } from '../../integrations/llm/types.ts';
import type { PhotoOut, PhotoProcessor } from '../../integrations/photos/types.ts';
import { DEFAULT_RULES, DRAFT_SCHEMA, PROMPT_VERSION, draftProblems, normalizeDraft, systemPrompt, userPrompt, type CopyRules, type Draft } from './prompt.ts';
import { plainDraft } from '../seo/copy.ts';
import { LETTERING, LETTER_REAL_PHOTOS, LETTER_SHOTS, letterThis, letteringPath, letteringPng } from './lettering.ts';
import { WINDOW_SHOTS, readAlpha, windowPlan, type WindowPlan } from './window-check.ts';
import { adjustPlace, decodePng, encodePng, frameRgba, frameSubject, placeSubject, type Adjust } from './subject-frame.ts';
import { SHOWROOM_FIT, SHOWROOM_PRESET, decodeImage, encodeJpeg, makeShowroom, marketingPrompt, sceneOf, showroomBackdrop, whiteStudio, type ShowroomProvider } from './showroom.ts';
import { resample, scaleDown } from '../../integrations/photos/local.ts';
import { applyPlates, type PlateEnd, type PxBox } from './plate-photo.ts';
import { enhanceValues, statsOf, type Enhance } from './enhance.ts';
import { cropAway, type MarkBox } from './photo-sort.ts';

// 0073: the sample cars' black studio with the model's name behind the car (was brand_background_v1, a light grey room).
// r28 (0567): studio_v3, the car framed to its own edges (subject-frame.ts): about 80% of the width, the wheels on the floor
// line, a contact shadow under the tyres, any mark or caption beside the car left out.
// r31 (0660): studio_v4, the car found at a firm alpha (the segmenter's haze and the floor's reflection no longer count as
// car, which left the car a quarter of the width and floating), and no model name lettered behind a real car: it showed
// as a large faint word around the car. The stand-ins (car/studio.ts) keep their lettering, as the sample cars.
// r33 (0700): studio_v5, the model's name lettered behind the car again, as on the sample photos (now the car is framed
// big it stands in front of the word): on the cover and on the outside views the samples letter (the eight named
// angles; not the extra outside photos), the word from the model (letteringName: CLA, C CLASS, AMG GT). The segmenter's
// cut-out is kept privately (its alpha is the mask the cut-out editor starts from) with where the car was placed.
export const PRESET = 'studio_v5';
// r35 (0990): the showroom scene (showroom.ts) in place of the black studio when the photo's scene is "showroom": the car in a
// plain dark showroom with the CarmaCars logo on the wall, its reflection on the floor, the model's name on the wall of the
// cover. Made here with no network (the free local composite); an image model, when its key is set and within its daily
// limit, makes it look photographed, and any refusal keeps the local one with the reason for staff.
export { SHOWROOM_PRESET };
/** r35: where the showroom room (no lettering) is kept for the windows of inside photos. */
export const SHOWROOM_BACKDROP_PATH = 'site/backdrop/showroom_v2.png';
export { LETTER_REAL_PHOTOS, LETTER_SHOTS, letterThis };
/** r33: what the cut-out editor sends (app.photo_cutout_edit): the edited cut-out and the move and size, or null. */
export function editOf(input: Record<string, unknown> | null | undefined): { cutout_path: string; adjust: Adjust } | null {
  const e = (input?.edit ?? null) as { cutout_path?: unknown; adjust?: Record<string, unknown> } | null;
  if (!e || typeof e.cutout_path !== 'string' || !e.cutout_path) return null;
  const n = (v: unknown, d: number) => (typeof v === 'number' && Number.isFinite(v) ? v : typeof v === 'string' && v.trim() !== '' && Number.isFinite(Number(v)) ? Number(v) : d);
  return { cutout_path: e.cutout_path, adjust: { dx: n(e.adjust?.dx, 0), dy: n(e.adjust?.dy, 0), scale: n(e.adjust?.scale, 1) } };
}
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
  id: string; kind: 'decode_vin' | 'draft_copy' | 'process_photo' | 'resize' | 'publish' | 'marketing_photo' | 'plate_redo'; intake_id: string; vehicle_id: string;
  attempts: number; max_attempts: number; input: Record<string, unknown>; vin?: string | null;
  facts?: Record<string, unknown> | null; staff_notes?: string | null; classes?: string[] | null;
  copy_rules?: { headline_chars: [number, number]; description_words: [number, number]; features: [number, number]; faq: [number, number]; banned_phrases: string[] } | null;
  photo?: { id: string; shot_type: string; angle: string; original_path: string; processed_path: string | null; rebackground: boolean; is_public: boolean; file_base: string; model?: string | null;
    /** 0567: the photo is flagged "watermark" (the sorter saw a mark, or it is queued for the check) */
    watermark?: boolean;
    /** 0568: the light touch-up applies (Admin "Auto-enhance listing photos" on, the photo's "Use original colours" off) */
    enhance?: boolean;
    /** 0700: the photo is the listing's cover (its model name is lettered behind the car) */
    is_cover?: boolean;
    /** 0990: the car's scene: "showroom" (the dark showroom) or "studio" (the black studio, also when missing) */
    scene?: 'studio' | 'showroom' | null } | null;
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
  /** r35 (0990): the image model that makes the showroom look photographed (gated by the database's daily limit); none: the
   *  free local showroom alone, noted "no key" on the photo when showroomNoKey. */
  showroomAi?: ShowroomProvider | null;
  showroomNoKey?: boolean;
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
    case 'marketing_photo': return marketingPhoto(d, j);
    case 'plate_redo': return plateRedo(d, j);
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
  // 0700: an edit or a mask waits for the allowance instead (the photo keeps its studio file meanwhile)
  if (b.images_paused && j.input?.mask_only) return { ok: false, provider: d.photos.name, error: `${USAGE_PAUSED}: the month's included image transformations are used`, retryable: true };
  // r35: only the cut-out needs the image service (every other step is made locally): an inside photo goes ahead
  if (b.images_paused && p.rebackground && !editOf(j.input)) return fallback(d, j, USAGE_PAUSED, `${USAGE_PAUSED}: the month's included image transformations are used`, 0, b, used);
  const src = await d.files.privateUrl(p.original_path);
  // 0700: a mask asked for by the cut-out editor (a photo made before the mask was kept): the segmenter's cut-out only
  if (j.input?.mask_only) {
    if (!p.rebackground) return { ok: true, provider: 'carmacars', output: { mask_only: true } };
    const cut = await d.photos.cutout(src);
    if (!cut.ok) return { ok: false, provider: d.photos.name, error: `${cut.reason}: ${cut.message}`, retryable: cut.retryable };
    const maskPath = `vehicles/${j.vehicle_id}/work/${p.id}-mask.png`;
    await d.files.putPrivate(maskPath, cut.bytes, 'image/png');
    return { ok: true, provider: d.photos.name, ...imageCost(cut.transformations, b, used), output: { mask_only: true, mask_path: maskPath } };
  }
  let n = 0;
  // r35: a quota never fails a photo (the original goes on the site, made again when the service may be used, 0080's
  // usage_retry_photos); an outage is tried again, and on the last attempt the original is used too
  const fail = (o: Extract<PhotoOut, { ok: false }>): JobResult | null => o.retryable && o.reason !== 'quota' && j.attempts < j.max_attempts
    ? { ok: false, provider: d.photos.name, error: `${o.reason}: ${o.message}`, retryable: true, ...imageCost(n, b, used) } : null;
  const why = (o: Extract<PhotoOut, { ok: false }>) => (o.reason === 'quota' ? `${USAGE_PAUSED}: ${o.message}` : o.message);
  let out: PhotoOut;
  let size = EXTERIOR;
  let windowsPlan: WindowPlan | null = null;
  let framed: Awaited<ReturnType<typeof frameSubject>> = null;
  let marksGone = false;
  let marks: MarkBox[] | null = null;
  let maskPath: string | null = null;
  let place: ReturnType<typeof placeSubject> | null = null;
  let lettered = false;
  const edit = p.rebackground ? editOf(j.input) : null;
  const showroom = sceneOf(p) === 'showroom';
  let room: { provider: 'local' | 'ai'; model?: string; note: string | null; reason: string | null } | null = null;
  let roomOut: PhotoOut | null = null;
  if (p.rebackground) {
    let cutBytes: Uint8Array;
    if (edit) {
      // 0700: the cut-out as staff edited it in the review (the original's colours, their mask): no segmenter call
      const e = await d.files.getPrivate(edit.cutout_path);
      if (!e) return { ok: false, provider: d.photos.name, error: 'The edited cut-out could not be read', retryable: j.attempts < j.max_attempts };
      cutBytes = e;
    } else {
      const cut = await d.photos.cutout(src);
      if (!cut.ok) return fail(cut) ?? fallback(d, j, cut.reason, why(cut), n, b, used);
      n += cut.transformations;
      cutBytes = cut.bytes;
      // 0700: the segmenter's cut-out as it came (its alpha is the mask), for the cut-out editor
      maskPath = `vehicles/${j.vehicle_id}/work/${p.id}-mask.png`;
      await d.files.putPrivate(maskPath, cutBytes, 'image/png');
    }
    const cutPath = `vehicles/${j.vehicle_id}/work/${p.id}-cutout.png`;
    // r28: the car cropped to its edges with its contact shadow, marks and captions beside it left out; when the PNG
    // cannot be read, the cut-out is placed as before (studio_v2 framing)
    // r35: the showroom draws the framed car itself, so its pixels are kept (one decode)
    let carImg: Awaited<ReturnType<typeof decodePng>> = null;
    if (showroom) {
      const img = await decodePng(cutBytes).catch(() => null);
      const f = img ? frameRgba(img) : null;
      if (f) { const { image, ...rest } = f; carImg = image; framed = { ...rest, png: await encodePng(image) }; }
    } else framed = await frameSubject(cutBytes).catch(() => null);
    await d.files.putPrivate(cutPath, framed?.png ?? cutBytes, 'image/png');
    // the model's name behind the car, as on the sample cars: one band per model, kept in the public bucket
    let lettering: { url: string; top: number; width: number } | null = null;
    if (showroom && framed && carImg) {
      // r35: the showroom, made here (no transformation); the image model on top when it may be asked
      place = adjustPlace(placeSubject(framed, EXTERIOR.width, EXTERIOR.height, SHOWROOM_FIT), edit?.adjust ?? null, EXTERIOR.width, EXTERIOR.height);
      const m = await makeShowroom({ car: { ...carImg, ground: framed.ground }, place, model: p.model ?? null, cover: !!p.is_cover, photoId: p.id },
        d.showroomAi ? [d.showroomAi] : [], !d.showroomAi && !!d.showroomNoKey);
      room = { provider: m.provider, ...(m.model ? { model: m.model } : {}), note: m.note, reason: m.reason };
      lettered = !!(p.is_cover && p.model);
      roomOut = { ok: true, bytes: m.bytes, contentType: m.contentType, transformations: 0 };
    } else if (p.model && letterThis(p)) {
      const lp = letteringPath(p.model);
      try {
        if (!(await d.files.hasPublic?.(lp))) await d.files.putPublic(lp, await letteringPng(p.model), 'image/png');
        lettering = { url: d.files.publicUrl(lp), top: LETTERING.top, width: LETTERING.width }; lettered = true;
      } catch { lettering = null; /* the photo is still made, on the plain studio */ }
    }
    out = roomOut ?? await d.photos.composite({ backdropUrl: d.files.publicUrl(BACKDROP_PATH), shadowUrl: d.files.publicUrl(SHADOW_PATH), cutoutUrl: await d.files.privateUrl(cutPath), lettering, ...EXTERIOR,
      place: (place = framed ? adjustPlace(placeSubject(framed, EXTERIOR.width, EXTERIOR.height), edit?.adjust ?? null, EXTERIOR.width, EXTERIOR.height) : null) });
    // a mark on an outside photo is gone when the car was framed (it is not part of the car's piece); otherwise it stays flagged
    marksGone = !!framed;
  } else {
    size = INTERIOR;
    // 0521: a dashboard or seats photo: what shows through the windows is replaced by the studio when the cut-out
    // passes the quality check (window-check.ts), else blurred; a failed cut-out leaves the photo as edited before
    const w = !b.images_paused && (WINDOW_SHOTS.includes(p.angle) || WINDOW_SHOTS.includes(p.shot_type)) ? await windows(d, j, src, showroom ? await showroomRoomUrl(d) : null) : null;
    if (w?.out) { n += w.n; out = w.out; windowsPlan = w.plan; }
    else { n += w?.n ?? 0; out = await d.photos.normalize({ sourceUrl: src, ...INTERIOR }); }
  }
  if (!out.ok) return fail(out) ?? (edit ? { ok: false, provider: d.photos.name, error: `${out.reason}: ${out.message}`, retryable: false, ...imageCost(n, b, used) }
    : fallback(d, j, out.reason, why(out), n, b, used));
  let done: Extract<PhotoOut, { ok: true }> = out;
  n += done.transformations;
  // 0567: an inside or detail photo flagged for a mark: the vision model says where; the edge band holding it is cut off
  if (!p.rebackground && p.watermark) {
    const r = await cleanMarks(d, j, done, size);
    n += r.n; marks = r.marks; marksGone = r.gone; if (r.out) done = r.out;
  }
  // 0568: the light touch-up, last (the photo as made so far is kept when any step of it fails)
  let enhance: Enhance | null = null;
  // r35: a showroom the image model made is not touched up again (its light is the model's)
  if (p.enhance && room?.provider !== 'ai') {
    const r = await touchUp(d, j, done, size, framed?.stats ?? null);
    n += r.n; if (r.out) { done = r.out; enhance = r.values; }
  }
  const path = `vehicles/${j.vehicle_id}/${p.file_base}.${ext(done.contentType)}`;
  await d.files.putPublic(path, done.bytes, done.contentType);
  return { ok: true, provider: d.photos.name, ...imageCost(n, b, used),
    output: { processed_path: path, width: size.width, height: size.height, preset_version: p.rebackground ? (room ? SHOWROOM_PRESET : PRESET) : windowsPlan ? `windows_${windowsPlan.action}_v1` : 'normalize_v1',
      // r31: an outside photo whose cut-out could not be framed is placed the old way (small): flagged so it is seen
      flags: [...(windowsPlan?.action === 'blur' ? ['windows_blurred'] : []), ...(p.rebackground && !framed ? ['not_framed'] : [])], ...(windowsPlan ? { windows: windowsPlan } : {}),
      ...(p.watermark ? { watermark_removed: marksGone, ...(marks ? { marks } : {}) } : {}),
      ...(framed ? { framing: { dropped: framed.dropped, share: framed.share } } : {}),
      // r35: a photo the image model made has no exact placement (the plate is checked again, never carried over)
      ...(room ? { showroom: room } : {}),
      ...(maskPath ? { mask_path: maskPath } : {}), ...(place && room?.provider !== 'ai' ? { place: { width: place.width, height: place.height, left: place.left, bottom: place.bottom } } : {}),
      ...(edit ? { edited: true } : {}), ...(p.rebackground ? { lettered } : {}),
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

/** r35: the empty showroom (no lettering) in the public bucket, made once, for the windows of inside photos; null when it
 *  cannot be stored (the black studio is used). */
async function showroomRoomUrl(d: WorkerDeps): Promise<string | null> {
  try {
    if (!(await d.files.hasPublic?.(SHOWROOM_BACKDROP_PATH))) await d.files.putPublic(SHOWROOM_BACKDROP_PATH, await encodePng(showroomBackdrop()), 'image/png');
    return d.files.publicUrl(SHOWROOM_BACKDROP_PATH);
  } catch { return null; }
}

/** 0521: the windows of an interior photo. The interior is cut out; its transparency (what the segmenter saw through the
 *  windows) passes the quality check or not: the studio behind the windows, or the photo itself blurred behind them. No
 *  window seen, or no cut-out: null out, and the photo is edited as before. */
async function windows(d: WorkerDeps, j: JobContext, src: string, roomUrl: string | null = null): Promise<{ out: PhotoOut | null; n: number; plan: WindowPlan | null }> {
  const p = j.photo!;
  const cut = await d.photos.cutout(src);
  if (!cut.ok) return { out: null, n: 0, plan: null };
  const plan = windowPlan(await readAlpha(cut.bytes));
  if (plan.action === 'none') return { out: null, n: cut.transformations, plan: null };
  const cutPath = `vehicles/${j.vehicle_id}/work/${p.id}-interior.png`;
  await d.files.putPrivate(cutPath, cut.bytes, 'image/png');
  const out = await d.photos.layer(plan.action === 'replace'
    ? { baseUrl: roomUrl ?? d.files.publicUrl(BACKDROP_PATH), overlayUrl: await d.files.privateUrl(cutPath), ...INTERIOR }
    : { baseUrl: src, baseBlur: 40, overlayUrl: await d.files.privateUrl(cutPath), ...INTERIOR });
  return { out: out.ok ? out : null, n: cut.transformations, plan: out.ok ? plan : null };
}

/** Transformations are off (or found no car): keep the original on the site and flag it for staff. */
async function fallback(d: WorkerDeps, j: JobContext, reason: string, message: string, n: number, b: Budget, used: { transformations: number }): Promise<JobResult> {
  const p = j.photo!;
  const bytes = await d.files.getPrivate(p.original_path);
  if (!bytes) return { ok: false, provider: d.photos.name, error: `The original photo could not be read (${message})`, retryable: true };
  // r35: made the site's size here (one decode, one pass down, one encode), never the camera's full file
  const img = await decodeImage(bytes).catch(() => null);
  const small = img ? encodeJpeg(scaleDown(img, EXTERIOR.width, EXTERIOR.width), 86) : null;
  const type = small ? 'image/jpeg' : bytes[0] === 0x89 ? 'image/png' : 'image/jpeg';
  const path = `vehicles/${j.vehicle_id}/${p.file_base}.${ext(type)}`;
  await d.files.putPublic(path, small ?? bytes, type);
  const flag = reason === 'no_subject' ? 'bad_cutout' : 'background_not_replaced';
  return { ok: true, provider: `${d.photos.name}:fallback`, ...imageCost(n, b, used),
    output: { processed_path: path, used_original: true, preset_version: 'original', flags: [flag], fallback_reason: message } };
}

/** 1053: one marketing copy of an outside photo in a scene (never the website's photo). The car from its kept cut-out, placed as
 *  in the showroom; the image model first (the scene's words, and the photo of the real place when the scene has one; the
 *  car's own pixels put back, a photo that moved it refused); without it, the site's own room for the local scenes (the dark
 *  showroom, the white studio), and for a photographic scene the copy says it needs the image model. */
export interface MarketingInput { id: string; vehicle_id: string; photo_id: string; scene: string; label: string; made: 'local' | 'photo'; place: string | null;
  mask: string; adjust: Adjust | null; reference: string | null }
async function marketingPhoto(d: WorkerDeps, j: JobContext): Promise<JobResult> {
  const m = (j.input as { marketing?: MarketingInput }).marketing;
  if (!m?.id || !m.mask) return { ok: false, error: 'The marketing photo is missing its cut-out', retryable: false };
  const cut = await d.files.getPrivate(m.mask);
  const img = cut ? await decodePng(cut).catch(() => null) : null;
  const f = img ? frameRgba(img) : null;
  if (!f) return { ok: true, provider: 'carmacars', output: { marketing: { id: m.id, status: 'failed', note: 'The car\'s cut-out could not be read' } } };
  const place = adjustPlace(placeSubject(f, EXTERIOR.width, EXTERIOR.height, SHOWROOM_FIT), m.adjust ?? null, EXTERIOR.width, EXTERIOR.height);
  const refBytes = m.reference ? await d.files.getPrivate(m.reference).catch(() => null) : null;
  const reference = refBytes ? { bytes: refBytes, contentType: refBytes[0] === 0x89 ? 'image/png' : 'image/jpeg' } : null;
  const made = await makeShowroom({ car: { ...f.image, ground: f.ground }, place, cover: false, photoId: m.photo_id,
    room: m.scene === 'showroom_dark' ? null : whiteStudio(),
    prompt: m.scene === 'showroom_dark' ? null : marketingPrompt({ label: m.label, place: m.place ?? m.label, reference: !!reference }), reference },
    d.showroomAi ? [d.showroomAi] : [], !d.showroomAi && !!d.showroomNoKey);
  if (made.provider !== 'ai' && m.made === 'photo') {
    return { ok: true, provider: 'carmacars', output: { marketing: { id: m.id, status: 'needs_gemini',
      note: `${m.label} needs the image model. ${(made.note ?? 'It is not set up.').replace(/^Made with the free showroom: /, '')}`.slice(0, 300) } } };
  }
  const path = `vehicles/${m.vehicle_id}/marketing/${m.id}.jpg`;
  await d.files.putPublic(path, made.bytes, made.contentType);
  return { ok: true, provider: made.provider === 'ai' ? 'ai' : 'carmacars', output: { marketing: { id: m.id, status: 'made', path, provider: made.provider, note: made.note } } };
}

/** r35 S2 (1056): a photo covered the old way made again from its uncovered file: the front plate edited out (the image
 *  model first when it may be asked, only the plate's area taken from its answer; the site's own fill otherwise), the
 *  rear plate the CARMA Ontario plate. The sizes are made here too. The database keeps the new file only while the photo
 *  is still the one the job was made from. */
export interface PlateRedoInput { photo_id: string; vehicle_id: string; source: string; prev_path: string | null; boxes: Array<{ x: number; y: number; w: number; h: number }>; end: PlateEnd; widths: number[] }
export const FRONT_PLATE_PROMPT = 'Edit this photo: remove the front licence plate and its holder from the bumper so the car looks like it never had a front plate: continue the bumper\'s paint, shape, lines, grille and reflections where the plate was. Change nothing else at all: the same car, colour, angle, light, background and framing. Do not add any text, plate, badge or sticker.';
async function plateRedo(d: WorkerDeps, j: JobContext): Promise<JobResult> {
  const m = (j.input as { plate?: PlateRedoInput }).plate;
  if (!m?.source || !m.boxes?.length) return { ok: false, error: 'The plate job is missing its photo', retryable: false };
  const bytes = await d.files.getPrivate(m.source);
  const src = bytes ? await decodeImage(bytes).catch(() => null) : null;
  if (!src) return { ok: false, error: 'The uncovered photo could not be read', retryable: !bytes };
  const img = scaleDown(src, 3000, 3000);
  const W = img.width, H = img.height;
  const boxes: PxBox[] = m.boxes.map((b) => ({ x: Math.floor(b.x * W), y: Math.floor(b.y * H), w: Math.max(2, Math.ceil(b.w * W)), h: Math.max(2, Math.ceil(b.h * H)) }));
  let provider = 'carmacars';
  if (m.end === 'front' && d.showroomAi) {
    // the image model edits the front plate out; only the plate's area (a little larger, feathered) is taken from its photo
    const r = await d.showroomAi.make({ car: { width: 1, height: 1, data: new Uint8ClampedArray(4), ground: 0 }, place: { width: 1, height: 1, left: 0, bottom: 0 }, cover: false, photoId: m.photo_id, prompt: FRONT_PLATE_PROMPT },
      encodeJpeg(img, 90)).catch(() => null);
    const ai = r && r.ok ? await decodeImage(r.bytes).catch(() => null) : null;
    if (ai) {
      const fit = resample(ai, { x: 0, y: 0, w: ai.width, h: ai.height }, W, H);
      for (const b of boxes) {
        const mx = b.w * 0.15, my = b.h * 0.25;
        for (let y = Math.max(0, Math.floor(b.y - my)); y < Math.min(H, b.y + b.h + my); y++) for (let x = Math.max(0, Math.floor(b.x - mx)); x < Math.min(W, b.x + b.w + mx); x++) {
          const fx = Math.min(1, Math.min(x - (b.x - mx), b.x + b.w + mx - x) / mx), fy = Math.min(1, Math.min(y - (b.y - my), b.y + b.h + my - y) / my);
          const a = Math.max(0, Math.min(1, Math.min(fx, fy) * 1.5)), i = (y * W + x) * 4;
          for (let c = 0; c < 3; c++) img.data[i + c] = img.data[i + c]! + (fit.data[i + c]! - img.data[i + c]!) * a;
        }
      }
      provider = 'ai';
      // a plate still readable there (high contrast left): the site's own fill on that box
      for (const b of boxes) {
        let n = 0, sum = 0, sq = 0;
        for (let y = b.y; y < b.y + b.h; y += 2) for (let x = b.x; x < b.x + b.w; x += 2) { const i = (y * W + x) * 4, l = (img.data[i]! + img.data[i + 1]! + img.data[i + 2]!) / 3; n++; sum += l; sq += l * l; }
        if (n && Math.sqrt(Math.max(0, sq / n - (sum / n) ** 2)) > 28) applyPlates(img, [b], 'front');
      }
    }
  }
  if (provider !== 'ai') applyPlates(img, boxes, m.end);
  const tag = j.id.replace(/-/g, '').slice(0, 6);
  const name = (m.prev_path?.split('/').pop() ?? 'photo').replace(/\.\w+$/, '').replace(/-[cp][0-9a-f]{6}(-\d+)?$/, '').replace(/[^\w-]+/g, '-').slice(0, 80) || 'photo';
  const path = `vehicles/${m.vehicle_id}/${name}-p${tag}.jpg`;
  await d.files.putPublic(path, encodeJpeg(img, 90), 'image/jpeg');
  const variants: Array<{ width: number; format: string; path: string }> = [];
  for (const w of [...new Set(m.widths ?? [])].filter((x) => x > 0 && x < W).sort((a, b) => b - a)) {
    const vp = `vehicles/${m.vehicle_id}/${name}-p${tag}-${w}.jpg`;
    await d.files.putPublic(vp, encodeJpeg(scaleDown(img, w), 86), 'image/jpeg');
    variants.push({ width: w, format: 'jpg', path: vp });
  }
  return { ok: true, provider, output: { plate: { processed_path: path, variants, width: W, height: H, end: m.end } } };
}

async function resize(d: WorkerDeps, j: JobContext, b: Budget, used: { transformations: number }): Promise<JobResult> {
  const p = j.photo;
  if (!p?.processed_path || !p.is_public) return { ok: true, provider: 'carmacars', output: { variants: [] } };
  // r35: the sizes are made locally, so a used allowance no longer stops them (paused with the service asked for everything:
  // the local processor answers anyway, see integrations/photos/local.ts)
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
