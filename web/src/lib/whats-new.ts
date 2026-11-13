// The "What's new" pop-up (release 43; migration 2730): which release a person is shown, and the words for their portal.
// The text is src/generated/whats-new.json (scripts/whats-new.mjs, from docs/releases/rNN.md); who has seen what is the
// database's user_release_seen. Pure: the layouts, the server action and the unit tests share it.

/** The portals a pop-up is kept per (user_release_seen.portal) */
export type WnPortal = 'renter' | 'owner' | 'partner' | 'investor' | 'staff' | 'admin';
export const WN_PORTALS: WnPortal[] = ['renter', 'owner', 'partner', 'investor', 'staff', 'admin'];
export const isWnPortal = (p: unknown): p is WnPortal => typeof p === 'string' && (WN_PORTALS as string[]).includes(p);

/** The section of a release note that is written for each portal ("## For owners" is `owners`) */
export const SECTION_OF: Record<WnPortal, string> = { renter: 'renters', owner: 'owners', partner: 'partners', investor: 'investors', staff: 'staff', admin: 'admins' };
/** A partner without a partner section reads the owner section */
const FALLBACK: Partial<Record<WnPortal, string>> = { partner: 'owners' };

export interface WnRelease { date: string; seq: number; summary: string; sections: Record<string, string[]> }
export interface WnData { releases: Record<string, WnRelease> }
export interface WnShow { release: string; date: string; summary: string; items: string[] }

const num = (id: string) => Number(/\d+/.exec(id)?.[0] ?? 0);
/** Newest first: by date, then the note's seq, then the release number, then the id */
export function releaseOrder(data: WnData): string[] {
  return Object.keys(data.releases).sort((a, b) => {
    const x = data.releases[a]!, y = data.releases[b]!;
    if (x.date !== y.date) return x.date < y.date ? 1 : -1;
    return (y.seq - x.seq) || (num(b) - num(a)) || (a < b ? 1 : -1);
  });
}

/** What a release says for a portal, or null when it says nothing there (and for a release that is not dated) */
export function showFor(data: WnData, release: string, portal: WnPortal): WnShow | null {
  const r = data.releases[release];
  if (!r || !/^\d{4}-\d{2}-\d{2}$/.test(r.date)) return null;
  const fb = FALLBACK[portal];
  const items = r.sections[SECTION_OF[portal]] ?? (fb ? r.sections[fb] : undefined);
  return items?.length ? { release, date: r.date, summary: r.summary, items } : null;
}

/** The newest release with words for this portal: what the menu link opens */
export function latestFor(data: WnData, portal: WnPortal): WnShow | null {
  for (const id of releaseOrder(data)) { const s = showFor(data, id, portal); if (s) return s; }
  return null;
}

/** The release to show now: the newest with words for this portal, if the person has not seen it there; otherwise null */
export function pickPopup(data: WnData, portal: WnPortal, seen: readonly string[]): WnShow | null {
  const s = latestFor(data, portal);
  return s && !seen.includes(s.release) ? s : null;
}

/** "November 12, 2026" for 2026-11-12 (no time zone involved) */
export function prettyDate(iso: string): string {
  const m = /^(\d{4})-(\d{2})-(\d{2})$/.exec(iso);
  if (!m) return iso;
  const months = ['January', 'February', 'March', 'April', 'May', 'June', 'July', 'August', 'September', 'October', 'November', 'December'];
  return `${months[Number(m[2]) - 1] ?? ''} ${Number(m[3])}, ${m[1]}`;
}
