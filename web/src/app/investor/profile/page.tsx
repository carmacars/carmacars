import Link from 'next/link';
import { pageMeta } from '@/features/seo/meta';
import { door, requireInvestor } from '@/server/door';
import { Requests } from '@/features/investor/Requests';
import { money } from '@/lib/format';

export const dynamic = 'force-dynamic';
export const metadata = pageMeta({ title: 'Profile and notices', path: '/investor/profile', noindex: true, description: 'Contact details and notices.' });

type Home = { investor: { legal_name: string; email: string | null; phone: string | null; address: string | null }; bank_last4: string | null; election_effective_month: string;
  investments: Array<{ id: string; invested_amount_cents: number; investment_date: string }>; documents?: unknown };

// Profile (07-investor.md section 2): contact details read-only, bank account last four, the notices an
// investor may send, two-step sign-in.
export default async function Profile() {
  const { user } = await requireInvestor('/investor/profile');
  const [h, docs] = await Promise.all([door<Home>(user.id, 'investor_read', 'home'), door<Array<{ id: string; kind: string; title: string | null; created_at: string }>>(user.id, 'investor_read', 'documents')]);
  const eff = new Intl.DateTimeFormat('en-CA', { month: 'long', year: 'numeric', timeZone: 'UTC' }).format(new Date(`${h.election_effective_month}T12:00:00Z`));
  return (
    <div className="stack">
      <h1 className="d2">Profile and notices</h1>
      <section className="pt-card" aria-labelledby="ct-t"><h2 className="d4" id="ct-t">Contact details</h2>
        <dl className="pt-dl"><div><dt>Name</dt><dd>{h.investor.legal_name}</dd></div><div><dt>Email</dt><dd>{h.investor.email ?? ''}</dd></div><div><dt>Phone</dt><dd>{h.investor.phone ?? ''}</dd></div>
          <div><dt>Address</dt><dd>{h.investor.address ?? ''}</dd></div><div><dt>Bank account</dt><dd>{h.bank_last4 ? `ending ${h.bank_last4}` : 'none on file'}</dd></div></dl>
        <p className="small">To update these, ask us; we confirm by phone.</p>
      </section>
      <Requests investments={h.investments.map((x) => ({ id: x.id, label: `${money(x.invested_amount_cents, { cents: true })} from ${x.investment_date}` }))} effective={eff} />
      <section className="pt-card" aria-labelledby="dc-t"><h2 className="d4" id="dc-t">Documents</h2>{docs.length ? <ul className="small">{docs.map((d) => <li key={d.id}>{d.title ?? d.kind.replace(/_/g, ' ')}</li>)}</ul> : <p className="small">No documents yet.</p>}</section>
      <section className="pt-card" aria-labelledby="ts-t"><h2 className="d4" id="ts-t">Two-step sign-in</h2><p className="small">Add an authenticator app for a second step at sign-in.</p><Link className="btn btn--ghost btn--sm" href="/two-step/setup?next=/investor/profile">Set up two-step sign-in</Link></section>
    </div>
  );
}
