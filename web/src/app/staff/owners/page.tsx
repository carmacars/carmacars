import Link from '@/components/Link';
import { pageMeta } from '@/features/seo/meta';
import { vaPage } from '@/server/va';
import { PageHead } from '@/features/admin/ui';

export const dynamic = 'force-dynamic';
export const metadata = pageMeta({ title: 'Owners', path: '/staff/owners', noindex: true, description: 'Owners with a car onboarding, and a search over every owner.' });

type Row = { id: string; name: string; email: string | null; cars: number; onboarding: number };

// r34: the owners customer service and fleet work with: those with a car onboarding first; a search by name, email,
// plate or VIN finds any owner. Each opens the owner's page (/staff/owners/<id>): the Onboarding checklist, the photos,
// the government forms and Add cars from a VIN list.
export default async function StaffOwners({ searchParams }: { searchParams: Promise<{ q?: string }> }) {
  const [{ read }, sp] = await Promise.all([vaPage('/staff/owners', ['cs', 'fleet']), searchParams]);
  const q = (sp.q ?? '').trim();
  const rows = await read<Row[]>('onboarding_owners', { q }).catch(() => [] as Row[]);
  return (<>
    <PageHead title="Owners" purpose={q ? `Owners matching "${q}".` : 'Owners with a car onboarding. Search to find any owner.'}>
      <Link prefetch={false} className="btn btn--ghost btn--sm" href="/staff/owners/add-car" data-testid="add-car-link">Add a car for an owner</Link></PageHead>
    <form className="row" style={{ gap: 'var(--s-2)', flexWrap: 'wrap' }} action="/staff/owners" role="search">
      <label className="vh" htmlFor="so-q">Name, email, plate or VIN</label>
      <input className="input" id="so-q" name="q" defaultValue={q} placeholder="Name, email, plate or VIN" data-testid="staff-owners-q" />
      <button className="btn btn--ghost btn--sm" type="submit">Search</button></form>
    {rows.length ? <ul className="ad-list" data-testid="staff-owners">{rows.map((o) => (
      <li key={o.id}><Link prefetch={false} className="link" href={`/staff/owners/${o.id}`}><b>{o.name}</b></Link> <span className="small muted">{[o.email, `${o.cars} car${o.cars === 1 ? '' : 's'}`, o.onboarding ? `${o.onboarding} onboarding` : null].filter(Boolean).join(' · ')}</span></li>))}</ul>
      : <p className="pt-empty muted">{q ? 'No owner matches.' : 'No owner has a car onboarding.'}</p>}
  </>);
}
