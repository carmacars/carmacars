import { pageMeta } from '@/features/seo/meta';
import { NoticeList } from '@/features/portal/Notices';
import { myNotifications } from '@/server/portal/data';
import { requireOwner } from '@/server/owner/data';

export const dynamic = 'force-dynamic';
export const metadata = pageMeta({ title: 'Notifications', path: '/owner/notifications', noindex: true, description: 'Messages about your vehicles, invoices and payouts.' });

export default async function OwnerNotifications() {
  const { user } = await requireOwner('/owner/notifications');
  const items = await myNotifications(user);
  return (
    <>
      <h1 className="d2">Notifications</h1>
      <p className="muted">Statement and billing emails are always sent. Manage other emails in your <a href="/account/notifications">account preferences</a>.</p>
      <NoticeList items={items} />
    </>
  );
}
