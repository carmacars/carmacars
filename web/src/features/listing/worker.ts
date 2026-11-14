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
import { PHOTO_SPEC, SHOWROOM_FIT, SHOWROOM_PRESET, backgroundReplaced, backgroundSwapPrompt, coverModelPrompt, decodeImage, encodeJpeg, fitFrame, makeShowroom, marketingPrompt, photoRoomPrompt, sceneOf, showroomBackdrop, whiteStudio, type ShowroomOut, type ShowroomProvider } from './showroom.ts';
import { letteringName } from '../car/studio.ts';
import { lightMatch, maskQuality, photoPlace } from './photo-room.ts';
import type { Rgba } from './subject-frame.ts';
import { drawFlyer, type FlyerSpec } from './flyer.ts';
import { scaleDown } from '../../integrations/photos/local.ts';
import { type PlateEnd } from './plate-photo.ts';
import { boxesForSave, decidePlate, greyOfRgba, refineAll } from './plate-auto.ts';
import { enhanceValues, statsOf, type Enhance } from './enhance.ts';
import { cropAway, type MarkBox } from './photo-sort.ts';
import { R45_PRESET, R45_SPEC, blurPlates, checkPrompt, CHECK_SCHEMA, CHECK_SYSTEM, isExterior, judgeCheck, promptFor, type CarFacts, type Verdict } from './r45.ts';
import { imageSize } from '../drive-import/image-size.ts';

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
/** r43 (2690): the start of the error of a photo that was to be made with Gemini and could not be (the photo is left as it was). */
export const GEMINI_ONLY = 'Redo with Gemini: ';

export interface JobContext {
  id: string; kind: 'decode_vin' | 'draft_copy' | 'process_photo' | 'resize' | 'publish' | 'marketing_photo' | 'plate_redo' | 'cover_model' | 'cover_flyer' | 'angle_make' | 'plate_auto' | 'photo_resort' | 'photo_r45'; intake_id: string; vehicle_id: string;
  attempts: number; max_attempts: number; input: Record<string, unknown>; vin?: string | null;
  facts?: Record<string, unknown> | null; staff_notes?: string | null; classes?: string[] | null;
  copy_rules?: { headline_chars: [number, number]; description_words: [number, number]; features: [number, number]; faq: [number, number]; banned_phrases: string[] } | null;
  photo?: { id: string; shot_type: string; angle: string; original_path: string; processed_path: string | null; rebackground: boolean; is_public: boolean; file_base: string; model?: string | null;
    /** the photo's size as recorded (the original's at upload; the site file's once processed) */
    width?: number | null; height?: number | null;
    /** 0567: the photo is flagged "watermark" (the sorter saw a mark, or it is queued for the check) */
    watermark?: boolean;
    /** 0568: the light touch-up applies (Admin "Auto-enhance listing photos" on, the photo's "Use original colours" off) */
    enhance?: boolean;
    /** 0700: the photo is the listing's cover (its model name is lettered behind the car) */
    is_cover?: boolean;
    /** 0990: the car's scene: "showroom" (the dark showroom) or "studio" (the black studio, also when missing) */
    scene?: 'studio' | 'showroom' | null } | null;
  /** r39 (2400): the car's photographed room (the same for every angle of the car); none: the drawn room */
  background?: { slug: string; path: string; floor: number; reflect: number } | null;
  /** r39 (2400): Program settings: the car's share of the frame in a photographed room, the cut-out's quality floor */
  cutout?: { car_width?: number; min_quality?: number } | null;
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
    /** r36 (2100): a public file's bytes (the cover photo a flyer is drawn on); null when missing. */
    getPublic?(path: string): Promise<Uint8Array | null>;
    /** r41 (2530): a file taken off its bucket (the uncovered file an automatic cover replaced, or a cover that came too late). */
    removePublic?(path: string): Promise<void>;
    removePrivate?(path: string): Promise<void>;
  };
  /** 0567: where the overlaid marks (watermark, logo, caption) are on an edited inside or detail photo, as fractions;
   *  [] none; null the model could not be asked (the photo then stays flagged, off the site). */
  findMarks?(img: { bytes: Uint8Array; contentType: string; width: number; height: number; photoId: string }): Promise<MarkBox[] | null>;
  now?(): number;
  /** r41 (2530): the vision model's answer on where the plates are (plate-auto.ts prompt), behind the marks' gate (the
   *  day's free AI share); null: the model may not be asked now (the job waits an hour). */
  findPlates?(img: { bytes: Uint8Array; contentType: string; width: number; height: number; photoId: string }): Promise<{ data: unknown; model: string } | null>;
  /** r41 (2530): the automatic plate decision recorded (server_plate_auto_apply): applied, and the files a cover replaced. */
  plateAutoApply?(p: Record<string, unknown>): Promise<{ applied: boolean; previous?: string[] }>;
  /** r44 (2780): a photo filed as "Other detail" sorted again by the vision model (Gemini first): its shot, 'unsure' when the
   *  model answered without a shot, null when it may not be asked now (the job waits an hour). */
  sortPhoto?(img: { bytes: Uint8Array; contentType: string; photoId: string }): Promise<{ shot: string; model: string } | 'unsure' | null>;
  /** r35 (0990): the image model that makes the showroom look photographed (gated by the database's daily limit); none: the
   *  free local showroom alone, noted "no key" on the photo when showroomNoKey. */
  showroomAi?: ShowroomProvider | null;
  showroomNoKey?: boolean;
  /** r36b (2200): a view of the car from an angle never photographed, made by the image model from the car's other photos,
   *  behind the same gate and free daily limit as the showroom; none: the view waits for the image model. */
  angleAi?: ((i: { images: Array<{ bytes: Uint8Array; contentType: string }>; prompt: string; photoId: string }) => Promise<ShowroomOut>) | null;
  /** r45 (2840): the second Gemini pass on a made photo (r45.ts checkPrompt): the JSON answer and the model; null when it may
   *  not be asked or did not answer (the photo is then not published). With angleAi, every listing photo is made by r45. */
  checkPhoto?: ((i: { images: Array<{ bytes: Uint8Array; contentType: string }>; system: string; prompt: string; schema: Record<string, unknown>; photoId: string }) => Promise<{ data: unknown; model: string } | null>) | null;
  /** The car copy is written by the search job (0061, features/seo): the draft step stores a plain copy from the
   *  facts without calling the model, so no neurons are spent twice. */
  plainCopy?: boolean;
}

export interface RunSummary { claimed: number; succeeded: number; failed: number; held: { photos: boolean; copy: boolean }; due: number; errors: string[] }

