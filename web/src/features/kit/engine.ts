// The writing kit's engine (docs/changes/2026-10-24-writing-kit.md): picks one written variant per slot with a stable
// hash of the page's address, fills it from the page's facts only, and drops a variant whose facts are missing.
// Pure and synchronous: no imports, no I/O, so it runs at render time on the Worker and in Node's test runner.
//
// A variant is a string, or [condition, string]. In a string:
//   {name}      a fact of the page (KitValues); a variant whose required fact is missing is never chosen
//   {{name}}    a site token (Program settings: {{maxDays}}, {{minAge}} ...); empty counts as missing
//   [ ... ]     an optional part: kept when every fact inside it is present, dropped otherwise (one level, no nesting)
//   <a|b|c>     one of several wordings, chosen by the hash (may hold facts; one level, no nesting)
//   #topic      at the start: what the sentence is about; once a topic is on the page, no other sentence with it is chosen
// A condition is tags joined by spaces (all must hold); "a|b" is either; "!a" is not a.

export type Variant = string | readonly [string, string];
export type Bank = readonly Variant[];
export type KitValue = string | number | null | undefined;
export type KitValues = Record<string, KitValue>;

/** 32-bit FNV-1a: the same address always gives the same number, a neighbouring address a different one. */
export function hash(s: string): number {
  let h = 0x811c9dc5;
  for (let i = 0; i < s.length; i++) { h ^= s.charCodeAt(i); h = Math.imul(h, 0x01000193); }
  // a final mix so that keys differing only at the end still spread over the whole range
  h ^= h >>> 15; h = Math.imul(h, 0x2c1b3c6d); h ^= h >>> 12; h = Math.imul(h, 0x297a2d39); h ^= h >>> 15;
  return h >>> 0;
}

// ---------------------------------------------------------------- conditions
type Pred = (tags: ReadonlySet<string>) => boolean;
const predCache = new Map<string, Pred>();
export function cond(expr: string): Pred {
  let p = predCache.get(expr);
  if (p) return p;
  const terms = expr.trim().split(/\s+/).filter(Boolean).map((t) => t.split('|').map((a) => (a.startsWith('!') ? { not: true, tag: a.slice(1) } : { not: false, tag: a })));
  p = (tags) => terms.every((alts) => alts.some((a) => tags.has(a.tag) !== a.not));
  predCache.set(expr, p);
  return p;
}

// ---------------------------------------------------------------- filling
const SLOT = /\{\{(\w+)\}\}|\{(\w+)\}/g;
const ALT = /<([^<>]*\|[^<>]*)>/g;
const OPT = /\[([^[\]]*)\]/g;

function present(v: KitValue): boolean { return v !== null && v !== undefined && v !== '' && !(typeof v === 'number' && !Number.isFinite(v)); }
function show(v: KitValue): string {
  if (typeof v !== 'number') return String(v);
  return Number.isInteger(v) ? String(v).replace(/\B(?=(\d{3})+(?!\d))/g, ',') : v.toLocaleString('en-CA');
}

/** Every fact the text needs is present (tokens and facts alike). */
function allPresent(text: string, f: KitValues, t: Record<string, string>): boolean {
  for (const m of text.matchAll(SLOT)) {
    if (m[1] !== undefined ? !present(t[m[1]]) : !present(f[m[2]!])) return false;
  }
  return true;
}
function subst(text: string, f: KitValues, t: Record<string, string>): string {
  return text.replace(SLOT, (_m, tok: string | undefined, key: string | undefined) => (tok !== undefined ? show(t[tok]) : show(f[key!])));
}

/** One variant filled, or null when a fact it needs is missing. */
export function fillVariant(text: string, f: KitValues, t: Record<string, string>, seed: string): string | null {
  let k = 0;
  let s = text.indexOf('<') >= 0 ? text.replace(ALT, (_m, body: string) => { const opts = body.split('|'); return opts[hash(`${seed}~${k++}`) % opts.length]!; }) : text;
  if (s.indexOf('[') >= 0) s = s.replace(OPT, (_m, body: string) => (allPresent(body, f, t) ? body : ''));
  if (!allPresent(s, f, t)) return null;
  return tidy(subst(s, f, t));
}

