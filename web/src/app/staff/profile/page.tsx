import Link from '@/components/Link';
import { pageMeta } from '@/features/seo/meta';
import { vaPage, FN_LABEL } from '@/server/va';
import { PageHead } from '@/features/admin/ui';
import { HomeAddressSection, homeAddressOf } from '@/features/staff/HomeAddress';
import { PayDetails } from '@/features/staff/PayDetails';
import { MyLine } from '@/features/phone/MyLine';
import { door } from '@/server/door';
import type { PayDetailsView } from '@/features/staff/pay-details';
import { SignInSettings } from '@/features/portal/SignInSettings';
import { notifyReach, signInState } from '@/server/sign-in-settings';
import { selfProfile } from '@/server/self-profile';
import { SelfProfile } from '@/features/portal/SelfProfile';
import { NotifyChannelCard } from '@/features/portal/NotifyChannel';
import { StaffDigestChoice } from '@/features/notifications/StaffDigestChoice';
import { ShiftFeedCard } from '@/features/shift-feed/ShiftFeedCard';
import { PushAlerts } from '@/features/push/PushAlerts';
import { NotifyPanel } from '@/features/notifications/NotifyPanel';
import { AppProfile } from '@/features/app-shell/AppProfile';
import { LocationSettings } from '@/features/location/LocationSettings';
import { BirthdaySection } from '@/features/staff/Birthday';
import { ResignSection } from '@/features/staff/Resign';

export const dynamic = 'force-dynamic';
export const metadata = pageMeta({ title: 'Profile', path: '/staff/profile', noindex: true, description: 'Your details, your home address and sign-in.' });

// /va/profile (migration 0059): who you are, your home address (entered by you, needed before you add a rental or earn a
// commission), and sign-in.
export default async function VaProfile() {
  const { user, roles } = await vaPage('/staff/profile');
  const [home, si, nc, pay, sp] = await Promise.all([homeAddressOf(user.id, 'va'), signInState(user.id), notifyReach(user.id),
    door<PayDetailsView>(user.id, 'va_read', 'my_pay_details').catch(() => null), selfProfile(user.id)]);
  return (
    <>
      <PageHead title="Profile" />
      <div className="stack-lg" style={{ maxWidth: '40rem' }}>
        <section className="pt-card stack" aria-labelledby="me-t"><h2 className="d4" id="me-t">{roles.name ?? user.email}</h2>
          <dl className="pt-dl"><div><dt>Email</dt><dd>{user.email}</dd></div><div><dt>Function</dt><dd>{FN_LABEL[roles.va!]}</dd></div></dl></section>
        {home.missing ? <p className="small" data-testid="home-address-above">Fill in your home address at the top of the page.</p> : <HomeAddressSection portal="va" state={home} />}
        <PayDetails portal="va" view={pay} canada={!!home.canada} />
        <MyLine userId={user.id} call="va_read" className="pt-card stack" />
        {sp && <SelfProfile data={sp} password={false} />}
        <BirthdaySection userId={user.id} portal="va" className="pt-card stack" refresh={['/staff/profile']} />
        {si && <SignInSettings state={si} className="pt-card stack" />}
        {nc && <NotifyChannelCard reach={nc} className="pt-card stack" />}
        <StaffDigestChoice userId={user.id} ops refresh={['/staff/profile']} className="pt-card stack" />
        <ShiftFeedCard userId={user.id} call="ops_read" />
        <PushAlerts userId={user.id} portal="staff" className="pt-card stack" />
        {/* r48 (3260): each kind of notification by channel, quiet hours, instant or a summary */}
        <NotifyPanel userId={user.id} portal="staff" idp="np-staff" />
        <LocationSettings userId={user.id} className="pt-card stack" />
        <AppProfile userId={user.id} lock className="pt-card stack" />
        <section className="pt-card stack" aria-labelledby="sec-t"><h2 className="d4" id="sec-t">Sign-in</h2>
          <p className="row"><Link prefetch={false} className="btn btn--ghost btn--sm" href="/two-step/setup?next=/staff/profile">Set up two-step sign-in</Link>
            <Link prefetch={false} className="btn btn--ghost btn--sm" href="/reset-password">Change my password</Link></p></section>
        {/* r50 (5020): Resign, last, away from the daily buttons */}
        <ResignSection userId={user.id} portal="va" className="pt-card stack" refresh={['/staff/profile']} />
      </div>
    </>
  );
}
