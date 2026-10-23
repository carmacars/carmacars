import { pageMeta } from '@/features/seo/meta';
import { PageHeader } from '@/features/portal/Chrome';
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
      <PageHeader title="Notifications" purpose={<>Messages about your vehicles, invoices and payouts. Statement and billing emails are always sent; choose the others in your <a className="link" href="/account/notifications">email preferences</a>.</>} />
      <NoticeList items={items} />
    </>
  );
}
