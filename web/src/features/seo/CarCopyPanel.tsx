'use client';
import { useState, useTransition } from 'react';
import { useRouter } from 'next/navigation';
import { seoAct } from '@/server/actions/seo';
import { CAR_FIELDS, CAR_FIELD_LABEL, type CarField } from './copy';

// The car copy on a listing (migration 0061): written by Workers AI from the car's facts and published by itself.
// Nobody has to type anything here. A person may still change a field: it is then locked, and every later rewrite
// keeps it until it is unlocked. "Write again" asks for a new version now.
export interface CarCopyData {
  vehicle_id: string; vehicle: string; eligible: boolean; is_sample: boolean; status: string | null; source: string | null;
  copy: Record<string, unknown> | null; locked: string[]; problems: string[]; last_error: string | null;
  generated_at: string | null; published_at: string | null; next_attempt_at: string | null; model: string | null; runs: number | null; up_to_date: boolean;
}
type Faq = { question: string; answer: string };
const LIST: CarField[] = ['highlights', 'good_for', 'included', 'requirements'];
const when = (iso: string | null) => (iso ? new Intl.DateTimeFormat('en-CA', { timeZone: 'America/Toronto', dateStyle: 'medium', timeStyle: 'short' }).format(new Date(iso)) : '');

function toText(f: CarField, v: unknown): string {
  if (LIST.includes(f)) return ((v as string[] | undefined) ?? []).join('\n');
  if (f === 'faq') return ((v as Faq[] | undefined) ?? []).map((q) => `${q.question} | ${q.answer}`).join('\n');
  if (f === 'alt_texts') return Object.entries((v as Record<string, string> | undefined) ?? {}).map(([k, x]) => `${k}: ${x}`).join('\n');
  return String(v ?? '');
}
function fromText(f: CarField, t: string): unknown {
  const lines = t.split('\n').map((x) => x.trim()).filter(Boolean);
  if (LIST.includes(f)) return lines;
  if (f === 'faq') return lines.map((x) => x.split('|')).filter((x) => x[0]?.trim() && x[1]?.trim()).map(([q, a]) => ({ question: q!.trim(), answer: a!.trim() }));
  if (f === 'alt_texts') return Object.fromEntries(lines.map((x) => [x.slice(0, x.indexOf(':')).trim(), x.slice(x.indexOf(':') + 1).trim()]).filter(([k, x]) => k && x));
  return t.trim();
}

