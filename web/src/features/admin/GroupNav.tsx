'use client';
import Link from 'next/link';
import { usePathname, useRouter, useSearchParams } from 'next/navigation';
import { useEffect, useState } from 'react';

// The portal's navigation, simply (the owner asked for an admin portal that is easy to find your way in): a few
// groups with plain names, the current group open with its pages and the current page highlighted, the others one
// tap away. On a phone the whole menu folds behind one "Menu" button that names where you are. Keyboard: "g" then a
// letter goes to a page; "/" focuses the search.
export interface NavLink { href: string; label: string; key?: string; /** a small heading above this link: a long group in a few labelled parts */ section?: string }
export interface NavGroup { key: string; label: string; links: NavLink[] }

function matches(path: string, query: string, href: string): boolean {
  const [p, q] = href.split('?');
  if (q) return path === p && query.includes(q);
  return path === p || (p !== '/admin' && p !== '/staff' && path.startsWith(`${p}/`));
}

/** The link of the page shown: the most specific match (/admin/bookings/new over /admin/bookings). */
export function currentLink(groups: NavGroup[], path: string, query: string): { group: NavGroup | null; link: NavLink | null } {
  let best: { group: NavGroup | null; link: NavLink | null; len: number } = { group: null, link: null, len: -1 };
  for (const g of groups) for (const l of g.links) {
    if (matches(path, query, l.href) && l.href.length > best.len) best = { group: g, link: l, len: l.href.length };
  }
  return { group: best.group, link: best.link };
}

export function GroupNav({ groups, counts = {}, label, testId }: { groups: NavGroup[]; counts?: Record<string, number>; label: string; testId?: string }) {
  const path = usePathname();
  const sp = useSearchParams();
  const query = sp?.toString() ?? '';
  const router = useRouter();
  const { group: cur, link: here } = currentLink(groups, path, query);
  const [open, setOpen] = useState<Record<string, boolean>>({});
  // the phone menu is open for the page it was opened on, so it closes by itself after a link is followed
  const [menuFor, setMenuFor] = useState<string | null>(null);
  const menu = menuFor === path;
  const setMenu = (on: boolean) => setMenuFor(on ? path : null);
  useEffect(() => {
    let g = false; let t: ReturnType<typeof setTimeout> | undefined;
    const keys = new Map(groups.flatMap((x) => x.links.filter((l) => l.key).map((l) => [l.key!, l.href] as [string, string])));
    const on = (e: KeyboardEvent) => {
      const el = e.target as HTMLElement | null;
      if (el && (el.isContentEditable || ['INPUT', 'TEXTAREA', 'SELECT'].includes(el.tagName)) || e.metaKey || e.ctrlKey || e.altKey) return;
      if (e.key === '/') { const s = document.querySelector<HTMLInputElement>('[data-shortcut="/"]'); if (s) { e.preventDefault(); s.focus(); } return; }
      if (g) { const href = keys.get(e.key); g = false; if (href) { e.preventDefault(); router.push(href); } return; }
      if (e.key === 'g') { g = true; clearTimeout(t); t = setTimeout(() => { g = false; }, 900); }
    };
    window.addEventListener('keydown', on);
    return () => window.removeEventListener('keydown', on);
  }, [router, groups]);
  const total = (g: NavGroup) => g.links.reduce((n, l) => n + (counts[l.href] ?? 0), 0);
  return (
    <nav className="gn" aria-label={label} data-testid={testId}>
      <button type="button" className="gn__menu" aria-expanded={menu} aria-controls={`${testId ?? 'gn'}-groups`} onClick={() => setMenu(!menu)} data-testid="nav-menu">
        <span className="gn__menu-icon" aria-hidden="true"><span /><span /><span /></span>
        <span><span className="vh">Menu. You are on </span>{cur ? <><b>{cur.label}</b>{here && here.label !== cur.label ? <span className="muted"> · {here.label}</span> : null}</> : 'Menu'}</span>
      </button>
      <ul className={`gn__groups${menu ? ' is-open' : ''}`} id={`${testId ?? 'gn'}-groups`}>
        {groups.map((g) => {
          const isCur = cur?.key === g.key;
          const expanded = open[g.key] ?? isCur;
          const n = total(g);
          if (g.links.length === 1) {
            const l = g.links[0]!;
            return (
              <li key={g.key} className={`gn__group${isCur ? ' is-current' : ''}`}>
                <Link prefetch={false} className="gn__single" href={l.href} aria-current={here?.href === l.href ? 'page' : undefined}>{g.label}{n ? <span className="pt__count">{n}</span> : null}</Link>
              </li>
            );
          }
          return (
            <li key={g.key} className={`gn__group${isCur ? ' is-current' : ''}`}>
              <button type="button" className="gn__head" aria-expanded={expanded} onClick={() => setOpen({ ...open, [g.key]: !expanded })} data-testid={`nav-group-${g.key}`}>
                <span>{g.label}</span>{n && !expanded ? <span className="pt__count">{n}</span> : null}<span className="gn__chev" aria-hidden="true" />
              </button>
              {expanded && (
                <ul className="gn__links">{g.links.map((l) => [
                  l.section ? <li key={`s-${l.section}`} className="gn__section" aria-hidden="true">{l.section}</li> : null,
                  <li key={l.href}><Link prefetch={false} href={l.href} aria-current={here?.href === l.href ? 'page' : undefined}>{l.label}{counts[l.href] ? <span className="pt__count">{counts[l.href]}</span> : null}</Link></li>
                ])}</ul>
              )}
            </li>
          );
        })}
      </ul>
    </nav>
  );
}
