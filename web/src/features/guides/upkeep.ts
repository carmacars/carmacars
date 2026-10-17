// The guides keep up with the portals (migration 0055): the checks a section's text must pass, and the prompt that asks
// Workers AI to rewrite a section, held to facts read from the code (web/scripts/portal-facts.mjs). Pure functions, used
// by the upkeep script (web/scripts/guide-upkeep.mjs), the rewrite job (/api/jobs/guide-rewrite) and the unit tests.

export interface PortalFacts {
  /** The portal's navigation, group by group, as the code has it. */
  nav: Array<{ group: string; links: string[] }>;
  /** Every label the portals show (buttons, links, headings, fields), normalized by normLabel. */
  labels: string[];
}
export interface SectionFacts {
  portal: string;
  nav: PortalFacts['nav'];
  /** The labels on the screens the section shows (from the pages' code). */
  screen_labels: string[];
  /** The labels the section names that the portals no longer show, each with the closest labels that do exist. */
  missing: Array<{ label: string; closest: string[] }>;
}

/** A label as compared: lower case, plain quotes and spaces, without the ending dots of "Pay $..." or a trailing colon. */
export function normLabel(s: string): string {
  return s.normalize('NFKC').replace(/[‘’]/g, "'").replace(/[“”]/g, '"').replace(/&amp;/g, '&').replace(/\s+/g, ' ')
    .replace(/[.:\s]+$/, '').replace(/\s*\(\d+\)$/, '').trim().toLowerCase();
}

/** The labels a section names as things to press or open: the bold words of its Markdown (**Label**), not the tables' first column. */
export function guideLabels(md: string): string[] {
  const out = new Set<string>();
  for (const line of md.split('\n')) {
    if (/^\s*\|/.test(line)) {
      // a table: only bold words after the first cell are steps ("Press **X**"); the first cell names a thing
      const cells = line.split('|').slice(2).join('|');
      for (const m of cells.matchAll(/\*\*([^*]{1,80})\*\*/g)) out.add(m[1]!.trim());
      continue;
    }
    for (const m of line.matchAll(/\*\*([^*]{1,80})\*\*/g)) out.add(m[1]!.trim());
  }
  return [...out];
}

// Words in bold that are not a label of the portals: emphasis, the parts of a path that name a group, things printed on
// paper, the keys of a keyboard. Matched after normLabel.
const NOT_LABELS = [/^(not|only|before|after|never|always|once|today|tomorrow|now|first|last|and|or|both|one|each)\b/, /^(g [a-z]|\/|esc|enter|tab)$/,
  /^\$/, /^\d/, /^step \d/, /^[^a-z]+$/, /^(add to home screen|share|allow|settings)$/];

