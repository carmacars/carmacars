// The search job (migration 0061): writes the car copy, the landing pages and the articles that are due with the text
// model, checks each answer (copy.ts), asks again with the problems named (the last attempt in strict mode), and
// reports the result: published when it passes, otherwise the current text stays and the item is tried again later.
// Then it sends the changed addresses to IndexNow. Pure: the database calls, the model and the network are passed in.
import type { TextGenerator } from '../../integrations/llm/types.ts';
import {
  ARTICLE_PROMPT_VERSION, ARTICLE_SCHEMA, CAR_COPY_SCHEMA, CAR_PROMPT_VERSION, PAGE_COPY_SCHEMA, PAGE_PROMPT_VERSION,
  allowedNumbers, articleProblems, articleSystemPrompt, articleUserPrompt, carCopyProblems, carSystemPrompt, carUserPrompt,
  carFixed, fillHighlights, normalizeArticle, normalizeCarCopy, normalizePageCopy, numbersIn, pageCopyProblems, pageSystemPrompt, pageUserPrompt,
  type CarCopy, type Faq, type PageCopy
} from './copy.ts';

export interface SeoClaim {
  cars: Array<{ vehicle_id: string; slug?: string | null; facts: Record<string, unknown>; locked: string[]; current: Partial<CarCopy>; others: string[]; all_intros: string[] }>;
  pages: Array<{ slug: string; kind: string; name: string; facts: Record<string, unknown>; copy: Partial<PageCopy>; locked: string[]; city?: string }>;
  articles: Array<{ slug: string; title: string; description: string; brief: string | null; body_md: string; faq: Faq[]; locked: string[] }>;
  ai: boolean; max_attempts: number; similarity_max_bps: number; banned: string[];
  indexnow: { enabled: boolean; key: string; paths: string[] };
  budget: Record<string, unknown>; due: Record<string, number>;
}
export interface SeoDeps {
  claim(limit: number): Promise<SeoClaim>;
  report(r: Record<string, unknown>): Promise<unknown>;
  text: TextGenerator;
  /** {{token}} values for articles (the site's settings in words). */
  tokens(): Promise<Record<string, string>>;
  /** Sends a batch to IndexNow; null when sending is off (not production). */
  indexNow?: ((key: string, paths: string[]) => Promise<{ status: number; error?: string; retryAfter?: number }>) | null;
  /** The answer, for the queue: a 429 spends no attempt and pauses the queue (until retryAfter seconds, else tomorrow; 0104). */
  sent?(paths: string[], status: number, error?: string, retryAfter?: number): Promise<unknown>;
  now?(): number;
}
export interface SeoSummary { cars: number; pages: number; articles: number; published: string[]; failed: string[]; indexnow: number; changed: string[]; errors: string[] }

