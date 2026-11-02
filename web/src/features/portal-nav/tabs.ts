// The customer portals' menus and tabs (r27 portals, the owner on November 1, 2026: "Every single portal is getting a
// revamp right? Functionality and organization and usability and flow of work and looks wise"). The same rules as the
// admin page groups (features/admin/hubs.ts on r27-nav): one menu link per subject, pages that showed the same subject
// from different angles merged into one page with a row of tabs (`?tab=<key>`), the old addresses redirecting to their
// tab with their query kept. Pure: the menus (renter, owner, investor) and the unit tests import it.

export type MenuIcon = 'home' | 'car' | 'doc' | 'star' | 'user' | 'card' | 'chart' | 'play';
/** A menu link. `exact`: current only on its own address. `also`: other addresses where it is current (its merged
 *  pages and their detail pages). `when`: shown only when the portal frame says so (a flag of the person). `count`: a
 *  number shown on the link (the unread notifications). */
export interface MenuLink { href: string; label: string; icon: MenuIcon; exact?: boolean; also?: string[]; when?: string; count?: 'unread' }
/** A tab of a merged page: its key (`?tab=`), its address and label. `when`: shown only for that kind of person. */
export interface PageTab { key: string; href: string; label: string; when?: string; not?: string }

const under = (path: string, href: string) => path === href || path.startsWith(`${href}/`);

/** The menu link current on this page: an exact match first, then the longest address the page is under. */
export function currentLink(menu: MenuLink[], path: string): MenuLink | null {
  let best: MenuLink | null = null; let n = -1;
  for (const l of menu) {
    const hrefs = [l.href, ...(l.also ?? [])];
    for (const h of hrefs) {
      const hit = l.exact && h === l.href ? path === h : under(path, h);
      if (hit && h.length > n) { best = l; n = h.length; }
    }
  }
  return best;
}

/** The links a person sees: those without a flag, and those whose flag is on. */
export function menuFor(menu: MenuLink[], flags: Record<string, boolean>): MenuLink[] {
  return menu.filter((l) => !l.when || flags[l.when]);
}

/** The tabs a person sees: `when` needs the flag on, `not` needs it off. */
export function tabsFor(tabs: PageTab[], flags: Record<string, boolean>): PageTab[] {
  return tabs.filter((t) => (!t.when || flags[t.when]) && (!t.not || !flags[t.not]));
}

/** The tab a merged page shows: the `tab` value when it is one of its tabs, else the first. */
export function tabOf(tabs: PageTab[], v: string | string[] | undefined): PageTab {
  const s = Array.isArray(v) ? v[0] : v;
  return tabs.find((t) => t.key === s) ?? tabs[0]!;
}

/** Where an old address now lives: the merged page with the tab (none for its first tab), the old query kept. */
export function movedTo(path: string, tab: string | null, sp: Record<string, string | string[] | undefined>): string {
  const q = new URLSearchParams();
  if (tab) q.set('tab', tab);
  for (const [k, v] of Object.entries(sp)) {
    if (v === undefined || (k === 'tab' && tab)) continue;
    for (const x of Array.isArray(v) ? v : [v]) q.append(k, x);
  }
  const s = q.toString();
  return s ? `${path}?${s}` : path;
}

