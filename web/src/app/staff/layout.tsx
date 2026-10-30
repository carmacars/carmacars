import '@/styles/portal.css';
import '@/styles/owner.css';
import '@/styles/admin.css';
import '@/components/portal-ui/portal-ui.css';
import '@/components/portal-ui/queue.css';
import '@/styles/va.css';
import Link from 'next/link';
import { currentUser } from '@/server/portal/data';
import { PortalSwitch, SignOutOrExit } from '@/features/access/Access';
import { GuideBanner, GuideLink } from '@/features/guides/GuideFrame';
import { AssistantPanel } from '@/features/assistant/AssistantPanel';
import { viewAs } from '@/server/view-as';
import { switchFunction } from '@/server/actions/va';
import { door, rolesOf } from '@/server/door';
import { DoorProvider } from '@/features/admin/door';
import { StaffNav } from '@/features/staff/StaffNav';
import { heldFunctions, STAFF_FN_LABEL } from '@/features/staff/nav';
import { HomeAddressCard, homeAddressOf } from '@/features/staff/HomeAddress';

// The staff portal's frame (0197; docs/blueprint/05-va.md and 06-field.md): one portal for every kind of staff work. The
// menu holds the groups of every function the person has (customer service, fleet, finance, sales, field work); the
// switcher picks the office function the screens work in. Every page checks the function and the second factor itself
// (vaPage, requireStaff).
export default async function StaffLayout({ children }: { children: React.ReactNode }) {
  const user = await currentUser();
  const roles = user ? await rolesOf(user.id).catch(() => null) : null;
  const viewing = await viewAs();
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
    needsAddress = !viewing && (await homeAddressOf(user.id, office ? 'va' : 'field')).missing;
  }
  const portal = office ? 'va' : 'field';
  return (
    <div className="ad va">
      <div className="ad__frame">
        {staff && roles ? (
          <aside className="ad__rail">
            <div className="ad__who"><span className="muted">{office ? STAFF_FN_LABEL[roles.va!] : STAFF_FN_LABEL.field} · <b data-testid="account-email">{roles.name ?? user?.email}</b></span>
              <span className="gd-frame-links"><Link prefetch={false} className="link" href={office ? '/staff/profile' : '/staff/field/profile'} data-testid="va-profile-link">Profile</Link>{!viewing && <AssistantPanel portal={portal} />}<GuideLink portal={portal} /><SignOutOrExit /></span></div>
            <PortalSwitch current="va" />
            {held.length > 1 && !viewing && (
              <nav className="ad-fn" aria-label="Function" data-testid="fn-switch"><p className="small muted">Working as</p>
                <ul className="ad-fn__list">{held.map((f) => (
                  <li key={f}>{f === 'field'
                    ? <Link prefetch={false} className="btn btn--sm btn--quiet" href="/staff/field" data-testid="fn-field">{STAFF_FN_LABEL.field}</Link>
                    : <form action={switchFunction.bind(null, f)}><button type="submit" className={`btn btn--sm ${f === roles.va ? 'btn--primary' : 'btn--quiet'}`} aria-pressed={f === roles.va}>{STAFF_FN_LABEL[f]}</button></form>}</li>
                ))}</ul></nav>)}
            <StaffNav functions={held} open={open} chat={chat} hot={hot} />
          </aside>
        ) : <div />}
        <div className="ad__main">{needsAddress ? <HomeAddressCard portal={portal} /> : null}{staff && user ? <GuideBanner portal={portal} userId={user.id} /> : null}<DoorProvider kind="va">{children}</DoorProvider></div>
      </div>
    </div>
  );
}
