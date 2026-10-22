import Link from 'next/link';
import { pageMeta } from '@/features/seo/meta';
import { page } from '@/server/admin/api';
import { door } from '@/server/door';
import { PageHead } from '@/features/admin/ui';
import { ChauffeurRequests, STATUSES, type ChauffeurData } from '@/features/chauffeur/ChauffeurRequests';

export const dynamic = 'force-dynamic';
export const metadata = pageMeta({ title: 'Chauffeur', path: '/admin/chauffeur', noindex: true, description: 'Chauffeur requests: quote, confirm and close them.' });

// Bookings > Chauffeur (migration 0093).
export default async function ChauffeurAdmin({ searchParams }: { searchParams: Promise<{ status?: string }> }) {
  const [{ user }, sp] = await Promise.all([page('/admin/chauffeur'), searchParams]);
  const status = STATUSES.includes(sp.status ?? '') ? sp.status! : undefined;
  const data = await door<ChauffeurData>(user.id, 'ops_read', 'chauffeur_requests', status ? { status } : {});
  return (
    <>
      <PageHead title="Chauffeur" kicker="Bookings"><Link prefetch={false} className="btn btn--ghost btn--sm" href="/chauffeur">The public page</Link></PageHead>
      <ChauffeurRequests data={data} base="/admin/chauffeur" status={status} />
    </>
  );
}
