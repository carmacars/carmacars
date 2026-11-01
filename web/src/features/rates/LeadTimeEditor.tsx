'use client';
import { useId, useState, useTransition } from 'react';
import { useRouter } from 'next/navigation';
import { adminAct, adminSaveRow } from '@/server/actions/admin-portal';
import { money } from '@/lib/format';
import { MAX_TIERS, pctText, tierRange, toRows, toTiers, type Tier, type TierRow } from './lead-time';

// Lead-time pricing (migration 0360) in Admin: the tiers as a small table, Program settings' on and off and the insurer
// choice, and a car's own choice (Program settings, off, or its own tiers). The database checks the table again.
const EXAMPLE_CENTS = 50000;

function TierTable({ rows, setRows, idp, disabled }: { rows: TierRow[]; setRows: (f: (r: TierRow[]) => TierRow[]) => void; idp: string; disabled?: boolean }) {
  const parsed = toTiers(rows);
  const tiers = 'tiers' in parsed ? parsed.tiers : null;
  const set = (i: number, k: keyof TierRow, v: string) => setRows((x) => x.map((r, j) => (j === i ? { ...r, [k]: v } : r)));
  return (
    <div className="lt-table">
      <table className="data lt-tiers">
        <thead><tr><th scope="col">Pickup is</th><th scope="col">From (hours before)</th><th scope="col">Adjustment (%)</th><th scope="col" className="num">On a {money(EXAMPLE_CENTS)} rental</th><th scope="col"><span className="vh">Remove</span></th></tr></thead>
        <tbody>{rows.map((r, i) => {
          const t = tiers?.[i];
          const amt = t ? Math.round((EXAMPLE_CENTS * t.bps) / 10000) : null;
          return (
            <tr key={i} data-testid={`lt-tier-${i}`}>
              <th scope="row" className="lt-when">{t ? tierRange(t.from_hours, tiers?.[i + 1]?.from_hours ?? null) : 'Check this row'}</th>
              <td data-label="From (hours before)"><label className="vh" htmlFor={`${idp}-f${i}`}>Tier {i + 1}: hours before pickup</label>
                <input className="input lt-in" id={`${idp}-f${i}`} inputMode="numeric" value={r.from} disabled={disabled || i === 0} onChange={(e) => set(i, 'from', e.target.value)} /></td>
              <td data-label="Adjustment (%)"><label className="vh" htmlFor={`${idp}-p${i}`}>Tier {i + 1}: adjustment in percent</label>
                <input className="input lt-in" id={`${idp}-p${i}`} inputMode="decimal" value={r.pct} disabled={disabled} onChange={(e) => set(i, 'pct', e.target.value)} /></td>
              <td className="num lt-eg" data-label={`On a ${money(EXAMPLE_CENTS)} rental`}>{t ? (t.bps === 0 ? 'No change' : `${t.bps > 0 ? '+' : '−'}${money(Math.abs(amt!), { cents: true })} (${pctText(t.bps)})`) : ''}</td>
              <td className="lt-rm">{i > 0 && !disabled && <button type="button" className="btn btn--quiet btn--sm" onClick={() => setRows((x) => x.filter((_, j) => j !== i))}>Remove</button>}</td>
            </tr>
          );
        })}</tbody>
      </table>
      {!disabled && rows.length < MAX_TIERS && <button type="button" className="btn btn--ghost btn--sm" data-testid="lt-add"
        onClick={() => setRows((x) => [...x, { from: String((Number(x[x.length - 1]?.from) || 0) + 24 * 7), pct: '0' }])}>Add a tier</button>}
    </div>
  );
}

