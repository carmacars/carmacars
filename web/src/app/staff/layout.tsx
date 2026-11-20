import '@/styles/portal.css';
import '@/styles/owner.css';
import '@/styles/admin.css';
import '@/components/portal-ui/portal-ui.css';
import '@/components/portal-ui/queue.css';
import '@/styles/va.css';
import '@/styles/ui-kit.css';
import Link from '@/components/Link';
import { currentUser } from '@/server/portal/data';
import { PortalSwitch, SignOutOrExit } from '@/features/access/Access';
import { GuideBanner, GuideLink } from '@/features/guides/GuideFrame';
import { WhatsNew } from '@/features/whats-new/WhatsNew';
import { StuckHelp } from '@/features/help/StuckHelp';
import { PushInvite } from '@/features/push/PushAlerts';
import { BrandMark } from '@/components/BrandMark';
import { AlertsBell } from '@/features/alerts/AlertsBell';
import { AlertPulse } from '@/features/motion/AlertPulse';
import { LivePortal } from '@/features/live/realtime/LiveRefresh';
import { liveTokens } from '@/server/live';
import { CallerPopup } from '@/features/caller/CallerPopup';
// r44 (2790): calls in the browser: the phone bar on every page (incoming calls ring here, calls placed show here)
import { VoiceDock } from '@/features/phone/VoiceDock';
import { viewAs } from '@/server/view-as';
import { AssistantLauncher as AssistantPanel } from '@/features/assistant/AssistantLauncher';
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
import { TownhallLink } from '@/features/townhall/TownhallLink';
import { ActivityBeat } from '@/features/staff-clock/ActivityBeat';
import { BugReportButton } from '@/features/bug-report/BugReport';

