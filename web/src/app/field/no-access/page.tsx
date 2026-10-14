import { pageMeta } from '@/features/seo/meta';
import { NoAccess } from '@/features/access/Access';

export const dynamic = 'force-dynamic';
export const metadata = pageMeta({ title: 'No access', path: '/field', noindex: true, description: 'This area is for CarmaCars field staff.' });
export default function Page() { return <NoAccess portal="field" />; }
