import Link from 'next/link';
import { pageMeta } from '@/features/seo/meta';
import { page } from '@/server/admin/api';
import { Badge, PageHead, Search, Table, d } from '@/features/admin/ui';

export const dynamic = 'force-dynamic';
export const metadata = pageMeta({ title: 'Renters', path: '/admin/renters', noindex: true, description: 'Every renter.' });

type Row = { id: string; legal_name: string; email: string | null; mobile: string | null; identity_status: string; is_blocked: boolean; created_at: string };

// People > Renters (October 16, 2026): every renter, searchable by name, email or phone; their bookings are one click away.
export default async function Renters({ searchParams }: { searchParams: Promise<Record<string, string | undefined>> }) {
  const [{ list }, sp] = await Promise.all([page('/admin/renters'), searchParams]);
  const res = await list<Row>('renters', { q: sp.q, order: 'created_at', limit: 200 });
  return (
    <>
      <PageHead title="Renters" kicker={`${res.count} found`}>
        <Search action="/admin/renters" value={sp.q} placeholder="Name, email or phone" />
        <Link prefetch={false} className="btn btn--primary btn--sm" href="/admin/bookings/new">Add a rental</Link>
      </PageHead>
      <Table<Row> testId="renters" caption="Renters" rows={res.rows} empty={sp.q ? `No renter matches "${sp.q}". Search by part of the name, the email or the phone number.` : 'No renters yet. They appear here after their first booking request, or when you add a rental.'} cols={[
        { key: 'legal_name', label: 'Renter', render: (r) => <Link prefetch={false} className="link" href={`/admin/bookings?q=${encodeURIComponent(r.email ?? r.legal_name)}`}>{r.legal_name}</Link> },
        { key: 'email', label: 'Email' }, { key: 'mobile', label: 'Phone' },
        { key: 'identity_status', label: 'Identity', render: (r) => <Badge s={r.identity_status} /> },
        { key: 'is_blocked', label: 'Blocked', render: (r) => (r.is_blocked ? 'Yes' : 'No') },
        { key: 'created_at', label: 'Since', render: (r) => d(r.created_at) }
      ]} />
    </>
  );
}