const ext = (type: string) => (type === 'image/png' ? 'png' : type === 'image/webp' ? 'webp' : 'jpg');

/** The steps that hold no photo in memory (run side by side); every other step is run one at a time. */
export const LIGHT_KINDS: ReadonlySet<JobContext['kind']> = new Set(['decode_vin', 'draft_copy', 'publish']);
/** r40 (2450): a photo larger than this (pixels) is never decoded here: the image service makes a working copy of
 *  WORK_SIDE pixels first, else the photo goes on the site as it is (its sizes are not made either). */
export const LOCAL_MAX_PIXELS = 12_000_000;
export const WORK_SIDE = 2400;
/** r45 (2840): the fleet's Gemini photos made side by side in one run. */
export const R45_PARALLEL = 2;
const tooLarge = (w: number | null | undefined, h: number | null | undefined) => !!w && !!h && w * h > LOCAL_MAX_PIXELS;

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
    const one = async (j: JobContext) => {
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
    };
    // r40 (2450): the copy steps side by side, the photo steps one after another: a few camera-sized photos decoded at once
    // filled the Worker's memory and the whole run was stopped (every claimed job, the VIN decode too, then failed "did not
    // finish within the lock time")
    const light = c.jobs.filter((j) => LIGHT_KINDS.has(j.kind)), heavy = c.jobs.filter((j) => !LIGHT_KINDS.has(j.kind) && j.kind !== 'photo_r45');
    // r45 (2840): the fleet's Gemini photos two at a time (each waits on Gemini most of its time; two keep the memory low)
    const r45 = c.jobs.filter((j) => j.kind === 'photo_r45');
    const pool = async (list: JobContext[], n: number) => { let k = 0; await Promise.all(Array.from({ length: Math.min(n, list.length) }, async () => { while (k < list.length) await one(list[k++]!); })); };
    await Promise.all([...light.map(one), (async () => { for (const j of heavy) await one(j); })(), pool(r45, R45_PARALLEL)]);
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
    case 'cover_model': case 'cover_flyer': return listingCover(d, j);
    case 'angle_make': return angleMake(d, j);
    case 'plate_auto': return plateAuto(d, j);
    case 'photo_resort': return resortPhoto(d, j);
    case 'photo_r45': return r45Job(d, j);
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
  // r43 (2690): "Redo photos with Gemini": the image model is the only engine. No key, no cut-out, a refusal or a changed car
  // fails the step with the reason and leaves the photo as it was: never the free showroom, the Cloudflare composite or the
  // unprocessed original (those would replace a poor photo with another poor one, or put an original on the site).
  const strict = j.input?.engine === 'gemini';
  // r44 (2780): Gemini's daily limit or a quota answer is not the photo's fault: the database queues the step again when Gemini
  // may be asked (gemini_wait), so a fleet-wide redo finishes over the following days by itself
  const strictFail = (why: string, wait?: string | null): JobResult => ({ ok: false, provider: 'gemini', error: `${GEMINI_ONLY}${why}. The photo was not changed.`, retryable: false,
    ...(wait === 'limit' || wait === 'quota' ? { output: { gemini_wait: wait } } : {}) });
  if (strict && !d.showroomAi) return strictFail('Gemini is not set up on the website (no GEMINI_API_KEY)');
  if (strict && !(p.rebackground && sceneOf(p) === 'showroom')) return strictFail('only an outside photo in the showroom is made with Gemini');
  const fb: typeof fallback = strict ? async (_d, _j, reason, message) => strictFail(`${reason}: ${message}`) : fallback;
  // a photo that never goes on the website (the odometer) is kept as it was taken
  if (!p.is_public) return { ok: true, provider: 'carmacars', output: { used_original: true, flags: [], preset_version: 'original' } };
  // r45 (2840): every listing photo is made by Gemini from the original (r45.ts); no Cloudflare cut-out, composite or resize.
  // Also a photo queued with its kept cut-out (Apply showroom, Redo, a detail sorted again, the cut-out editor): the original
  // is used, never the cut-out. Only a mask asked for by the cut-out editor keeps its own step.
  if (d.angleAi && d.checkPhoto && !j.input?.mask_only) {
    const r = await makeR45(d, j);
    if (r.pass) return { ok: true, provider: 'ai', units: 1, unit: 'requests', cost_microusd: 0, output: r.output };
    const wait = r.wait === 'limit' || r.wait === 'quota' ? r.wait : null;
    return { ok: false, provider: 'gemini', error: `${GEMINI_ONLY}${r.why}. The photo was not changed.`, retryable: !wait && j.attempts < Math.min(j.max_attempts, 3),
      output: { r45: r.output.r45, ...(wait ? { gemini_wait: wait } : {}) } };
  }
  // the usage guard (0080): no transformations while the allowance is used up; the original goes on the site now and the
  // database queues the studio background again once transformations may be used (app.usage_retry_photos)
  // 0700: an edit or a mask waits for the allowance instead (the photo keeps its studio file meanwhile)
  if (b.images_paused && j.input?.mask_only) return { ok: false, provider: d.photos.name, error: `${USAGE_PAUSED}: the month's included image transformations are used`, retryable: true };
  // r35: only the cut-out needs the image service (every other step is made locally): an inside photo goes ahead
  // r40 (2450): a camera-sized photo (a Google Drive import) is made smaller by the image service first, and the photo is
  // made from that copy; when it cannot be, it goes on the site as it is (never decoded here: it fills the Worker's memory)
  if (!j.input?.work_copy && !editOf(j.input)) {
    let size: { width: number; height: number } | null = p.width && p.height ? { width: p.width, height: p.height } : null;
    if (!size) { const head = await d.files.getPrivate(p.original_path).catch(() => null); size = head ? imageSize(head) : null; }
    if (size && tooLarge(size.width, size.height)) {
      const w = await workingCopy(d, j);
      if (!w) return strict ? strictFail('the photo is too large to edit here') : asIs(d, j, size);
      const r = await processPhoto(d, { ...j, input: { ...j.input, work_copy: true }, photo: { ...p, original_path: w.path, width: null, height: null } }, b, used);
      if (r.ok && r.output) r.output = { ...r.output, work_copy: w.path };
      return r;
    }
  }
  if (b.images_paused && p.rebackground && !editOf(j.input)) return fb(d, j, USAGE_PAUSED, `${USAGE_PAUSED}: the month's included image transformations are used`, 0, b, used);
  const src = await d.files.privateUrl(p.original_path);
  // 0700: a mask asked for by the cut-out editor (a photo made before the mask was kept): the segmenter's cut-out only
  if (j.input?.mask_only) {
    if (!p.rebackground) return { ok: true, provider: 'carmacars', output: { mask_only: true } };
    const cut = await d.photos.cutout(src);
    // r38 (2372): a quota, or the last attempt, never fails the photo: it keeps its studio file, the mask is asked again later
    if (!cut.ok && (cut.reason === 'quota' || j.input?.local_only || j.attempts >= j.max_attempts)) return { ok: true, provider: `${d.photos.name}:fallback`, output: { mask_only: true, mask_pending: true, fallback_reason: cut.message } };
    if (!cut.ok) return { ok: false, provider: d.photos.name, error: `${cut.reason}: ${cut.message}`, retryable: cut.retryable };
    const maskPath = `vehicles/${j.vehicle_id}/work/${p.id}-mask.png`;
    await d.files.putPrivate(maskPath, cut.bytes, 'image/png');
    return { ok: true, provider: d.photos.name, ...imageCost(cut.transformations, b, used), output: { mask_only: true, mask_path: maskPath } };
  }
  let n = 0;
  // r35: a quota never fails a photo (the original goes on the site, made again when the service may be used, 0080's
  // usage_retry_photos); an outage is tried again, and on the last attempt the original is used too
  // r38 (2372): queued again by "Process photos without the resize service" (local_only): no retry, the original goes on
  const fail = (o: Extract<PhotoOut, { ok: false }>): JobResult | null => o.retryable && o.reason !== 'quota' && !j.input?.local_only && j.attempts < j.max_attempts
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
  const showroom = sceneOf(p) === 'showroom';
  const edit = p.rebackground ? editOf(j.input) : null;
  // r44 (2780): a cut-out staff edited is theirs; the segmenter's own kept mask (auto_mask, sent again by a redo) is scored like a new one
  const trusted = !!edit && !j.input?.auto_mask;
  // r44: a car the site cannot cut out cleanly gets its background replaced by the image model from the original (the same
  // room every outside photo has), instead of going on the site with the place it was photographed in
  const swap = async (why: string): Promise<JobResult | null> => {
    if (!p.rebackground || !showroom || !d.showroomAi) return null;
    const r = await swapBackground(d, j, n, b, used);
    if (r.ok) return r;
    return strict ? strictFail(`${why}; Gemini could not replace the background (${r.why})`, r.why?.split(':')[0]) : null;
  };
  let room: { provider: 'local' | 'ai'; model?: string; note: string | null; reason: string | null; mask_quality?: number; background?: string; spec?: string } | null = null;
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
      if (!cut.ok) return fail(cut) ?? (await swap(`no cut-out (${cut.message})`)) ?? fb(d, j, cut.reason, why(cut), n, b, used);
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
    const raw = await decodePng(cutBytes).catch(() => null);
    // r39 (2400): the segmenter's mask scored (one piece, firm and smooth edges); a poor one is never composited: the real
    // photo goes on (its plates covered as every photo). A cut-out staff edited is theirs and is used.
    const mq = raw && !trusted ? maskQuality(raw) : null;
    if (mq && mq.score < (j.cutout?.min_quality ?? 0.6)) {
      const swapped = await swap(`the cut-out is not clean enough to place in a room (mask quality ${mq.score})`);
      if (swapped) return swapped;
      if (strict) return strictFail(`the cut-out is not clean enough to place in a room (mask quality ${mq.score}); edit the cut-out first`);
      const lowFb = await fallback(d, j, 'low_mask', `The cut-out is not clean enough to place in a room (mask quality ${mq.score}): the real photo is used`, n, b, used);
      if (lowFb.ok && lowFb.output) lowFb.output = { ...lowFb.output, ...(maskPath ? { mask_path: maskPath } : {}),
        showroom: { provider: 'local', reason: 'low_mask', note: `The real photo is used: the cut-out's mask is poor (quality ${mq.score}).`, mask_quality: mq.score, used_original: true } };
      return lowFb;
    }
    const f = raw ? frameRgba(raw) : null;
    if (f) { const { image, ...rest } = f; carImg = image; framed = { ...rest, png: await encodePng(image) }; }
    if (strict && !(showroom && framed && carImg)) return (await swap('the car could not be framed from its cut-out')) ?? strictFail('the car could not be framed from its cut-out');
    await d.files.putPrivate(cutPath, framed?.png ?? cutBytes, 'image/png');
    // the model's name behind the car, as on the sample cars: one band per model, kept in the public bucket
    let lettering: { url: string; top: number; width: number } | null = null;
    if (showroom && framed && carImg) {
      // r35: the showroom, made here (no transformation); the image model on top when it may be asked
      // r39 (2400): a photographed room when one is stored (the car about 70% wide, its wheels on the room's floor line,
      // its light matched; no logo or lettering on a real wall), else the drawn room
      const pr = await photoRoom(d, j);
      const car = { ...carImg, ground: framed.ground };
      place = adjustPlace(pr ? photoPlace(framed, EXTERIOR.width, EXTERIOR.height, { floor: pr.floor, carWidth: j.cutout?.car_width ?? 0.7 })
        : placeSubject(framed, EXTERIOR.width, EXTERIOR.height, SHOWROOM_FIT), edit?.adjust ?? null, EXTERIOR.width, EXTERIOR.height);
      const m = await makeShowroom({ car, place, model: p.model ?? null, cover: !!p.is_cover, photoId: p.id,
        ...(pr ? { room: pr.img, prompt: photoRoomPrompt(), look: { reflect: pr.reflect, gain: lightMatch(pr.img, car, pr.floor) } } : {}) },
        d.showroomAi ? [d.showroomAi] : [], !d.showroomAi && !!d.showroomNoKey);
      if (strict && m.provider !== 'ai') return strictFail(`Gemini did not make it${m.note ? ` (${m.note.replace(/^Made with the free showroom: /, '').replace(/\.$/, '')})` : ''}`, m.reason);
      room = { provider: m.provider, ...(m.model ? { model: m.model } : {}), note: m.note, reason: m.reason,
        ...(mq ? { mask_quality: mq.score } : {}), ...(pr ? { background: pr.slug } : {}), spec: PHOTO_SPEC };
      lettered = !pr && !!(p.is_cover && p.model);
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
    : fb(d, j, out.reason, why(out), n, b, used));
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