/** Runs one claim: the items it holds, then IndexNow. */
export async function runSeoJob(d: SeoDeps, o: { limit?: number; deadlineMs?: number } = {}): Promise<SeoSummary> {
  const now = d.now ?? (() => Date.now());
  const start = now();
  const deadline = o.deadlineMs ?? 25_000;
  const sum: SeoSummary = { cars: 0, pages: 0, articles: 0, published: [], failed: [], indexnow: 0, changed: [], errors: [] };
  const c = await d.claim(o.limit ?? 2);
  const tries = Math.max(1, c.max_attempts ?? 3);
  const banned = c.banned ?? [];
  const late = () => now() - start > deadline;

  for (const car of c.cars) {
    sum.cars++;
    if (late()) { await d.report({ kind: 'car', id: car.vehicle_id, ok: false, error: 'The job ran out of time; tried again on the next run' }); continue; }
    const r = await writeCar(d.text, car, { tries, banned, maxSimilarity: (c.similarity_max_bps ?? 5000) / 10000 });
    await d.report({ kind: 'car', id: car.vehicle_id, ...r });
    (r.ok ? sum.published : sum.failed).push(`car:${car.vehicle_id}`);
    if (r.ok && car.slug) sum.changed.push(`/cars/${car.slug}`);
  }
  for (const pg of c.pages) {
    sum.pages++;
    if (late()) { await d.report({ kind: 'page', id: pg.slug, ok: false, error: 'The job ran out of time; tried again on the next run' }); continue; }
    const r = await writePage(d.text, pg, { tries, banned, tokens: Object.keys(await d.tokens()) });
    await d.report({ kind: 'page', id: pg.slug, ...r });
    (r.ok ? sum.published : sum.failed).push(`page:${pg.slug}`);
    if (r.ok) sum.changed.push(`/car-rental/${pg.slug}`);
  }
  for (const a of c.articles) {
    sum.articles++;
    if (late()) { await d.report({ kind: 'article', id: a.slug, ok: false, error: 'The job ran out of time; tried again on the next run' }); continue; }
    const r = await writeArticle(d.text, a, await d.tokens(), { tries, banned });
    await d.report({ kind: 'article', id: a.slug, ...r });
    (r.ok ? sum.published : sum.failed).push(`article:${a.slug}`);
    if (r.ok) sum.changed.push(`/guides/${a.slug}`);
  }
  // IndexNow: up to 500 addresses a run, in one request
  if (d.indexNow && c.indexnow?.enabled && c.indexnow.paths.length) {
    const paths = c.indexnow.paths;
    try {
      const res = await d.indexNow(c.indexnow.key, paths);
      await d.sent?.(paths, res.status, res.error, res.retryAfter);
      if (res.status >= 200 && res.status < 300) sum.indexnow = paths.length; else sum.errors.push(`indexnow ${res.status}: ${res.error ?? ''}`.trim());
    } catch (e) {
      const msg = e instanceof Error ? e.message : String(e);
      await d.sent?.(paths, 0, msg);
      sum.errors.push(`indexnow: ${msg}`);
    }
  }
  return sum;
}

type Result = { ok: boolean; copy?: unknown; problems?: string[]; error?: string; model?: string; prompt_version?: string; neurons: number; ms: number; provider: string } & Record<string, unknown>;

async function attempt<T>(t: TextGenerator, tries: number, ask: (problems: string[], strict: boolean) => { system: string; prompt: string; schema: Record<string, unknown>; max: number; task: 'car_copy' | 'seo_page' | 'article' },
  parse: (x: unknown) => T | null, check: (x: T) => string[]): Promise<{ best: T | null; problems: string[]; neurons: number; ms: number; error?: string; model: string }> {
  let problems: string[] = [];
  let neurons = 0;
  const t0 = Date.now();
  let error: string | undefined;
  for (let i = 0; i < tries; i++) {
    const strict = i === tries - 1 && i > 0;
    const q = ask(problems, strict);
    const r = await t.generate<Record<string, unknown>>({ task: q.task, system: q.system, prompt: q.prompt, schema: q.schema, maxOutputTokens: q.max, temperature: strict ? 0 : i ? 0.3 : 0.5 });
    neurons += r.usage?.neurons ?? 0;
    if (!r.ok) {
      error = `${r.reason}: ${r.message}`;
      if (r.reason === 'quota' || r.reason === 'unavailable') break;
      problems = ['the answer was not valid JSON for the schema'];
      continue;
    }
    const x = parse(r.data);
    if (!x) { problems = ['the answer did not follow the schema']; continue; }
    problems = check(x);
    if (!problems.length) return { best: x, problems, neurons, ms: Date.now() - t0, model: t.model };
  }
  return { best: null, problems, neurons, ms: Date.now() - t0, error, model: t.model };
}

