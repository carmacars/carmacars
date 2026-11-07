import Link from '@/components/Link';
import { door } from '@/server/door';
import { Act } from '@/features/admin/Act';
import { DateInput } from '@/components/DateInput';
import { $, Card, Table, d } from '@/features/admin/ui';
import { RepairCostForm } from './RepairCostForm';
import { paidByLabel, period, type Extras, type Level } from './model';

// Kickbacks and repair costs (release 29, C2; migration 0581) at one level: the business (Admin > Money and Finance's
// Money), an owner (the owner's page, with "Show repair costs and kickbacks to this owner") or a car (the car's page, also
// for Fleet). A period (default: this year to today), the lines (Body shop, Tow, Storage kickback; Repair costs; the
// owner's and the insurer's repairs apart), by owner and by car, every row, the CSV. The source of the kickbacks is the
// partner invoices and the money received on them (Money > Partner invoices); repair costs are added here.
type R = Record<string, unknown>;
export async function ProfitExtras({ userId, aal, level, id, sp, base, claimId, carLink }: {
  userId: string; aal?: 'aal1' | 'aal2' | null; level: Level; id?: string | null; sp: Record<string, string | undefined>; base: string; claimId?: string | null;
  /** the car page's address for a vehicle id (the business and owner tables link to it) */ carLink?: (id: string) => string;
}) {
  const p = period(sp);
  const x = await door<Extras>(userId, 'ops_read', 'profit_extras', { level, id: id ?? null, from: p.from, to: p.to }, aal);
  const refresh = [base.split('?')[0]!];
  const csv = `/api/staff/profit-extras?${new URLSearchParams({ level, ...(id ? { id } : {}), from: x.from, to: x.to }).toString()}`;
  const repairs = claimId ? x.repairs.filter((r) => r.claim_id === claimId) : x.repairs;
  const kickbacks = claimId ? x.kickbacks.filter((k) => k.claim_id === claimId) : x.kickbacks;
  const editable = level === 'vehicle' || !!claimId || level === 'business';
  return (
    <div className="stack" data-testid={`profit-extras-${level}`}>
      <form className="row" method="get" action={base.split('?')[0]} data-testid="px-period">
        {[...new URLSearchParams(base.includes('?') ? base.split('?')[1] : '').entries()].filter(([k]) => k !== 'from' && k !== 'to').map(([k, v]) => <input key={k} type="hidden" name={k} value={v} />)}
        <div className="field"><label className="label" htmlFor={`px-from-${claimId ?? level}`}>From</label><DateInput className="input" id={`px-from-${claimId ?? level}`} type="date" name="from" defaultValue={x.from} /></div>
        <div className="field"><label className="label" htmlFor={`px-to-${claimId ?? level}`}>To</label><DateInput className="input" id={`px-to-${claimId ?? level}`} type="date" name="to" defaultValue={x.to} /></div>
        <button className="btn btn--ghost btn--sm" type="submit">Show</button>
        <a className="btn btn--ghost btn--sm" href={csv} data-testid="px-csv">CSV</a>
      </form>
      {!claimId && <Card title={`Kickbacks and repair costs, ${d(x.from)} to ${d(x.to)}`} testId="px-lines">
        <dl className="pt-dl pt-dl--money">
          {x.lines.map((l) => <div key={l.line}><dt>{l.kind === 'memo' ? <span className="muted">{l.line} (not a CarmaCars cost)</span> : l.line}</dt><dd>{l.kind === 'cost' ? `−${$(l.cents)}` : $(l.cents)}</dd></div>)}
          <div><dt><b>Net (kickbacks less repair costs)</b></dt><dd><b>{$(x.net_cents)}</b></dd></div>
        </dl>
        {!!x.unassigned_kickback_cents && <p className="small alert alert--warn"><span>{$(x.unassigned_kickback_cents)} of kickbacks is on invoices with no car: choose the car on each invoice (Money &gt; Partner invoices).</span></p>}
        {level === 'owner' && id && <div className="row small" data-testid="px-owner-visibility">The owner {x.show_to_owner ? 'sees' : 'does not see'} these lines in their portal.
          <Act ops action="owner_profit_extras_visibility" payload={{ owner: id, on: !x.show_to_owner }} label={x.show_to_owner ? 'Hide from this owner' : 'Show repair costs and kickbacks to this owner'}
            confirm={x.show_to_owner ? undefined : 'The owner will see the kickbacks and repair costs of their own cars in their portal.'} refresh={refresh} testId="px-owner-toggle" /></div>}
      </Card>}
      {x.by_owner && x.by_owner.length > 0 && <Card title="By owner"><Table<R> rows={x.by_owner as unknown as R[]} cols={[{ key: 'name', label: 'Owner' },
        { key: 'kickback_cents', label: 'Kickbacks', num: true, render: (r) => $(r.kickback_cents) }, { key: 'repair_cents', label: 'Repair costs', num: true, render: (r) => $(r.repair_cents) }]} /></Card>}
      {level !== 'vehicle' && x.by_car.length > 0 && <Card title="By car"><Table<R> rows={x.by_car as unknown as R[]} cols={[
        { key: 'name', label: 'Car', render: (r) => (carLink ? <Link prefetch={false} className="link" href={carLink(String(r.vehicle_id))}>{String(r.name)}</Link> : String(r.name)) },
        { key: 'body_shop_cents', label: 'Body shop kickback', num: true, render: (r) => $(r.body_shop_cents) }, { key: 'tow_cents', label: 'Tow kickback', num: true, render: (r) => $(r.tow_cents) },
        { key: 'storage_cents', label: 'Storage kickback', num: true, render: (r) => $(r.storage_cents) }, { key: 'repair_cents', label: 'Repair costs', num: true, render: (r) => $(r.repair_cents) }]} /></Card>}
      <Card title={claimId ? 'Kickbacks on this claim' : 'Kickbacks received'}><Table<R> rows={kickbacks as unknown as R[]} empty="No kickback received in this period." cols={[
        { key: 'on_date', label: 'Received', render: (r) => d(r.on_date) }, { key: 'line', label: 'Line' }, { key: 'car', label: 'Car', render: (r) => String(r.car ?? 'No car yet') },
        { key: 'partner', label: 'Partner' }, { key: 'invoice_number', label: 'Invoice' }, { key: 'cents', label: 'Before HST', num: true, render: (r) => $(r.cents) }]} /></Card>
      <Card title={claimId ? 'Repair costs on this claim' : 'Repair costs'} aside={editable ? <RepairCostForm vehicleId={level === 'vehicle' ? id : null} claimId={claimId} partners={x.partners ?? []} claims={x.claims} cars={x.cars} refresh={refresh} /> : undefined}>
        <Table<R> rows={repairs as unknown as R[]} empty="No repair cost in this period." testId="px-repairs" cols={[
          { key: 'on_date', label: 'Date', render: (r) => d(r.on_date) }, ...(level === 'vehicle' ? [] : [{ key: 'car', label: 'Car' }]), { key: 'vendor', label: 'Vendor' }, { key: 'description', label: 'What was done', className: 'wrap' },
          { key: 'cents', label: 'Amount', num: true, render: (r) => $(r.cents) }, { key: 'tax_cents', label: 'Tax', num: true, render: (r) => $(r.tax_cents) },
          { key: 'paid_by', label: 'Paid by', render: (r) => paidByLabel(String(r.paid_by)) }, { key: 'claim_number', label: 'Claim' },
          { key: 'receipt', label: 'Receipt', render: (r) => (r.receipt ? <a className="link" href={`/api/staff/profit-extras?receipt=${String(r.id)}`} target="_blank" rel="noreferrer">View</a> : '') },
          { key: 'act', label: '', render: (r) => <span className="ad-actions"><RepairCostForm partners={x.partners ?? []} claims={x.claims} edit={r as never} refresh={refresh} />
            <Act ops action="repair_cost_void" payload={{ id: r.id }} label="Remove" variant="danger" fields={[{ name: 'reason', label: 'Why' }]} refresh={refresh} /></span> }]} />
      </Card>
      {!claimId && <p className="small muted">Kickbacks are the money received on partner invoices, before HST, on the day it came in.</p>}
    </div>
  );
}
