import Link from 'next/link';
import { pageMeta } from '@/features/seo/meta';
import { page } from '@/server/admin/api';
import { door } from '@/server/door';
import { PageHead } from '@/features/admin/ui';
import { TollReader } from '@/features/tolls/TollReader';
import { ReadQueue } from '@/features/tolls/ReadQueue';

export const dynamic = 'force-dynamic';
export const metadata = pageMeta({ title: 'Read a notice', path: '/admin/tolls/read', noindex: true, description: 'Read a toll notice or statement.' });
export default async function ReadNotice() {
  const { user } = await page('/admin/tolls/read');
  const q = await door<Parameters<typeof ReadQueue>[0]['q']>(user.id, 'ops_read', 'toll_read_queue');
  return (<>
    <PageHead kicker={<Link prefetch={false} className="link" href="/admin/tolls">Tolls and tickets</Link>} title="Read a notice">
      <Link prefetch={false} className="btn btn--ghost btn--sm" href="/admin/tolls/profiles">Reading profiles</Link>
    </PageHead>
    <TollReader base="/admin" />
    <ReadQueue q={q} base="/admin" />
  </>);
}