/** r44 (2780): the original photo with its background replaced by the image model: the original and the empty room (the car's
 *  photographed room when it has one, else the drawn showroom without lettering) go to the model; its answer is fitted to the
 *  frame and used only when the room shows around the car (backgroundReplaced). The plate is checked again afterwards. */
export async function swapBackground(d: WorkerDeps, j: JobContext, n: number, b: Budget, used: { transformations: number }): Promise<JobResult & { why?: string }> {
  const p = j.photo!;
  const no = (why: string) => ({ ok: false, why } as JobResult & { why: string });
  if (!d.showroomAi) return no('no key');
  const bytes = await d.files.getPrivate(p.original_path).catch(() => null);
  const img = bytes ? await decodeImage(bytes).catch(() => null) : null;
  if (!img) return no('the original could not be read');
  const pr = await photoRoom(d, j);
  const roomJpeg = encodeJpeg(pr?.img ?? showroomBackdrop(), 86);
  const name = p.is_cover && p.model && !pr ? letteringName(p.model) : null;
  const r = await d.showroomAi.make({ car: { width: 1, height: 1, data: new Uint8ClampedArray(4), ground: 0 }, place: { width: 1, height: 1, left: 0, bottom: 0 },
    model: p.model ?? null, cover: !!p.is_cover, photoId: p.id, prompt: backgroundSwapPrompt({ cover: !!p.is_cover, name }),
    reference: { bytes: roomJpeg, contentType: 'image/jpeg' } }, encodeJpeg(scaleDown(img, EXTERIOR.width, EXTERIOR.width), 90)).catch((e: unknown) => ({ ok: false as const, reason: 'error' as const, message: e instanceof Error ? e.message : String(e) }));
  if (!r.ok) return no(`${r.reason}: ${r.message}`);
  const ai = await decodeImage(r.bytes).catch(() => null);
  if (!ai) return no('the answer could not be read');
  const fitted = fitFrame(ai, EXTERIOR.width, EXTERIOR.height);
  if (!pr && !backgroundReplaced(fitted)) return no('the answer still shows the place the photo was taken');
  const path = `vehicles/${j.vehicle_id}/${p.file_base}.jpg`;
  await d.files.putPublic(path, encodeJpeg(fitted), 'image/jpeg');
  return { ok: true, provider: 'ai', ...imageCost(n, b, used),
    output: { processed_path: path, width: EXTERIOR.width, height: EXTERIOR.height, preset_version: SHOWROOM_PRESET, flags: [], lettered: !!name,
      showroom: { provider: 'ai', ...(r.model ? { model: r.model } : {}), note: null, reason: null, mode: 'swap', spec: PHOTO_SPEC, ...(pr ? { background: pr.slug } : {}) },
      ...(p.enhance !== undefined ? { enhance: null } : {}) } };
}

