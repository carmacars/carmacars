// The Visitors page's tabs (r27 consolidation, the owner on November 2, 2026: Live chat inside Visitors): Live now, Chat
// (live chat, with Texts and calls under it) and History, for Admin (/admin/visitors) and staff (/staff/visitors). The old
// Live chat and Live visitors addresses redirect here with their query kept. No imports, so the unit tests run it as it is.

export type VisitorsView = 'live' | 'chat' | 'history';
export type VisitorsPortal = 'admin' | 'staff';
export const VIEWS: readonly VisitorsView[] = ['live', 'chat', 'history'];
const LABEL: Record<VisitorsView, string> = { live: 'Live now', chat: 'Chat', history: 'History' };

export const visitorsBase = (portal: VisitorsPortal) => (portal === 'admin' ? '/admin/visitors' : '/staff/visitors');

/** The tab shown: ?view=, else Live now. */
export function viewOf(v: string | string[] | undefined): VisitorsView {
  const s = Array.isArray(v) ? v[0] : v;
  return (VIEWS as readonly string[]).includes(s ?? '') ? (s as VisitorsView) : 'live';
}

/** A tab's address: Live now is the page itself. */
export function viewHref(portal: VisitorsPortal, view: VisitorsView, extra: Record<string, string> = {}): string {
  const q = new URLSearchParams(view === 'live' ? extra : { view, ...extra });
  const s = q.toString();
  return `${visitorsBase(portal)}${s ? `?${s}` : ''}`;
}

export const VISITOR_TABS: Record<VisitorsPortal, Array<{ view: VisitorsView; href: string; label: string }>> = {
  admin: [...VIEWS.map((v) => ({ view: v, href: viewHref('admin', v), label: LABEL[v] })), { view: 'chat' as const, href: viewHref('admin', 'chat', { inbox: 'phone' }), label: 'Texts and calls' }],
  staff: [...VIEWS.map((v) => ({ view: v, href: viewHref('staff', v), label: LABEL[v] })), { view: 'chat' as const, href: viewHref('staff', 'chat', { inbox: 'phone' }), label: 'Texts and calls' }]
};
export const viewLabel = (v: VisitorsView) => LABEL[v];

/** Where an old Live chat address goes: the Chat tab, every value of its query kept (its own ?view=phone is the Texts and
 *  calls inbox, now ?inbox=phone; ?id= opens the conversation as before). */
export function chatMovedTo(portal: VisitorsPortal, sp: Record<string, string | string[] | undefined>): string {
  const q = new URLSearchParams({ view: 'chat' });
  for (const [k, v] of Object.entries(sp)) {
    if (v === undefined) continue;
    for (const x of Array.isArray(v) ? v : [v]) {
      if (k === 'view') { if (x === 'phone') q.set('inbox', 'phone'); continue; }
      q.append(k, x);
    }
  }
  return `${visitorsBase(portal)}?${q.toString()}`;
}

/** Where the old staff Live visitors address goes: Live now, its query kept. */
export function liveMovedTo(sp: Record<string, string | string[] | undefined>): string {
  const q = new URLSearchParams();
  for (const [k, v] of Object.entries(sp)) { if (v === undefined || k === 'view') continue; for (const x of Array.isArray(v) ? v : [v]) q.append(k, x); }
  const s = q.toString();
  return `/staff/visitors${s ? `?${s}` : ''}`;
}

/** An address with more query values: "?" or "&" as the address needs. */
export function addQuery(base: string, q: Record<string, string>): string {
  const s = new URLSearchParams(q).toString();
  return s ? `${base}${base.includes('?') ? '&' : '?'}${s}` : base;
}
/** The Chat tab of a portal's Visitors page (the address every inbox link starts from). */
export const chatBase = (portal: VisitorsPortal) => viewHref(portal, 'chat');