export function CarCopyPanel({ d, slug }: { d: CarCopyData | null; slug?: string | null }) {
  const router = useRouter();
  const [pending, start] = useTransition();
  const [editing, setEditing] = useState<CarField | null>(null);
  const [text, setText] = useState('');
  const [msg, setMsg] = useState<{ ok: boolean; text: string } | null>(null);
  if (!d) return null;
  const paths = slug ? [`/cars/${slug}`] : [];
  const run = (action: 'car_copy_edit' | 'car_copy_regenerate', p: Record<string, unknown>, ok: string) => start(async () => {
    const r = await seoAct(action, { vehicle: d.vehicle_id, ...p }, paths);
    setMsg(r.ok ? { ok: true, text: ok } : { ok: false, text: r.message });
    if (r.ok) { setEditing(null); router.refresh(); }
  });
  const status = !d.eligible ? (d.is_sample ? 'A sample car: its copy is not written (it is not shown to search engines).' : 'No listing yet: the copy is written once the car has one.')
    : d.status === 'published' && d.source === 'ai' ? `Written by Workers AI${d.generated_at ? ` on ${when(d.generated_at)}` : ''} and published. Nothing to review.`
    : d.status === 'published' && d.source === 'claude-batch' ? `Written by the daily Claude batch${d.generated_at ? ` on ${when(d.generated_at)}` : ''}, checked and published. Nothing to review.`
    : d.status === 'failed' ? `The last rewrite did not pass the checks; the page keeps its current text, and it is tried again ${d.next_attempt_at ? `after ${when(d.next_attempt_at)}` : 'later'}.`
    : d.source === 'template' ? 'A plain copy from the facts is live while the written copy is prepared (by the next daily batch).'
    : 'Being written now.';
  const copy = d.copy ?? {};
  return (
    <section className="pt-card ad-card" aria-labelledby="cc-h" data-testid="car-copy">
      <h2 className="d4" id="cc-h">Copy (written automatically)</h2>
      <p className="small" data-testid="car-copy-status" data-status={d.status ?? 'none'} data-source={d.source ?? 'none'}>{status}</p>
      {!d.up_to_date && d.eligible && <p className="small muted">The car&apos;s facts changed since this text was written; a new version is on its way.</p>}
      {d.problems.length > 0 && d.status === 'failed' && <details className="small"><summary className="link">What the checks found</summary><ul>{d.problems.map((x) => <li key={x}>{x}</li>)}</ul></details>}
      {d.eligible && <dl className="cc-fields">{CAR_FIELDS.map((f) => {
        const locked = d.locked.includes(f);
        return (
          <div key={f} className="cc-field" data-testid={`cc-${f}`} data-locked={locked ? 'yes' : 'no'}>
            <dt><b>{CAR_FIELD_LABEL[f]}</b>{locked && <span className="ad-b ad-b--light"> Locked: kept by every rewrite</span>}</dt>
            <dd>{editing === f ? (
              <div className="stack">
                <label className="vh" htmlFor={`cc-in-${f}`}>{CAR_FIELD_LABEL[f]}</label>
                <textarea className="input ad-textarea" id={`cc-in-${f}`} rows={['intro', 'faq', 'alt_texts'].includes(f) ? 6 : LIST.includes(f) ? 5 : 2} value={text} onChange={(e) => setText(e.target.value)} />
                <p className="xs muted">{LIST.includes(f) ? 'One a line.' : f === 'faq' ? 'One a line: question | answer.' : f === 'alt_texts' ? 'One a line: photo: description.' : ''}</p>
                <p className="row"><button type="button" className="btn btn--primary btn--sm" disabled={pending} data-testid={`cc-save-${f}`} onClick={() => run('car_copy_edit', { field: f, value: fromText(f, text) }, 'Saved and locked.')}>Save and lock</button>
                  <button type="button" className="btn btn--ghost btn--sm" onClick={() => setEditing(null)}>Cancel</button></p>
              </div>
            ) : (
              <>
                {LIST.includes(f) ? <ul className="small">{((copy[f] as string[] | undefined) ?? []).map((x) => <li key={x}>{x}</li>)}</ul>
                  : f === 'faq' ? <ul className="small">{((copy[f] as Faq[] | undefined) ?? []).map((q) => <li key={q.question}><b>{q.question}</b> {q.answer}</li>)}</ul>
                  : f === 'alt_texts' ? <ul className="small">{Object.entries((copy[f] as Record<string, string> | undefined) ?? {}).map(([k, x]) => <li key={k}><b>{k.replace(/_/g, ' ')}</b>: {x}</li>)}</ul>
                  : <p className="small" style={{ whiteSpace: 'pre-line' }}>{String(copy[f] ?? '')}</p>}
                <p className="row">
                  <button type="button" className="btn btn--quiet btn--sm" onClick={() => { setText(toText(f, copy[f])); setEditing(f); setMsg(null); }}>Change</button>
                  {locked && <button type="button" className="btn btn--quiet btn--sm" disabled={pending} data-testid={`cc-unlock-${f}`} onClick={() => run('car_copy_edit', { field: f, unlock: true }, 'Unlocked: the next version writes it again.')}>Unlock</button>}
                </p>
              </>
            )}</dd>
          </div>);
      })}</dl>}
      {d.eligible && <p className="row"><button type="button" className="btn btn--ghost btn--sm" disabled={pending} data-testid="cc-regenerate" onClick={() => run('car_copy_regenerate', {}, 'Asked for: a new version is written in a minute or two.')}>Write again</button>
        <span className="xs muted">Locked fields are kept.</span></p>}
      {msg && <p className={`alert ${msg.ok ? 'alert--ok' : 'alert--error'}`} role={msg.ok ? 'status' : 'alert'}><span>{msg.text}</span></p>}
    </section>
  );
}
