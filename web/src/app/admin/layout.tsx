import '@/styles/portal.css';
import '@/styles/owner.css';
import '@/styles/admin.css';
import '@/styles/admin-ui.css';
import { realUser as currentUser } from '@/server/portal/data';
import { signOut } from '@/server/actions/auth';
import { AdminNav, AdminSearch, GROUPS } from '@/features/admin/AdminNav';
import { HubBar } from '@/features/admin/HubBar';
import { ADMIN_HUBS, ADMIN_SECTIONS, pagesOf } from '@/features/admin/hubs';
import { VISITOR_TABS } from '@/features/visitors/tabs';
import { RevampScope } from '@/features/admin/revamp/RevampScope';
import { REVAMP_ADMIN } from '@/features/admin/revamp/scope';
import { AdminCommand } from '@/features/admin/shell/AdminCommand';
import { SECTIONS } from './settings/sections';
import { adminGate } from '@/server/admin/data';
import { rpc } from '@/lib/db/repo';
import { door } from '@/server/door';
import { PortalSwitch } from '@/features/access/Access';
import { GuideBanner, GuideLink } from '@/features/guides/GuideFrame';
import { PushInvite } from '@/features/push/PushAlerts';
import { AssistantPanel } from '@/features/assistant/AssistantPanel';
import { greetName } from '@/features/admin/today/greeting';

// Ctrl+K reaches every page of the menu, every tab of a page group and every settings page (the menu lists none of them)
// r27 consolidation: the groups' actions (Add a car, Rates for many cars...) and the Visitors page's tabs too
const JUMP = [...GROUPS, ...ADMIN_HUBS.map((h) => ({ key: `hub-${h.key}`, label: h.label, links: pagesOf(h).map((t) => ({ href: t.href, label: `${h.label}: ${t.label}` })) })),
  { key: 'visitors', label: 'Visitors', links: VISITOR_TABS.admin.map((t) => ({ href: t.href, label: `Visitors: ${t.label}` })) },
  { key: 'actions', label: 'Actions', links: [{ href: '/admin/offers/new', label: 'Send an offer' }, { href: '/admin/bookings/new', label: 'Add a rental' }] },
  // the sections' own pages (Maintenance, Applications, Investors, Tolls and tickets, Settings)
  ...ADMIN_SECTIONS.map((x) => ({ key: `sec-${x.key}`, label: x.label, links: x.items.flatMap((i) => (typeof i === 'string' ? [] : [{ href: i.href, label: i.label }])) })),
  { key: 'settings-all', label: 'Settings', links: SECTIONS.map(([k, title]) => ({ href: `/admin/settings/${k}`, label: title })) }];

// The admin portal's frame (docs/blueprint/03-admin.md; simpler since October 16, 2026): who is signed in, one search
// box, seven groups of pages with the counts that need someone. Every page checks the Admin role and two-step sign-in itself (requireAdmin);
// the frame shows the rail only to an Admin.
export default async function AdminLayout({ children }: { children: React.ReactNode }) {
  const user = await currentUser();
  const gate = user ? await adminGate(user).catch(() => null) : null;
  let counts: Record<string, number> = {};
  if (user && gate?.admin) {
    // five numbers for the rail (public.admin_rail_counts, 0036), not the whole dashboard on every admin page
    try {
      const c = (await rpc('admin_rail_counts', { p_admin: user.id }, { role: 'service_role' })) as unknown as Record<'requests' | 'listings' | 'statements' | 'tolls' | 'refunds' | 'applications', number>;
      // r27: statements to approve on Owner money (its link and its Statements tab), refunds to decide on Payments (By day)
      // r27: a section's link carries its pages' counts (Cars: listings; People: applications; Money: refunds, statements, tolls);
      // the rows on top of the pages carry each page's own
      counts = { '/admin/requests': c.requests, '/admin/vehicles': c.listings, '/admin/applications': c.applications ?? 0, '/admin/money?tab=day': (c.refunds ?? 0) + (c.statements ?? 0) + (c.tolls ?? 0),
        rowListings: c.listings, rowStatements: c.statements, rowTolls: c.tolls, rowRefunds: c.refunds, rowApplications: c.applications ?? 0 };
    } catch { counts = {}; }
    // chats waiting for a person (0060) and hot visitors on the site now (0086), from the same read: one badge on Visitors
    // (r27 consolidation: Live chat is its Chat tab), each tab shows its own
    try { const c = await door<{ waiting: number; hot?: number }>(user.id, 'admin_read', 'chat_counts'); counts['/admin/visitors'] = (Number(c.waiting) || 0) + (Number(c.hot) || 0); } catch { /* no count */ }
  }
  return (
    <div className="ad">
      <div className="ad__frame">
        {gate?.admin ? (
          <aside className="ad__rail">
            <div className="ad__who"><span className="muted">Admin · <b data-testid="account-email">{gate.name ?? user?.email}</b></span>
              <span className="gd-frame-links"><AssistantPanel portal="admin" greeting={greetName(gate)} /><GuideLink portal="admin" /><form action={signOut}><button className="btn btn--quiet btn--sm" type="submit">Sign out</button></form></span></div>
            <PortalSwitch current="admin" />
            <div className="ad__find"><AdminSearch /><AdminCommand groups={JUMP} /></div>
            <AdminNav counts={counts} />
          </aside>
        ) : <div />}
        <div className="ad__main">{gate?.admin && user ? <GuideBanner portal="admin" userId={user.id} /> : null}{gate?.admin && user ? <PushInvite portal="admin" home="/admin" /> : null}{gate?.admin ? <HubBar hubs={ADMIN_HUBS} sections={ADMIN_SECTIONS} counts={{ '/admin/listings': counts.rowListings ?? 0, '/admin/applications': counts.rowApplications ?? 0, '/admin/tolls': counts.rowTolls ?? 0,
          '/admin/owner-money?tab=invoices': counts.rowStatements ?? 0, '/admin/owner-money?tab=statements': counts.rowStatements ?? 0, '/admin/money?tab=day': counts.rowRefunds ?? 0 }} /> : null}<RevampScope list={REVAMP_ADMIN}>{children}</RevampScope></div>
      </div>
    </div>
  );
}
