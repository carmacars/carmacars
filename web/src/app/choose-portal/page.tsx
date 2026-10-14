import Link from 'next/link';
import { redirect } from 'next/navigation';
import { pageMeta } from '@/features/seo/meta';
import { realUser } from '@/server/portal/data';
import { rolesOf } from '@/server/door';
import { portalsFor } from '@/server/portals';
import { SignOutOrExit } from '@/features/access/Access';

export const dynamic = 'force-dynamic';
export const metadata = pageMeta({ title: 'Choose a portal', path: '/choose-portal', noindex: true, description: 'Choose which CarmaCars portal to open.' });

// After sign-in, for a person with more than one portal (an Admin who also works as an assistant, an owner who is
// also an investor). One button per portal; the frame of each portal links to the others too.
export default async function ChoosePortal({ searchParams }: { searchParams: Promise<{ password?: string }> }) {
  const user = await realUser();
  if (!user) redirect('/sign-in?next=/choose-portal');
  const { password } = await searchParams;
  const roles = await rolesOf(user.id);
  const list = portalsFor(roles);
  if (list.length === 1) redirect(list[0]!.href);
  return (
    <div className="container" style={{ maxWidth: '32rem', paddingBlock: 'var(--s-7)' }}>
      <div className="stack-lg">
        {password && <p className="alert alert--ok" role="status"><span className="alert__title">Password saved</span><span>You are signed in with your new password.</span></p>}
        <h1 className="d2">Choose a portal</h1>
        <p className="muted">Signed in as <b data-testid="account-email">{user.email}</b>.</p>
        {list.length ? (
          <ul className="portals" data-testid="choose-portal">{list.map((p) => <li key={p.href}><a className="btn btn--primary btn--lg" href={p.href}>{p.label}</a></li>)}</ul>
        ) : (
          <p>This account has no portal yet. If CarmaCars invited you, ask the person who did to check your role. To rent a car, <Link className="link" href="/cars">browse the fleet</Link>.</p>
        )}
        {roles.admin && <p className="small muted">As an Admin you can also open any portal as one of its people: <Link prefetch={false} className="link" href="/admin/portals">Admin &gt; Portals</Link>.</p>}
        <SignOutOrExit className="btn btn--ghost" />
      </div>
    </div>
  );
}
