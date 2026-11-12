// Release 40 (migration 2402): one page per service group. Terms with the same search intent are synonyms of the group's
// term (place_terms.canonical_slug): their addresses answer 301 with the group's page, and the group's pages list them.
// No imports: the place pages, the vehicle pages and the unit test share it.

/** The visible line of a group's synonyms ("Also searched as: car hire, cars for hire"), or null when it has none. */
export function alsoSearched(phrases: readonly string[] | null | undefined): string | null {
  const seen = new Set<string>();
  const list = (phrases ?? []).map((x) => x.trim()).filter((x) => x && !seen.has(x.toLowerCase()) && seen.add(x.toLowerCase()));
  return list.length ? `Also searched as: ${list.join(', ')}` : null;
}

/** Where a synonym's vehicle tree address goes: the group term's tree (/t/<group>/...), or /cars for the car rental group
 *  (''); a language prefix (/fr) is kept. */
export function synonymTreePath(group: string, rest: readonly string[], lang = ''): string {
  const tail = rest.length ? `/${rest.join('/')}` : '';
  return `${lang ? `/${lang}` : ''}${group ? `/t/${group}` : '/cars'}${tail}`;
}

/** The 301 of a /t/<term>/... address when <term> is a synonym (the map of public.vehicle_tiers), else null. */
export function termTreeRedirect(seg: readonly string[], synonyms: Record<string, string> | null | undefined, lang = ''): string | null {
  const [term, ...rest] = seg;
  // a language is a code (fr, zh-hk), never anything that could make the address leave the site
  if (lang && !/^[a-z]{2,3}(-[a-z0-9]{2,8})?$/i.test(lang)) return null;
  if (!term || !synonyms || !Object.prototype.hasOwnProperty.call(synonyms, term)) return null;
  return synonymTreePath(synonyms[term]!, rest, lang);
}
