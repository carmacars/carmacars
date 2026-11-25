'use client';
import { useId, useState, useTransition } from 'react';
import { useRouter } from 'next/navigation';
import { ownerStageAct } from '@/server/actions/owner-stages';
import { instantOfTorontoInput } from '@/lib/dates';

// The owner pipeline (r50, 4511): the owner's two records on the Ownership transfer stage. "I booked it" (the
// ServiceOntario appointment: when and which centre) and "Transfer done" (the fees paid by whoever the terms say).
export function AppointmentForm({ vehicleId, finderUrl }: { vehicleId: string; finderUrl: string }) {
  const id = useId();
  const router = useRouter();
  const [open, setOpen] = useState(false);
  const [at, setAt] = useState('');
  const [place, setPlace] = useState('');
  const [error, setError] = useState('');
  const [pending, start] = useTransition();
  const save = () => start(async () => {
    setError('');
    const when = instantOfTorontoInput(at);
    if (!when) { setError('Enter the date and time of the appointment.'); return; }
    if (!place.trim()) { setError('Which ServiceOntario centre? Its name or address.'); return; }
    const r = await ownerStageAct(vehicleId, { op: 'appointment', at: when, place: place.trim() });
    if (!r.ok) { setError(r.message); return; }
    setOpen(false); router.refresh();
  });
  return (
    <div className="os-form stack" data-testid="os-appointment" data-guide="os-appointment">
      <div className="os-actions">
        <a className="btn btn--primary" href={finderUrl} target="_blank" rel="noopener noreferrer" data-testid="os-finder">Find a ServiceOntario centre</a>
        <button type="button" className="btn btn--ghost" onClick={() => setOpen((x) => !x)} aria-expanded={open} aria-controls={`${id}-f`} data-testid="os-booked-open">I booked it</button>
      </div>
      {open && <div id={`${id}-f`} className="os-fields">
        <div className="field"><label className="label" htmlFor={`${id}-at`}>Date and time</label>
          <input id={`${id}-at`} className="input" type="datetime-local" value={at} onChange={(e) => setAt(e.target.value)} data-testid="os-at" /></div>
        <div className="field"><label className="label" htmlFor={`${id}-pl`}>ServiceOntario centre</label>
          <input id={`${id}-pl`} className="input" type="text" value={place} onChange={(e) => setPlace(e.target.value)} maxLength={200} placeholder="Its name or address" data-testid="os-place" /></div>
        <p><button type="button" className="btn btn--primary" onClick={save} disabled={pending} data-testid="os-save">{pending ? 'Saving' : 'Save my appointment'}</button></p>
      </div>}
      <p className="error" role="alert">{error}</p>
    </div>
  );
}

export function VisitedForm({ vehicleId, payer }: { vehicleId: string; payer: string }) {
  const router = useRouter();
  const [paid, setPaid] = useState(false);
  const [error, setError] = useState('');
  const [pending, start] = useTransition();
  const save = () => start(async () => {
    setError('');
    if (!paid) { setError('Tick that the registry fees are paid.'); return; }
    const r = await ownerStageAct(vehicleId, { op: 'visited', fees_paid: true });
    if (!r.ok) { setError(r.message); return; }
    router.refresh();
  });
  return (
    <div className="os-form stack" data-testid="os-visited" data-guide="os-visited">
      <label className="os-check"><input type="checkbox" checked={paid} onChange={(e) => setPaid(e.target.checked)} data-testid="os-fees" /> <span>The fees are paid. {payer}.</span></label>
      <p><button type="button" className="btn btn--primary" onClick={save} disabled={pending} data-testid="os-visited-save">{pending ? 'Saving' : 'Transfer done'}</button></p>
      <p className="error" role="alert">{error}</p>
    </div>
  );
}
