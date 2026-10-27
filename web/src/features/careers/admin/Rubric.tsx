'use client';
import { useRouter } from 'next/navigation';
import { useState } from 'react';
import { adminAct } from '@/server/actions/admin-portal';
import { DECISIONS, finalScore, interviewScore, type Criterion } from '../model';

// The interviewer's rubric (migration 0173): each criterion 1 to 5, notes, the decision. The interview score (of 100, by the
// weights) and the final score (40% screening, 60% interview) show as you score; the database works them out again on Save
// and ranks the candidate within the role.
export function Rubric({ id, criteria, screening, initial }: { id: string; criteria: Criterion[]; screening: number | null;
  initial: { scores: Record<string, number>; notes: string | null; decision: string | null } | null }) {
  const router = useRouter();
  const [scores, setScores] = useState<Record<string, number | undefined>>(initial?.scores ?? {});
  const [notes, setNotes] = useState(initial?.notes ?? '');
  const [decision, setDecision] = useState(initial?.decision ?? '');
  const [busy, setBusy] = useState(false);
  const [msg, setMsg] = useState<{ ok: boolean; text: string } | null>(null);
  const inter = interviewScore(criteria, scores);
  const fin = finalScore(screening, inter);
  async function save() {
    setBusy(true); setMsg(null);
    const r = await adminAct<{ rank?: number | null }>('hiring_score', { id, scores, notes, decision }, ['/admin/hiring', `/admin/hiring/${id}`]);
    setBusy(false);
    if (!r.ok) { setMsg({ ok: false, text: r.message }); return; }
    setMsg({ ok: true, text: r.data.rank ? `Saved. Rank ${r.data.rank} in this role.` : 'Saved.' });
    router.refresh();
  }
  return (
    <form className="stack cr-rubric" noValidate onSubmit={(e) => { e.preventDefault(); void save(); }} aria-label="Interview rubric" data-testid="rubric">
      {criteria.map((c) => (
        <fieldset key={c.key} className="cr-crit" data-testid={`crit-${c.key}`}>
          <legend><b>{c.label}</b> <span className="muted small">weight {c.weight}</span></legend>
          <p className="small muted">{c.hint}</p>
          <div className="cr-scale" role="radiogroup" aria-label={`${c.label}, 1 to 5`}>
            {[1, 2, 3, 4, 5].map((n) => (
              <label key={n} className={`cr-pt${scores[c.key] === n ? ' is-on' : ''}`}>
                <input type="radio" name={`crit-${c.key}`} value={n} checked={scores[c.key] === n} onChange={() => setScores((s) => ({ ...s, [c.key]: n }))} data-testid={`crit-${c.key}-${n}`} />
                <span>{n}</span>
              </label>))}
          </div>
        </fieldset>))}
      <div className="field"><label className="label" htmlFor={`rb-notes-${id}`}>Notes</label>
        <textarea className="textarea" id={`rb-notes-${id}`} rows={4} value={notes} onChange={(e) => setNotes(e.target.value)} data-testid="rubric-notes" /></div>
      <fieldset className="cr-crit"><legend><b>Decision</b></legend>
        <div className="cr-scale">{DECISIONS.map(([k, l]) => (
          <label key={k} className={`cr-pt cr-pt--wide${decision === k ? ' is-on' : ''}`}><input type="radio" name="decision" value={k} checked={decision === k} onChange={() => setDecision(k)} data-testid={`decision-${k}`} /><span>{l}</span></label>))}</div>
      </fieldset>
      <p className="cr-totals" aria-live="polite" data-testid="rubric-totals">Screening <b>{screening ?? '-'}</b> · Interview <b>{inter ?? '-'}</b> of 100 · Final <b>{fin ?? '-'}</b></p>
      {msg && <p className={`alert${msg.ok ? '' : ' alert--error'}`} role={msg.ok ? 'status' : 'alert'} data-testid="rubric-msg"><span>{msg.text}</span></p>}
      <button className="btn btn--primary" type="submit" disabled={busy} data-testid="rubric-save">{busy ? 'Saving' : 'Save the rubric'}</button>
    </form>
  );
}