/** Settings > Program settings: the tiers, on or off, and bookings billed to an insurer. */
export function LeadTimeSettings({ enabled, insurer, tiers }: { enabled: boolean; insurer: boolean; tiers: Tier[] }) {
  const router = useRouter();
  const idp = useId().replace(/:/g, '');
  const [on, setOn] = useState(enabled);
  const [ins, setIns] = useState(insurer);
  const [rows, setRows] = useState<TierRow[]>(() => toRows(tiers));
  const [msg, setMsg] = useState<{ ok: boolean; text: string } | null>(null);
  const [pending, start] = useTransition();
  function save(e: React.FormEvent) {
    e.preventDefault();
    const p = toTiers(rows);
    if ('error' in p) { setMsg({ ok: false, text: p.error }); return; }
    start(async () => {
      const r = await adminSaveRow('program_settings', { lead_time_enabled: on, lead_time_insurer: ins, lead_time_tiers: p.tiers }, 'current');
      setMsg(r.ok ? { ok: true, text: 'Saved. New quotes and requests use it; bookings already made keep theirs.' } : { ok: false, text: r.message });
      if (r.ok) router.refresh();
    });
  }
  return (
    <form onSubmit={save} className="stack lt" data-testid="lead-time-settings">
      <label className="switch lt-switch"><input type="checkbox" role="switch" checked={on} onChange={(e) => setOn(e.target.checked)} data-testid="lt-on" />
        <span><b>Lead-time pricing is {on ? 'on' : 'off'}</b><span className="small muted lt-sub">A premium for short notice, a little off for booking ahead</span></span></label>
      <p className="small muted">A percentage of the rental charge only, before tax: never the fees, the deposit or add-ons. It is worked out when the quote is made and locked on the request, so the offer and the payment keep it. The car page and the cars list show it once dates are chosen; &quot;From $X a day&quot; stays at the base rate.</p>
      <TierTable rows={rows} setRows={setRows} idp={idp} disabled={!on} />
      <label className="switch lt-switch"><input type="checkbox" role="switch" checked={ins} onChange={(e) => setIns(e.target.checked)} disabled={!on} data-testid="lt-insurer" />
        <span><b>Also adjust bookings billed to an insurer</b><span className="small muted lt-sub">Off: an insurer pays its own rate, never a short-notice premium</span></span></label>
      <p className="small muted">Staff can change it on a booking (More options on the review screen) and a price typed by hand replaces it. A car can turn it off or have its own tiers: Vehicles, the car, Rates.</p>
      <div className="row"><button type="submit" className="btn btn--primary btn--sm" disabled={pending} data-testid="lt-save">{pending ? 'Saving' : 'Save lead-time pricing'}</button>
        {msg && <span className={msg.ok ? 'small' : 'small ad-err'} role="status">{msg.text}</span>}</div>
    </form>
  );
}

/** Vehicles > the car > Rates: Program settings, off for this car, or its own tiers. */
export function CarLeadTime({ vehicleId, mode, tiers, programTiers, programOn }: { vehicleId: string; mode: 'program' | 'off' | 'own'; tiers: Tier[] | null; programTiers: Tier[]; programOn: boolean }) {
  const router = useRouter();
  const idp = useId().replace(/:/g, '');
  const [m, setM] = useState(mode);
  const [rows, setRows] = useState<TierRow[]>(() => toRows(tiers ?? programTiers));
  const [msg, setMsg] = useState<{ ok: boolean; text: string } | null>(null);
  const [pending, start] = useTransition();
  const shown = m === 'own' ? rows : toRows(programTiers);
  function save(e: React.FormEvent) {
    e.preventDefault();
    const p = m === 'own' ? toTiers(rows) : { tiers: null };
    if ('error' in p) { setMsg({ ok: false, text: p.error }); return; }
    start(async () => {
      const r = await adminAct('vehicle_lead_time', { vehicle_id: vehicleId, mode: m, tiers: p.tiers }, [`/admin/vehicles/${vehicleId}`]);
      setMsg(r.ok ? { ok: true, text: 'Saved. New quotes for this car use it.' } : { ok: false, text: r.message });
      if (r.ok) router.refresh();
    });
  }
  return (
    <form onSubmit={save} className="stack lt" data-testid="car-lead-time">
      <fieldset className="seg lt-seg"><legend className="vh">Lead-time pricing for this car</legend>
        {([['program', 'Program settings'], ['off', 'Off for this car'], ['own', 'Its own tiers']] as const).map(([k, l]) => (
          <label key={k}><input type="radio" name={`${idp}-mode`} value={k} checked={m === k} onChange={() => setM(k)} data-testid={`car-lt-${k}`} />{l}</label>))}
      </fieldset>
      {m === 'off' ? <p className="small">This car&apos;s rental charge is never adjusted for short notice or booking ahead.</p>
        : <>{m === 'program' && <p className="small muted">{programOn ? 'The tiers in Program settings, shown here as they are now.' : 'Lead-time pricing is off in Program settings: no car is adjusted.'}</p>}
          <TierTable rows={shown} setRows={setRows} idp={idp} disabled={m !== 'own'} /></>}
      <div className="row"><button type="submit" className="btn btn--primary btn--sm" disabled={pending} data-testid="car-lt-save">{pending ? 'Saving' : 'Save'}</button>
        {msg && <span className={msg.ok ? 'small' : 'small ad-err'} role="status">{msg.text}</span>}</div>
    </form>
  );
}
