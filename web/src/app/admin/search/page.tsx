import Link from 'next/link';
import { pageMeta } from '@/features/seo/meta';
import { page } from '@/server/admin/api';
import { door } from '@/server/door';
import { PageHead, Search } from '@/features/admin/ui';

export const dynamic = 'force-dynamic';
export const metadata = pageMeta({ title: 'Search', path: '/admin/search', noindex: true, description: 'Find a booking, car, owner, partner or renter.' });

type Group = { key: string; label: string; rows: Array<{ title: string; sub: string; href: string }> };

// One search box for the whole portal (October 16, 2026): a booking number, a plate or VIN, an owner, a partner, a
// renter's name or email; the results grouped by what they are.
export default async function AdminSearchPage({ searchParams }: { searchParams: Promise<Record<string, string | undefined>> }) {
  const [{ user }, sp] = await Promise.all([page('/admin/search'), searchParams]);
  const q = (sp.q ?? '').trim();
  const r = q ? await door<{ q: string; groups: Group[] }>(user.id, 'ops_read', 'admin_search', { q }) : { q, groups: [] as Group[] };
  const found = r.groups.filter((g) => g.rows.length);
  return (
    <>
      <PageHead title="Search" kicker={q ? `${found.reduce((n, g) => n + g.rows.length, 0)} found for "${q}"` : 'Bookings, cars, owners, partners and renters'}>
        <Search action="/admin/search" value={q} placeholder="Booking, plate, VIN, name or email" />
      </PageHead>
      {!q ? <p className="ad-empty">Type a booking number (CC-1042), a plate, a VIN, or a name or email address, then press Search.</p>
        : q.length < 2 ? <p className="ad-empty">Type at least two letters or digits.</p>
        : !found.length ? <p className="ad-empty" data-testid="search-empty">Nothing matches &quot;{q}&quot;. Check the spelling, or search for part of it: the last digits of a plate or a VIN, or a first name.</p>
        : <div className="ad-results" data-testid="search-results">{found.map((g) => (
          <section key={g.key} className="pt-card ad-card" aria-labelledby={`sr-${g.key}`} data-testid={`search-${g.key}`}>
            <div className="pt-card__head"><h2 className="d4" id={`sr-${g.key}`}>{g.label} ({g.rows.length})</h2></div>
            <ul className="ad-list">{g.rows.map((x) => <li key={x.href}><span><Link prefetch={false} className="link" href={x.href}>{x.title}</Link></span><span className="ad-sub">{x.sub}</span></li>)}</ul>
          </section>))}</div>}
    </>
  );
}
