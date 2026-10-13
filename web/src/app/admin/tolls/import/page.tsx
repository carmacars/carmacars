import Link from 'next/link';
import { pageMeta } from '@/features/seo/meta';
import { page } from '@/server/admin/api';
import { TollImport } from '@/features/admin/TollImport';
import { PageHead } from '@/features/admin/ui';

export const dynamic = 'force-dynamic';
export const metadata = pageMeta({ title: 'Import tolls', path: '/admin/tolls/import', noindex: true, description: 'Import a toll or ticket statement.' });
export default async function Import() {
  await page('/admin/tolls/import');
  return <><PageHead kicker={<Link prefetch={false} className="link" href="/admin/tolls">Tolls and tickets</Link>} title="Import a statement" /><TollImport /></>;
}
