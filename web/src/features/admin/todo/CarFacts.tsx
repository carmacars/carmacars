'use client';
import { useState, useTransition } from 'react';
import { useRouter } from 'next/navigation';
import { opsAct } from '@/server/actions/ops';
import { GEARBOXES } from '@/features/vin/vin';
import { Pop } from './Pop';
import type { Prompt } from './types';

// Admin > Today (migration 0094): a car whose VIN fits several trims, and a car whose gearbox or seats nobody confirmed.
// One step each: press the trim, or the gearbox and the seats. The car's title, description and search text are made
// again, and the line is gone.
function useSave() {
  const router = useRouter();
  const [pending, start] = useTransition();
  const [err, setErr] = useState<string | null>(null);
  const save = (action: string, payload: Record<string, unknown>) => start(async () => {
    setErr(null);
    const r = await opsAct(action, payload, ['/admin']);
    if (!r.ok) { setErr(r.message); return; }
    router.refresh();
  });
  return { pending, err, save };
}

export function TrimPick({ p, testId }: { p: Prompt; testId: string }) {
  const { pending, err, save } = useSave();
  return (
    <Pop label="Pick the trim" title={p.title} testId={testId}>
      <p className="small">The VIN fits each of these. Press the one on the car&apos;s papers or its badge.</p>
      <div className="row" role="group" aria-label="Trims">
        {(p.candidates ?? []).map((t) => <button key={t} type="button" className="btn btn--sm btn--primary" disabled={pending}
          onClick={() => save('vehicle_pick_trim', { vehicle_id: p.vehicle_id, trim: t })} data-testid={`${testId}-pick`}>{t}</button>)}
        <button type="button" className="btn btn--sm btn--ghost" disabled={pending} onClick={() => save('vehicle_pick_trim', { vehicle_id: p.vehicle_id, trim: null })}
          data-testid={`${testId}-none`}>None of these</button>
      </div>
      {err && <p className="error" role="alert">{err}</p>}
    </Pop>
  );
}

const SEATS = [2, 4, 5, 6, 7, 8, 9];
export function SpecsConfirm({ p, testId }: { p: Prompt; testId: string }) {
  const { pending, err, save } = useSave();
  const [gear, setGear] = useState<string | null>(GEARBOXES.find((g) => g === p.transmission) ?? null);
  const [seats, setSeats] = useState<number | null>(p.seats ?? null);
  return (
    <Pop label="Confirm" title={p.title} testId={testId}>
      <p className="small">Check the car or its papers. The listing shows these to renters.</p>
      <fieldset className="field"><legend className="label">Gearbox</legend>
        <div className="row">{GEARBOXES.map((g) => <button key={g} type="button" aria-pressed={gear === g} className={`btn btn--sm ${gear === g ? 'btn--primary' : 'btn--ghost'}`}
          onClick={() => setGear(g)} data-testid={`${testId}-gear`}>{g}</button>)}</div></fieldset>
      <fieldset className="field"><legend className="label">Seats{p.seats_default ? ' (the usual number for its body: check it)' : ''}</legend>
        <div className="row">{SEATS.map((n) => <button key={n} type="button" aria-pressed={seats === n} className={`btn btn--sm ${seats === n ? 'btn--primary' : 'btn--ghost'}`}
          onClick={() => setSeats(n)} data-testid={`${testId}-seats`}>{n}</button>)}</div></fieldset>
      <p><button type="button" className="btn btn--primary" disabled={pending || !gear || !seats} onClick={() => save('vehicle_confirm_specs', { vehicle_id: p.vehicle_id, transmission: gear, seats })}
        data-testid={`${testId}-save`}>{pending ? 'Saving' : 'Save'}</button></p>
      {err && <p className="error" role="alert">{err}</p>}
    </Pop>
  );
}
