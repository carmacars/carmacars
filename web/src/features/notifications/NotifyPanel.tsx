import { rpc } from '@/lib/db/repo';
import { NotificationPrefs } from './NotificationPrefs';
import { saveMyNotifyPref } from '@/server/actions/notify-prefs';
import type { Portal, PrefState } from './prefs';

// The signed-in person's notification preferences for one portal (release 48, 3260), loaded on the server and handed to
// the page's switches. Used by the renter's and the owner's Notifications tabs and the staff, field, Admin and investor
// profile pages; the partner portal and the Admin's view of a person pass their own save.
const SR = { role: 'service_role' as const };

export async function myNotifyPrefs(userId: string, portal: Portal): Promise<PrefState | null> {
  return (await rpc('server_notify_prefs' as never, { p_user: userId, p_portal: portal } as never, SR).catch(() => null)) as unknown as PrefState | null;
}

export async function NotifyPanel({ userId, portal, idp = 'np', title = 'Notification preferences' }: { userId: string; portal: Portal; idp?: string; title?: string | null }) {
  const s = await myNotifyPrefs(userId, portal);
  if (!s) return <div className="pt-empty" data-testid={`${idp}-error`}><p className="d4">Your notification preferences did not load.</p><p className="muted">Reload the page. Nothing was changed.</p></div>;
  return (
    <section className="stack" aria-labelledby={`${idp}-title`} id="notifications">
      {title && <h2 className="pt-section-title" id={`${idp}-title`}>{title}</h2>}
      <NotificationPrefs initial={s} idp={idp} save={saveMyNotifyPref.bind(null, portal)} />
    </section>
  );
}
