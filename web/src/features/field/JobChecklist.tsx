'use client';
import { useState, useTransition, type ReactNode } from 'react';
import { useRouter } from 'next/navigation';
import { fieldAct } from '@/server/actions/field';
import { preparePhoto, uploads, useUploads } from './queue';
import type { Answer, FieldJob, JobChecklistData, Step } from './types';
import { FdIcon } from './icons';

// The checklist of a detail, photo shoot, tracker install or removal, registry run, recovery, other job, or
// a re-shoot (06-field.md section 7; migration 0033): one card per step, each answer saved to the server as
// it is given (a phone that dies loses nothing), photos through the same upload queue as the handover. Done
// is refused until every required step is answered; a Problem becomes a task for Fleet.
const nice = (s: string) => s.replace(/_/g, ' ');

export function JobChecklist({ j, listing }: { j: FieldJob; listing?: ReactNode }) {
  const c = j.checklist as JobChecklistData;
  const jobId = j.job.id;
  const router = useRouter();
  const q = useUploads(jobId);
  const [a, setA] = useState<Record<string, Answer>>(c.answers ?? {});
  const [msg, setMsg] = useState<{ ok: boolean; text: string } | null>(null);
  const [busy, setBusy] = useState<string | null>(null);
  const [pending, start] = useTransition();

  const save = async (key: string, v: Answer) => {
    const next = { ...a, [key]: { ...a[key], ...v } };
    setA(next);
    const r = await fieldAct('checklist_save', { job: jobId, answers: { [key]: next[key] } });
    if (!r.ok) setMsg({ ok: false, text: r.message });
  };
  const addPhotos = async (s: Step, files: FileList | null) => {
    if (!files?.length) return;
    setBusy(s.key);
    try {
      const keys: string[] = [];
      for (const f of Array.from(files)) {
        const p = await preparePhoto(f);
        keys.push(await uploads.addAndWait({ job: jobId, seq: 500, shot: s.key, mode: 'raw', blob: p.blob, taken_at: new Date().toISOString(), width: p.width, height: p.height, flags: p.flags }));
      }
      await save(s.key, { photos: [...(a[s.key]?.photos ?? []), ...keys] });
    } catch (e) { setMsg({ ok: false, text: e instanceof Error ? e.message : 'The photo could not be sent.' }); } finally { setBusy(null); }
  };
  const shot = async (seq: number, name: string, file: File | undefined, reshoot: boolean) => {
    if (!file) return;
    setBusy(name);
    try {
      const p = await preparePhoto(file);
      if (reshoot) {
        const key = await uploads.addAndWait({ job: jobId, seq: 600 + seq, shot: name, mode: 'raw', blob: p.blob, taken_at: new Date().toISOString(), width: p.width, height: p.height, flags: p.flags });
        const r = await fieldAct('reshoot_photo', { job: jobId, shot: name, bucket: 'condition-photos', path: key });
        if (!r.ok) throw new Error(r.message);
        router.refresh();
      } else {
        await uploads.add({ job: jobId, seq, shot: name, mode: 'photo', blob: p.blob, taken_at: new Date().toISOString(), width: p.width, height: p.height, flags: p.flags });
      }
    } catch (e) { setMsg({ ok: false, text: e instanceof Error ? e.message : 'The photo could not be sent.' }); } finally { setBusy(null); }
  };
  const done = () => start(async () => {
    setMsg(null);
    if (q.pending.length) { setMsg({ ok: false, text: `Wait for the photos to finish sending (${q.pending.length} left).` }); return; }
    const r = await fieldAct<{ problems: number }>('complete_job', { job: jobId });
    if (!r.ok) { setMsg({ ok: false, text: r.message }); return; }
    setMsg({ ok: true, text: r.data.problems ? 'Done. Fleet has your problem notes.' : 'Done.' });
    router.refresh();
  });

  // a step counts as answered once it has a value or a photo (the server decides what is still missing)
  const isAnswered = (s: Step) => Boolean(a[s.key]?.v || a[s.key]?.photos?.length);
  const answered = c.steps.filter(isAnswered).length;
  const body = (s: Step) => {
    const v = a[s.key] ?? {};
    switch (s.type) {
      case 'tick': case 'rules':
        return (<>
          {s.text && <p className="pt-note small">{s.text}</p>}
          <div className="fd-pick" role="radiogroup" aria-label={s.label}>
            <button type="button" className={`btn ${v.v === 'ok' ? 'btn--primary' : 'btn--ghost'}`} aria-pressed={v.v === 'ok'} onClick={() => void save(s.key, { v: 'ok' })} data-testid={`ck-${s.key}-ok`}>{s.type === 'rules' ? 'I have read this' : 'OK'}</button>
            {s.type === 'tick' && <button type="button" className={`btn ${v.v === 'problem' ? 'btn--primary ad-btn--danger' : 'btn--ghost'}`} aria-pressed={v.v === 'problem'} onClick={() => void save(s.key, { v: 'problem' })} data-testid={`ck-${s.key}-problem`}>Problem</button>}
          </div>
          {v.v === 'problem' && <label className="field"><span className="label">What is wrong{s.stop ? ' (tell Fleet before you go on)' : ''}</span>
            <input className="input" defaultValue={v.note ?? ''} onBlur={(e) => void save(s.key, { note: e.target.value })} /></label>}
        </>);
      case 'choice':
        return <div className="fd-pick fd-pick--stack" role="radiogroup" aria-label={s.label}>{(s.options ?? []).map(([k, l]) => (
          <button key={k} type="button" className={`btn ${v.v === k ? 'btn--primary' : 'btn--ghost'}`} aria-pressed={v.v === k} onClick={() => void save(s.key, { v: k })} data-testid={`ck-${s.key}-${k}`}>{l}</button>))}</div>;
      case 'text': case 'serial': case 'number':
        return <label className="field"><span className="label">{s.type === 'serial' ? 'Serial number' : s.type === 'number' ? 'Value' : 'Your note'}</span>
          {s.type === 'text' ? <textarea className="textarea" defaultValue={v.v ?? ''} onBlur={(e) => void save(s.key, { v: e.target.value })} data-testid={`ck-${s.key}`} />
            : <input className="input fd-big" inputMode={s.type === 'number' ? 'numeric' : undefined} autoCapitalize="characters" defaultValue={v.v ?? ''} onBlur={(e) => void save(s.key, { v: e.target.value.trim() })} data-testid={`ck-${s.key}`} />}</label>;
      case 'photos':
        return (<>
          <p className="small">{(v.photos ?? []).length} photo(s) sent{s.min ? `; at least ${s.min}` : ''}.</p>
          <label className="btn btn--ghost fd-wide">{busy === s.key ? 'Sending' : 'Take a photo'}
            <input className="vh" type="file" accept="image/*" capture="environment" multiple data-testid={`ck-${s.key}-photo`} onChange={(e) => { void addPhotos(s, e.target.files); e.target.value = ''; }} /></label>
        </>);
      case 'shots':
        return <ul className="fd-shots">{j.shots.map((x) => {
          const have = (j.report?.photos ?? []).some((p) => p.shot === x.shot) || q.arrived(x.seq);
          return <li key={x.shot}><span>{have ? '✓ ' : ''}{nice(x.shot)}</span>
            <label className="btn btn--ghost btn--sm">{have ? 'Retake' : 'Take'}<input className="vh" type="file" accept="image/*" capture="environment" data-testid={`ck-shot-${x.shot}`} onChange={(e) => { void shot(x.seq, x.shot, e.target.files?.[0], false); e.target.value = ''; }} /></label></li>;
        })}</ul>;
      case 'reshoot':
        return <ul className="fd-shots">{(c.reshoot?.shots ?? []).map((x) => (
          <li key={x.shot}><span>{x.done ? '✓ ' : ''}{nice(x.shot)}{x.guide ? <span className="xs muted"> · {x.guide}</span> : null}</span>
            <label className="btn btn--ghost btn--sm">{busy === x.shot ? 'Sending' : x.done ? 'Retake' : 'Take'}<input className="vh" type="file" accept="image/*" capture="environment" data-testid={`ck-reshoot-${x.shot}`} onChange={(e) => { void shot(x.seq, x.shot, e.target.files?.[0], true); e.target.value = ''; }} /></label></li>))}</ul>;
      case 'listing':
        return listing ?? null;
      default:
        return null;
    }
  };

  return (
    <div className="stack" data-testid="job-checklist">
      <div className="fd-upload" aria-hidden="true"><div className="fd-meter"><span style={{ width: `${Math.round((answered / Math.max(1, c.steps.length)) * 100)}%` }} /></div></div>
      <p className="fd-upload__line">{answered} of {c.steps.length} steps answered</p>
      {c.steps.map((s, i) => (
        <section key={s.key} className={`fd-card fd-ckstep${isAnswered(s) ? ' is-done' : ''}`} aria-labelledby={`ck-${s.key}-t`}>
          <p className="fd-ckstep__n">{isAnswered(s) ? <span className="fd-shot__ok" aria-hidden="true"><FdIcon name="check" /></span> : null}Step {i + 1} of {c.steps.length}{s.required ? '' : ', optional'}</p>
          <h2 className="fd-ckstep__h" id={`ck-${s.key}-t`}>{s.label}</h2>
          {s.help && <p className="small muted">{s.help}</p>}
          {body(s)}
        </section>
      ))}
      {q.pending.length > 0 && <p className="small" role="status">{q.pending.length} photo(s) waiting to send.</p>}
      {c.missing.length > 0 && <p className="small muted">Still to do: {c.missing.join('; ')}.</p>}
      {msg && <p className={`alert ${msg.ok ? 'alert--ok' : 'alert--error'}`} role={msg.ok ? 'status' : 'alert'}><span>{msg.text}</span></p>}
      <button type="button" className="btn btn--primary fd-wide fd-sticky" disabled={pending} onClick={done} data-testid="job-complete">{pending ? 'Finishing' : 'Done: complete the job'}</button>
    </div>
  );
}