export async function writeCar(t: TextGenerator, car: SeoClaim['cars'][number], o: { tries: number; banned: string[]; maxSimilarity: number }): Promise<Result> {
  const locked = car.locked ?? [];
  // the same model must read differently (the setting); any other car only must not be a near copy
  const same = (car.others ?? []).filter(Boolean);
  const rest = (car.all_intros ?? []).filter((x) => x && !same.includes(x));
  const r = await attempt(t, o.tries,
    (problems, strict) => ({ task: 'car_copy', system: carSystemPrompt(), prompt: carUserPrompt(car.facts, { locked, avoid: car.others, problems, strict }), schema: CAR_COPY_SCHEMA as unknown as Record<string, unknown>, max: 1800 }),
    (x) => {
      const c = normalizeCarCopy(x); if (!c) return null;
      // the site's own parts (headline, search text, pickup, included, requirements) and six features from the offered equipment
      Object.assign(c, carFixed(car.facts));
      c.highlights = fillHighlights(c.highlights, car.facts);
      for (const k of locked) if (k in (car.current ?? {})) (c as unknown as Record<string, unknown>)[k] = (car.current as Record<string, unknown>)[k];
      return c;
    },
    (c) => carCopyProblems(c, car.facts, { banned: o.banned, others: same, maxSimilarity: o.maxSimilarity, skip: locked })
      .concat(carCopyProblems(c, car.facts, { others: rest, maxSimilarity: Math.max(o.maxSimilarity, 0.8), skip: locked }).filter((x) => /repeats another/.test(x))));
  return { ok: !!r.best, copy: r.best ?? undefined, problems: r.problems, error: r.best ? undefined : r.error ?? (r.problems.length ? 'The copy did not pass the checks' : 'No answer'),
    model: r.model, prompt_version: CAR_PROMPT_VERSION, neurons: r.neurons, ms: r.ms, provider: t.name };
}

export async function writePage(t: TextGenerator, pg: SeoClaim['pages'][number], o: { tries: number; banned: string[]; tokens?: string[] }): Promise<Result> {
  const locked = pg.locked ?? [];
  const r = await attempt(t, o.tries,
    (problems) => ({ task: 'seo_page', system: pageSystemPrompt(), prompt: pageUserPrompt(pg, { locked, current: pg.copy, problems }), schema: PAGE_COPY_SCHEMA as unknown as Record<string, unknown>, max: 2200 }),
    (x) => { const c = normalizePageCopy(x); if (!c) return null; for (const k of locked) if (k in (pg.copy ?? {})) (c as unknown as Record<string, unknown>)[k] = (pg.copy as Record<string, unknown>)[k]; return c; },
    (c) => pageCopyProblems(c, pg, { banned: o.banned, skip: locked, tokens: o.tokens }));
  return { ok: !!r.best, copy: r.best ?? undefined, problems: r.problems, error: r.best ? undefined : r.error ?? 'The page did not pass the checks', model: r.model, prompt_version: PAGE_PROMPT_VERSION, neurons: r.neurons, ms: r.ms, provider: t.name };
}

export async function writeArticle(t: TextGenerator, a: SeoClaim['articles'][number], tokens: Record<string, string>, o: { tries: number; banned: string[] }): Promise<Result> {
  const numbers = allowedNumbers([a.brief ?? '', a.body_md, a.title, ...a.faq.flatMap((q) => [q.question, q.answer])], numbersIn(a.brief ?? '', false));
  const r = await attempt(t, o.tries,
    (problems) => ({ task: 'article', system: articleSystemPrompt(tokens), prompt: articleUserPrompt(a, problems), schema: ARTICLE_SCHEMA as unknown as Record<string, unknown>, max: 3500 }),
    (x) => { const n = normalizeArticle(x); if (!n) return null; for (const k of a.locked ?? []) if (k in a) (n as unknown as Record<string, unknown>)[k] = (a as unknown as Record<string, unknown>)[k]; return n; },
    (n) => articleProblems(n, { tokens: Object.keys(tokens), numbers, banned: o.banned }));
  return { ok: !!r.best, ...(r.best ?? {}), problems: r.problems, error: r.best ? undefined : r.error ?? 'The article did not pass the checks', model: r.model, prompt_version: ARTICLE_PROMPT_VERSION, neurons: r.neurons, ms: r.ms, provider: t.name };
}
