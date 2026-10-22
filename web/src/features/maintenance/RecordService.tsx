'use client';
import { useEffect, useId, useMemo, useRef, useState, useTransition } from 'react';
import { useRouter } from 'next/navigation';
import { maintCar, recordService } from '@/server/actions/maintenance';
import { billingWords, hstOf, kmText, preselect, SEASON_LABEL, SEASONS, STATUS_LABEL, STATUS_TONE, type CarMaintenance, type Payer, type Season } from './model';

type Extra = { expires_on?: string; tread_mm?: string; tire_set_id?: string; store_removed_at?: string; new_tires?: boolean; season?: Season; size?: string; brand?: string; made_on?: string };
const today = () => new Date(Date.now() - new Date().getTimezoneOffset() * 60_000).toISOString().slice(0, 10);
const dollars = (cents: number) => (cents / 100).toFixed(2);
const cents = (s: string) => { const n = Number(s.replace(/[$,\s]/g, '')); return Number.isFinite(n) && s.trim() !== '' ? Math.round(n * 100) : null; };

/**
 * Record a service in one step (migration 0089): what was done, the date and odometer, the shop, the cost and HST, who
 * pays, whether the bill is in, the receipt. Saving makes the bill (company expense, owner cost on the statement, claim
 * cost or renter charge) and resets each item's timer. Opens from the car's Maintenance tab (with the car's data), from
 * the fleet overview and a To do prompt (it loads the car when opened).
 */
