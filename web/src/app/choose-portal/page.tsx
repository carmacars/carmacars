import Link from '@/components/Link';
import { cookies } from 'next/headers';
import { redirect } from 'next/navigation';
import { pageMeta } from '@/features/seo/meta';
import { realUser } from '@/server/portal/data';
import { rolesOf, type Roles } from '@/server/door';
import { FN_NAME, portalsFor, type PortalLink } from '@/server/portals';
import { SignOutOrExit } from '@/features/access/Access';
import { LAST_PORTAL_COOKIE, orderCards, PORTAL_WHAT, PortalChooser, type PortalCard } from '@/features/access/PortalChooser';

export const dynamic = 'force-dynamic';
export const metadata = pageMeta({ title: 'Choose a portal', path: '/choose-portal', noindex: true, description: 'Choose which CarmaCars portal to open.' });

// After sign-in, for a person with more than one portal (an Admin who also works as an assistant, an owner who is
// also an investor). One card per portal, the last one used first (0720); the frame of each portal links to the others too.
function card(p: PortalLink, r: Roles): PortalCard {
  const fieldOnly = p.key === 'va' && p.href === '/staff/field';
  const staffRole = [...(r.va_functions ?? (r.va ? [r.va] : [])).map((f) => FN_NAME[f] ?? f), ...(r.field ? ['Field work'] : [])].join(', ');
  const role = p.key === 'admin' ? 'Admin' : p.key === 'va' ? `Staff: ${staffRole || 'Staff'}` : p.key === 'investor' ? 'Investor' : p.key === 'owner' ? 'Car owner' : 'Renter';
  return { ...p, icon: fieldOnly ? 'field' : p.key, what: PORTAL_WHAT[fieldOnly ? 'field' : p.key], role };
}

export default async function ChoosePortal({ searchParams }: { searchParams: Promise<{ password?: string }> }) {
  const user = await realUser();
  if (!user) redirect('/sign-in?next=/choose-portal');
  const { password } = await searchParams;
  const roles = await rolesOf(user.id);
  const list = portalsFor(roles);
  if (list.length === 1) redirect(list[0]!.href);
  const last = (await cookies()).get(LAST_PORTAL_COOKIE)?.value ?? null;
  const known = list.some((p) => p.key === last) ? last : null;
  return (
    <PortalChooser email={user.email} last={known} cards={orderCards(list.map((p) => card(p, roles)), known)}
      banner={password ? <p className="alert alert--ok" role="status"><span className="alert__title">Password saved</span><span>You are signed in with your new password.</span></p> : null}
      footer={<div className="cp__foot">
        {!list.length && <p>This account has no portal yet. If CarmaCars invited you, ask the person who did to check your role. To rent a car, <Link className="link" href="/cars">browse the fleet</Link>.</p>}
        {roles.admin && <p className="small muted">As an Admin you can also open any portal as one of its people: <Link prefetch={false} className="link" href="/admin/portals">Admin &gt; Portals</Link>.</p>}
        <SignOutOrExit className="btn btn--ghost" />
      </div>} />
  );
}
