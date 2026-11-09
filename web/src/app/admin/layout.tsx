import '@/styles/portal.css';
import '@/styles/owner.css';
import '@/styles/admin.css';
import '@/styles/admin-ui.css';
import { realUser as currentUser } from '@/server/portal/data';
import { signOut } from '@/server/actions/auth';
import { AdminNav, AdminSearch } from '@/features/admin/AdminNav';
import { JUMP } from '@/features/admin/jumpPages';
import { ADMIN_HUBS, ADMIN_SECTIONS } from '@/features/admin/hubs';
import { HubBar } from '@/features/admin/HubBar';
import { RevampScope } from '@/features/admin/revamp/RevampScope';
import { REVAMP_ADMIN } from '@/features/admin/revamp/scope';
import { AdminCommand } from '@/features/admin/shell/AdminCommand';
import { adminGate } from '@/server/admin/data';
import { rpc } from '@/lib/db/repo';
import { door } from '@/server/door';
import { PortalSwitch } from '@/features/access/Access';
import { GuideBanner, GuideLink } from '@/features/guides/GuideFrame';
import { StuckHelp } from '@/features/help/StuckHelp';
import { PushInvite } from '@/features/push/PushAlerts';
import { AssistantPanel } from '@/features/assistant/AssistantPanel';
import { greetName } from '@/features/admin/today/greeting';
import { BrandMark } from '@/components/BrandMark';
import { AlertsBell } from '@/features/alerts/AlertsBell';
import { AlertPulse } from '@/features/motion/Moment';
import { CallerPopup } from '@/features/caller/CallerPopup';


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
            <div className="ad__who"><span className="muted"><BrandMark size={22} className="ad__mark" />Admin · <b data-testid="account-email">{gate.name ?? user?.email}</b></span>
              <span className="gd-frame-links">{user ? <AlertPulse /> : null}{user ? <AlertsBell userId={user.id} href="/admin/alerts" /> : null}<AssistantPanel portal="admin" greeting={greetName(gate)} /><GuideLink portal="admin" /><form action={signOut}><button className="btn btn--quiet btn--sm hd-act" type="submit" title="Sign out"><svg viewBox="0 0 24 24" aria-hidden="true" fill="none" stroke="currentColor" strokeWidth="1.8" strokeLinecap="round" strokeLinejoin="round"><path d="M9 4H6.5A2.5 2.5 0 0 0 4 6.5v11A2.5 2.5 0 0 0 6.5 20H9M15 8l4 4-4 4M19 12H9" /></svg><span className="hd-lbl">Sign out</span></button></form></span></div>
            <PortalSwitch current="admin" />
            <div className="ad__find"><AdminSearch /><AdminCommand groups={JUMP} /></div>
            <AdminNav counts={counts} />
          </aside>
        ) : <div />}
        <div className="ad__main">{gate?.admin && user ? <GuideBanner portal="admin" userId={user.id} /> : null}{gate?.admin && user ? <StuckHelp portal="admin" /> : null}{gate?.admin && user ? <PushInvite portal="admin" home="/admin" userId={user.id} /> : null}{gate?.admin && user ? <CallerPopup portal="admin" /> : null}{gate?.admin ? <HubBar hubs={ADMIN_HUBS} sections={ADMIN_SECTIONS} counts={{ '/admin/listings': counts.rowListings ?? 0, '/admin/applications': counts.rowApplications ?? 0, '/admin/tolls': counts.rowTolls ?? 0,
          '/admin/owner-money?tab=invoices': counts.rowStatements ?? 0, '/admin/owner-money?tab=statements': counts.rowStatements ?? 0, '/admin/money?tab=day': counts.rowRefunds ?? 0 }} /> : null}<RevampScope list={REVAMP_ADMIN}>{children}</RevampScope></div>
      </div>
    </div>
  );
}
