// Clicks must not throw the page back to the top (Release 27, the owner: "Button clicks still scroll up, fix that
// everywhere"). Next.js scrolls to the top on every navigation, including one to the same page with other search
// parameters (a tab, a filter, a page of results, a sort). `staysOnPage` says whether a target is the page we are on, so
// the shared Link (components/Link.tsx) passes scroll={false} and router calls use `scrollOption`. A real navigation to
// another page still goes to the top, and a link with a #hash keeps the browser's own scroll to it. No imports.

type Target = string | { pathname?: string | null; query?: unknown; hash?: string | null; search?: string | null } | null | undefined;

/** The path of a target relative to the current path ('' when the target is only a query or a hash). */
function pathOf(href: Target): { path: string | null; hash: boolean } {
  if (href === null || href === undefined) return { path: null, hash: false };
  if (typeof href !== 'string') return { path: href.pathname ?? '', hash: !!href.hash };
  if (/^[a-z][a-z0-9+.-]*:/i.test(href) || href.startsWith('//')) return { path: null, hash: false }; // another site, mailto:, tel:
  const hash = href.includes('#');
  const noHash = href.split('#')[0] ?? '';
  return { path: noHash.split('?')[0] ?? '', hash };
}

/** Is `href` the page we are on (the same path, only the query differs or is cleared)? Targets with a #hash and other
 * sites are not: they keep the default. `current` is the pathname of the page. */
export function staysOnPage(href: Target, current: string | null | undefined): boolean {
  const { path, hash } = pathOf(href);
  if (path === null || hash || !current) return false;
  if (path === '') return true;
  const norm = (p: string) => (p.length > 1 ? p.replace(/\/+$/, '') : p);
  return norm(path) === norm(current);
}

/** For router.push / router.replace: `{ scroll: false }` when the target is the page we are on, else the default. */
export function scrollOption(to: string, current: string | null | undefined = typeof window === 'undefined' ? null : window.location.pathname): { scroll: boolean } {
  return { scroll: !staysOnPage(to, current) };
}
