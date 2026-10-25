// The search copy written by the daily Claude batch (migration 0133, docs/seo-batches.md): the queue the writer reads
// and the checks every answer passes before it is published. The checks are the website's own (copy.ts, as the search
// job uses them in worker.ts: lengths, the house style, the brand, no numbered company, the Protection Plan wording,
// claims and numbers only from the facts, a car's intro unlike the others), plus: no promise of a service the facts do
// not state, and no page repeating another page of the site or of the same batch. Pure: the workflows run it through
// web/scripts/seo-queue.mjs and web/scripts/seo-import.mjs, the unit tests directly.
import {
  ARTICLE_PROMPT_VERSION, ARTICLE_SCHEMA, CAR_COPY_SCHEMA, CAR_PROMPT_VERSION, LIMITS, PAGE_COPY_SCHEMA, PAGE_PROMPT_VERSION,
  allowedNumbers, articleProblems, carCopyProblems, carFixed, carSystemPrompt, carUserPrompt, fillHighlights, normalizeArticle, normalizeCarCopy,
  normalizePageCopy, numbersIn, pageCopyProblems, pageSystemPrompt, pageUserPrompt, similarity, type ArticleDraft, type CarCopy, type Faq, type PageCopy
} from './copy.ts';

export const BATCH_SOURCE = 'claude-batch';
export const QUEUE_VERSION = 'seo-queue-v1';
export type Kind = 'car' | 'page' | 'article';

/** One page that needs text, as app.seo_batch_queue and app.seo_batch_context return it. */
export interface RawItem {
  kind: Kind; id: string; url: string | null; page_type: string; name: string; priority?: number; city?: string | null;
  facts?: Record<string, unknown>; brief?: string | null; locked?: string[]; current?: Record<string, unknown> | null; source?: string; status?: string;
  others?: string[]; all_intros?: string[]; missing?: boolean; ref?: unknown;
}
export interface Ctx { banned?: string[]; similarity_max_bps?: number; city?: string | null }

/** An item of seo/queue/latest.json: what to write, from which facts, with the same instructions the website's writer had. */
export interface QueueItem {
  kind: Kind; id: string; url: string | null; priority: number; page_type: string; name: string;
  facts: Record<string, unknown> | null; brief: string | null; locked: string[]; current: Record<string, unknown> | null; current_source: string | null;
  write: string[]; word_target: string; avoid: string[];
  instructions: { system: string; prompt: string }; output_schema: Record<string, unknown>; prompt_version: string;
}

const tokensIn = (v: unknown) => [...new Set([...JSON.stringify(v ?? '').matchAll(/\{\{(\w+)\}\}/g)].map((m) => m[1]!))];

/** The articles' system prompt without the live token values (the batch keeps the tokens the article already uses). */
function articleSystem(tokens: string[]): string {
  return ['You write and update the guides of CarmaCars, a car rental company in Toronto, Ontario: practical articles for people renting a car in the Toronto area.',
    'Plain Canadian English, short sentences, the second person. No superlatives, no exclamation marks, never an em dash or an en dash. Write the company name exactly as CarmaCars.',
    'Write Markdown: "## " for section headings, "- " for bullets, short paragraphs. No "# " title (the page has one) and no links to other websites.',
    tokens.length ? `Every CarmaCars fee, price or rule number must be written as one of these {{tokens}} (the site fills them in), never typed: ${tokens.map((t) => `{{${t}}}`).join(', ')}.` : 'Write no CarmaCars fee, price or rule number.',
    'Facts about Ontario (roads, laws, tolls) only when the brief or the current article states them. Do not invent prices of other companies.',
    'Answer with one JSON object that follows the schema exactly, and nothing else.'].join('\n');
}

