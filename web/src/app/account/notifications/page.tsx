import { pageMeta } from '@/features/seo/meta';
import { NoticeList, Preferences } from '@/features/portal/Notices';
import { myNotificationPrefs, myNotifications, myProfile, requireUser } from '@/server/portal/data';
import { consentTexts } from '@/server/booking-data';

export const dynamic = 'force-dynamic';
export const metadata = pageMeta({ title: 'Notifications', path: '/account/notifications', noindex: true, description: 'Messages about your bookings and your email preferences.' });

export default async function Notifications() {
  const user = await requireUser('/account/notifications');
  const [items, prefs, profile, c] = await Promise.all([myNotifications(user), myNotificationPrefs(user), myProfile(user), consentTexts()]);
  return (
    <>
      <h1 className="d2">Notifications</h1>
      <div className="pt-split">
        <section className="stack" aria-labelledby="pt-inbox"><h2 className="pt-section-title" id="pt-inbox">Messages</h2><NoticeList items={items} /></section>
        <aside className="pt-split__aside"><section className="pt-card" aria-labelledby="pt-prefs"><h2 className="d4" id="pt-prefs">Preferences</h2>
          <Preferences prefs={prefs} marketing={!!profile.user?.marketing_opt_in} marketingText={c.marketing.text} />
        </section></aside>
      </div>
    </>
  );
}