// The staff portal's frame (0197; docs/blueprint/05-va.md and 06-field.md): one portal for every kind of staff work. The
// menu holds the groups of every function the person has (customer service, fleet, finance, sales, field work); the
// role switcher (r48 ops: one for every role of the account, features/access) picks the office function the screens work in. Every page checks the function and the second factor itself
// (vaPage, requireStaff). 1154: the Academy link sits in the rail's header in every state, held or not.
export default async function StaffLayout({ children }: { children: React.ReactNode }) {
  const user = await currentUser();
  // r48 speed: the roles and the view-as state together, then every read of the frame together (they were six round trips
  // one after another before any staff page could show)
  // an Admin viewing the portal as someone (read only) gets the pop-up's empty region and no live read (the Admin's own, in Admin)
  const [roles, viewing] = user ? await Promise.all([rolesOf(user.id).catch(() => null), viewAs().catch(() => null)]) : [null, null];
  const held = heldFunctions(roles?.functions?.length ? roles.functions : [...(roles?.va_functions ?? (roles?.va ? [roles.va] : [])), ...(roles?.field ? ['field'] : [])]);
  const office = !!roles?.va;
  const staff = office || !!roles?.field;
  let open = 0;
  let needsAddress = false;
  let canada: boolean | undefined;
  let chat = 0;
  let hot = 0;
  // r41: live updates (server/live.ts): the areas this person's functions read (field staff: the field area)
  const livePromise = user && staff ? liveTokens(user.id, office ? ['me', 'bookings', 'requests', 'leads', 'messages', 'field', 'tasks', 'calls'] : ['me', 'field', 'tasks']) : Promise.resolve({} as Awaited<ReturnType<typeof liveTokens>>);
  if (user && roles && staff) {
    const [digest, counts, h] = await Promise.all([
      office ? door<{ open: number }>(user.id, 'va_read', 'digest').catch(() => null) : null,
      // chats waiting for a person (0060), for customer service and Sales, and hot visitors on the site now (0086)
      office && (held.includes('cs') || held.includes('sales')) ? door<{ waiting: number; hot?: number }>(user.id, 'va_read', 'chat_counts').catch(() => null) : null,
      // the first sign-in (0059): the home address, asked on every page until it is in
      // 0325: view-as shows the frame exactly as the person sees it (the card too while their address is missing)
      homeAddressOf(user.id, office ? 'va' : 'field')]);
    open = Number(digest?.open) || 0;
    if (counts) { chat = Number(counts.waiting) || 0; hot = Number(counts.hot) || 0; }
    needsAddress = h.missing; canada = h.canada;
  }
  const portal = office ? 'va' : 'field';
  const live = await livePromise;
  return (
    <div className="ad va">
      <div className="ad__frame">
        {staff && roles ? (
          <aside className="ad__rail">
            <div className="ad__who"><span className="muted"><BrandMark size={22} className="ad__mark" />{office ? STAFF_FN_LABEL[roles.va!] : STAFF_FN_LABEL.field} · <b data-testid="account-email">{roles.preferred_name ?? roles.name ?? user?.email}</b></span>
              <span className="gd-frame-links">{user ? <AlertPulse topic={live.me} /> : null}{user && staff ? <LivePortal tokens={live} /> : null}{user ? <AlertsBell userId={user.id} href="/staff/alerts" /> : null}<Link prefetch={false} className="btn btn--quiet btn--sm hd-act" href={office ? '/staff/profile' : '/staff/field/profile'} title="Profile" data-testid="va-profile-link"><svg viewBox="0 0 24 24" aria-hidden="true" fill="none" stroke="currentColor" strokeWidth="1.8" strokeLinecap="round" strokeLinejoin="round"><circle cx="12" cy="8" r="3.5" /><path d="M5 20c.6-3.6 3.2-5.5 7-5.5s6.4 1.9 7 5.5" /></svg><span className="hd-lbl">Profile</span></Link><Link prefetch={false} className="btn btn--quiet btn--sm hd-act" href="/staff/academy" title="Academy" data-testid="va-academy-link"><svg viewBox="0 0 24 24" aria-hidden="true" fill="none" stroke="currentColor" strokeWidth="1.8" strokeLinecap="round" strokeLinejoin="round"><path d="M3 8l9-4 9 4-9 4-9-4z" /><path d="M7 10v5c1.5 1.5 3 2 5 2s3.5-.5 5-2v-5" /></svg><span className="hd-lbl">Academy</span></Link><AssistantPanel portal={portal} />{user ? <WhatsNew portal="staff" userId={user.id} /> : null}<GuideLink portal={portal} />{user && !viewing ? <BugReportButton portal={office ? 'staff' : 'field'} mineHref="/staff/bug-reports" /> : null}<SignOutOrExit /></span></div>
            <PortalSwitch current="va" />
            {/* r35 part C (1505): the weekly townhall's call link, on every staff portal */}
            {user && !viewing ? <TownhallLink userId={user.id} /> : null}
            {/* 1800: the inactivity tracker (the fact of activity only) for the staff who clock in */}
            {user && !viewing && (held.includes('cs') || held.includes('fleet') || held.includes('finance')) ? <ActivityBeat /> : null}
            <StaffNav functions={held} open={open} chat={chat} hot={hot} />
          </aside>
        ) : <div />}
        <div className="ad__main">{needsAddress ? <HomeAddressCard portal={portal} canada={canada} /> : null}{staff && user ? <GuideBanner portal={portal} userId={user.id} /> : null}{staff && user ? <StuckHelp portal={portal} /> : null}{office && user ? <CallerPopup portal="va" quiet={Boolean(viewing)} topic={live.calls} /> : null}{staff && user ? <VoiceDock quiet={Boolean(viewing)} /> : null}{staff && user && !needsAddress ? <PushInvite portal={office ? 'staff' : 'field'} home={office ? '/staff' : ['/staff', '/staff/field']} userId={user.id} /> : null}{staff ? <HubBar hubs={staffHubs(held)} sections={staffSections(held)} /> : null}<DoorProvider kind="va"><RevampScope list={REVAMP_STAFF}>{staff && user ? <TermsGate userId={user.id} portal={office ? 'staff' : 'field'}>{children}</TermsGate> : children}</RevampScope></DoorProvider></div>
      </div>
    </div>
  );
}
