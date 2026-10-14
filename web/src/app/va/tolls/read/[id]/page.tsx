import Link from 'next/link';
import { notFound } from 'next/navigation';
import { pageMeta } from '@/features/seo/meta';
import { vaPage } from '@/server/va';
import { door } from '@/server/door';
import { PageHead } from '@/features/admin/ui';
import { TollReview, type Read } from '@/features/tolls/TollReview';

export const dynamic = 'force-dynamic';
export const metadata = pageMeta({ title: 'Check a notice', path: '/va/tolls/read', noindex: true, description: 'Check the lines read from a notice.' });
export default async function VaCheckRead({ params }: { params: Promise<{ id: string }> }) {
  const { id } = await params;
  if (!/^[0-9a-f-]{36}$/.test(id)) notFound();
  const { user, aal } = await vaPage(`/va/tolls/read/${id}`, ['finance']);
  const read = await door<Read | null>(user.id, 'ops_read', 'toll_read', { id }, aal);
  if (!read) notFound();
  return (<>
    <PageHead kicker={<><Link prefetch={false} className="link" href="/va/tolls">Tolls and tickets</Link> · <Link prefetch={false} className="link" href="/va/tolls/read">Notices read</Link></>} title={`Check ${read.read_number}`} />
    <TollReview read={read} base="/va" />
  </>);
}
