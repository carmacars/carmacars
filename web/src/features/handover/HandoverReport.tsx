import { Act } from '@/features/admin/Act';
import { money } from '@/lib/format';
import { when } from '@/features/agreement/model';
import { storage, type Bucket } from '@/integrations/storage';
import { fmtDuration } from './late';
import type { ConditionSide, HandoverReportData } from './types';

// The photo report of a rental (migration 0130): the check-out and the check-in side by side, with the actual times
// against the due-back time, the kilometres and the fuel or charge, every photo (when and where it was taken), the damage
// marks and the return charges. Staff waive a charge with a reason; an Admin corrects an actual time with a reason. The
// renter reads the same report (without the staff controls) from their booking, their documents and the emails.
const SIDE: Record<string, string> = { pickup: 'Check-out (pickup)', return: 'Check-in (return)', swap_out: 'Car swapped out', swap_in: 'Car swapped in' };
const shotName = (s: string) => s.replace(/_/g, ' ').replace(/^./, (c) => c.toUpperCase());
const pct = (v: number | null, electric: boolean | null) => (v === null || v === undefined ? '' : electric ? `${v}%` : `${Math.round(v / 12.5)}/8 (${v}%)`);

export async function HandoverReport({ r, staff, canWaive, canCorrect, refresh = [] }: { r: HandoverReportData; staff: boolean; canWaive?: boolean; canCorrect?: boolean; refresh?: string[] }) {
  const s = await storage();
  const signed = await Promise.all(r.reports.map(async (side) => ({ side, photos: await Promise.all(side.photos.map(async (p) => ({ ...p, src: await s.signedDownloadUrl(p.bucket as Bucket, p.path, 900).catch(() => null) }))) })));
  const late = r.minutes_late > 0;
  const facts: Array<[string, string]> = [
    ['Due back', when(r.return_at)],
    ['Checked out', r.handed_over_at ? when(r.handed_over_at) : 'not yet'],
    ['Checked in', r.checked_in_at ? when(r.checked_in_at) : r.status === 'on_rent' ? 'still out' : 'not yet'],
    ['Late', late ? `${r.checked_in_at ? 'Late by' : 'Overdue by'} ${fmtDuration(r.minutes_late)}${r.grace_minutes ? ` (grace period ${fmtDuration(r.grace_minutes)})` : ''}` : 'on time'],
    ['Odometer', r.km_out !== null ? `${r.km_out.toLocaleString('en-CA')} km out${r.km_in !== null ? `, ${r.km_in.toLocaleString('en-CA')} km in` : ''}` : ''],
    ['Kilometres', r.km_driven !== null ? `${r.km_driven.toLocaleString('en-CA')} driven of ${(r.km_allowance ?? 0).toLocaleString('en-CA')} included${r.km_over > 0 ? `: ${r.km_over} km over` : ''}` : ''],
    [r.electric ? 'Charge' : 'Fuel', r.fuel_out_pct !== null ? `${pct(r.fuel_out_pct, r.electric)} out${r.fuel_in_pct !== null ? `, ${pct(r.fuel_in_pct, r.electric)} in` : ''}${r.fuel_short_pct > 0 ? `: ${r.fuel_short_pct}% lower` : ''}` : '']
  ];
  return (
    <div className="stack-lg" data-testid="handover-report">
      <section className="pt-card" aria-labelledby="hr-sum">
        <h2 className="d4" id="hr-sum">{r.vehicle}{r.plate ? ` · ${r.plate}` : ''}</h2>
        <dl className="pt-dl" data-testid="report-facts">{facts.filter(([, v]) => v).map(([k, v]) => <div key={k}><dt>{k}</dt><dd className={k === 'Late' && late ? 'ad-late' : undefined}>{v}</dd></div>)}</dl>
        {canCorrect && (r.handed_over_at || r.checked_in_at) && (
          <div className="row" style={{ flexWrap: 'wrap', gap: 'var(--s-2)' }}>
            {r.handed_over_at && <Act ops action="handover_time_correct" payload={{ booking: r.booking_id, which: 'out' }} label="Correct the check-out time" testId="correct-out" refresh={refresh}
              fields={[{ name: 'at', label: 'Actual check-out', type: 'datetime', required: true, value: r.handed_over_at }, { name: 'reason', label: 'Why', type: 'text', required: true }]} done="Corrected." />}
            {r.checked_in_at && <Act ops action="handover_time_correct" payload={{ booking: r.booking_id, which: 'in' }} label="Correct the check-in time" testId="correct-in" refresh={refresh}
              fields={[{ name: 'at', label: 'Actual check-in', type: 'datetime', required: true, value: r.checked_in_at }, { name: 'reason', label: 'Why', type: 'text', required: true }]} done="Corrected." />}
          </div>
        )}
      </section>
      {(r.charges.length > 0 || (r.waivers?.length ?? 0) > 0) && (
        <section className="pt-card" aria-labelledby="hr-ch" data-testid="report-charges">
          <h2 className="d4" id="hr-ch">Return charges</h2>
          <p className="small muted">{staff ? 'Written at check-in from the readings, the times and the fee defaults. The final statement is issued from them.' : 'From the readings and the times above. Your itemized statement follows.'}</p>
          <dl className="pt-dl pt-dl--money">
            {r.charges.map((c) => (
              <div key={c.key}><dt>{c.label}{staff && canWaive && !c.on_statement && <> <Act ops action="check_in_waive" payload={{ booking: r.booking_id, key: c.key }} label="Waive" variant="quiet" testId={`waive-${c.key}`} refresh={refresh}
                fields={[{ name: 'reason', label: 'Why it is waived', type: 'text', required: true }]} done="Waived." /></>}</dt><dd>{money(c.amount_cents + c.hst_cents, { cents: true })}</dd></div>
            ))}
          </dl>
          {staff && (r.waivers ?? []).map((w) => <p key={w.key} className="small" data-testid={`waived-${w.key}`}>Waived: {w.key.replace(/_/g, ' ')}, by {w.by ?? 'staff'} on {when(w.at)}. {w.reason}</p>)}
        </section>
      )}
      {signed.length === 0 && <p className="pt-empty">No check-out yet. The photo report appears here once the car is checked out.</p>}
      {signed.map(({ side, photos }) => <Side key={side.id} side={side} photos={photos} electric={r.electric} />)}
    </div>
  );
}