export function RecordService({ vehicleId, car: given, label = 'Record a service', only, variant = 'primary', testId = 'record-service', autoOpen = false }: {
  vehicleId: string; car?: CarMaintenance | null; label?: string; only?: string[]; variant?: 'primary' | 'ghost'; testId?: string; autoOpen?: boolean;
}) {
  const router = useRouter();
  const idp = useId().replace(/:/g, '');
  const dlg = useRef<HTMLDialogElement>(null);
  const file = useRef<HTMLInputElement>(null);
  const [car, setCar] = useState<CarMaintenance | null>(given ?? null);
  const [pending, start] = useTransition();
  const [err, setErr] = useState<string | null>(null);
  const [done, setDone] = useState<string | null>(null);
  const [shown, setShown] = useState(false);
  const [picked, setPicked] = useState<string[]>([]);
  const [extra, setExtra] = useState<Record<string, Extra>>({});
  const [f, setF] = useState(() => ({ done_on: today(), odometer: '', shop: '', cost: '', hst: '', hstTouched: false, payer: '' as Payer | '', billed: true, claim_id: '', booking_id: '', notes: '' }));

  const begin = (c: CarMaintenance) => {
    setCar(c);
    setPicked(preselect(c.items.filter((i) => i.active), only));
    setExtra({});
    setF({ done_on: c.today, odometer: c.current_km ? String(c.current_km) : '', shop: '', cost: '', hst: '', hstTouched: false, payer: c.default_payer, billed: true, claim_id: '', booking_id: '', notes: '' });
    setErr(null); setDone(null);
    if (file.current) file.current.value = '';
    setShown(true);
  };
  const open = () => {
    if (given ?? car) { begin((given ?? car)!); dlg.current?.showModal(); return; }
    start(async () => {
      const r = await maintCar(vehicleId);
      if (!r.ok) { setErr(r.message); return; }
      begin(r.data); dlg.current?.showModal();
    });
  };
  // opened from a To do prompt or a task link (?record=<car>): the pop-up opens with the page
  useEffect(() => {
    if (!autoOpen) return;
    const t = setTimeout(open, 0);
    return () => clearTimeout(t);
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [autoOpen]);

  const costC = cents(f.cost) ?? 0;
  const hstC = f.hstTouched ? cents(f.hst) ?? 0 : hstOf(costC, car?.hst_bps ?? 1300);
  const total = costC + hstC;
  const items = useMemo(() => (car?.items ?? []).filter((i) => i.active), [car]);
  const kinds = new Set(items.filter((i) => picked.includes(i.code)).map((i) => i.kind));
  const otherSets = (car?.tire_sets ?? []).filter((t) => !t.on_car && !t.retired_on);
  const ex = (code: string) => extra[code] ?? {};
  const setEx = (code: string, v: Extra) => setExtra((s) => ({ ...s, [code]: { ...s[code], ...v } }));
  const toggle = (code: string, on: boolean) => setPicked((p) => (on ? [...p, code] : p.filter((x) => x !== code)));

  const submit = () => {
    if (!car) return;
    if (!picked.length) { setErr('Tick what was done (at least one item).'); return; }
    const payload = {
      vehicle_id: car.vehicle_id, done_on: f.done_on, odometer_km: f.odometer ? Number(f.odometer.replace(/\D/g, '')) : null, shop: f.shop, notes: f.notes,
      cost_cents: costC, hst_cents: hstC, payer: f.payer || car.default_payer, billed: f.billed,
      claim_id: f.payer === 'claim' ? f.claim_id : null, booking_id: f.payer === 'renter' ? f.booking_id : null,
      items: picked.map((code) => {
        const it = items.find((i) => i.code === code)!; const e = ex(code);
        return {
          code,
          expires_on: it.kind === 'expiry' ? e.expires_on || null : null,
          tread_mm: it.kind === 'tires' && !e.new_tires ? e.tread_mm || null : null,
          tire_set_id: it.kind === 'seasonal' ? e.tire_set_id || null : null,
          store_removed_at: it.kind === 'seasonal' ? e.store_removed_at || null : null,
          new_set: it.kind === 'tires' && e.new_tires ? { season: e.season ?? 'all_season', size: e.size ?? '', brand: e.brand ?? '', tread_mm: e.tread_mm ?? '', made_on: e.made_on ?? '' } : undefined
        };
      })
    };
    const fd = new FormData();
    fd.set('p', JSON.stringify(payload));
    const fl = file.current?.files?.[0];
    if (fl) fd.set('receipt', fl);
    start(async () => {
      const r = await recordService(fd);
      if (!r.ok) { setErr(r.message); return; }
      setDone(r.data.billing_status === 'needs_admin' ? 'Recorded. An Admin bills it (above your single limit).' : 'Recorded. The timers are reset.');
      dlg.current?.close();
      router.refresh();
    });
  };

  const cls = `btn btn--sm ${variant === 'primary' ? 'btn--primary' : 'btn--ghost'}`;
  return (
    <>
      <button className={cls} type="button" onClick={open} disabled={pending} data-testid={testId} aria-haspopup="dialog">{pending && !car ? 'Opening' : label}</button>
      {done && <span className="small" role="status" data-testid={`${testId}-done`}>{done}</span>}
      {!car && err && <span className="ad-err" role="alert">{err}</span>}
      <dialog ref={dlg} className="ad-dialog mt-dialog" aria-labelledby={`${idp}-t`} data-testid={`${testId}-dialog`} onClose={() => setShown(false)}>
        <h2 className="d4" id={`${idp}-t`}>Record a service{car ? `: ${car.name}${car.plate ? ` ${car.plate}` : ''}` : ''}</h2>
        {car && shown && (
          <form className="ad-form" noValidate onSubmit={(e) => { e.preventDefault(); submit(); }} data-testid={`${testId}-form`}>
            <fieldset className="mt-items">
              <legend className="label">What was done</legend>
              <ul className="mt-picks">{items.map((i) => (
                <li key={i.code}>
                  <label className="check" htmlFor={`${idp}-${i.code}`}>
                    <input id={`${idp}-${i.code}`} type="checkbox" checked={picked.includes(i.code)} onChange={(e) => toggle(i.code, e.target.checked)} data-item={i.code} />
                    <span>{i.label} <span className={`ad-b ${STATUS_TONE[i.status]}`}>{STATUS_LABEL[i.status]}</span></span>
                  </label>
                  {picked.includes(i.code) && i.kind === 'expiry' && (
                    <div className="field mt-sub"><label className="label" htmlFor={`${idp}-${i.code}-x`}>New expiry date</label>
                      <input className="input" id={`${idp}-${i.code}-x`} type="date" value={ex(i.code).expires_on ?? ''} onChange={(e) => setEx(i.code, { expires_on: e.target.value })} aria-describedby={`${idp}-${i.code}-xh`} />
                      <p className="hint" id={`${idp}-${i.code}-xh`}>Empty: {i.interval_months ?? 12} months from the service date.</p></div>
                  )}
                  {picked.includes(i.code) && i.kind === 'tires' && (
                    <div className="mt-sub">
                      <label className="check" htmlFor={`${idp}-nt`}><input id={`${idp}-nt`} type="checkbox" checked={Boolean(ex(i.code).new_tires)} onChange={(e) => setEx(i.code, { new_tires: e.target.checked })} /> <span>New tires put on (the old set is retired)</span></label>
                      {ex(i.code).new_tires ? (
                        <div className="ad-fields">
                          <div className="field"><label className="label" htmlFor={`${idp}-ns`}>Kind</label>
                            <select className="select" id={`${idp}-ns`} value={ex(i.code).season ?? 'all_season'} onChange={(e) => setEx(i.code, { season: e.target.value as Season })}>{SEASONS.map(([v, l]) => <option key={v} value={v}>{l}</option>)}</select></div>
                          <div className="field"><label className="label" htmlFor={`${idp}-nz`}>Size</label><input className="input" id={`${idp}-nz`} value={ex(i.code).size ?? ''} placeholder="225/45R17" onChange={(e) => setEx(i.code, { size: e.target.value })} /></div>
                          <div className="field"><label className="label" htmlFor={`${idp}-nb`}>Brand and model</label><input className="input" id={`${idp}-nb`} value={ex(i.code).brand ?? ''} onChange={(e) => setEx(i.code, { brand: e.target.value })} /></div>
                          <div className="field"><label className="label" htmlFor={`${idp}-nt2`}>Tread depth (mm)</label><input className="input" id={`${idp}-nt2`} inputMode="decimal" value={ex(i.code).tread_mm ?? ''} onChange={(e) => setEx(i.code, { tread_mm: e.target.value })} /></div>
                          <div className="field"><label className="label" htmlFor={`${idp}-nm`}>Made (DOT date)</label><input className="input" id={`${idp}-nm`} type="date" value={ex(i.code).made_on ?? ''} onChange={(e) => setEx(i.code, { made_on: e.target.value })} /></div>
                        </div>
                      ) : (
                        <div className="field"><label className="label" htmlFor={`${idp}-tr`}>Tread depth measured (mm)</label><input className="input" id={`${idp}-tr`} inputMode="decimal" value={ex(i.code).tread_mm ?? ''} onChange={(e) => setEx(i.code, { tread_mm: e.target.value })} /></div>
                      )}
                    </div>
                  )}
                  {picked.includes(i.code) && i.kind === 'seasonal' && (
                    <div className="ad-fields mt-sub">
                      <div className="field"><label className="label" htmlFor={`${idp}-sw`}>Set that went on</label>
                        <select className="select" id={`${idp}-sw`} value={ex(i.code).tire_set_id ?? ''} onChange={(e) => setEx(i.code, { tire_set_id: e.target.value })} aria-describedby={`${idp}-swh`}>
                          <option value="">{otherSets.length ? 'Choose the set' : 'No other set on file'}</option>
                          {otherSets.map((t) => <option key={t.id} value={t.id}>{SEASON_LABEL[t.season]}{t.brand ? `, ${t.brand}` : ''}{t.storage_location ? ` (from ${t.storage_location})` : ''}</option>)}
                        </select>
                        <p className="hint" id={`${idp}-swh`}>Add a set under Tires first if it is not listed.</p></div>
                      <div className="field"><label className="label" htmlFor={`${idp}-st`}>Where the removed set is stored</label><input className="input" id={`${idp}-st`} value={ex(i.code).store_removed_at ?? ''} onChange={(e) => setEx(i.code, { store_removed_at: e.target.value })} /></div>
                    </div>
                  )}
                </li>))}
              </ul>
            </fieldset>
            <div className="ad-fields">
              <div className="field"><label className="label" htmlFor={`${idp}-d`}>Date done</label><input className="input" id={`${idp}-d`} type="date" required max={car.today} value={f.done_on} onChange={(e) => setF({ ...f, done_on: e.target.value })} /></div>
              <div className="field"><label className="label" htmlFor={`${idp}-km`}>Odometer (km)</label><input className="input" id={`${idp}-km`} inputMode="numeric" value={f.odometer} onChange={(e) => setF({ ...f, odometer: e.target.value.replace(/[^\d]/g, '') })} aria-describedby={`${idp}-kmh`} data-testid={`${testId}-km`} />
                <p className="hint" id={`${idp}-kmh`}>Now about {kmText(car.current_km) || 'unknown'}. Empty: the reading of that day.</p></div>
              <div className="field"><label className="label" htmlFor={`${idp}-shop`}>Shop</label><input className="input" id={`${idp}-shop`} value={f.shop} onChange={(e) => setF({ ...f, shop: e.target.value })} data-testid={`${testId}-shop`} /></div>
              <div className="field"><label className="label" htmlFor={`${idp}-c`}>Cost before HST ($)</label><input className="input" id={`${idp}-c`} inputMode="decimal" value={f.cost} onChange={(e) => setF({ ...f, cost: e.target.value })} data-testid={`${testId}-cost`} /></div>
              <div className="field"><label className="label" htmlFor={`${idp}-h`}>HST ($)</label><input className="input" id={`${idp}-h`} inputMode="decimal" value={f.hstTouched ? f.hst : costC ? dollars(hstC) : ''} onChange={(e) => setF({ ...f, hst: e.target.value, hstTouched: true })} aria-describedby={`${idp}-hh`} />
                <p className="hint" id={`${idp}-hh`}>Worked out at {(car.hst_bps / 100).toFixed(0)}%; change it to match the receipt.</p></div>
              <div className="field"><label className="label" htmlFor={`${idp}-p`}>Who pays</label>
                <select className="select" id={`${idp}-p`} value={f.payer || car.default_payer} onChange={(e) => setF({ ...f, payer: e.target.value as Payer })} data-testid={`${testId}-payer`}>
                  {car.payers.map(([v, l]) => <option key={v} value={v}>{l}</option>)}
                </select></div>
              {(f.payer || car.default_payer) === 'claim' && <div className="field"><label className="label" htmlFor={`${idp}-cl`}>Claim</label>
                <select className="select" id={`${idp}-cl`} value={f.claim_id} onChange={(e) => setF({ ...f, claim_id: e.target.value })} required>
                  <option value="">{car.claims.length ? 'Choose the claim' : 'No open claim on this car'}</option>
                  {car.claims.map((c) => <option key={c.id} value={c.id}>{c.claim_number} ({c.status.replace(/_/g, ' ')})</option>)}
                </select></div>}
              {(f.payer || car.default_payer) === 'renter' && <div className="field"><label className="label" htmlFor={`${idp}-bk`}>Rental</label>
                <select className="select" id={`${idp}-bk`} value={f.booking_id} onChange={(e) => setF({ ...f, booking_id: e.target.value })} required>
                  <option value="">{car.bookings.length ? 'Choose the rental' : 'No rental of this car yet'}</option>
                  {car.bookings.map((b) => <option key={b.id} value={b.id}>{b.booking_number}, {b.pickup_at.slice(0, 10)} to {b.return_at.slice(0, 10)}</option>)}
                </select></div>}
              <div className="field ad-field--wide"><label className="check" htmlFor={`${idp}-b`}><input id={`${idp}-b`} type="checkbox" checked={f.billed} onChange={(e) => setF({ ...f, billed: e.target.checked })} data-testid={`${testId}-billed`} /> <span>The bill is in: bill it now</span></label></div>
              <div className="field ad-field--wide"><label className="label" htmlFor={`${idp}-r`}>Receipt (PDF or photo)</label><input className="input" id={`${idp}-r`} type="file" accept="application/pdf,image/jpeg,image/png" ref={file} /></div>
              <div className="field ad-field--wide"><label className="label" htmlFor={`${idp}-n`}>Notes</label><textarea className="input ad-textarea" id={`${idp}-n`} rows={2} value={f.notes} onChange={(e) => setF({ ...f, notes: e.target.value })} /></div>
            </div>
            <p className="small mt-summary" data-testid={`${testId}-summary`}>{billingWords((f.payer || car.default_payer) as Payer, f.billed, total, car.limit_cents, car.supply_type)}
              {total > 0 && <> Total <b className="num">${dollars(total)}</b>.</>}{kinds.has('seasonal') || kinds.has('tires') ? ' The tire set on the car is updated.' : ''}</p>
            {err && <p className="alert alert--error" role="alert"><span>{err}</span></p>}
            <div className="row">
              <button className="btn btn--primary btn--sm" type="submit" disabled={pending} data-testid={`${testId}-submit`}>{pending ? 'Saving' : 'Record the service'}</button>
              <button className="btn btn--ghost btn--sm" type="button" onClick={() => dlg.current?.close()}>Cancel</button>
            </div>
          </form>
        )}
      </dialog>
    </>
  );
}
