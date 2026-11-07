import { Act, type Field } from '@/features/admin/Act';
import { $, Card, d } from '@/features/admin/ui';
import { pct } from '@/lib/format';

// The fleet lease of a supplier (migration 0640): the supplier's lease terms (the Regular and Troubled Rates, the claim
// and write-off shares, the notice), each car's tier and delivery, the Upkeep Table, and upkeep costs billed to the right
// party. A supplier who came in on the fleet supplier route (0710) starts with the default terms of Program settings and the
// default Upkeep Table; each car's tier is the one he chose when he added it, and approval puts the car on the lease.
export interface FleetLeaseData {
  pay_model: string;
  terms: { regular_cents: number; troubled_cents: number; claim_profit_bps: number; early_writeoff_bps: number; writeoff_months: number; later_writeoff_bps: number;
    notice_days: number; effective_from: string; awaiting_signature: boolean } | null;
  history: Array<{ id: string; regular_cents: number; troubled_cents: number; effective_from: string; effective_to: string | null; awaiting_signature: boolean }>;
  upkeep: Array<{ cost_type: string; label: string; party: 'supplier' | 'company' | null }>;
  cars: Array<{ vehicle_id: string; name: string; plate: string | null; delivered_on: string | null; first_payout: string | null; tier: string | null; monthly_cents: number | null;
    periods: Array<{ kind: string; tier: string | null; monthly_cents: number; starts_on: string; ends_on: string | null; reason: string | null }>;
    /** 0710: the tier the supplier chose when he added the car (locked), and the car's onboarding status */
    requested_tier?: 'regular' | 'troubled' | null; onboarding_status?: string | null }>;
  awaiting_lawyer: boolean;
  /** 0710: fleet_supplier when the supplier signed up on the route (or staff added him on it) */
  route?: string | null;
}

const tierOpts: Array<[string, string]> = [['regular', 'Regular'], ['troubled', 'Troubled (needs work)']];
// Admin only for the correction (the door refuses anyone else); the tier is shown read only otherwise.
const cap = (s: string | null) => (s ? s[0]!.toUpperCase() + s.slice(1) : '');

