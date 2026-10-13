import Link from 'next/link';
import { pageMeta } from '@/features/seo/meta';
import { page } from '@/server/admin/api';
import { TollEntry } from '@/features/admin/TollEntry';
import { Card, PageHead } from '@/features/admin/ui';

export const dynamic = 'force-dynamic';
export const metadata = pageMeta({ title: 'Log a notice', path: '/admin/tolls/new', noindex: true, description: 'Log one toll, ticket or fine.' });
export default async function NewToll() {
  await page('/admin/tolls/new');
  return (<>
    <PageHead kicker={<Link prefetch={false} className="link" href="/admin/tolls">Tolls and tickets</Link>} title="Log a notice" />
    <Card title="Save and match"><TollEntry /></Card>
  </>);
}
