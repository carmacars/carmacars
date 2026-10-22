import { pageMeta } from '@/features/seo/meta';
import { vaPage } from '@/server/va';
import { PageHead } from '@/features/admin/ui';
import { ChauffeurRequests, STATUSES, type ChauffeurData } from '@/features/chauffeur/ChauffeurRequests';

export const dynamic = 'force-dynamic';
export const metadata = pageMeta({ title: 'Chauffeur', path: '/va/chauffeur', noindex: true, description: 'Chauffeur requests: quote, confirm and close them.' });

// Chauffeur requests (migration 0093) for customer service and Sales: the same list and actions as Admin > Chauffeur.
export default async function VaChauffeur({ searchParams }: { searchParams: Promise<{ status?: string }> }) {
  const [{ read }, sp] = await Promise.all([vaPage('/va/chauffeur', ['cs', 'sales']), searchParams]);
  const status = STATUSES.includes(sp.status ?? '') ? sp.status! : undefined;
  const data = await read<ChauffeurData>('chauffeur_requests', status ? { status } : {});
  return (<><PageHead title="Chauffeur" kicker="Bookings" /><ChauffeurRequests data={data} base="/va/chauffeur" status={status} /></>);
}
