'use client';
import { useId, useRef, useState, useTransition } from 'react';
import { useRouter } from 'next/navigation';
import { Act } from '@/features/admin/Act';
import { guidedAct } from '@/server/actions/guided';

// Insurer confirmed (migration 0078): the car goes on the fleet insurance policy from the date of the insurer's written
// confirmation. Its onboarding moves past the insurer step, the Enrollment Date is set and the owner gets the enrollment
// notice; the paperwork stays on the checklist. One car (the car's page, a To do prompt) or several (one insurer email).
const today = () => new Intl.DateTimeFormat('en-CA', { timeZone: 'America/Toronto', year: 'numeric', month: '2-digit', day: '2-digit' }).format(new Date());
const WHAT = 'From this date the car is on the fleet policy: it can be handed over, its Enrollment Date is this date and the owner gets the enrollment notice. Its paperwork stays on its checklist.';

export function InsurerConfirm({ vehicleId, name, refresh = [], label = 'Mark insured', variant = 'primary', testId = 'insurer-confirm' }: {
  vehicleId: string; name: string; refresh?: string[]; label?: string; variant?: 'primary' | 'ghost'; testId?: string;
}) {
  return (
    <Act ops action="insurer_confirm" payload={{ vehicle_id: vehicleId }} label={label} variant={variant} title={`Insurer confirmed: ${name}`} confirm={WHAT}
      submitLabel="Insurer confirmed" refresh={['/admin', ...refresh]} testId={testId} done="On the fleet policy."
      fields={[{ name: 'on', label: 'Date the insurer confirmed it', type: 'date', required: true, value: today() },
        { name: 'note', label: 'Reference (optional)', type: 'text', hint: 'The insurer’s email subject or policy change number, for the record.' }]} />
  );
}

export function InsurerBulk({ cars, refresh = [] }: { cars: Array<{ vehicle_id: string; name: string; plate: string | null }>; refresh?: string[] }) {
  const router = useRouter();
  const dlg = useRef<HTMLDialogElement>(null);
  const idp = useId().replace(/[^\w-]/g, '');
  const [ticked, setTicked] = useState<string[]>(() => cars.map((c) => c.vehicle_id));
  const [on, setOn] = useState(today);
  const [note, setNote] = useState('');
  const [msg, setMsg] = useState<{ ok: boolean; text: string } | null>(null);
  const [pending, start] = useTransition();
  const submit = () => start(async () => {
    setMsg(null);
    const r = await guidedAct<{ count: number; failed: Array<{ name: string; error: string }> }>('insurer_confirm_bulk', { vehicle_ids: ticked, on, note: note || null }, refresh);
    if (!r.ok) { setMsg({ ok: false, text: r.message }); return; }
    if (r.data.failed.length) { setMsg({ ok: false, text: `${r.data.count} marked insured. Not marked: ${r.data.failed.map((f) => `${f.name} (${f.error})`).join('; ')}` }); router.refresh(); return; }
    dlg.current?.close();
    router.refresh();
  });
  return (
    <>
      <button className="btn btn--primary btn--sm" type="button" aria-haspopup="dialog" data-testid="insurer-bulk" onClick={() => { setMsg(null); dlg.current?.showModal(); }}>Mark several insured</button>
      <dialog ref={dlg} className="ad-dialog" aria-labelledby={`${idp}-t`} data-testid="insurer-bulk-dialog">
        <h2 className="d4" id={`${idp}-t`}>Insurer confirmed: several cars</h2>
        <form className="ad-form" noValidate onSubmit={(e) => { e.preventDefault(); submit(); }}>
          <p className="small">{WHAT} Untick a car the insurer did not name.</p>
          <fieldset className="gd-cars"><legend className="pt-kicker">Cars the insurer confirmed ({ticked.length} of {cars.length})</legend>
            {cars.map((c) => (
              <label key={c.vehicle_id} className="check"><input type="checkbox" checked={ticked.includes(c.vehicle_id)} data-testid={`insurer-bulk-car-${c.vehicle_id}`}
                onChange={(e) => setTicked((s) => (e.target.checked ? [...s, c.vehicle_id] : s.filter((x) => x !== c.vehicle_id)))} /> <span>{c.name}{c.plate ? ` (${c.plate})` : ''}</span></label>))}
          </fieldset>
          <div className="ad-fields">
            <div className="field ad-field"><label className="label" htmlFor={`${idp}-on`}>Date the insurer confirmed them</label>
              <input className="input" id={`${idp}-on`} type="date" value={on} max={today()} onChange={(e) => setOn(e.target.value)} required /></div>
            <div className="field ad-field"><label className="label" htmlFor={`${idp}-note`}>Reference (optional)</label>
              <input className="input" id={`${idp}-note`} value={note} onChange={(e) => setNote(e.target.value)} /></div>
          </div>
          {msg && <p className={`alert ${msg.ok ? 'alert--ok' : 'alert--error'}`} role="alert"><span>{msg.text}</span></p>}
          <div className="row">
            <button className="btn btn--primary btn--sm" type="submit" disabled={pending || ticked.length === 0} data-testid="insurer-bulk-submit">{pending ? 'Working' : `Insurer confirmed ${ticked.length} car${ticked.length === 1 ? '' : 's'}`}</button>
            <button className="btn btn--ghost btn--sm" type="button" onClick={() => dlg.current?.close()}>Cancel</button>
          </div>
        </form>
      </dialog>
    </>
  );
}
