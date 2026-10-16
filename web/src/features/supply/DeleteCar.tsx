'use client';
import { useId, useRef, useState, useTransition } from 'react';
import { useRouter } from 'next/navigation';
import { deleteSampleCars, deleteVehicle } from '@/server/actions/supply';

// Deleting a car (migration 0046): only a car with nothing tied to money; the Admin types the plate (or the car's
// name) to confirm. Its photo files go from storage too. Anything else is retired instead.
export function DeleteCar({ vehicleId, name, plate, blockers }: { vehicleId: string; name: string; plate: string | null; blockers: string[] }) {
  const router = useRouter();
  const dlg = useRef<HTMLDialogElement>(null);
  const id = useId().replace(/:/g, '');
  const [typed, setTyped] = useState('');
  const [err, setErr] = useState<string | null>(null);
  const [pending, start] = useTransition();
  if (blockers.length) {
    return <p className="small muted" data-testid="delete-blocked">Delete is not possible: this car has {blockers.join(', ')}. Retire it instead; its history stays.</p>;
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
        setRes({ ok: true, text: `${r.data.deleted} sample car${r.data.deleted === 1 ? '' : 's'} deleted, ${r.data.files} photo file${r.data.files === 1 ? '' : 's'} removed.`, kept: r.data.kept });
        router.refresh();
      });
    }}>
      <p className="small">Deletes each of the {count} sample cars that has nothing tied to money (no booking, payment, issued invoice, statement or stored document). A sample car with any of those stays, with the reason.</p>
      <div className="field"><label className="label" htmlFor="ds-confirm">Type DELETE SAMPLE CARS to confirm</label>
        <input className="input" id="ds-confirm" value={typed} onChange={(e) => setTyped(e.target.value)} autoComplete="off" data-testid="delete-samples-confirm" /></div>
      {res && <p className={`alert ${res.ok ? 'alert--ok' : 'alert--error'}`} role={res.ok ? 'status' : 'alert'}><span>{res.text}</span></p>}
      {res?.kept?.length ? <ul className="small" data-testid="delete-samples-kept">{res.kept.map((k) => <li key={k.name}>{k.name}: kept ({k.why})</li>)}</ul> : null}
      <div className="row"><button className="btn btn--sm btn--primary ad-btn--danger" type="submit" disabled={pending || !typed.trim()} data-testid="delete-samples-submit">{pending ? 'Deleting' : 'Delete all sample cars'}</button></div>
    </form>
  );
}