export function queueItem(r: RawItem, n: number): QueueItem {
  const locked = r.locked ?? [];
  const base = { kind: r.kind, id: String(r.id), url: r.url ?? null, priority: r.priority ?? n, page_type: r.page_type, name: r.name, locked, current: r.current ?? null, current_source: r.source ?? null };
  if (r.kind === 'car') {
    const facts = r.facts ?? {};
    return { ...base, facts, brief: null, avoid: (r.others ?? []).slice(0, 3),
      write: ['intro', 'highlights', 'good_for', 'faq', 'alt_texts'],
      word_target: `intro ${LIMITS.intro_words[0] + 2} to 30 words; ${LIMITS.highlights[1]} highlights copied from the equipment lists; ${LIMITS.good_for[0]} to ${LIMITS.good_for[1]} good_for; ${LIMITS.faq[0]} to ${LIMITS.faq[0] + 1} questions`,
      instructions: { system: carSystemPrompt(), prompt: carUserPrompt(facts, { locked, avoid: r.others }) }, output_schema: CAR_COPY_SCHEMA as unknown as Record<string, unknown>, prompt_version: CAR_PROMPT_VERSION };
  }
  if (r.kind === 'page') {
    const facts = r.facts ?? {};
    const page = { slug: String(r.id), kind: r.page_type, name: r.name, facts, city: r.city ?? undefined };
    return { ...base, facts, brief: null, avoid: [],
      write: ['seo_title', 'meta_description', 'h1', 'intro', 'sections', 'faq'],
      word_target: `intro ${LIMITS.page_intro_words[0] + 10} to ${LIMITS.page_intro_words[1] - 30} words; ${LIMITS.page_sections[0] + 1} to ${LIMITS.page_sections[1]} sections of ${LIMITS.section_words[0] + 20} to ${LIMITS.section_words[1] - 40} words; ${LIMITS.page_faq[0] + 1} to ${LIMITS.page_faq[1]} questions`,
      instructions: { system: pageSystemPrompt(), prompt: pageUserPrompt(page, { locked, current: (r.current ?? undefined) as Partial<PageCopy> | undefined }) },
      output_schema: PAGE_COPY_SCHEMA as unknown as Record<string, unknown>, prompt_version: PAGE_PROMPT_VERSION };
  }
  const cur = (r.current ?? {}) as { title?: string; description?: string; body_md?: string; faq?: Faq[] };
  const tokens = tokensIn([r.brief, cur]);
  return { ...base, facts: null, brief: r.brief ?? null, avoid: [],
    write: ['title', 'description', 'body_md', 'faq'],
    word_target: `title ${LIMITS.article_title[0]} to ${LIMITS.article_title[1]} characters; description ${LIMITS.article_description[0]} to ${LIMITS.article_description[1]} characters; body ${LIMITS.article_words[0] + 200} to ${LIMITS.article_words[1] - 400} words with at least 4 "## " sections; 3 to 5 questions`,
    instructions: { system: articleSystem(tokens), prompt: [`<brief>${r.brief ?? 'Keep the subject and the facts of the current article, and make it clearer and more useful.'}</brief>`,
      `<current>${JSON.stringify(cur)}</current>`, 'Write the article again within the word target.', locked.length ? `Keep these fields exactly as they are: ${locked.join(', ')}.` : ''].filter(Boolean).join('\n') },
    output_schema: ARTICLE_SCHEMA as unknown as Record<string, unknown>, prompt_version: ARTICLE_PROMPT_VERSION };
}

/** seo/queue/latest.json. */
export function buildQueue(q: { generated_at?: string; items: RawItem[]; banned?: string[]; similarity_max_bps?: number; waiting?: Record<string, number> }, limit = 500) {
  const items = q.items.slice(0, limit).map((r, i) => queueItem(r, i + 1));
  return {
    version: QUEUE_VERSION, generated_at: q.generated_at ?? new Date().toISOString(), count: items.length, waiting: q.waiting ?? {},
    rules: {
      banned: q.banned ?? [], similarity_max: (q.similarity_max_bps ?? 5000) / 10000, limits: LIMITS,
      house: ['No em dash or en dash anywhere.', 'Write CarmaCars exactly so; never name a numbered or legal company.', 'No exclamation marks, no hype words.',
        'Never present insurance as something renters get from CarmaCars: say nothing, or name "the Protection Plan".',
        'Only numbers that are in the facts; no prices on landing pages or articles (articles use the {{tokens}} only).',
        'Claim no equipment, condition, rating or service the facts do not state; promise no guarantee, warranty, same-day service or free extra.',
        'Every page reads differently from every other page (cars of the same model, other landing pages, other items of the batch).']
    },
    output: { file: 'seo/batches/<date>-<name>.json', shape: '{"batch": "name", "items": [{"kind": "car|page|article", "id": "<id from the queue>", "copy": {...} | "title", "description", "body_md", "faq"}]}' },
    items
  };
}