/** Transformations are off (or found no car): keep the original on the site and flag it for staff. */
/** r39 (2400): the car's photographed room (showroom_backgrounds, stored by web/scripts/showroom-photos.mjs) at the frame's
 *  size, read once per worker run; null when none is set, it cannot be read, or the store cannot be read (the drawn room). */
const rooms = new Map<string, Rgba | null>();
export async function photoRoom(d: WorkerDeps, j: JobContext): Promise<{ img: Rgba; slug: string; floor: number; reflect: number } | null> {
  const bg = j.background;
  if (!bg?.path || !d.files.getPublic) return null;
  if (!rooms.has(bg.path)) {
    const bytes = await d.files.getPublic(bg.path).catch(() => null);
    const img = bytes ? await decodeImage(bytes).catch(() => null) : null;
    if (rooms.size > 3) rooms.delete(rooms.keys().next().value!);
    rooms.set(bg.path, img ? fitFrame(img, EXTERIOR.width, EXTERIOR.height) : null);
  }
  const img = rooms.get(bg.path);
  if (!img) return null;
  const num = (v: unknown, dflt: number) => (typeof v === 'number' && Number.isFinite(v) ? v : typeof v === 'string' && Number.isFinite(Number(v)) ? Number(v) : dflt);
  return { img: { width: img.width, height: img.height, data: new Uint8ClampedArray(img.data) }, slug: bg.slug, floor: num(bg.floor, 0.82), reflect: num(bg.reflect, 0.12) };
}

/** r40 (2450): a working copy of a camera-sized photo, WORK_SIDE pixels on its long side, made by the image service and kept
 *  privately; null when the service cannot make it (or made one still too large). */
async function workingCopy(d: WorkerDeps, j: JobContext): Promise<{ path: string } | null> {
  const p = j.photo!;
  if (!d.photos.shrink) return null;
  const o = await d.photos.shrink({ sourceUrl: await d.files.privateUrl(p.original_path), width: WORK_SIDE }).catch(() => null);
  if (!o || !o.ok) return null;
  const sz = imageSize(o.bytes);
  if (!sz || tooLarge(sz.width, sz.height)) return null;
  const path = `vehicles/${j.vehicle_id}/work/${p.id}-src.${ext(o.contentType)}`;
  await d.files.putPrivate(path, o.bytes, o.contentType);
  return { path };
}

/** r40 (2450): the original on the site as it is (not decoded, not resized), flagged so staff see it. */
async function asIs(d: WorkerDeps, j: JobContext, size: { width: number; height: number }): Promise<JobResult> {
  const p = j.photo!;
  const bytes = await d.files.getPrivate(p.original_path);
  if (!bytes) return { ok: false, provider: d.photos.name, error: 'The original photo could not be read', retryable: true };
  const type = bytes[0] === 0x89 ? 'image/png' : 'image/jpeg';
  const path = `vehicles/${j.vehicle_id}/${p.file_base}.${ext(type)}`;
  await d.files.putPublic(path, bytes, type);
  return { ok: true, provider: `${d.photos.name}:fallback`, units: 0, unit: 'transformations', cost_microusd: 0,
    output: { processed_path: path, used_original: true, preset_version: 'original', width: size.width, height: size.height, flags: ['too_large'],
      fallback_reason: 'The photo is too large to make here and the image service did not make a smaller copy: it is on the site as it is' } };
}

