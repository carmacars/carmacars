// The listing pipeline's worker (docs/blueprint/09-listing-pipeline.md section 5): claims due jobs from the
// queue of migration 0022 (through 0032's server_listing_claim), runs each with the providers, and reports
// the result (server_listing_result), which moves the intake on. Pure: every outside service is passed in,
// so the unit tests run it with fakes and the server wires the real ones (src/server/listing-worker.ts).
import type { TextGenerator } from '../../integrations/llm/types.ts';
import type { PhotoOut, PhotoProcessor } from '../../integrations/photos/types.ts';
import { DEFAULT_RULES, DRAFT_SCHEMA, PROMPT_VERSION, draftProblems, normalizeDraft, systemPrompt, userPrompt, type CopyRules, type Draft } from './prompt.ts';

export const PRESET = 'brand_background_v1';
export const BACKDROP_PATH = 'site/backdrop/brand_background_v1.png';
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
  photo?: { id: string; shot_type: string; angle: string; original_path: string; processed_path: string | null; rebackground: boolean; is_public: boolean; file_base: string } | null;
}
export interface Budget { ai_neurons_today: number; ai_neurons_limit: number; transformations_month: number; transformations_free: number }
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
  };
  now?(): number;
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
  const src = await d.files.privateUrl(p.original_path);
  let n = 0;
  const fail = (o: Extract<PhotoOut, { ok: false }>): JobResult | null => o.retryable
    ? { ok: false, provider: d.photos.name, error: `${o.reason}: ${o.message}`, retryable: true, ...imageCost(n, b, used) } : null;
  let out: PhotoOut;
  let size = EXTERIOR;
  if (p.rebackground) {
    const cut = await d.photos.cutout(src);
    if (!cut.ok) return fail(cut) ?? fallback(d, j, cut.reason, cut.message, n, b, used);
    n += cut.transformations;
    const cutPath = `vehicles/${j.vehicle_id}/work/${p.id}-cutout.png`;
    await d.files.putPrivate(cutPath, cut.bytes, 'image/png');
    out = await d.photos.composite({ backdropUrl: d.files.publicUrl(BACKDROP_PATH), shadowUrl: d.files.publicUrl(SHADOW_PATH), cutoutUrl: await d.files.privateUrl(cutPath), ...EXTERIOR });
  } else {
    size = INTERIOR;
    out = await d.photos.normalize({ sourceUrl: src, ...INTERIOR });
  }
  if (!out.ok) return fail(out) ?? fallback(d, j, out.reason, out.message, n, b, used);
  n += out.transformations;
  const path = `vehicles/${j.vehicle_id}/${p.file_base}.${ext(out.contentType)}`;
  await d.files.putPublic(path, out.bytes, out.contentType);
  return { ok: true, provider: d.photos.name, ...imageCost(n, b, used),
    output: { processed_path: path, width: size.width, height: size.height, preset_version: p.rebackground ? PRESET : 'normalize_v1', flags: [] } };
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