function Side({ side, photos, electric }: { side: ConditionSide; photos: Array<ConditionSide['photos'][number] & { src: string | null }>; electric: boolean | null }) {
  return (
    <section className="pt-card" aria-labelledby={`hr-${side.id}`} data-testid={`report-${side.kind}`}>
      <h2 className="d4" id={`hr-${side.id}`}>{SIDE[side.kind] ?? side.kind}</h2>
      <dl className="pt-dl">
        <div><dt>When</dt><dd>{side.performed_at ? when(side.performed_at) : ''}</dd></div>
        <div><dt>By</dt><dd>{side.performed_by_name ?? ''}</dd></div>
        <div><dt>Odometer</dt><dd>{side.odometer_km !== null ? `${side.odometer_km.toLocaleString('en-CA')} km` : ''}</dd></div>
        <div><dt>{electric ? 'Charge' : 'Fuel'}</dt><dd>{pct(side.fuel_pct, electric)}</dd></div>
        <div><dt>Keys</dt><dd>{side.keys_count ?? ''}</dd></div>
        {side.cleanliness && <div><dt>Cleanliness</dt><dd>{side.cleanliness.replace(/_/g, ' ')}</dd></div>}
        <div><dt>Signed</dt><dd>{side.renter_signed_at ? 'Renter and staff' : side.renter_declined_to_sign ? 'Staff (the renter declined to sign)' : side.unattended ? 'Staff (unattended)' : 'Staff'}</dd></div>
        {side.notes && <div><dt>Notes</dt><dd>{side.notes}</dd></div>}
      </dl>
      <h3 className="pt-kicker">Damage</h3>
      {side.damages.length ? <ul className="small">{side.damages.map((d) => <li key={d.label}><b>{d.label}</b> {d.location}{d.kind ? `, ${d.kind}` : ''}{d.size_cm ? `, ${d.size_cm} cm` : ''}: {d.description}{d.is_new ? ' (new)' : ' (recorded before)'}{d.status_vs_pickup === 'worse' ? ' (worse than at pickup)' : ''}</li>)}</ul> : <p className="small muted">None recorded.</p>}
      <h3 className="pt-kicker">Photos ({photos.length})</h3>
      <ul className="hr-photos">
        {photos.map((p) => (
          <li key={p.seq}>
            {/* eslint-disable-next-line @next/next/no-img-element -- signed private photo */}
            {p.src ? <a href={p.src} target="_blank" rel="noreferrer"><img src={p.src} alt={`${shotName(p.shot)}${p.damage_label ? ` ${p.damage_label}` : ''}`} loading="lazy" decoding="async" width={240} height={160} /></a> : <span className="small muted">Not available</span>}
            <span className="xs">{shotName(p.shot)}{p.damage_label ? ` ${p.damage_label}` : ''}{p.taken_at ? ` · ${when(p.taken_at)}` : ''}{p.latitude !== null && p.longitude !== null ? <> · <a className="link" href={`https://www.google.com/maps/search/?api=1&query=${p.latitude},${p.longitude}`} target="_blank" rel="noreferrer">where</a></> : null}</span>
          </li>
        ))}
      </ul>
    </section>
  );
}
