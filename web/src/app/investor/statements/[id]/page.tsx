import { notFound } from 'next/navigation';
import { pageMeta } from '@/features/seo/meta';
import { door, requireInvestor } from '@/server/door';
import { money } from '@/lib/format';
import { when } from '@/features/agreement/model';

export const dynamic = 'force-dynamic';
export const metadata = pageMeta({ title: 'Statement', path: '/investor/statements', noindex: true, description: 'One monthly statement.' });

type S = { legal_name: string; agreement_number: string | null; return_month: string; opening_invested_cents: number; yearly_bps: number; days_earning: number; days_in_month: number;
  return_cents: number; withheld_tax_cents: number; disposition: string; status: string; payment_date: string; closing_invested_cents: number; paid_at: string | null; bank_last4: string | null;
  company: { legal_name: string | null; address: string | null } | null };

// The statement section 3.6 of the agreement requires (07-investor.md section 2). Another investor's
// statement reads as not found.
export default async function Statement({ params }: { params: Promise<{ id: string }> }) {
  const { id } = await params;
  if (!/^[0-9a-f-]{36}$/.test(id)) notFound();
  const { user } = await requireInvestor(`/investor/statements/${id}`);
  const s = await door<S | null>(user.id, 'investor_read', 'statement', { id });
  if (!s) notFound();
  const c = (n: number) => money(n, { cents: true });
  const month = new Intl.DateTimeFormat('en-CA', { month: 'long', year: 'numeric', timeZone: 'UTC' }).format(new Date(`${s.return_month}T12:00:00Z`));
  const last = new Date(Date.UTC(Number(s.return_month.slice(0, 4)), Number(s.return_month.slice(5, 7)), 0)).toISOString().slice(0, 10);
  return (
    <article className="stack" data-testid="statement">
      <h1 className="d2">Statement for {month}</h1>
      <p><a className="btn btn--ghost btn--sm" href={`/files/investor_statement/${id}`} data-testid="statement-pdf">Download PDF</a></p>
      <dl className="pt-dl">
        <div><dt>Investor</dt><dd>{s.legal_name}</dd></div><div><dt>Agreement</dt><dd>{s.agreement_number ?? ''}</dd></div>
        <div><dt>Invested Amount at the start of the month</dt><dd>{c(s.opening_invested_cents)}</dd></div>
        <div><dt>Yearly Percentage</dt><dd>{(s.yearly_bps / 100).toFixed(2)}%</dd></div>
        <div><dt>Days earning</dt><dd>{s.days_earning} of {s.days_in_month}</dd></div>
        <div><dt>Return for the month</dt><dd>{c(s.return_cents)}</dd></div>
        {s.withheld_tax_cents > 0 && <div><dt>Tax withheld</dt><dd>{c(s.withheld_tax_cents)}</dd></div>}
        <div><dt>{s.disposition === 'reinvest' ? 'Reinvested' : 'Paid'}</dt><dd>{s.disposition === 'reinvest' ? `Reinvested on ${when(`${last}T12:00:00Z`, false)}` : s.paid_at ? `Paid to your account ending ${s.bank_last4 ?? ''} on ${when(s.paid_at, false)}` : `To be paid on ${when(`${s.payment_date}T12:00:00Z`, false)}`}</dd></div>
        <div><dt>Invested Amount at the end of the month</dt><dd>{c(s.closing_invested_cents)}</dd></div>
      </dl>
      <p className="small muted">This statement is given under section 3.6 of your Investment Agreement. The Company gives no tax advice. {s.company?.legal_name ?? ''}{s.company?.address ? `, ${s.company.address}` : ''}</p>
    </article>
  );
}