// ---------------------------------------------------------------- the checks
/** Promises of a service the facts must state first (auto services, delivery, guarantees). */
const SERVICE_PROMISES = /\b(guarantee[ds]?|warrant(y|ies|ied)|same[- ]day (service|repair|delivery)|24\/7|certified (technicians?|mechanics?)|oem parts|we (fix|repair|service|detail)\w*|free (pickup|towing|estimates?|loaner|inspection|car wash)|money[- ]back)\b/gi;
export function servicePromises(text: string, facts: unknown): string[] {
  const f = JSON.stringify(facts ?? {}).toLowerCase();
  return [...new Set([...text.matchAll(SERVICE_PROMISES)].map((m) => m[0]).filter((m) => !f.includes(m.toLowerCase())))].map((m) => `do not promise "${m}": the facts do not say CarmaCars offers it`);
}

/** An item of a batch file. */
export interface BatchItem { kind?: Kind; id?: string; url?: string; copy?: Record<string, unknown>; title?: string; description?: string; body_md?: string; faq?: Faq[]; prompt_version?: string }
export type Checked = { ok: true; kind: Kind; id: string; url: string | null; publish: Record<string, unknown> } | { ok: false; kind?: Kind; id?: string; url?: string | null; problems: string[] };

const pageBody = (c: PageCopy) => `${c.intro} ${c.sections.map((s) => s.body).join(' ')}`;

