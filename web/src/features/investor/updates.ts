// The investor portal's Updates page (/investor/updates, release 29): every release and what it added, newest first.
// Source: one investor note per release in docs/releases/<release>.md, written for investors:
//
//   ---
//   release: r27                 the id (also the file name)
//   title: Release 27            what the page shows ("Update October 21, 2026" for one that cannot be pinned down)
//   date: 2026-11-06             the day it went live; "pending" until then (left off the page)
//   seq: 1                       optional: the order of releases on the same day (higher is later)
//   summary: One line.
//   changes:                     the change records (docs/changes) it shipped; every record belongs to one release
//     - 2026-11-06-portals-revamp.md
//   ---
//   ## Renters                   the areas below, in any order; each item a "- " line in plain language
//   - The renter portal, redesigned
//
// scripts/gen-release-notes.mjs builds updates-data.json from the notes; scripts/check-release-notes.mjs (run by
// scripts/check-text.sh) checks every change record has its release and nothing on the deny list below is in a note.
// Pure: the scripts, the page and the unit tests share it.

export const AREAS = ['Renters', 'Owners', 'Staff tools', 'Partners', 'Website & search', 'Reliability & security'] as const;
export type Area = (typeof AREAS)[number];
export interface ReleaseNote { release: string; title: string; date: string; seq: number; summary: string; changes: string[]; areas: Array<{ area: Area; items: string[] }> }
export type Update = Omit<ReleaseNote, 'changes'>;

/** One note's text as a release; throws with the reason when it is not well formed. */
export function parseNote(text: string, file = 'note'): ReleaseNote {
  const m = /^---\n([\s\S]*?)\n---\n?([\s\S]*)$/.exec(text.replace(/\r\n/g, '\n'));
  if (!m) throw new Error(`${file}: no frontmatter between --- lines`);
  const head: Record<string, string> = {}; const changes: string[] = [];
  let inChanges = false;
  for (const line of m[1]!.split('\n')) {
    if (!line.trim()) continue;
    const item = /^\s+-\s+(.+)$/.exec(line);
    if (item && inChanges) { changes.push(item[1]!.trim()); continue; }
    const kv = /^([a-z]+):\s*(.*)$/.exec(line);
    if (!kv) throw new Error(`${file}: cannot read the line "${line}"`);
    inChanges = kv[1] === 'changes';
    if (!inChanges) head[kv[1]!] = kv[2]!.trim();
  }
  for (const k of ['release', 'title', 'date', 'summary']) if (!head[k]) throw new Error(`${file}: "${k}" is missing`);
  if (head.date !== 'pending' && !/^\d{4}-\d{2}-\d{2}$/.test(head.date!)) throw new Error(`${file}: the date is YYYY-MM-DD or "pending"`);
  const areas: ReleaseNote['areas'] = [];
  let cur: ReleaseNote['areas'][number] | null = null;
  for (const line of m[2]!.split('\n')) {
    if (!line.trim()) continue;
    const h = /^##\s+(.+)$/.exec(line);
    if (h) {
      const a = h[1]!.trim() as Area;
      if (!AREAS.includes(a)) throw new Error(`${file}: "${a}" is not an area (${AREAS.join(', ')})`);
      cur = { area: a, items: [] }; areas.push(cur); continue;
    }
    const it = /^-\s+(.+)$/.exec(line);
    if (!it || !cur) throw new Error(`${file}: an item is a "- " line under an area heading ("${line}")`);
    cur.items.push(it[1]!.trim());
  }
  if (!areas.some((a) => a.items.length)) throw new Error(`${file}: no items`);
  return { release: head.release!, title: head.title!, date: head.date!, seq: Number(head.seq ?? 0) || 0, summary: head.summary!, changes, areas };
}

/** The releases the page shows: live ones only, newest first. */
export function forPage(notes: ReleaseNote[]): Update[] {
  return notes.filter((n) => n.date !== 'pending')
    .sort((a, b) => (a.date === b.date ? b.seq - a.seq : a.date < b.date ? 1 : -1))
    .map((n) => { const { release, title, date, seq, summary } = n; return { release, title, date, seq, summary, areas: AREAS.map((a) => n.areas.find((x) => x.area === a)).filter((x): x is Update['areas'][number] => !!x && x.items.length > 0) }; });
}

/** Search and area filter of the page (case-insensitive words, all must match an item, its release's title or summary). */
export function filterUpdates(list: Update[], q: string, area: Area | ''): Update[] {
  const words = q.toLowerCase().split(/\s+/).filter(Boolean);
  return list.map((u) => {
    const head = `${u.title} ${u.summary} ${u.date}`.toLowerCase();
    const areas = u.areas.filter((a) => !area || a.area === area)
      .map((a) => ({ area: a.area, items: a.items.filter((i) => words.every((w) => `${head} ${i.toLowerCase()}`.includes(w))) }))
      .filter((a) => a.items.length);
    return { ...u, areas };
  }).filter((u) => u.areas.length);
}

// ---------------------------------------------------------------- what investor material never says
// Fleet size and car counts, utilization, insurance premiums or details, internal costs, margins, vendor pricing, pay;
// any other business than CarmaCars; names (only "the founders"); personal data; security weak points; incident details.
export const DENY: Array<[RegExp, string]> = [
  [/almash/i, 'another business'], [/blind\s*spot/i, 'another business'], [/\b01\s*motors\b/i, 'another business'],
  [/\bturo\b|ridealike|getaround/i, 'another business'], [/gohighlevel|\bghl\b/i, 'another business'],
  [/\bejar\b|zillions|piggybank|tokenrocket|cleanguys|avnts/i, 'another business'],
  [/\bstripe\b|\bresend\b|cloudflare|\bquo\b|onlinejobs|rentalcoverage|serviceontario|facebook|google|apple wallet/i, 'a vendor or another business'], [/App Store|Google Play/, 'a vendor or another business'],
  [/\b(abbas|mahad|karan|max|yusuf|motala|hussain)\b/i, 'a personal name'],
  [/\b\d+\s+(cars|vehicles)\b|fleet\s+(size|of\s+\d)|\bcar\s+count/i, 'fleet size'],
  [/utili[sz]ation|occupancy/i, 'utilization'],
  [/premium|insurance|deductible/i, 'insurance details'],
  [/\bmargins?\b|internal\s+costs?|cost\s+per|\bcogs\b|vendor\s+pric/i, 'costs or margins'],
  [/salar(y|ies)|\bwages?\b|hourly\s+pay|\bva\s+pay|per\s+hour|\bpaid\s+\$|\$\s?\d/i, 'pay or money amounts'],
  [/\bcommissions?\b/i, 'pay'],
  [/[\w.+-]+@[\w-]+\.[\w.]+|\+?1?[\s(-]*\d{3}[\s)-]*\d{3}[\s-]*\d{4}/, 'personal data'],
  [/vulnerab|exploit|injection|\bxss\b|csrf|bypass|leak|breach|attack|scraper|bot\s+traffic/i, 'a security detail ("security hardening")'],
  [/incident|outage|\bdown\s?time|crash|backlog|overrun|\bwal\b|spam/i, 'an incident detail ("reliability improvements")'],
  [/\b0\d{3}\b|migration/i, 'internal detail']
];
/** The deny-list hits in a text: [the words found, why]. */
export function denyHits(text: string): Array<[string, string]> {
  const out: Array<[string, string]> = [];
  for (const [re, why] of DENY) { const m = re.exec(text); if (m) out.push([m[0], why]); }
  return out;
}
