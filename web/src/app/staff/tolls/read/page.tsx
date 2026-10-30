import Link from 'next/link';
import { pageMeta } from '@/features/seo/meta';
import { vaPage } from '@/server/va';
import { door } from '@/server/door';
import { PageHead } from '@/features/admin/ui';
import { TollReader } from '@/features/tolls/TollReader';
import { ReadQueue } from '@/features/tolls/ReadQueue';

export const dynamic = 'force-dynamic';
export const metadata = pageMeta({ title: 'Read a notice', path: '/staff/tolls/read', noindex: true, description: 'Read a toll notice or statement.' });
export default async function VaReadNotice() {
  const { user, aal } = await vaPage('/staff/tolls/read', ['finance']);
  const q = await door<Parameters<typeof ReadQueue>[0]['q']>(user.id, 'ops_read', 'toll_read_queue', {}, aal);
  return (<>
    <PageHead kicker={<Link prefetch={false} className="link" href="/staff/tolls">Tolls and tickets</Link>} title="Read a notice">
      <Link prefetch={false} className="btn btn--ghost btn--sm" href="/staff/tolls/profiles">Reading profiles</Link>
    </PageHead>
    <TollReader base="/staff" />
    <ReadQueue q={q} base="/staff" />
  </>);
}