/** The labels of a section that no screen shows (each compared with normLabel; "Pay $..." matches any label that starts with "pay $"). */
export function missingLabels(md: string, known: Iterable<string>): string[] {
  const set = new Set<string>();
  const prefixes: string[] = [];
  const patterns: RegExp[] = [];
  for (const k of known) {
    // ~invite to the * portal: a label built from a template in the code
    if (k.startsWith('~')) { const p = normLabel(k.slice(1)); if (p.replace(/[^a-z]/g, '').length >= 3) patterns.push(new RegExp('^' + p.split('*').map((x) => x.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')).join('.+') + '$')); continue; }
    const n = normLabel(k); if (n) set.add(n);
  }
  for (const n of set) if (n.length >= 3) prefixes.push(n);
  return guideLabels(md).filter((label) => {
    const n = normLabel(label);
    if (!n || NOT_LABELS.some((r) => r.test(n))) return false;
    if (set.has(n) || patterns.some((r) => r.test(n))) return false;
    // "Pay $..." and "View as (owner portal)": the start of the label is enough when the guide marks the rest as variable
    const stem = n.replace(/\s*(\$|\(|\.\.\.|…).*$/, '').trim();
    if (stem !== n && stem.length >= 3 && prefixes.some((p) => p.startsWith(stem))) return false;
    return true;
  });
}

/** Menu paths that do not match the menu: "**Owners and partners** > **Owners**" must name a page of that group. Only paths
 *  that start with a group's name are checked ("**Vehicles** > the car" names no group). */
export function navPathProblems(md: string, nav: PortalFacts['nav']): string[] {
  const groups = new Map<string, Set<string>>();
  for (const g of nav) {
    const k = normLabel(g.group);
    const set = groups.get(k) ?? new Set<string>();
    for (const l of g.links) set.add(normLabel(l));
    groups.set(k, set);
  }
  const out: string[] = [];
  for (const m of md.matchAll(/\*\*([^*]{1,60})\*\* > \*\*([^*]{1,60})\*\*/g)) {
    const links = groups.get(normLabel(m[1]!));
    if (links && !links.has(normLabel(m[2]!))) out.push(`${m[1]} > ${m[2]}`);
  }
  return [...new Set(out)];
}

/** The closest known labels to a missing one (shared words, then a similar start), for the rewrite's facts. */
export function closestLabels(label: string, known: string[], n = 5): string[] {
  const words = (s: string) => new Set(normLabel(s).split(/[^a-z0-9$]+/).filter((w) => w.length > 2));
  const a = words(label);
  const scored = known.map((k) => {
    const b = words(k);
    let shared = 0; for (const w of a) if (b.has(w)) shared++;
    return { k, score: shared / Math.max(1, Math.max(a.size, b.size)) + (normLabel(k).startsWith(normLabel(label).slice(0, 4)) ? 0.1 : 0) };
  }).filter((x) => x.score > 0.2).sort((x, y) => y.score - x.score || x.k.length - y.k.length);
  return [...new Set(scored.map((x) => x.k))].slice(0, n);
}

/** The image lines of a section (they must come back word for word: their pins and sizes belong to the screenshot). */
export function imageLines(md: string): string[] {
  return md.split('\n').filter((l) => /!\[[^\]]*\]\([^)]+\)/.test(l)).map((l) => l.trim());
}

/** The addresses a section's screenshots show (address: carmacars.ca/admin/owners), for the facts of those screens. */
export function sectionAddresses(md: string): string[] {
  return [...new Set([...md.matchAll(/address: carmacars\.ca(\/[^;"\s]*)/g)].map((m) => m[1]!.replace(/\/[0-9a-f-]{36}|\/CC-\d+|\/OA-\d+/gi, '/[id]')))];
}

/** Why a rewritten section cannot be published as it is (an empty list: it can). */
export function rewriteProblems(before: string, after: string, knownLabels: Iterable<string>): string[] {
  const problems: string[] = [];
  const known = [...knownLabels];
  const lost = imageLines(before).filter((l) => !after.includes(l));
  if (lost.length) problems.push(`${lost.length} screenshot line${lost.length > 1 ? 's' : ''} changed or missing`);
  if (/[—–]/.test(after)) problems.push('an em dash');
  if (/\bCarma\s+Cars\b|\bCarmacars\b|\bCARMACARS\b|\bcarma cars\b/.test(after)) problems.push('the brand written differently from CarmaCars');
  const ratio = after.length / Math.max(1, before.length);
  if (ratio < 0.6 || ratio > 1.6) problems.push(`the length changed too much (${Math.round(ratio * 100)}%)`);
  const headsBefore = before.split('\n').filter((l) => /^## /.test(l)).length;
  const headsAfter = after.split('\n').filter((l) => /^## /.test(l)).length;
  if (headsAfter < headsBefore) problems.push('a task heading is missing');
  const bad = missingLabels(after, known);
  if (bad.length) problems.push(`names buttons the portals do not show: ${bad.slice(0, 4).join(', ')}`);
  return problems;
}

export const REWRITE_SYSTEM = 'You keep a software user guide up to date. You get one chapter of the guide in Markdown and FACTS taken from the code of the portal today: its menu, the labels on the screens the chapter shows, and the button names the chapter uses that no longer exist, each with the closest labels that do. Return the chapter with only the changes the facts make necessary: replace each missing button name with the right label from the facts, fix menu paths to match the menu, and keep every step in the order of the screen. Write button and label names in bold exactly as in the facts, and never name a button that is not in the facts. Keep everything else word for word, including every image line exactly as it is (title, size and pins), the headings, the tips and the tables. Plain friendly language, short sentences, no em dashes, and the brand written CarmaCars. Answer in JSON with body_md (the whole chapter) and summary (one sentence on what you changed).';
export const REWRITE_SCHEMA = { type: 'object', properties: { body_md: { type: 'string' }, summary: { type: 'string' } }, required: ['body_md', 'summary'] };

export function rewritePrompt(title: string, body: string, facts: SectionFacts, reason: string): string {
  const f = { menu: facts.nav.map((g) => `${g.group}: ${g.links.join(', ')}`), screen_labels: facts.screen_labels.slice(0, 160), missing: facts.missing };
  return `Why this chapter is checked: ${reason}.\n<facts>${JSON.stringify(f)}</facts>\nThe chapter "${title}":\n<<<GUIDE\n${body}\nGUIDE>>>\nReturn the whole chapter in body_md.`;
}

/** What the fake model returns for a rewrite (local work and tests): each missing label replaced by its closest label. */
export function fakeRewrite(prompt: string): { body_md: string; summary: string } {
  const body = /<<<GUIDE\n([\s\S]*?)\nGUIDE>>>/.exec(prompt)?.[1] ?? '';
  let facts: { missing?: SectionFacts['missing'] } = {};
  try { facts = JSON.parse(/<facts>([\s\S]*?)<\/facts>/.exec(prompt)?.[1] ?? '{}'); } catch { /* none */ }
  let out = body; const done: string[] = [];
  for (const m of facts.missing ?? []) {
    const to = m.closest[0];
    if (!to) continue;
    out = out.split(`**${m.label}**`).join(`**${to}**`); done.push(`${m.label} is now ${to}`);
  }
  return { body_md: out, summary: done.length ? `Renamed buttons: ${done.join('; ')}.` : 'No change needed.' };
}