async function fallback(d: WorkerDeps, j: JobContext, reason: string, message: string, n: number, b: Budget, used: { transformations: number }): Promise<JobResult> {
  const p = j.photo!;
  const bytes = await d.files.getPrivate(p.original_path);
  if (!bytes) return { ok: false, provider: d.photos.name, error: `The original photo could not be read (${message})`, retryable: true };
  // r35: made the site's size here (one decode, one pass down, one encode), never the camera's full file
  const img = await decodeImage(bytes).catch(() => null);
  const scaled = img ? scaleDown(img, EXTERIOR.width, EXTERIOR.width) : null;
  const small = scaled ? encodeJpeg(scaled, 86) : null;
  const type = small ? 'image/jpeg' : bytes[0] === 0x89 ? 'image/png' : 'image/jpeg';
  const path = `vehicles/${j.vehicle_id}/${p.file_base}.${ext(type)}`;
  await d.files.putPublic(path, small ?? bytes, type);
  const flag = reason === 'no_subject' ? 'bad_cutout' : 'background_not_replaced';
  return { ok: true, provider: `${d.photos.name}:fallback`, ...imageCost(n, b, used),
    output: { processed_path: path, used_original: true, preset_version: 'original', flags: [flag], fallback_reason: message, ...(scaled ? { width: scaled.width, height: scaled.height } : {}) } };
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
  const pr = m.scene === 'showroom_dark' ? await photoRoom(d, j) : null;
  const place = adjustPlace(pr ? photoPlace(f, EXTERIOR.width, EXTERIOR.height, { floor: pr.floor, carWidth: j.cutout?.car_width ?? 0.7 })
    : placeSubject(f, EXTERIOR.width, EXTERIOR.height, SHOWROOM_FIT), m.adjust ?? null, EXTERIOR.width, EXTERIOR.height);
  const refBytes = m.reference ? await d.files.getPrivate(m.reference).catch(() => null) : null;
  const reference = refBytes ? { bytes: refBytes, contentType: refBytes[0] === 0x89 ? 'image/png' : 'image/jpeg' } : null;
  const made = await makeShowroom({ car: { ...f.image, ground: f.ground }, place, cover: false, photoId: m.photo_id,
    room: m.scene === 'showroom_dark' ? pr?.img ?? null : whiteStudio(),
    ...(pr ? { look: { reflect: pr.reflect, gain: lightMatch(pr.img, { ...f.image, ground: f.ground }, pr.floor) } } : {}),
    prompt: m.scene === 'showroom_dark' ? (pr ? photoRoomPrompt() : null) : marketingPrompt({ label: m.label, place: m.place ?? m.label, reference: !!reference }), reference },
    d.showroomAi ? [d.showroomAi] : [], !d.showroomAi && !!d.showroomNoKey);
  if (made.provider !== 'ai' && m.made === 'photo') {
    return { ok: true, provider: 'carmacars', output: { marketing: { id: m.id, status: 'needs_gemini',
      note: `${m.label} needs the image model. ${(made.note ?? 'It is not set up.').replace(/^Made with the free showroom: /, '')}`.slice(0, 300) } } };
  }
  const path = `vehicles/${m.vehicle_id}/marketing/${m.id}.jpg`;
  await d.files.putPublic(path, made.bytes, made.contentType);
  return { ok: true, provider: made.provider === 'ai' ? 'ai' : 'carmacars', output: { marketing: { id: m.id, status: 'made', path, provider: made.provider, note: made.note } } };
}

/** r36 (2100): the listing's first photo made for its style. "model": the car from its kept cut-out in the showroom, then the
 *  image model adds a fully clothed adult model beside it (Program settings' words plus the site's own rules); the car must
 *  stay the same car (makeShowroom's check), and without the image model the cover says so and the plain cover stays.
 *  "flyer": the flyer band drawn by the site on the cover photo itself, from the words the database filled for the car. */
export interface CoverInput { id: string; vehicle_id: string; photo_id: string; style: 'model' | 'flyer'; source: string; mask: string | null; adjust: Adjust | null;
  model: string | null; prompt: string | null; flyer: FlyerSpec | null }
async function listingCover(d: WorkerDeps, j: JobContext): Promise<JobResult> {
  const c = (j.input as { cover?: CoverInput }).cover;
  if (!c?.id) return { ok: false, error: 'The cover job is missing its cover', retryable: false };
  const done = (o: Record<string, unknown>, provider = 'carmacars'): JobResult => ({ ok: true, provider, output: { cover: { id: c.id, ...o } } });
  const path = `vehicles/${c.vehicle_id}/cover/${c.id}.jpg`;
  if (c.style === 'flyer') {
    const bytes = d.files.getPublic ? await d.files.getPublic(c.source).catch(() => null) : null;
    const img = bytes ? await decodeImage(bytes).catch(() => null) : null;
    if (!img) return done({ status: 'failed', note: 'The cover photo could not be read' });
    const out = encodeJpeg(drawFlyer(img, c.flyer ?? {}), 86);
    await d.files.putPublic(path, out, 'image/jpeg');
    return done({ status: 'made', path, width: img.width, height: img.height, provider: 'local' });
  }
  if (!c.mask) return done({ status: 'failed', note: 'The cover photo has no kept cut-out: make its listing photos first' });
  const cut = await d.files.getPrivate(c.mask);
  const img = cut ? await decodePng(cut).catch(() => null) : null;
  const f = img ? frameRgba(img) : null;
  if (!f) return done({ status: 'failed', note: 'The car\'s cut-out could not be read' });
  const pr = await photoRoom(d, j);
  const place = adjustPlace(pr ? photoPlace(f, EXTERIOR.width, EXTERIOR.height, { floor: pr.floor, carWidth: j.cutout?.car_width ?? 0.7 })
    : placeSubject(f, EXTERIOR.width, EXTERIOR.height, SHOWROOM_FIT), c.adjust ?? null, EXTERIOR.width, EXTERIOR.height);
  const made = await makeShowroom({ car: { ...f.image, ground: f.ground }, place, cover: false, photoId: c.photo_id, room: pr?.img ?? null,
    ...(pr ? { look: { reflect: pr.reflect, gain: lightMatch(pr.img, { ...f.image, ground: f.ground }, pr.floor) } } : {}),
    prompt: coverModelPrompt(c.prompt, !!pr) }, d.showroomAi ? [d.showroomAi] : [], !d.showroomAi && !!d.showroomNoKey);
  if (made.provider !== 'ai') {
    return done({ status: 'needs_gemini', note: `With a model needs the image model. ${(made.note ?? 'It is not set up.').replace(/^Made with the free showroom: /, '')}`.slice(0, 300) });
  }
  await d.files.putPublic(path, made.bytes, made.contentType);
  return done({ status: 'made', path, width: EXTERIOR.width, height: EXTERIOR.height, provider: 'ai' }, 'ai');
}

/** r36b (2200): the missing angle. The car's approved photos (up to three) go to the image model with Program settings'
 *  words; the answer is kept as a generated view that staff approve before the site shows it (never the cover). Without the
 *  image model, or past its free daily use, the view says so and nothing is made. */
