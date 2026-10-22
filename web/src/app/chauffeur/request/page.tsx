import { Suspense } from 'react';
import { PageHead } from '@/components/Blocks';
import { JsonLd } from '@/components/JsonLd';
import { ChauffeurForm } from '@/features/chauffeur/ChauffeurForm';
import type { ChauffeurServices } from '@/features/chauffeur/schema';
import { breadcrumbLd, type Trail, seoMeta } from '@/features/seo/meta';
import { rpc } from '@/lib/db/repo';
import { torontoToday } from '@/lib/dates';
import { fill, getTokens } from '@/lib/site';

export const dynamic = 'force-dynamic';
const trail: Trail = [['Home', '/'], ['Chauffeur service', '/chauffeur'], ['Request']];

export async function generateMetadata() {
  const t = await getTokens();
  return seoMeta({ title: fill('Request a chauffeur in {{city}} | {{brand}}', t), path: '/chauffeur/request',
    description: fill('Request a chauffeur and a luxury car or van by the hour in {{city}}: the vehicle, the date, the hours and the address. We quote before you pay.', t) });
}

export default async function ChauffeurRequest({ searchParams }: { searchParams: Promise<{ vehicle?: string }> }) {
  const [c, sp] = await Promise.all([rpc('chauffeur_services', {}) as unknown as Promise<ChauffeurServices>, searchParams]);
  return (
    <div className="p-chauffeur-request">
      <JsonLd graph={[breadcrumbLd(trail, '/chauffeur/request')]} />
      <PageHead trail={trail} h1="Request a chauffeur." lead="Two hours minimum. We confirm the vehicle and the driver, then send your quote." />
      <section className="section"><div className="wrap grid"><div className="c-7 s-8">
        <Suspense fallback={null}><ChauffeurForm vehicles={c.vehicles} initial={typeof sp.vehicle === 'string' ? sp.vehicle : null} today={torontoToday()} hstBps={c.hst_bps} /></Suspense>
      </div></div></section>
    </div>
  );
}
