import Link from 'next/link';
import { pageMeta } from '@/features/seo/meta';
import { vaPage, FN_LABEL } from '@/server/va';
import { PageHead } from '@/features/admin/ui';
import { HomeAddressSection, homeAddressOf } from '@/features/staff/HomeAddress';

export const dynamic = 'force-dynamic';
export const metadata = pageMeta({ title: 'Profile', path: '/va/profile', noindex: true, description: 'Your details, your home address and sign-in.' });

// /va/profile (migration 0059): who you are, your home address (entered by you, needed before you add a rental or earn a
// commission), and sign-in.
export default async function VaProfile() {
  const { user, roles } = await vaPage('/va/profile');
  const home = await homeAddressOf(user.id, 'va');
  return (
    <>
      <PageHead title="Profile" />
      <div className="stack-lg" style={{ maxWidth: '40rem' }}>
        <section className="pt-card stack" aria-labelledby="me-t"><h2 className="d4" id="me-t">{roles.name ?? user.email}</h2>
          <dl className="pt-dl"><div><dt>Email</dt><dd>{user.email}</dd></div><div><dt>Function</dt><dd>{FN_LABEL[roles.va!]}</dd></div></dl></section>
        {home.missing ? <p className="small" data-testid="home-address-above">Fill in your home address at the top of the page.</p> : <HomeAddressSection portal="va" state={home} />}
        <section className="pt-card stack" aria-labelledby="sec-t"><h2 className="d4" id="sec-t">Sign-in</h2>
          <p><Link prefetch={false} className="btn btn--ghost btn--sm" href="/reset-password">Change my password</Link></p></section>
      </div>
    </>
  );
}