export function FleetLease({ data, ownerId }: { data: FleetLeaseData; ownerId: string }) {
  const refresh = [`/admin/owners/${ownerId}`];
  const t = data.terms;
  const termFields: Field[] = [
    { name: 'regular_cents', label: 'Regular Rate (a month per car)', type: 'money', required: true, value: t ? t.regular_cents / 100 : undefined },
    { name: 'troubled_cents', label: 'Troubled Rate (a month per car that needs work)', type: 'money', required: true, value: t ? t.troubled_cents / 100 : undefined },
    { name: 'claim_profit_bps', label: 'Claim Profit Share (%)', type: 'percent', required: true, value: t ? t.claim_profit_bps / 100 : undefined },
    { name: 'early_writeoff_bps', label: 'Early Write-Off Share (% of the balance after any lien)', type: 'percent', required: true, value: t ? t.early_writeoff_bps / 100 : undefined },
    { name: 'writeoff_months', label: 'Write-Off Period (months in service)', type: 'number', required: true, value: t?.writeoff_months },
    { name: 'later_writeoff_bps', label: 'Later Write-Off Share (% after the Write-Off Period)', type: 'percent', required: true, value: t ? t.later_writeoff_bps / 100 : undefined },
    { name: 'notice_days', label: 'Notice Period (days)', type: 'number', required: true, value: t?.notice_days },
    { name: 'from', label: 'From (empty: the first day of next month)', type: 'date' },
    { name: 'note', label: 'Note' }
  ];
  return (
    <Card title="Fleet lease" testId="fleet-lease" aside={data.awaiting_lawyer ? <span className="badge badge--outline" data-testid="fleet-lease-lawyer">Agreement awaiting lawyer OK</span> : undefined}>
      {data.route === 'fleet_supplier' && <p className="small" data-testid="fleet-lease-route"><span className="badge badge--outline">Fleet supplier route</span> He signed up on the route: the default terms and Upkeep Table were set at once (change them here), he chose each car&apos;s tier, and he signs in the owner portal only. Each car&apos;s ServiceOntario forms (the lease, and the transfer into his corporation when needed) are filled in at once; no fees.</p>}
      <p className="small">For a supplier&apos;s corporation that leases cars to CarmaCars: a fixed lease a month per car by tier, paid in arrears on the 10th with the owner payouts (the first payment one full month after delivery), part months by the day. Each car&apos;s tier is set once, when it is onboarded. CarmaCars keeps the rentals; the supplier pays no fee of any kind (no owner invoice or debit is ever made for these cars). The supplier signs the Fleet Supplier Lease Agreement, filled from these terms. {data.pay_model === 'fleet_lease' ? 'Every car of this owner is on the lease.' : 'Put each car on the lease below; the agreement switches once every car is.'}</p>
      {t ? <dl className="ad-kv small" data-testid="fleet-lease-terms">
        <dt>Regular / Troubled</dt><dd>{$(t.regular_cents)} / {$(t.troubled_cents)} a month per car</dd>
        <dt>Claim Profit Share</dt><dd>{pct(t.claim_profit_bps)}</dd>
        <dt>Write-off</dt><dd>{pct(t.early_writeoff_bps)} under {t.writeoff_months} months in service, {pct(t.later_writeoff_bps)} after, of the balance after any lien</dd>
        <dt>Notice</dt><dd>{t.notice_days} days</dd>
        <dt>Since</dt><dd>{d(t.effective_from)}{t.awaiting_signature ? ' (waiting for the supplier to sign the new agreement)' : ''}</dd></dl>
        : <p className="small muted">No lease terms yet: enter the ones agreed with this supplier.</p>}
      <Act action="fleet_lease_terms_save" payload={{ owner_id: ownerId }} label={t ? 'Change the lease terms' : 'Enter the lease terms'} variant={t ? 'ghost' : 'primary'} refresh={refresh}
        title="Fleet lease terms" submitLabel="Save" testId="fleet-lease-terms-save" fields={termFields}
        done={t ? 'Saved. Once the supplier has signed, new terms wait for the supplier to sign the new agreement.' : 'Saved.'} />
      <h3 className="d5">Cars</h3>
      {data.cars.length ? <ul className="ad-list" data-testid="fleet-lease-cars">{data.cars.map((c) => (
        <li key={c.vehicle_id}><span><b>{c.name}</b>{c.plate ? ` · ${c.plate}` : ''} · {c.tier ? <><span data-testid={`fleet-tier-${c.vehicle_id}`}>{cap(c.tier)}</span>, {$(c.monthly_cents)} a month · delivered {d(c.delivered_on)} · first payment {d(c.first_payout)}</> : c.requested_tier ? <><span data-testid={`fleet-tier-${c.vehicle_id}`}>{cap(c.requested_tier)}</span> (chosen by the supplier), on the lease when you approve the car</> : 'not on the lease'}</span>
          {!c.tier && c.requested_tier
            ? <Act action="fleet_onboarding_tier_correct" payload={{ vehicle_id: c.vehicle_id }} label="Correct the tier" variant="quiet" refresh={refresh} title="Correct a tier chosen by mistake" submitLabel="Correct"
                done="Corrected. Approval puts the car on the lease at this tier."
                fields={[{ name: 'tier', label: 'The correct tier', type: 'select', required: true, options: tierOpts, value: c.requested_tier === 'regular' ? 'troubled' : 'regular' },
                  { name: 'reason', label: 'What was chosen by mistake (kept in the audit log)', required: true, hint: 'Only for a mistake: the supplier chose the tier when he added the car, and it does not change.' }]} />
            : c.tier
            ? <Act action="fleet_lease_tier_correct" payload={{ vehicle_id: c.vehicle_id }} label="Correct the tier" variant="quiet" refresh={refresh} title="Correct a tier entered by mistake" submitLabel="Correct"
                done="Corrected from the delivery (or from the day after the last approved statement)."
                fields={[{ name: 'tier', label: 'The correct tier', type: 'select', required: true, options: tierOpts, value: c.tier === 'regular' ? 'troubled' : 'regular' },
                  { name: 'reason', label: 'What was entered by mistake (kept in the audit log)', required: true, hint: 'Only for a data-entry mistake: a car\'s tier is set once, when it is onboarded, and does not change.' }]} />
            : <Act action="fleet_lease_car_set" payload={{ vehicle_id: c.vehicle_id }} label="Put on the lease" refresh={refresh} title="Put the car on the fleet lease" submitLabel="Save" done="On the lease."
                fields={[{ name: 'delivered_on', label: 'Delivered on', type: 'date', required: true }, { name: 'tier', label: 'Tier (set once, it does not change)', type: 'select', required: true, options: tierOpts }, { name: 'reason', label: 'Note', value: 'Delivered' }]} />}
        </li>))}</ul> : <p className="small muted">No cars yet: add them with Add another car, then put each on the lease.</p>}
      <h3 className="d5">Upkeep Table</h3>
      <ul className="ad-list small" data-testid="fleet-upkeep">{data.upkeep.map((u) => <li key={u.cost_type}><span>{u.label}</span><span>{u.party === 'supplier' ? 'The supplier' : u.party === 'company' ? 'CarmaCars' : 'Not set'}</span></li>)}</ul>
      <Act action="upkeep_split_save" payload={{ owner_id: ownerId }} nest="split" label="Set who pays each cost" refresh={refresh} title="Upkeep Table" submitLabel="Save" done="Saved." testId="fleet-upkeep-save"
        fields={data.upkeep.map((u) => ({ name: u.cost_type, label: u.label, type: 'select', required: true, value: u.party ?? '', options: [['supplier', 'The supplier'], ['company', 'CarmaCars']] }))} />
      {data.cars.some((c) => c.tier) && <Act action="fleet_upkeep_cost" label="Record an upkeep cost" refresh={refresh} title="An upkeep cost" submitLabel="Record" done="Recorded. A cost the supplier pays is on its next statement."
        fields={[{ name: 'vehicle_id', label: 'Car', type: 'select', required: true, options: data.cars.filter((c) => c.tier).map((c) => [c.vehicle_id, c.name] as [string, string]) },
          { name: 'cost_type', label: 'Cost type', type: 'select', required: true, options: data.upkeep.filter((u) => u.party).map((u) => [u.cost_type, u.label] as [string, string]) },
          { name: 'amount_cents', label: 'Amount before tax', type: 'money', required: true }, { name: 'hst_cents', label: 'HST', type: 'money' },
          { name: 'description', label: 'What was done', required: true }, { name: 'incurred_on', label: 'Date', type: 'date' }]} />}
    </Card>
  );
}
