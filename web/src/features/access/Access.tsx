import Link from 'next/link';
import { signOut } from '@/server/actions/auth';
import { currentUser } from '@/server/portal/data';
import { rolesOf } from '@/server/door';
import { viewAs } from '@/server/view-as';
import { PORTAL_HOME, portalsFor, type PortalKey } from '@/server/portals';

// Shared pieces of every portal's frame and refusal page: who is signed in, the portals that account has, and
// Sign out (or Exit, while an Admin views as someone).

/** Sign out, or, while an Admin views as someone, Exit (back to the Admin's own account). */
export async function SignOutOrExit({ className = 'btn btn--quiet btn--sm' }: { className?: string }) {
  if (await viewAs()) return <form method="post" action="/api/view-as/exit"><button className={className} type="submit">Exit view</button></form>;
  return <form action={signOut}><button className={className} type="submit">Sign out</button></form>;
}

/** Links to the account's other portals (nothing when it has only this one). */
export async function PortalSwitch({ current }: { current: PortalKey }) {
  const user = await currentUser();
  if (!user) return null;
  const roles = await rolesOf(user.id).catch(() => null);
  if (!roles) return null;
  // the staff portal has its own function switcher, so its functions are not listed again there
  const list = portalsFor(roles).filter((p) => p.key !== current);
  if (!list.length) return null;
  return (
    <nav className="portal-switch" aria-label="Your other portals" data-testid="portal-switch">
      <span className="muted">Also:</span>
      {list.map((p) => <a key={p.href} className="link" href={p.href}>{p.label}</a>)}
    </nav>
  );
}

const WHAT: Record<Exclude<PortalKey, 'account'>, { title: string; text: string }> = {
  admin: { title: 'This area is for CarmaCars admins', text: 'This account does not have admin access. If it should, ask an Admin to add the role in Admin > Staff.' },
  va: { title: 'This area is for CarmaCars staff', text: 'This account does not have a staff role. If you work with us, ask an Admin to add it.' },
  field: { title: 'This area is for CarmaCars staff doing field work', text: 'This account does not have field work. Ask an Admin if you think it should.' },
  investor: { title: 'No investments for this account', text: 'This area holds statements for existing investors, invited by CarmaCars.' },
  owner: { title: 'No owner account here yet', text: 'This sign-in is not linked to a car owner. Apply to list your car, or sign in with the email you applied with.' }
};

/** A refusal page that says plainly who is signed in, and offers their own portals and Sign out. */
export async function NoAccess({ portal }: { portal: Exclude<PortalKey, 'account'> }) {
  const user = await currentUser();
  const w = WHAT[portal];
  if (!user) {
    return (
      <div className="pt-empty" data-testid="no-access">
        <h1 className="d3">{w.title}</h1>
        <p className="muted">Sign in to continue.</p>
        <Link prefetch={false} className="btn btn--primary" href={`/sign-in?next=${PORTAL_HOME[portal]}`}>Sign in</Link>
      </div>
    );
  }
  const roles = await rolesOf(user.id).catch(() => null);
  const mine = roles ? portalsFor(roles) : [];
  const v = await viewAs();
  return (
    <div className="pt-empty" data-testid="no-access">
      <h1 className="d3">{w.title}</h1>
      <p>{v ? <>Viewing as <b data-testid="no-access-email">{user.email}</b>.</> : <>You are signed in as <b data-testid="no-access-email">{user.email}</b>.</>}</p>
      <p className="muted">{w.text}</p>
      {portal === 'owner' && !mine.some((p) => p.key === 'owner') && <p><Link className="link" href="/list-your-car/apply">Apply to list your car</Link></p>}
      {mine.length > 0 && <>
        <p className="small muted">{v ? 'Their portals' : 'Your portals'}</p>
        <ul className="portals" data-testid="my-portals">{mine.map((p) => <li key={p.href}><a className="btn btn--primary" href={p.href}>{p.label}</a></li>)}</ul>
      </>}
      {roles?.admin && !v && portal !== 'admin' && <p className="small">To see this portal as one of its people, use <Link prefetch={false} className="link" href="/admin/portals">Admin &gt; Portals</Link>.</p>}
      <SignOutOrExit className="btn btn--ghost" />
    </div>
  );
}
