import Link from 'next/link';
import { pageMeta } from '@/features/seo/meta';
import { door, requireStaff } from '@/server/door';
import { auth } from '@/lib/auth';
import { signOut } from '@/server/actions/auth';
import { FieldButton } from '@/features/field/FieldButton';
import { HomeAddressSection, homeAddressOf } from '@/features/staff/HomeAddress';
import { SignInSettings } from '@/features/portal/SignInSettings';
import { notifyReach, signInState } from '@/server/sign-in-settings';
import { NotifyChannelCard } from '@/features/portal/NotifyChannel';

export const dynamic = 'force-dynamic';
export const metadata = pageMeta({ title: 'Profile', path: '/staff/field/profile', noindex: true, description: 'Your details and sign-in.' });

type P = { name: string; email: string; phone: string | null; field_function: string; started_on: string | null; referral_code: string | null };

// /field/profile (06-field.md section 10): name, phone, home address (0059), password, two-step sign-in, sign out.
export default async function Profile() {
  const { user } = await requireStaff('field', '/staff/field/profile');
  const [p, factors, home, si] = await Promise.all([door<P>(user.id, 'field_read', 'profile'), (await auth()).mfaFactors().catch(() => []), homeAddressOf(user.id, 'field'), signInState(user.id)]);
  const nc = await notifyReach(user.id);
  const twoStep = factors.some((f) => f.verified);
  return (
    <div className="stack">
      <h1 className="d3">Profile</h1>
      <section className="fd-card" aria-labelledby="me-t"><h2 className="d4" id="me-t">{p.name}</h2>
        <dl className="pt-dl"><div><dt>Email</dt><dd>{p.email}</dd></div><div><dt>Phone</dt><dd data-testid="profile-phone">{p.phone ?? 'not given'}</dd></div>
          <div><dt>Work</dt><dd>{p.field_function.replace(/_/g, ' ')}</dd></div>{p.started_on && <div><dt>Since</dt><dd>{p.started_on}</dd></div>}</dl>
        <FieldButton action="profile_save" payload={{}} label="Save my phone" testId="profile-save" fields={[{ name: 'phone', label: 'Mobile phone', required: true }]} />
      </section>
      {home.missing ? <p className="small" data-testid="home-address-above">Fill in your home address at the top of the page.</p> : <HomeAddressSection portal="field" state={home} />}
      {si && <SignInSettings state={si} className="fd-card stack" />}
      {nc && <NotifyChannelCard reach={nc} className="fd-card stack" />}
      <section className="fd-card" aria-labelledby="sec-t"><h2 className="d4" id="sec-t">Sign-in</h2>
        <p className="small">Two-step sign-in: {twoStep ? 'on, with your authenticator app.' : 'not set up.'}</p>
        {!twoStep && <Link prefetch={false} className="btn btn--ghost fd-wide" href="/two-step/setup?next=/staff/field/profile">Set up two-step sign-in</Link>}
        <Link prefetch={false} className="btn btn--ghost fd-wide" href="/reset-password">Change my password</Link>
        <form action={signOut}><button className="btn btn--ghost fd-wide" type="submit">Sign out</button></form>
      </section>
    </div>
  );
}
