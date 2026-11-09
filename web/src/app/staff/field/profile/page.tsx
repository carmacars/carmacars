import Link from '@/components/Link';
import { pageMeta } from '@/features/seo/meta';
import { door, requireStaff } from '@/server/door';
import { auth } from '@/lib/auth';
import { signOut } from '@/server/actions/auth';
import { FieldButton } from '@/features/field/FieldButton';
import { HomeAddressSection, homeAddressOf } from '@/features/staff/HomeAddress';
import { SignInSettings } from '@/features/portal/SignInSettings';
import { notifyReach, signInState } from '@/server/sign-in-settings';
import { selfProfile } from '@/server/self-profile';
import { SelfProfile } from '@/features/portal/SelfProfile';
import { NotifyChannelCard } from '@/features/portal/NotifyChannel';
import { PushAlerts } from '@/features/push/PushAlerts';
import { AppProfile } from '@/features/app-shell/AppProfile';

export const dynamic = 'force-dynamic';
export const metadata = pageMeta({ title: 'Profile', path: '/staff/field/profile', noindex: true, description: 'Your details and sign-in.' });

type P = { name: string; email: string; phone: string | null; field_function: string; started_on: string | null; referral_code: string | null };

// /field/profile (06-field.md section 10): name, phone, home address (0059), password, two-step sign-in, sign out.
export default async function Profile() {
  const { user } = await requireStaff('field', '/staff/field/profile');
  const [p, factors, home, si, sales] = await Promise.all([door<P>(user.id, 'field_read', 'profile'), (await auth()).mfaFactors().catch(() => []), homeAddressOf(user.id, 'field'), signInState(user.id),
    door<{ opted_in: boolean; ready: boolean } | null>(user.id, 'field_read', 'sales_state').catch(() => null)]);
  const [nc, sp] = await Promise.all([notifyReach(user.id), selfProfile(user.id)]);
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
      <section className="fd-card" aria-labelledby="pay-t"><h2 className="d4" id="pay-t">Pay details</h2>
        <p className="small">Your legal name, SIN, void cheque and how you are paid are on <Link prefetch={false} className="link" href="/staff/field/pay#pay-details">My pay</Link>.</p></section>
      <section className="fd-card stack" aria-labelledby="sales-t" data-testid="sales-optin"><h2 className="d4" id="sales-t">Sales</h2>
        {sales?.opted_in
          ? <><p className="small">{sales.ready ? 'You do sales too: the Sales tab has your pages.' : 'You asked to do sales too. Pass the Sales path in Training and the Sales pages open.'}</p>
              <FieldButton action="sales_optin" payload={{ on: false }} label="Stop doing sales" sheet={{ confirm: 'Stop doing sales', title: 'The Sales tab and pages close' }} testId="sales-off" /></>
          : <><p className="small">Sell rentals too and earn commission on the rentals you bring in, as the sales terms say. The Sales path in Training comes first.</p>
              <FieldButton action="sales_optin" payload={{ on: true }} label="I want to do sales too" primary testId="sales-on" /></>}
        <p className="small"><Link prefetch={false} className="link" href="/staff/field/referrals">My referral link</Link> · <Link prefetch={false} className="link" href="/staff/field/rentals/new">Add a rental</Link></p>
      </section>
      {sp && <SelfProfile data={sp} className="fd-card stack" password={false} />}
      {si && <SignInSettings state={si} className="fd-card stack" />}
      {nc && <NotifyChannelCard reach={nc} className="fd-card stack" />}
      <PushAlerts userId={user.id} portal="field" className="fd-card stack" />
      <AppProfile userId={user.id} lock className="fd-card stack" />
      <section className="fd-card" aria-labelledby="sec-t"><h2 className="d4" id="sec-t">Sign-in</h2>
        <p className="small">Two-step sign-in: {twoStep ? 'on, with your authenticator app.' : 'not set up.'}</p>
        {!twoStep && <Link prefetch={false} className="btn btn--ghost fd-wide" href="/two-step/setup?next=/staff/field/profile">Set up two-step sign-in</Link>}
        <Link prefetch={false} className="btn btn--ghost fd-wide" href="/reset-password">Change my password</Link>
        <form action={signOut}><button className="btn btn--ghost fd-wide" type="submit">Sign out</button></form>
      </section>
    </div>
  );
}
