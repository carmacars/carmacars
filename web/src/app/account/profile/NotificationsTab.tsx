import { NoticeList, Preferences } from '@/features/portal/Notices';
import { myNotifications, myProfile } from '@/server/portal/data';
import { consentTexts } from '@/server/booking-data';
import type { SessionUser } from '@/lib/auth';
import { NotifyPanel } from '@/features/notifications/NotifyPanel';
import type { Portal } from '@/features/notifications/prefs';

// Account > Notifications: the messages from CarmaCars, and which optional emails you get. The owner portal shows the
// same preferences on its own Notifications tab (before r27 it sent owners here).
export async function NotificationsTab({ user, title = 'Messages', portal = 'renter' }: { user: SessionUser; title?: string; portal?: Portal }) {
  const [items, profile, c] = await Promise.all([myNotifications(user), myProfile(user), consentTexts()]);
  // r48 (3260): under the messages, each kind of notification by channel (push, email, text), quiet hours and instant or a
  // summary; the marketing consent keeps its own box (the anti-spam law asks for it by itself)
  return (<>
    <div className="pt-split">
      <section className="stack" aria-labelledby="pt-inbox"><h2 className="pt-section-title" id="pt-inbox">{title}</h2><NoticeList items={items} /></section>
      <aside className="pt-split__aside"><section className="pt-card" aria-labelledby="pt-prefs"><h2 className="d4" id="pt-prefs">Offers and news</h2>
        <Preferences prefs={[]} marketing={profile.user?.marketing_on ?? !!profile.user?.marketing_opt_in} marketingText={c.marketing.text} />
      </section></aside>
    </div>
    <NotifyPanel userId={user.id} portal={portal} idp={portal === 'owner' ? 'np-owner' : 'np-renter'} />
  </>);
}
