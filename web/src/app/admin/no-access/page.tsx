import { pageMeta } from '@/features/seo/meta';
import { NoAccess } from '@/features/access/Access';

export const dynamic = 'force-dynamic';
export const metadata = pageMeta({ title: 'Admin', path: '/admin', noindex: true, description: 'Admin access.' });
export default function Page() { return <NoAccess portal="admin" />; }