export interface AngleInput { id: string; vehicle_id: string; shot: string; label: string; sources: string[]; prompt: string }
export async function angleMake(d: WorkerDeps, j: JobContext): Promise<JobResult> {
  const a = (j.input as { angle?: AngleInput }).angle;
  if (!a?.id) return { ok: false, error: 'The angle job is missing its view', retryable: false };
  const done = (o: Record<string, unknown>, provider = 'carmacars'): JobResult => ({ ok: true, provider, output: { angle: { id: a.id, ...o } } });
  if (!d.angleAi) return done({ status: 'needs_gemini', note: 'The image model is not set up (no key).' });
  const images: Array<{ bytes: Uint8Array; contentType: string }> = [];
  for (const p of (a.sources ?? []).slice(0, 3)) {
    const b = d.files.getPublic ? await d.files.getPublic(p).catch(() => null) : null;
    if (b) images.push({ bytes: b, contentType: /\.png$/i.test(p) ? 'image/png' : 'image/jpeg' });
  }
  if (!images.length) return done({ status: 'failed', note: 'The car\'s photos could not be read' });
  const r = await d.angleAi({ images, prompt: a.prompt, photoId: j.photo?.id ?? a.id });
  if (!r.ok) {
    const why = r.reason === 'limit' ? 'The image model\'s free daily use is used up: try again tomorrow.' : r.reason === 'off' ? 'The image model is off in Program settings.'
      : r.reason === 'quota' ? 'The image model\'s free quota is used up for now: try again in an hour.' : `The image model did not make it (${r.message}).`;
    return done({ status: ['limit', 'off', 'quota', 'model'].includes(r.reason) ? 'needs_gemini' : 'failed', note: why.slice(0, 300) });
  }
  const path = `vehicles/${a.vehicle_id}/generated/${a.id}.${r.contentType === 'image/png' ? 'png' : 'jpg'}`;
  await d.files.putPublic(path, r.bytes, r.contentType);
  return done({ status: 'made', path, provider: 'ai' }, 'ai');
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
  const boxes = m.boxes.map((b) => ({ x: Math.floor(b.x * W), y: Math.floor(b.y * H), w: Math.max(2, Math.ceil(b.w * W)), h: Math.max(2, Math.ceil(b.h * H)) }));
  // r45 (2840): every plate is blurred (the owner): nothing is drawn on a plate and no plate is edited out
  const provider = 'carmacars';
  blurPlates(img, boxes.map((b) => ({ x: b.x / W, y: b.y / H, w: b.w / W, h: b.h / H })));
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

/** r41 (2530): the plate checked by itself: plate-auto.ts decides; the cover is "Cover the plate"'s (applyPlates). */
export interface PlateAutoInput { photo_id: string; vehicle_id: string; shot_type: string; source: string; detect_path?: string | null; inside: boolean; end: PlateEnd;
  uncovered_path?: string | null; widths?: number[]; cover_min?: number; clear_min?: number }
const DETECT_MAX_BYTES = 3_400_000;
async function plateAuto(d: WorkerDeps, j: JobContext): Promise<JobResult> {
  const m = (j.input as { plate?: PlateAutoInput }).plate;
  if (!m?.photo_id || !m.source) return { ok: false, error: 'The plate check is missing its photo', retryable: false };
  if (!d.findPlates || !d.plateAutoApply || !d.files.getPublic) return { ok: true, provider: 'carmacars', output: { plate_auto: { decision: 'deferred', why: 'not wired' } } };
  // the model sees a smaller size when the photo has one; the cover is drawn on the photo itself
  let seen = m.detect_path ? await d.files.getPublic(m.detect_path).catch(() => null) : null;
  let full: Uint8Array | null = null;
  if (!seen) { full = await d.files.getPublic(m.source).catch(() => null); seen = full; }
  if (!seen) return { ok: false, error: 'The photo could not be read', retryable: true };
  let size: { width: number; height: number } | null = imageSize(seen);
  let contentType = seen[0] === 0x89 ? 'image/png' : 'image/jpeg';
  if (size && tooLarge(size.width, size.height)) return { ok: true, provider: 'carmacars', output: { plate_auto: { decision: 'unsure', why: 'too large to read here' } } };
  if (!size || seen.length > DETECT_MAX_BYTES) {
    const img = await decodeImage(seen).catch(() => null);
    if (!img) return { ok: true, provider: 'carmacars', output: { plate_auto: { decision: 'unsure', why: 'unreadable' } } };
    const small = scaleDown(img, 1280, 1280);
    seen = encodeJpeg(small, 85); size = { width: small.width, height: small.height }; contentType = 'image/jpeg';
  }
  const asked = await d.findPlates({ bytes: seen, contentType, width: size.width, height: size.height, photoId: m.photo_id }).catch(() => null);
  if (!asked) return { ok: true, provider: 'carmacars', output: { plate_auto: { decision: 'deferred' } } };
  const dec = decidePlate(asked.data, { width: size.width, height: size.height, inside: !!m.inside, coverMin: m.cover_min, clearMin: m.clear_min });
  const base = { photo_id: m.photo_id, path: m.source, confidence: dec.confidence, model: asked.model };
  if (dec.decision !== 'cover') {
    const r = await d.plateAutoApply({ ...base, decision: dec.decision === 'no_plate' ? 'not_visible' : 'unsure', boxes: boxesForSave(dec.boxes) });
    return { ok: true, provider: asked.model, output: { plate_auto: { decision: dec.decision, confidence: dec.confidence, why: dec.why, applied: r.applied } } };
  }
  full ??= await d.files.getPublic(m.source).catch(() => null);
  const src = full ? await decodeImage(full).catch(() => null) : null;
  if (!src) return { ok: false, error: 'The photo could not be read to cover its plate', retryable: !full };
  const img = scaleDown(src, 3000, 3000);
  const W = img.width, H = img.height;
  const boxes = refineAll(greyOfRgba(img), dec.boxes);
  // r45 (2840): blurred so no character can be read; nothing drawn on the plate
  blurPlates(img, boxes);
  const tag = j.id.replace(/-/g, '').slice(0, 6);
  const name = (m.source.split('/').pop() ?? 'photo').replace(/\.\w+$/, '').replace(/-[acp][0-9a-f]{6}(-\d+)?$/, '').replace(/[^\w-]+/g, '-').slice(0, 80) || 'photo';
  const path = `vehicles/${m.vehicle_id}/${name}-a${tag}.jpg`;
  const main = encodeJpeg(img, 90);
  const written: string[] = [path];
  await d.files.putPublic(path, main, 'image/jpeg');
  const variants: Array<{ width: number; format: string; path: string }> = [];
  for (const w of [...new Set(m.widths ?? [])].filter((x) => x > 0 && x < W).sort((a, b) => b - a)) {
    const vp = `vehicles/${m.vehicle_id}/${name}-a${tag}-${w}.jpg`;
    await d.files.putPublic(vp, encodeJpeg(scaleDown(img, w), 86), 'image/jpeg');
    written.push(vp); variants.push({ width: w, format: 'jpg', path: vp });
  }
  // the photo exactly as it was, kept privately (never shown): undo puts this file back
  const png = /\.png$/i.test(m.source);
  let uncovered: string | null = null, wrotePrivate = false;
  if (full) {
    uncovered = `vehicles/${m.vehicle_id}/uncovered/${m.photo_id}-${tag}.${png ? 'png' : 'jpg'}`;
    await d.files.putPrivate(uncovered, full, png ? 'image/png' : 'image/jpeg'); wrotePrivate = true;
  }
  const r = await d.plateAutoApply({ ...base, decision: 'covered', boxes: boxesForSave(boxes), processed_path: path, variants, uncovered_path: uncovered, width: W, height: H, byte_size: main.length });
  // as /api/listing/plate: the replaced files go off the public bucket; a cover that came too late takes its own files away
  for (const p of r.applied ? (r.previous ?? []) : written) await d.files.removePublic?.(p).catch(() => undefined);
  if (!r.applied && wrotePrivate && uncovered) await d.files.removePrivate?.(uncovered).catch(() => undefined);
  return { ok: true, provider: asked.model, output: { plate_auto: { decision: 'cover', confidence: dec.confidence, boxes: boxes.length, applied: r.applied, processed_path: r.applied ? path : null } } };
}

/** r44 (2780): a photo filed as "Other detail" (the sorter could not say, or it was imported before the sorter could read it)
 *  is sorted again. The answer goes to the database, which files an outside photo under its shot (the front three-quarter
 *  becomes the car's primary photo) and makes it in the showroom with Gemini. Nothing is changed here. */
export interface ResortInput { photo_id: string; vehicle_id: string; source: string }
async function resortPhoto(d: WorkerDeps, j: JobContext): Promise<JobResult> {
  const m = (j.input as { resort?: ResortInput }).resort;
  if (!m?.photo_id || !m.source) return { ok: false, error: 'The sort job is missing its photo', retryable: false };
  if (!d.sortPhoto) return { ok: true, provider: 'carmacars', output: { resort: { photo_id: m.photo_id, decision: 'deferred', why: 'not wired' } } };
  const bytes = await d.files.getPrivate(m.source).catch(() => null);
  if (!bytes) return { ok: false, error: 'The photo could not be read', retryable: true };
  let seen = bytes, contentType = bytes[0] === 0x89 ? 'image/png' : 'image/jpeg';
  const size = imageSize(bytes);
  if (size && tooLarge(size.width, size.height)) return { ok: true, provider: 'carmacars', output: { resort: { photo_id: m.photo_id, decision: 'unsure', why: 'too large to read here' } } };
  if (bytes.length > DETECT_MAX_BYTES || (size && Math.max(size.width, size.height) > 1600)) {
    const img = await decodeImage(bytes).catch(() => null);
    if (!img) return { ok: true, provider: 'carmacars', output: { resort: { photo_id: m.photo_id, decision: 'unsure', why: 'unreadable' } } };
    seen = encodeJpeg(scaleDown(img, 1280, 1280), 85); contentType = 'image/jpeg';
  }
  const r = await d.sortPhoto({ bytes: seen, contentType, photoId: m.photo_id }).catch(() => null);
  if (!r) return { ok: true, provider: 'carmacars', output: { resort: { photo_id: m.photo_id, decision: 'deferred' } } };
  if (r === 'unsure') return { ok: true, provider: 'carmacars', output: { resort: { photo_id: m.photo_id, decision: 'unsure' } } };
  return { ok: true, provider: r.model, output: { resort: { photo_id: m.photo_id, decision: 'sorted', shot: r.shot, exterior: resortExterior(r.shot) } } };
}
/** The shots that are an outside view of the whole car (made in the showroom); a body detail, the roof or the engine bay
 *  (exterior_other) stays a detail photo, kept as taken. */
export const resortExterior = (shot: string) => ['front_left', 'front', 'left', 'rear_left', 'rear', 'rear_right', 'right', 'front_right'].includes(shot);

async function resize(d: WorkerDeps, j: JobContext, b: Budget, used: { transformations: number }): Promise<JobResult> {
  const p = j.photo;
  if (!p?.processed_path || !p.is_public) return { ok: true, provider: 'carmacars', output: { variants: [] } };
  // r40 (2450): a photo kept as it was taken because it is too large to decode here: the site uses that file alone
  if (tooLarge(p.width, p.height)) return { ok: true, provider: 'carmacars', output: { variants: [], flags: ['no_variants'] } };
  // r35: the sizes are made locally, so a used allowance no longer stops them (paused with the service asked for everything:
  // the local processor answers anyway, see integrations/photos/local.ts)
  const src = d.files.publicUrl(p.processed_path);
  const variants: { width: number; format: string; path: string }[] = [];
  let n = 0;
  for (const w of VARIANT_WIDTHS) {
    const o = await d.photos.resize({ sourceUrl: src, width: w });
    if (!o.ok) {
      // r38 (2372): a quota, local_only, or the last attempt: the site uses the master file alone (never a failed listing)
      if (o.retryable && o.reason !== 'quota' && !j.input?.local_only && j.attempts < j.max_attempts) return { ok: false, provider: d.photos.name, error: `${o.reason}: ${o.message}`, retryable: true, ...imageCost(n, b, used) };
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

// ================================================================ r45 (2840): every listing photo made by Gemini from the original
/** The job's r45 words: edit (a real photo) or generate (a missing standard angle from the car's own photos). */
export interface R45Input { mode?: 'edit' | 'generate'; car?: CarFacts | null; sources?: string[] }
/** Gemini takes the original as it is (HEIC too) up to this size; a larger JPEG or PNG is made smaller here first. */
const R45_MAX_BYTES = 7_000_000;
const R45_SIDE = 2400;
const R45_SIZES = { exterior: EXTERIOR, interior: INTERIOR };
const mimeOf = (b: Uint8Array): string | null => {
  if (b[0] === 0xff && b[1] === 0xd8) return 'image/jpeg';
  if (b[0] === 0x89 && b[1] === 0x50) return 'image/png';
  if (b[0] === 0x52 && b[1] === 0x49 && b[8] === 0x57 && b[9] === 0x45) return 'image/webp';
  const brand = String.fromCharCode(...b.subarray(8, 12));
  if (String.fromCharCode(...b.subarray(4, 8)) === 'ftyp') return /^(heic|heix|hevc|mif1|msf1|heim|heis)/.test(brand) ? 'image/heic' : /^avif/.test(brand) ? 'image/avif' : 'image/heif';
  return null;
};
/** An original as Gemini is sent it: the file itself when it is small enough, else a smaller JPEG; null when it cannot be. */
export async function forModel(bytes: Uint8Array | null): Promise<{ bytes: Uint8Array; contentType: string } | null> {
  if (!bytes?.length) return null;
  const type = mimeOf(bytes);
  if (!type) return null;
  const size = imageSize(bytes);
  const big = bytes.length > R45_MAX_BYTES || (!!size && Math.max(size.width, size.height) > R45_SIDE * 1.7);
  if (!big) return { bytes, contentType: type };
  if (type !== 'image/jpeg' && type !== 'image/png') return bytes.length <= 15_000_000 ? { bytes, contentType: type } : null;
  if (size && tooLarge(size.width, size.height)) return bytes.length <= 15_000_000 ? { bytes, contentType: type } : null;
  const img = await decodeImage(bytes).catch(() => null);
  return img ? { bytes: encodeJpeg(scaleDown(img, R45_SIDE, R45_SIDE), 90), contentType: 'image/jpeg' } : null;
}

export interface R45Made { pass: boolean; why: string; wait?: string | null; output: Record<string, unknown> & { r45: Record<string, unknown> } }
/** One photo made to r45.1: Gemini edits the original (or generates the view from the car's photos), the site checks the
 *  edges of an outside photo, Gemini's second pass checks the rest, the plates it found are blurred by the site, and the
 *  photo and its sizes are stored. Nothing is stored when the check refuses it. */
export async function makeR45(d: WorkerDeps, j: JobContext): Promise<R45Made> {
  const p = j.photo!;
  const inp = ((j.input as { r45?: R45Input }).r45 ?? {}) as R45Input;
  const generated = inp.mode === 'generate';
  const shot = p.shot_type;
  const ext = isExterior(shot);
  const car: CarFacts = inp.car ?? { model: p.model ?? null };
  const no = (why: string, extra: Record<string, unknown> = {}, wait: string | null = null): R45Made =>
    ({ pass: false, why, wait, output: { r45: { pass: false, spec: R45_SPEC, why, generated, ...(wait ? { wait } : {}), ...extra } } });
  if (!d.angleAi || !d.checkPhoto) return no('Gemini is not set up on the website (no GEMINI_API_KEY)', {}, 'no_key');
  const paths = generated ? (inp.sources ?? []).slice(0, 3) : [p.original_path];
  const real: Array<{ bytes: Uint8Array; contentType: string }> = [];
  for (const path of paths) { const m = await forModel(await d.files.getPrivate(path).catch(() => null)); if (m) real.push(m); }
  if (!real.length) return no(generated ? 'the car\'s photos could not be read' : 'the original photo could not be read');
  const room = ext ? await photoRoom(d, j) : null;
  const roomImg = ext ? { bytes: encodeJpeg(room?.img ?? showroomBackdrop(), 86), contentType: 'image/jpeg' } : null;
  const prompt = promptFor({ car, shot, generated, sources: real.length });
  const made = await d.angleAi({ images: [...real, ...(roomImg ? [roomImg] : [])], prompt, photoId: p.id })
    .catch((e: unknown): ShowroomOut => ({ ok: false, reason: 'error', message: e instanceof Error ? e.message : String(e) }));
  if (!made.ok) return no(`Gemini did not make it (${made.reason}: ${made.message})`, {}, ['limit', 'quota', 'off'].includes(made.reason) ? made.reason : null);
  const ai = await decodeImage(made.bytes).catch(() => null);
  if (!ai) return no('Gemini\'s photo could not be read');
  const size = ext ? R45_SIZES.exterior : R45_SIZES.interior;
  const fitted = fitFrame(ai, size.width, size.height);
  // the site's own check: the top and the side walls of the drawn room are dark (a photographed room has its own light)
  const edgesDark = ext && !room ? backgroundReplaced(fitted) : null;
  const seen = encodeJpeg(scaleDown(fitted, 1280, 1280), 85);
  const asked = await d.checkPhoto({ images: [{ bytes: seen, contentType: 'image/jpeg' }, ...real], system: CHECK_SYSTEM, prompt: checkPrompt({ car, shot, generated }),
    schema: CHECK_SCHEMA as unknown as Record<string, unknown>, photoId: p.id }).catch(() => null);
  if (!asked) return no('the check could not be asked now', {}, 'quota');
  const v: Verdict = judgeCheck(asked.data, { shot, generated, edgesDark });
  const base = { model: made.model ?? null, check_model: asked.model, view: v.view, reasons: v.reasons };
  if (!v.pass) return no(`the check refused it: ${v.reasons.join(', ')}`, base);
  // the plates: blurred by the site on top of Gemini's blur, so no character can be read whatever Gemini left
  blurPlates(fitted, v.plates);
  const tag = j.id.replace(/-/g, '').slice(0, 6);
  const path = `vehicles/${j.vehicle_id}/${p.file_base}-r45${tag}.jpg`;
  await d.files.putPublic(path, encodeJpeg(fitted, 88), 'image/jpeg');
  // the sizes the site uses, made here (never the image service)
  const variants: Array<{ width: number; format: string; path: string }> = [];
  for (const w of VARIANT_WIDTHS) {
    if (w >= fitted.width) continue;
    const vp = `vehicles/${j.vehicle_id}/${p.file_base}-r45${tag}-${w}.jpg`;
    await d.files.putPublic(vp, encodeJpeg(scaleDown(fitted, w), 84), 'image/jpeg');
    variants.push({ width: w, format: 'jpg', path: vp });
  }
  const plates = v.plates.map((b) => ({ x: +b.x.toFixed(4), y: +b.y.toFixed(4), w: +b.w.toFixed(4), h: +b.h.toFixed(4) }));
  return { pass: true, why: '', output: {
    processed_path: path, width: size.width, height: size.height, variants, preset_version: R45_PRESET, flags: [],
    showroom: { provider: 'ai', ...(made.model ? { model: made.model } : {}), note: null, reason: null, mode: generated ? 'generate' : 'edit', spec: R45_SPEC, ...(room ? { background: room.slug } : {}) },
    ...(p.enhance !== undefined ? { enhance: null } : {}), ...(p.rebackground ? { lettered: false } : {}),
    r45: { pass: true, spec: R45_SPEC, generated, plates, ...base } } };
}

/** The fleet's r45 step (job photo_r45): made, or refused with the reasons; the database files it, tries again (twice) or
 *  flags it, and waits for Gemini's daily limit or a quota without counting a try. */
async function r45Job(d: WorkerDeps, j: JobContext): Promise<JobResult> {
  if (!j.photo) return { ok: false, error: 'The photo is missing', retryable: false };
  const r = await makeR45(d, j);
  return { ok: true, provider: r.pass ? 'ai' : 'gemini', units: 1, unit: 'requests', cost_microusd: 0, output: r.output };
}
