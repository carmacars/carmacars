'use client';
import { useId, useRef, useState, useTransition } from 'react';
import { useRouter } from 'next/navigation';
import { deleteSampleCars, deleteVehicle } from '@/server/actions/supply';

// Deleting a car (migration 0046): only a car with nothing tied to money; the Admin types the plate (or the car's
// name) to confirm. Its photo files go from storage too. Anything else is retired instead.
export type Removed = { booking_number: string; status: string; text: string };
// Deleting a car (0064): booking requests that never confirmed and never took money go with the car (kept in the
// archive of deleted requests); the renters stay. A confirmed, paid or signed booking still stops the delete.
export function DeleteCar({ vehicleId, name, plate, blockers, removes = [] }: { vehicleId: string; name: string; plate: string | null; blockers: string[]; removes?: Removed[] }) {
  const router = useRouter();
  const dlg = useRef<HTMLDialogElement>(null);
  const id = useId().replace(/:/g, '');
  const [typed, setTyped] = useState('');
  const [err, setErr] = useState<string | null>(null);
  const [pending, start] = useTransition();
  if (blockers.length) {
    return <p className="small muted" data-testid="delete-blocked">Delete is not possible: this car has {blockers.join(', ')}. Retire it instead; its history stays.{removes.length ? ` Requests that never confirmed (${removes.map((r) => r.booking_number).join(', ')}) do not stop a delete.` : ''}</p>;
  }
  return (
    <>
      <button className="btn btn--sm btn--primary ad-btn--danger" type="button" data-testid="vehicle-delete" aria-haspopup="dialog" onClick={() => { setErr(null); dlg.current?.showModal(); }}>Delete this car</button>
      <dialog ref={dlg} className="ad-dialog" aria-labelledby={`${id}-t`}>
        <h2 className="d4" id={`${id}-t`}>Delete {name}</h2>
        <form className="ad-form" noValidate onSubmit={(e) => {
          e.preventDefault();
          start(async () => {
            const r = await deleteVehicle(vehicleId, typed);
            if (!r.ok) { setErr(r.message); return; }
            dlg.current?.close();
            router.push('/admin/vehicles?deleted=1');
          });
        }}>
          <p className="small">The car, its listing, rates, photos and calendar blocks are deleted for good. Nothing about money is tied to it. This cannot be undone.</p>
          {removes.length > 0 && <div className="small" data-testid="vehicle-delete-removes"><p>These booking requests never confirmed and never took money. They are removed with the car (a copy is kept in the archive of deleted requests); the renters stay on file:</p>
            <ul>{removes.map((r) => <li key={r.booking_number}>{r.text}</li>)}</ul></div>}
          <div className="field"><label className="label" htmlFor={`${id}-c`}>Type the plate{plate ? ` (${plate})` : ''} or the name ({name}) to confirm</label>
            <input className="input" id={`${id}-c`} value={typed} onChange={(e) => setTyped(e.target.value)} autoComplete="off" data-testid="vehicle-delete-confirm" /></div>
          {err && <p className="alert alert--error" role="alert"><span>{err}</span></p>}
          <div className="row">
            <button className="btn btn--sm btn--primary ad-btn--danger" type="submit" disabled={pending || !typed.trim()} data-testid="vehicle-delete-submit">{pending ? 'Deleting' : 'Delete for good'}</button>
            <button className="btn btn--ghost btn--sm" type="button" onClick={() => dlg.current?.close()}>Cancel</button>
          </div>
        </form>
      </dialog>
    </>
  );
}

export function DeleteSampleCars({ count }: { count: number }) {
  const router = useRouter();
  const [typed, setTyped] = useState('');
  const [res, setRes] = useState<{ ok: boolean; text: string; kept?: Array<{ name: string; why: string }> } | null>(null);
  const [pending, start] = useTransition();
  return (
    <form className="ad-form" noValidate data-testid="delete-samples" onSubmit={(e) => {
      e.preventDefault();
      start(async () => {
        const r = await deleteSampleCars(typed);
        if (!r.ok) { setRes({ ok: false, text: r.message }); return; }
        const n = r.data.requests_removed?.length ?? 0;
        setRes({ ok: true, text: `${r.data.deleted} sample car${r.data.deleted === 1 ? '' : 's'} deleted, ${r.data.files} photo file${r.data.files === 1 ? '' : 's'} removed${n ? `, ${n} booking request${n === 1 ? '' : 's'} that never confirmed removed with them` : ''}.`, kept: r.data.kept });
        router.refresh();
      });
    }}>
      <p className="small">Deletes each of the {count} sample cars that has nothing tied to money (no confirmed or paid booking, payment, issued invoice, statement or stored document). Booking requests that never confirmed and never took money go with their car; the renters stay. A sample car with any of the others stays, with the reason.</p>
      <div className="field"><label className="label" htmlFor="ds-confirm">Type DELETE SAMPLE CARS to confirm</label>
        <input className="input" id="ds-confirm" value={typed} onChange={(e) => setTyped(e.target.value)} autoComplete="off" data-testid="delete-samples-confirm" /></div>
      {res && <p className={`alert ${res.ok ? 'alert--ok' : 'alert--error'}`} role={res.ok ? 'status' : 'alert'}><span>{res.text}</span></p>}
      {res?.kept?.length ? <ul className="small" data-testid="delete-samples-kept">{res.kept.map((k) => <li key={k.name}>{k.name}: kept ({k.why})</li>)}</ul> : null}
      <div className="row"><button className="btn btn--sm btn--primary ad-btn--danger" type="submit" disabled={pending || !typed.trim()} data-testid="delete-samples-submit">{pending ? 'Deleting' : 'Delete all sample cars'}</button></div>
    </form>
  );
}