/** Spaces and punctuation after optional parts were dropped: no double spaces, no space before a comma or full stop. */
export function tidy(s: string): string {
  return s.replace(/\s+/g, ' ').replace(/\s+([,.;:?)])/g, '$1').replace(/\(\s+/g, '(').replace(/,\s*([.?])/g, '$1').replace(/\.\./g, '.').trim()
    .replace(/^[a-z]/, (c) => c.toUpperCase());
}

// ---------------------------------------------------------------- picking
export interface PickContext {
  seed: string; facts: KitValues; tokens: Record<string, string>; tags: ReadonlySet<string>;
  /** the sentences already on the page (never the same sentence twice) */
  used: Set<string>;
  /** the topics already on the page (#topic at the start of a variant) */
  topics?: Set<string>;
}
const TOPIC = /^((?:#\w+\s+)+)/;

// Each bank is read once into its compiled form (its conditions, topics and the facts it needs outside optional parts),
// so a page checks a variant with a few lookups before it fills anything.
interface Compiled { pred: Pred | null; topics: string[]; text: string; req: string[]; tok: string[]; plain: boolean }
const compiled = new WeakMap<Bank, Compiled[]>();
function compile(bank: Bank): Compiled[] {
  let c = compiled.get(bank);
  if (c) return c;
  c = bank.map((v) => {
    let text = typeof v === 'string' ? v : v[1];
    const m = TOPIC.exec(text);
    const topics = m ? m[1]!.trim().split(/\s+/).map((x) => x.slice(1)) : [];
    if (m) text = text.slice(m[0].length);
    const outside = text.replace(OPT, '').replace(ALT, '');
    const req: string[] = [], tok: string[] = [];
    for (const x of outside.matchAll(SLOT)) (x[1] !== undefined ? tok : req).push(x[1] ?? x[2]!);
    return { pred: typeof v === 'string' ? null : cond(v[0]), topics, text, req, tok, plain: text.indexOf('[') < 0 && text.indexOf('<') < 0 };
  });
  compiled.set(bank, c);
  return c;
}

/** The variant of a bank for this page: the conditions that hold, then from a hashed start the first that fills. */
export function pick(bank: Bank | undefined, key: string, c: PickContext): string | null {
  if (!bank || !bank.length) return null;
  const ok = compile(bank).filter((v) => !v.pred || v.pred(c.tags));
  if (!ok.length) return null;
  const start = hash(`${c.seed}|${key}`) % ok.length;
  const topics = c.topics ?? (c.topics = new Set());
  for (let i = 0; i < ok.length; i++) {
    const v = ok[(start + i) % ok.length]!;
    if (v.topics.length && v.topics.some((x) => topics.has(x))) continue;
    if (v.req.some((k) => !present(c.facts[k])) || v.tok.some((k) => !present(c.tokens[k]))) continue;
    const out = v.plain ? tidy(subst(v.text, c.facts, c.tokens)) : fillVariant(v.text, c.facts, c.tokens, `${c.seed}|${key}|${i}`);
    if (out === null) continue;
    const id = out.slice(0, 60).toLowerCase();
    if (c.used.has(id)) continue;
    c.used.add(id);
    for (const x of v.topics) topics.add(x);
    return out;
  }
  return null;
}

/** A stable shuffle of a list by the page's seed (Fisher and Yates with the hash as the source). */
export function shuffle<T>(xs: readonly T[], seed: string): T[] {
  const a = [...xs];
  for (let i = a.length - 1; i > 0; i--) { const j = hash(`${seed}#${i}`) % (i + 1); [a[i], a[j]] = [a[j]!, a[i]!]; }
  return a;
}

export const wordCount = (s: string) => (s.trim() ? s.trim().split(/\s+/).length : 0);