/** One item against the live facts (ctx from app.seo_batch_context). `seen`: the texts of the batch's earlier items. */
export function checkItem(live: RawItem, out: BatchItem, ctx: Ctx = {}, seen: { car: string[]; page: string[]; article: string[] } = { car: [], page: [], article: [] }): Checked {
  const ref = { kind: live.kind, id: live.id ? String(live.id) : out.id, url: live.url ?? out.url ?? null };
  if (live.missing) return { ok: false, ...ref, kind: out.kind, problems: ['no such page needs text (the id or address is not a landing page, an eligible car or a guide)'] };
  if (out.kind && out.kind !== live.kind) return { ok: false, ...ref, problems: [`the kind is ${live.kind}, not ${out.kind}`] };
  const banned = ctx.banned ?? [];
  const locked = live.locked ?? [];
  const current = (live.current ?? {}) as Record<string, unknown>;
  if (live.kind === 'car') {
    const facts = live.facts ?? {};
    const c = normalizeCarCopy(out.copy ?? null);
    if (!c) return { ok: false, ...ref, problems: ['copy is missing or has no intro'] };
    // the site's own parts and six features from the offered equipment, as the search job does (worker.ts writeCar)
    Object.assign(c, carFixed(facts));
    c.highlights = fillHighlights(c.highlights, facts);
    for (const k of locked) if (k in current) (c as unknown as Record<string, unknown>)[k] = current[k];
    const max = (ctx.similarity_max_bps ?? 5000) / 10000;
    const same = [...(live.others ?? []), ...seen.car].filter(Boolean);
    const rest = (live.all_intros ?? []).filter((x) => x && !same.includes(x));
    const problems = carCopyProblems(c, facts, { banned, others: same, maxSimilarity: max, skip: locked })
      .concat(carCopyProblems(c, facts, { others: rest, maxSimilarity: Math.max(max, 0.8), skip: locked }).filter((x) => /repeats another/.test(x)))
      .concat(servicePromises([c.intro, ...c.good_for, ...c.faq.flatMap((q) => [q.question, q.answer])].join('\n'), facts));
    if (problems.length) return { ok: false, ...ref, problems: [...new Set(problems)] };
    seen.car.push(c.intro);
    return { ok: true, ...ref, kind: 'car', id: String(live.id), publish: { kind: 'car', id: String(live.id), copy: c satisfies CarCopy, prompt_version: out.prompt_version ?? CAR_PROMPT_VERSION } };
  }
  if (live.kind === 'page') {
    const facts = live.facts ?? {};
    const c = normalizePageCopy(out.copy ?? null);
    if (!c) return { ok: false, ...ref, problems: ['copy is missing, or has no h1 or intro'] };
    for (const k of locked) if (k in current) (c as unknown as Record<string, unknown>)[k] = current[k];
    const problems = pageCopyProblems(c, { name: live.name, facts }, { banned, skip: locked, tokens: tokensIn(current), others: [...(live.others ?? []), ...seen.page].filter(Boolean) })
      .concat(servicePromises(pageBody(c) + '\n' + c.faq.map((q) => `${q.question} ${q.answer}`).join('\n'), facts));
    if (problems.length) return { ok: false, ...ref, problems: [...new Set(problems)] };
    seen.page.push(pageBody(c));
    return { ok: true, ...ref, kind: 'page', id: String(live.id), publish: { kind: 'page', id: String(live.id), copy: c, prompt_version: out.prompt_version ?? PAGE_PROMPT_VERSION } };
  }
  const n = normalizeArticle({ title: out.title ?? out.copy?.title, description: out.description ?? out.copy?.description, body_md: out.body_md ?? out.copy?.body_md, faq: out.faq ?? out.copy?.faq });
  if (!n) return { ok: false, ...ref, problems: ['body_md is missing'] };
  for (const k of locked) if (k in current) (n as unknown as Record<string, unknown>)[k] = current[k];
  const cur = current as { title?: string; body_md?: string; faq?: Faq[] };
  const numbers = allowedNumbers([live.brief ?? '', cur.body_md ?? '', cur.title ?? '', ...(cur.faq ?? []).flatMap((q) => [q.question, q.answer])], numbersIn(live.brief ?? '', false));
  const problems = articleProblems(n, { tokens: tokensIn([live.brief, current]), numbers, banned });
  const others = [...(live.others ?? []), ...seen.article].filter(Boolean);
  const worst = others.length ? Math.max(...others.map((x) => similarity(n.body_md, x))) : 0;
  if (worst > 0.35) problems.push(`the article repeats another guide (${Math.round(worst * 100)}% the same)`);
  problems.push(...servicePromises(n.body_md, live.brief));
  if (problems.length) return { ok: false, ...ref, problems: [...new Set(problems)] };
  seen.article.push(n.body_md);
  return { ok: true, ...ref, kind: 'article', id: String(live.id), publish: { kind: 'article', id: String(live.id), ...(n satisfies ArticleDraft), prompt_version: out.prompt_version ?? ARTICLE_PROMPT_VERSION } };
}

/** A whole batch: each item checked in order (the batch's own items must differ from each other too). The second item
 *  for the same page is refused. `live` is app.seo_batch_context's answer for the batch's refs, in the same order. */
export function checkBatch(items: BatchItem[], live: RawItem[], ctx: Ctx = {}): Checked[] {
  const seen = { car: [] as string[], page: [] as string[], article: [] as string[] };
  const done = new Set<string>();
  return items.map((it, i) => {
    const l = live[i] ?? { kind: it.kind ?? 'page', id: it.id ?? '', url: it.url ?? null, page_type: '', name: '', missing: true };
    const key = `${l.kind}:${l.id}`;
    if (!l.missing && done.has(key)) return { ok: false, kind: l.kind, id: String(l.id), url: l.url, problems: ['the same page appears twice in the batch: only the first is used'] };
    const r = checkItem(l, it, ctx, seen);
    if (r.ok) done.add(key);
    return r;
  });
}

/** The refs app.seo_batch_context reads: {kind, id} or {url}. */
export const refsOf = (items: BatchItem[]) => items.map((it) => (it.id ? { kind: it.kind ?? null, id: String(it.id) } : { url: it.url ?? null }));
