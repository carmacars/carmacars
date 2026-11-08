import Link from '@/components/Link';
import { pageMeta } from '@/features/seo/meta';
import { OfficialForm, type Official } from '@/features/official-forms/OfficialForm';
import { staffFillOr404 } from '@/server/government-forms';

export const dynamic = 'force-dynamic';
export const metadata = pageMeta({ title: 'Government form', path: '/staff/government-forms', noindex: true, description: 'One government form of an owner\'s car, filled from the records.' });

// One official ServiceOntario form of an owner's car (r34, 0822), filled in the browser from the values on record.
export default async function StaffGovernmentForm({ params }: { params: Promise<{ id: string }> }) {
  const f = await staffFillOr404((await params).id);
  return (<>
    <header className="stack"><p className="pt-kicker"><Link prefetch={false} className="link" href={`/staff/owners/${f.owner_id}#gov-forms`}>{f.owner_name}</Link></p>
      <h1 className="d2">{f.form_code}{f.title ? `: ${f.title.replace(f.form_code, '').trim()}` : ''}</h1><p className="muted">{f.vehicle_name}{f.current ? '' : ' (an earlier version)'}</p></header>
    <OfficialForm f={f as unknown as Official} templateHref={`/staff/government-forms/${f.id}/template`} docBase="/staff/documents" />
    <p className="small"><Link prefetch={false} className="link" href={`/staff/government-forms/${f.id}/sheet`}>The data sheet (PDF)</Link></p>
  </>);
}
