import { pageMeta } from '@/features/seo/meta';
import { NoAccess } from '@/features/access/Access';
import { requireOwnerUser } from '@/server/owner/data';

export const dynamic = 'force-dynamic';
export const metadata = pageMeta({ title: 'Owner portal', path: '/owner', noindex: true, description: 'The CarmaCars owner portal.' });

export default async function NotAnOwner() {
  await requireOwnerUser('/owner');
  return <NoAccess portal="owner" />;
}
