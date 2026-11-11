'use client';
import { useState, useTransition } from 'react';
import { useRouter } from 'next/navigation';
import { fieldAct } from '@/server/actions/field';
import { fieldWork, type FieldFileAction } from '@/server/actions/field-work';
import { preparePhoto } from '@/features/field/queue';
import { DateInput } from '@/components/DateInput';
import { FdIcon } from '@/features/field/icons';
import { CAR_UPDATES, type Addon, type Card } from './model';

// The steps opened on a card (r35 part X): the clean check (tick and photo), the add-ons ticked as in the car, an update on a car
// needing service, the prep items with their uploads, and the listing photos in spare time. The database decides each again.

export function useRun() {
  const router = useRouter();
  const [pending, start] = useTransition();
  const [msg, setMsg] = useState<{ ok: boolean; text: string } | null>(null);
  const run = (f: () => Promise<{ ok: boolean; message?: string }>, done: string, after?: () => void) => start(async () => {
    setMsg(null);
    let r: { ok: boolean; message?: string };
    try { r = await f(); } catch { r = { ok: false, message: 'No connection. Nothing was saved: try again when you have signal.' }; }
    if (!r.ok) { setMsg({ ok: false, text: r.message ?? 'Not saved.' }); return; }
    setMsg({ ok: true, text: done });
    after?.();
    router.refresh();
  });
  return { pending, msg, run, setMsg };
}
export function Msg({ m }: { m: { ok: boolean; text: string } | null }) {
  return m ? <p className={m.ok ? 'fp-done' : 'error'} role={m.ok ? 'status' : 'alert'}>{m.ok && <FdIcon name="check" />}{m.text}</p> : null;
}

/** A photo or a PDF: a big tap area that opens the camera (photos are shrunk on the phone first). */
export function PhotoPick({ file, set, label = 'Take the photo', pdf = false, testId }: { file: File | null; set: (f: File | null) => void; label?: string; pdf?: boolean; testId?: string }) {
  const [busy, setBusy] = useState(false);
  return (
    <label className={`fp-photo${file ? ' is-set' : ''}`} data-testid={testId}>
      <FdIcon name={file ? 'check' : 'camera'} />{busy ? 'Getting the photo ready' : file ? `${file.type === 'application/pdf' ? 'PDF' : 'Photo'} ready: tap to change` : label}
      <input type="file" accept={pdf ? 'image/*,application/pdf' : 'image/*'} capture={pdf ? undefined : 'environment'} onChange={async (e) => {
        const f = e.target.files?.[0] ?? null;
        if (!f) return;
        if (f.type === 'application/pdf') { set(f); return; }
        setBusy(true);
        try { const p = await preparePhoto(f); set(new File([p.blob], 'photo.jpg', { type: 'image/jpeg' })); } catch { set(f); } finally { setBusy(false); }
      }} />
    </label>
  );
}

/** Send a step with its file. */
export async function sendWork(action: FieldFileAction, p: Record<string, unknown>, file: File | null) {
  const fd = new FormData();
  fd.set('action', action);
  fd.set('p', JSON.stringify(p));
  if (file) fd.set('file', file);
  return fieldWork(fd);
}

export function CleanCheck({ c, onDone }: { c: Card; onDone?: () => void }) {
  const [file, setFile] = useState<File | null>(null);
  const [clean, setClean] = useState(true);
  const [note, setNote] = useState('');
  const { pending, msg, run } = useRun();
  const job = c.type === 'job' ? c.id : undefined;
  return (
    <div className="fp-step" data-testid="clean-check">
      <p className="fp-step__h">{c.clean?.moment === 'after_return' ? 'Clean check after the return' : c.type === 'clean' ? 'Is this car clean?' : 'Clean check before the pickup'}</p>
      <div className="fp-seg" role="group" aria-label="Clean or not">
        <button type="button" aria-pressed={clean} onClick={() => setClean(true)}>Clean</button>
        <button type="button" aria-pressed={!clean} onClick={() => setClean(false)}>Needs cleaning</button>
      </div>
      {!clean && <div className="field"><label className="label" htmlFor={`cn-${c.key}`}>What is not clean</label>
        <input id={`cn-${c.key}`} className="input" value={note} maxLength={500} onChange={(e) => setNote(e.target.value)} /></div>}
      <PhotoPick file={file} set={setFile} label="Take a photo of the car" testId="clean-photo" />
      <button type="button" className="btn btn--primary fd-wide" disabled={pending || !file} data-testid="clean-save"
        onClick={() => run(() => sendWork('clean_check', job ? { job, clean, note } : { vehicle: c.vehicle.id, clean, note }, file), 'Clean check saved.', onDone)}>{pending ? 'Saving' : 'Save the clean check'}</button>
      <Msg m={msg} />
    </div>
  );
}

