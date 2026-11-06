import { money } from '@/lib/format';
import { door } from '@/server/door';
import { paidByLabel, type Extras } from './model';

const day = (s: string) => new Intl.DateTimeFormat('en-CA', { month: 'short', day: 'numeric', year: 'numeric', timeZone: 'UTC' }).format(new Date(`${s}T12:00:00Z`));

// The owner's own repair costs and kickbacks (release 29, C2; migration 0581), only when CarmaCars staff turned on "Show
// repair costs and kickbacks to this owner"; otherwise nothing renders. This year to today, the owner's cars only.
export async function OwnerExtras({ userId }: { userId: string }) {
  const x = await door<Extras>(userId, 'ops_read', 'profit_extras_mine', {}).catch(() => null);
  if (!x?.visible) return null;
  const shown = x.lines.filter((l) => l.cents !== 0);
  return (
    <section className="pu-panel" aria-labelledby="ow-px" data-testid="owner-profit-extras">
      <div className="pu-panel__head"><h2 className="pu-title" id="ow-px">Repairs and partner credits on your cars, {day(x.from)} to {day(x.to)}</h2></div>
      {shown.length ? <dl className="pt-dl pt-dl--money">{shown.map((l) => <div key={l.line}><dt>{l.line}</dt><dd>{money(l.cents, { cents: true })}</dd></div>)}</dl>
        : <p className="small muted">Nothing on your cars this year.</p>}
      {x.repairs.length > 0 && <ul className="small">{x.repairs.map((r) => <li key={r.id}>{day(r.on_date)} · {r.car} · {r.description} · {money(r.cents, { cents: true })} · paid by {paidByLabel(r.paid_by).toLowerCase()}</li>)}</ul>}
    </section>
  );
}
