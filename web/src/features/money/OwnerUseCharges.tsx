import Link from '@/components/Link';
import { money } from '@/lib/format';
import { ownerUseStateWords, type OwnerUse } from './owner-use';

export type { OwnerUse } from './owner-use';

// r48 RW (3270, 3272): on an Owner Booking's Money tab, the charges billed to the owner (never to a renter): what waits
// for its evidence, and each owner invoice with how it is being collected. The card on file is charged at once; if that
// fails the owner gets the invoice and its pay link; unpaid at the earlier of 7 days and the statement cut-off, the
// statement takes it.
const fmt = (c: number) => money(Number(c ?? 0), { cents: true });
const day = (d: string) => new Intl.DateTimeFormat('en-CA', { timeZone: 'UTC', month: 'short', day: 'numeric', year: 'numeric' }).format(new Date(`${d.slice(0, 10)}T12:00:00Z`));

export function OwnerUseCharges({ data, isAdmin }: { data: OwnerUse; isAdmin: boolean }) {
  const open = data.invoices.reduce((a, i) => a + Math.max(i.balance_cents, 0), 0);
  return (
    <section className="pt-card ad-card stack" aria-labelledby="bm-ou-h" data-testid="bm-owner-use">
      <div className="pt-card__head"><h2 className="d4" id="bm-ou-h">Charges billed to the owner</h2>
        <span className="small muted">{data.invoices.length ? (open > 0 ? `${fmt(open)} open` : 'All paid') : 'None yet'}</span></div>
      <p className="small muted">This is an Owner Booking: its charges go to the owner, never to a renter. The card on file is charged at once; if that fails the owner is sent the invoice with a pay link, and anything unpaid is deducted from the next statement (at 7 days or the statement cut-off, whichever comes first).</p>
      {!data.on && <p className="alert alert--warn small" data-testid="bm-ou-off"><span>Billing owner-use charges is off in Program settings: nothing is billed by itself.</span></p>}
      {data.waiting.length > 0 && (
        <div className="stack" data-testid="bm-ou-waiting">
          <h3 className="label">Waiting for evidence</h3>
          <ul className="stack">{data.waiting.map((w) => (
            <li key={w.id} className="small"><b>{fmt(w.amount_cents)}</b> {w.description}{w.missing?.length ? `: needs ${w.missing.join(', ').replace(/_/g, ' ')}` : ''}</li>))}</ul>
        </div>)}
      {data.invoices.length === 0 && data.waiting.length === 0 && <p className="small" data-testid="bm-ou-empty">No charges on this booking yet. Any charge added after the return is billed to the owner here.</p>}
      {data.invoices.map((i) => {
        const s = ownerUseStateWords(i, day);
        return (
          <article key={i.id} className="stack" data-testid="bm-ou-invoice">
            <div className="pt-card__head">
              <h3 className="label">{isAdmin ? <Link href={`/admin/invoices/${encodeURIComponent(i.invoice_number)}`}>Invoice {i.invoice_number}</Link> : <>Invoice {i.invoice_number}</>}</h3>
              <span className={`ad-b ${s.warn ? 'ad-b--amber' : 'ad-b--light'}`} data-testid="bm-ou-state">{s.word}</span>
            </div>
            <ul className="stack">{i.lines.map((l, n) => (
              <li key={n} className="small"><b>{fmt(l.amount_cents)}</b> {l.description}{l.note ? <span className="muted"> ({l.note})</span> : null}</li>))}</ul>
            <p className="small">Total {fmt(i.total_cents)}{i.balance_cents > 0 ? `, ${fmt(i.balance_cents)} open` : ''}{i.issued_on ? `, issued ${day(i.issued_on)}` : ''}.</p>
            <p className={`small${s.warn ? ' muted' : ''}`} data-testid="bm-ou-text">{s.text}</p>
          </article>);
      })}
    </section>
  );
}
