import { pageMeta } from '@/features/seo/meta';
import { NoAccess } from '@/features/access/Access';

export const dynamic = 'force-dynamic';
export const metadata = pageMeta({ title: 'No access', path: '/staff', noindex: true, description: 'This area is for CarmaCars staff.' });
export default function Page() { return <NoAccess portal="va" />; }
