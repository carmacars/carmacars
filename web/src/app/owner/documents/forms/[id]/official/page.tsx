import Link from 'next/link';
import { notFound } from 'next/navigation';
import { pageMeta } from '@/features/seo/meta';
import { rpc } from '@/lib/db/repo';
import { requireOwner } from '@/server/owner/data';
import { OfficialForm, type Official } from '@/features/official-forms/OfficialForm';

export const dynamic = 'force-dynamic';
export const metadata = pageMeta({ title: 'Registry form', path: '/owner/documents', noindex: true, description: 'Your registry form, filled from your records.' });
export default async function OwnerOfficialForm({ params }: { params: Promise<{ id: string }> }) {
  const { id } = await params;
  if (!/^[0-9a-f-]{36}$/.test(id)) notFound();
  const { user } = await requireOwner(`/owner/documents/forms/${id}/official`);
  const f = (await rpc('owner_form_official', { p_by: user.id, p_fill: id }, { role: 'service_role' }).catch(() => null)) as unknown as Official | null;
  if (!f) notFound();
  return (<>
    <header className="stack"><p className="pt-kicker"><Link prefetch={false} className="link" href="/owner/documents">Documents</Link></p>
      <h1 className="d2">{f.form_code}{f.title ? `: ${f.title.replace(f.form_code, '').trim()}` : ''}</h1><p className="muted">{f.vehicle_name}</p></header>
    <OfficialForm f={f} />
  </>);
}
