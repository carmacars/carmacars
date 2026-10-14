import { pageMeta } from '@/features/seo/meta';
import { NoAccess } from '@/features/access/Access';

export const dynamic = 'force-dynamic';
export const metadata = pageMeta({ title: 'No access', path: '/investor', noindex: true, description: 'Statements for existing investors.' });
export default function Page() { return <NoAccess portal="investor" />; }
