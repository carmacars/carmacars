import '@/styles/portal.css';
import '@/styles/owner.css';
import '@/styles/admin.css';
import { currentUser } from '@/server/portal/data';
import { signOut } from '@/server/actions/auth';
import { switchFunction } from '@/server/actions/va';
import { door, rolesOf } from '@/server/door';
import { DoorProvider } from '@/features/admin/door';
import { VaNav } from '@/features/va/VaNav';
import { FN_LABEL } from '@/server/va';

// The assistants' frame (docs/blueprint/05-va.md): the same frame and screens as the admin portal, through
// the assistant's door. Every page checks the role and the second factor itself (vaPage).
export default async function VaLayout({ children }: { children: React.ReactNode }) {
  const user = await currentUser();
  const roles = user ? await rolesOf(user.id).catch(() => null) : null;
  let open = 0;
  if (user && roles?.va) {
    try { open = Number((await door<{ open: number }>(user.id, 'va_read', 'digest')).open) || 0; } catch { open = 0; }
  }
  return (
    <div className="ad">
      <div className="ad__frame">
        {roles?.va ? (
          <aside className="ad__rail">
            <div className="ad__who"><span className="muted">{FN_LABEL[roles.va]} · <b>{roles.name ?? user?.email}</b></span>
              <form action={signOut}><button className="btn btn--quiet btn--sm" type="submit">Sign out</button></form></div>
            {(roles.va_functions?.length ?? 0) > 1 && (
              <nav className="ad-fn" aria-label="Function" data-testid="fn-switch"><p className="small muted">Working as</p>
                <ul className="ad-fn__list">{roles.va_functions!.map((f) => (
                  <li key={f}><form action={switchFunction.bind(null, f)}><button type="submit" className={`btn btn--sm ${f === roles.va ? 'btn--primary' : 'btn--quiet'}`} aria-pressed={f === roles.va}>{FN_LABEL[f]}</button></form></li>
                ))}</ul></nav>)}
            <VaNav fn={roles.va} open={open} />
          </aside>
        ) : <div />}
        <div className="ad__main"><DoorProvider kind="va">{children}</DoorProvider></div>
      </div>
    </div>
  );
}
