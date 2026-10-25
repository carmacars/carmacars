// The writing kit (docs/changes/2026-10-24-writing-kit.md): rich, varied, true text for every programmatic page with no
// model at render time. A page gives its facts (facts.ts); the plan of its type (plans.ts) says which sections and
// slots it has; the library (lib/) holds the hand-written variants; the engine picks one per slot by a stable hash of
// the address. The same address always gets the same words, a neighbouring address different ones.
// Precedence on a page: text written for that page (the search copy, seo-import) > the kit > the old template.
import { type Bank, type PickContext, pick, shuffle, wordCount } from './engine.ts';
import type { KitPage, PageKind } from './facts.ts';
import { COMMON } from './lib/common.ts';
import { EXTRA } from './lib/extra.ts';
import { EXTRA2 } from './lib/extra2.ts';
import { EXTRA3 } from './lib/extra3.ts';
import { HUBS } from './lib/hubs.ts';
import { TWINS } from './lib/twins.ts';
import { VEHICLES } from './lib/vehicles.ts';
import { PLANS, type SectionPlan } from './plans.ts';

/** Every bank, its variants joined from each file of the library. */
export const LIBRARY: Record<string, Bank> = {};
for (const part of [COMMON, HUBS, VEHICLES, TWINS, EXTRA, EXTRA2, EXTRA3]) for (const [k, v] of Object.entries(part)) LIBRARY[k] = [...(LIBRARY[k] ?? []), ...v];
export const KIT_VERSION = 'kit-1';

export interface KitSection { id: string; heading: string; paras: string[] }
export interface KitText { kind: PageKind; version: string; sections: KitSection[]; faq: Array<{ question: string; answer: string }>; words: number }

/** Groups of neighbouring sections with the same group number swap places by the page's hash. */
function order(sections: SectionPlan[], seed: string): SectionPlan[] {
  const out: SectionPlan[] = [];
  for (let i = 0; i < sections.length;) {
    const g = sections[i]!.group;
    let j = i + 1;
    if (g !== undefined) while (j < sections.length && sections[j]!.group === g) j++;
    const run = sections.slice(i, j);
    out.push(...(run.length > 1 ? shuffle(run, `${seed}/g${g}`) : run));
    i = j;
  }
  return out;
}

const sectionWords = (s: KitSection) => wordCount(s.heading) + s.paras.reduce((n, p) => n + wordCount(p), 0);

/** The kit's text for one page. Pure and fast (well under a millisecond): no model, no database, no cache needed. */
export function writeKit(page: KitPage): KitText {
  const plan = PLANS[page.kind];
  const c: PickContext = { seed: page.path, facts: page.values, tokens: page.tokens, tags: page.tags, used: new Set() };
  const built: Array<{ s: KitSection; prio: number }> = [];
  const occ = new Map<string, number>();
  for (const sp of order(plan.sections, page.path)) {
    if (sp.when && !sp.when.split(/\s+/).every((t) => t.split('|').some((a) => (a.startsWith('!') ? !page.tags.has(a.slice(1)) : page.tags.has(a))))) continue;
    // a bank used twice on a page starts from its own hashed place each time (never two neighbours of one list)
    const paras = sp.paras.map((keys) => keys.map((k) => { const n = occ.get(k) ?? 0; occ.set(k, n + 1); return pick(LIBRARY[k], n ? `${k}#${n}` : k, c); })
      .filter((x): x is string => !!x).join(' ')).filter(Boolean);
    if (!paras.length) continue;
    const heading = pick(LIBRARY[sp.h], `${sp.h}#${sp.id}`, c) ?? '';
    if (!heading) continue;
    built.push({ s: { id: sp.id, heading, paras }, prio: sp.prio });
  }
  // over the range: drop the lowest priority sections first (never the first one), then the last sentences
  const max = plan.words[1];
  let total = built.reduce((n, b) => n + sectionWords(b.s), 0);
  while (total > max && built.length > 1) {
    const low = built.slice(1).reduce((a, b) => (b.prio < a.prio ? b : a));
    const w = sectionWords(low.s);
    // a section that would take the page under its minimum is trimmed instead of dropped
    if (total - w < plan.words[0]) {
      const p = low.s.paras;
      const last = p[p.length - 1]!.split(/(?<=[.?])\s+/);
      if (last.length > 1) { last.pop(); p[p.length - 1] = last.join(' '); } else if (p.length > 1) p.pop(); else { built.splice(built.indexOf(low), 1); }
    } else built.splice(built.indexOf(low), 1);
    total = built.reduce((n, b) => n + sectionWords(b.s), 0);
  }
  const faq: KitText['faq'] = [];
  for (const k of plan.faq) {
    const x = pick(LIBRARY[k], k, c);
    if (!x) continue;
    const [q, a] = x.split(/\s*\|\|\s*/);
    if (q && a) faq.push({ question: q, answer: a.replace(/^[a-z]/, (m) => m.toUpperCase()) });
  }
  return { kind: page.kind, version: KIT_VERSION, sections: built.map((b) => b.s), faq, words: total };
}

/** Written text for the page (seo-import, the search copy) when it has any, else the kit's. */
export interface WrittenText { intro?: string | null; sections?: Array<{ heading: string; body: string }> | null; faq?: Array<{ question: string; answer: string }> | null }
export function chooseText(written: WrittenText | null | undefined, kit: KitText): { source: 'written' | 'kit'; sections: KitSection[]; faq: KitText['faq'] } {
  const ws = (written?.sections ?? []).filter((s) => s.heading?.trim() && s.body?.trim());
  if (ws.length) {
    return { source: 'written', sections: ws.map((s, i) => ({ id: `w${i}`, heading: s.heading.trim(), paras: s.body.split(/\n{2,}/).map((p) => p.trim()).filter(Boolean) })),
      faq: (written?.faq ?? []).filter((q) => q.question && q.answer) };
  }
  return { source: 'kit', sections: kit.sections, faq: kit.faq };
}

/** Questions merged: the page's own first, then the kit's, never the same question twice, at most max. */
export function mergeFaq<T extends { question: string; answer: string }>(own: T[], kit: Array<{ question: string; answer: string }>, max = 8): Array<{ question: string; answer: string }> {
  const key = (q: string) => q.toLowerCase().replace(/[^a-z0-9]+/g, ' ').trim();
  const seen = new Set(own.map((q) => key(q.question)));
  const out: Array<{ question: string; answer: string }> = [...own];
  for (const q of kit) { if (out.length >= max) break; if (!seen.has(key(q.question))) { seen.add(key(q.question)); out.push(q); } }
  return out;
}

export type { KitPage, PageKind } from './facts.ts';
