import '@/styles/portal.css';
import '@/styles/owner.css';
import '@/styles/admin.css';
import '@/components/portal-ui/portal-ui.css';
import '@/components/portal-ui/queue.css';
import '@/styles/va.css';
import Link from '@/components/Link';
import { currentUser } from '@/server/portal/data';
import { PortalSwitch, SignOutOrExit } from '@/features/access/Access';
import { GuideBanner, GuideLink } from '@/features/guides/GuideFrame';
import { StuckHelp } from '@/features/help/StuckHelp';
import { PushInvite } from '@/features/push/PushAlerts';
import { BrandMark } from '@/components/BrandMark';
import { AlertsBell } from '@/features/alerts/AlertsBell';
import { CallerPopup } from '@/features/caller/CallerPopup';
import { viewAs } from '@/server/view-as';
import { AssistantPanel } from '@/features/assistant/AssistantPanel';
import { switchFunction } from '@/server/actions/va';
import { door, rolesOf } from '@/server/door';
import { DoorProvider } from '@/features/admin/door';
import { StaffNav } from '@/features/staff/StaffNav';
import { HubBar } from '@/features/admin/HubBar';
import { staffHubs, staffSections } from '@/features/staff/nav';
import { RevampScope } from '@/features/admin/revamp/RevampScope';
import { REVAMP_STAFF } from '@/features/admin/revamp/scope';
import { heldFunctions, STAFF_FN_LABEL } from '@/features/staff/nav';
import { TermsGate } from '@/features/terms/TermsGate';
import { HomeAddressCard, homeAddressOf } from '@/features/staff/HomeAddress';

// The staff portal's frame (0197; docs/blueprint/05-va.md and 06-field.md): one portal for every kind of staff work. The
// menu holds the groups of every function the person has (customer service, fleet, finance, sales, field work); the
// switcher picks the office function the screens work in. Every page checks the function and the second factor itself
// (vaPage, requireStaff).
export default async function StaffLayout({ children }: { children: React.ReactNode }) {
  const user = await currentUser();
  const roles = user ? await rolesOf(user.id).catch(() => null) : null;
  // an Admin viewing the portal as someone (read only) gets no caller pop-up: its live read is the Admin's own, in Admin
  const viewing = user ? await viewAs().catch(() => null) : null;
  const held = heldFunctions(roles?.functions?.length ? roles.functions : [...(roles?.va_functions ?? (roles?.va ? [roles.va] : [])), ...(roles?.field ? ['field'] : [])]);
  const office = !!roles?.va;
  const staff = office || !!roles?.field;
  let open = 0;
  let needsAddress = false;
  let chat = 0;
  let hot = 0;
  if (user && roles && staff) {
    if (office) {
      try { open = Number((await door<{ open: number }>(user.id, 'va_read', 'digest')).open) || 0; } catch { open = 0; }
      // chats waiting for a person (0060), for customer service and Sales, and hot visitors on the site now (0086)
      if (held.includes('cs') || held.includes('sales')) {
        try { const c = await door<{ waiting: number; hot?: number }>(user.id, 'va_read', 'chat_counts'); chat = Number(c.waiting) || 0; hot = Number(c.hot) || 0; } catch { chat = 0; }
      }
    }
    // the first sign-in (0059): the home address, asked on every page until it is in
    // 0325: view-as shows the frame exactly as the person sees it (the card too while their address is missing)
    needsAddress = (await homeAddressOf(user.id, office ? 'va' : 'field')).missing;
  }
  const portal = office ? 'va' : 'field';
  return (
    <div className="ad va">
      <div className="ad__frame">
        {staff && roles ? (
          <aside className="ad__rail">
            <div className="ad__who"><span className="muted"><BrandMark size={22} className="ad__mark" />{office ? STAFF_FN_LABEL[roles.va!] : STAFF_FN_LABEL.field} · <b data-testid="account-email">{roles.preferred_name ?? roles.name ?? user?.email}</b></span>
              <span className="gd-frame-links">{user ? <AlertsBell userId={user.id} href="/staff/alerts" /> : null}<Link prefetch={false} className="btn btn--quiet btn--sm hd-act" href={office ? '/staff/profile' : '/staff/field/profile'} title="Profile" data-testid="va-profile-link"><svg viewBox="0 0 24 24" aria-hidden="true" fill="none" stroke="currentColor" strokeWidth="1.8" strokeLinecap="round" strokeLinejoin="round"><circle cx="12" cy="8" r="3.5" /><path d="M5 20c.6-3.6 3.2-5.5 7-5.5s6.4 1.9 7 5.5" /></svg><span className="hd-lbl">Profile</span></Link><AssistantPanel portal={portal} /><GuideLink portal={portal} /><SignOutOrExit /></span></div>
            <PortalSwitch current="va" />
            {held.length > 1 && (
              <nav className="ad-fn" aria-label="Function" data-testid="fn-switch"><p className="small muted">Working as</p>
                <ul className="ad-fn__list">{held.map((f) => (
                  <li key={f}>{f === 'field'
                    ? <Link prefetch={false} className="btn btn--sm btn--quiet" href="/staff/field" data-testid="fn-field">{STAFF_FN_LABEL.field}</Link>
                    : <form action={switchFunction.bind(null, f)}><button type="submit" className={`btn btn--sm ${f === roles.va ? 'btn--primary' : 'btn--quiet'}`} aria-pressed={f === roles.va}>{STAFF_FN_LABEL[f]}</button></form>}</li>
                ))}</ul></nav>)}
            <StaffNav functions={held} open={open} chat={chat} hot={hot} />
          </aside>
        ) : <div />}
        <div className="ad__main">{needsAddress ? <HomeAddressCard portal={portal} /> : null}{staff && user ? <GuideBanner portal={portal} userId={user.id} /> : null}{staff && user ? <StuckHelp portal={portal} /> : null}{office && user && !viewing && (held.includes('cs') || held.includes('fleet')) ? <CallerPopup portal="va" /> : null}{staff && user && !needsAddress ? <PushInvite portal={office ? 'staff' : 'field'} home={office ? '/staff' : ['/staff', '/staff/field']} userId={user.id} /> : null}{staff ? <HubBar hubs={staffHubs(held)} sections={staffSections(held)} /> : null}<DoorProvider kind="va"><RevampScope list={REVAMP_STAFF}>{staff && user ? <TermsGate userId={user.id} portal={office ? 'staff' : 'field'}>{children}</TermsGate> : children}</RevampScope></DoorProvider></div>
      </div>
    </div>
  );
}