export function AddonTicks({ addons }: { addons: Addon[] }) {
  const { pending, msg, run } = useRun();
  return (
    <div className="fp-step" data-testid="addon-ticks">
      <p className="fp-step__h">Prepare: put each in the car, then tick ({addons.filter((a) => a.ticked).length} of {addons.length})</p>
      {addons.map((a) => (
        <label key={a.id} className={`fp-tick${a.ticked ? ' is-on' : ''}`}>
          <input type="checkbox" checked={a.ticked} disabled={pending} onChange={(e) => run(() => fieldAct('addon_tick', { id: a.id, ticked: e.target.checked }), e.target.checked ? `${a.name}: in the car.` : `${a.name}: not ticked.`)} data-testid={`addon-${a.id}`} />
          <span><b className="fp-tick__qty">{a.quantity} x</b> {a.name}{a.note ? <small>{a.note}</small> : null}{a.ticked && a.ticked_by ? <small>Ticked by {a.ticked_by}</small> : null}</span>
        </label>))}
      <p className="small">The pickup waits until every add-on is ticked. If the trip must go without one, ask an Admin to override on the job.</p>
      <Msg m={msg} />
    </div>
  );
}

export function CarUpdate({ c }: { c: Card }) {
  const [status, setStatus] = useState('taken_in');
  const [note, setNote] = useState('');
  const { pending, msg, run } = useRun();
  return (
    <div className="fp-step" data-testid="car-update">
      <p className="fp-step__h">What happened with the car</p>
      <div className="field"><label className="label" htmlFor={`cu-${c.key}`}>Update</label>
        <select id={`cu-${c.key}`} className="select" value={status} onChange={(e) => setStatus(e.target.value)}>{CAR_UPDATES.map(([v, l]) => <option key={v} value={v}>{l}</option>)}</select></div>
      <div className="field"><label className="label" htmlFor={`cun-${c.key}`}>Note {status === 'note' || status === 'waiting_parts' ? '' : '(optional)'}</label>
        <input id={`cun-${c.key}`} className="input" value={note} maxLength={500} onChange={(e) => setNote(e.target.value)} placeholder="Which shop, what they said" /></div>
      <button type="button" className="btn btn--primary fd-wide" disabled={pending} onClick={() => run(() => fieldAct('car_update', { vehicle: c.vehicle.id, status, note }), 'Fleet has your update.')}>{pending ? 'Saving' : 'Send the update to Fleet'}</button>
      <p className="small">Done the service? Use Add, then Service record, so the car and the money are right.</p>
      <Msg m={msg} />
    </div>
  );
}

export function PhotoStart({ c }: { c: Card }) {
  const router = useRouter();
  const { pending, msg, run } = useRun();
  return (
    <div className="fp-step">
      {c.missing && c.missing.length > 0 && <p className="small">Missing: {c.missing.slice(0, 4).join('; ')}{c.missing.length > 4 ? ' and more' : ''}.</p>}
      <button type="button" className="btn btn--primary fd-wide" disabled={pending} data-testid="photo-start"
        onClick={() => run(async () => { const r = await fieldAct<{ job: string }>('photo_start', { vehicle: c.vehicle.id }); if (r.ok) router.push(`/staff/field/jobs/${r.data.job}`); return r; }, 'Opening the photo shoot.')}>{pending ? 'Opening' : 'Take the listing photos'}</button>
      <Msg m={msg} />
    </div>
  );
}

export function PrepItems({ c }: { c: Card }) {
  const [open, setOpen] = useState<string | null>(null);
  const [file, setFile] = useState<File | null>(null);
  const [note, setNote] = useState('');
  const [exp, setExp] = useState('');
  const { pending, msg, run } = useRun();
  return (
    <div className="fp-step" data-testid="prep-items">
      {c.note && <p className="small"><b>From Fleet:</b> {c.note}</p>}
      {(c.items ?? []).map((i) => (
        <div key={i.code} className="stack">
          <button type="button" className={`fp-tick${i.done ? ' is-on' : ''}`} aria-expanded={open === i.code} onClick={() => { setOpen(open === i.code ? null : i.code); setFile(null); setNote(''); setExp(''); }} data-testid={`prep-${i.code}`}>
            <span className="fp-steps__mark" aria-hidden="true">{i.done ? <FdIcon name="check" /> : null}</span><span>{i.label}{i.done ? <small>Done</small> : null}</span></button>
          {open === i.code && !i.done && <div className="fp-form">
            <PhotoPick file={file} set={setFile} pdf label={i.code === 'safety_certificate' ? 'Upload the safety certificate' : 'Add a photo or PDF (optional)'} />
            {i.code === 'safety_certificate' && <div className="field"><label className="label" htmlFor={`exp-${c.key}`}>Valid until</label>
              <DateInput id={`exp-${c.key}`} type="date" className="input" value={exp} onChange={(e) => setExp(e.target.value)} /></div>}
            <div className="field"><label className="label" htmlFor={`pn-${c.key}-${i.code}`}>Note (optional)</label>
              <input id={`pn-${c.key}-${i.code}`} className="input" value={note} maxLength={300} onChange={(e) => setNote(e.target.value)} /></div>
            <button type="button" className="btn btn--primary fd-wide" disabled={pending || (i.code === 'safety_certificate' && !file)}
              onClick={() => run(() => sendWork('prep_item', { id: c.id, code: i.code, note, expires_on: exp || null }, file), `${i.label}: done.`, () => setOpen(null))}>{pending ? 'Saving' : 'Mark it done'}</button>
            <p className="small">Spent money on it? Use Add: Money spent or Service record.</p>
          </div>}
        </div>))}
      <Msg m={msg} />
    </div>
  );
}
