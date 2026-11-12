import { NoticeList, Preferences } from '@/features/portal/Notices';
import { myNotificationPrefs, myNotifications, myProfile } from '@/server/portal/data';
import { consentTexts } from '@/server/booking-data';
import type { SessionUser } from '@/lib/auth';

// Account > Notifications: the messages from CarmaCars, and which optional emails you get. The owner portal shows the
// same preferences on its own Notifications tab (before r27 it sent owners here).
export async function NotificationsTab({ user, title = 'Messages' }: { user: SessionUser; title?: string }) {
  const [items, prefs, profile, c] = await Promise.all([myNotifications(user), myNotificationPrefs(user), myProfile(user), consentTexts()]);
  return (
    <div className="pt-split">
      <section className="stack" aria-labelledby="pt-inbox"><h2 className="pt-section-title" id="pt-inbox">{title}</h2><NoticeList items={items} /></section>
      <aside className="pt-split__aside"><section className="pt-card" aria-labelledby="pt-prefs"><h2 className="d4" id="pt-prefs">Email preferences</h2>
        <Preferences prefs={prefs} marketing={profile.user?.marketing_on ?? !!profile.user?.marketing_opt_in} marketingText={c.marketing.text} />
      </section></aside>
    </div>
  );
}
