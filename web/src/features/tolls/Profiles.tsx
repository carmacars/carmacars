'use client';
import { useMemo, useState, useTransition } from 'react';
import { useRouter } from 'next/navigation';
import { money } from '@/lib/format';
import { staffDo } from '@/server/actions/staff-tools';
import { FIELD_LABELS, KINDS, readText, type FieldKey, type Kind, type Profile, type Rules } from './parse';

// Reading profiles (migration 0042), adjusted without code: the words that tell an issuer's notices apart, the
// labels in front of each value, and for a statement the words of lines that are not trips. "Try it" reads the
// text pasted in the box with the profile as it stands on screen, before it is saved.
type Row = Profile & { is_active: boolean; notes: string | null; sample_text: string | null; reads: number };
const FIELDS: FieldKey[] = ['statement_number', 'account_number', 'statement_date', 'due_on', 'total', 'authority', 'notice_number', 'plate', 'transponder', 'date', 'time', 'place', 'amount', 'fees'];
const list = (s: string) => s.split('\n').map((x) => x.trim()).filter(Boolean);
const text = (a?: string[]) => (a ?? []).join('\n');

export function ProfileEditor({ p, onSaved }: { p: Row | null; onSaved?: () => void }) {
  const router = useRouter();
  const [pending, start] = useTransition();
  const [msg, setMsg] = useState<{ ok: boolean; text: string } | null>(null);
  const r = p?.rules ?? {};
  const [v, setV] = useState({ operator: p?.operator ?? '', name: p?.name ?? '', kind: (p?.notice_kind ?? 'toll_invoice') as Kind, layout: r.layout ?? 'single', detect: text(r.detect), authority: r.authority ?? '',
    date_order: r.date_order ?? 'auto', amount: r.trip?.amount ?? 'last', skip: text(r.trip?.skip_words), fees: text(r.trip?.statement_fee_words), priority: String(p?.priority ?? 100),
    is_active: p?.is_active ?? true, notes: p?.notes ?? '', sample: p?.sample_text ?? '', fields: Object.fromEntries(FIELDS.map((k) => [k, text(r.fields?.[k])])) as Record<FieldKey, string> });
  const rules: Rules = useMemo(() => ({ layout: v.layout, detect: list(v.detect), authority: v.authority.trim() || undefined, date_order: v.date_order,
    fields: Object.fromEntries(FIELDS.filter((k) => list(v.fields[k]).length).map((k) => [k, list(v.fields[k])])),
    trip: { skip_words: list(v.skip), statement_fee_words: list(v.fees), amount: v.amount } }), [v]);
  const trial = useMemo(() => {
    if (!v.sample.trim()) return null;
    const lines = v.sample.split('\n').map((t, i, a) => ({ text: t, page: 1, y: i / a.length }));
    return readText(lines, { id: p?.id ?? 'new', operator: v.operator, name: v.name, source: 'pdf_text', notice_kind: v.kind, rules, priority: Number(v.priority) || 100 }, { plates: [] });
  }, [v.sample, v.operator, v.name, v.kind, v.priority, rules, p?.id]);
  const idp = `pf-${p?.id.slice(0, 8) ?? 'new'}`;
  const T = (k: string, label: string, val: string, set: (s: string) => void, rows = 3, hint?: string) => (
    <div className="field ad-field"><label className="label" htmlFor={`${idp}-${k}`}>{label}</label>
      <textarea className="input ad-textarea" id={`${idp}-${k}`} rows={rows} value={val} onChange={(e) => set(e.target.value)} aria-describedby={hint ? `${idp}-${k}-h` : undefined} />
      {hint && <p className="hint" id={`${idp}-${k}-h`}>{hint}</p>}</div>);
  const save = () => start(async () => {
    const res = await staffDo('toll_profile_upsert', { id: p?.id ?? null, operator: v.operator, name: v.name, source: 'pdf_text', notice_kind: v.kind, rules, priority: Number(v.priority) || 100,
      is_active: v.is_active, notes: v.notes, sample_text: v.sample });
    setMsg(res.ok ? { ok: true, text: 'Saved. The next notice read uses it.' } : { ok: false, text: res.message });
    if (res.ok) { onSaved?.(); router.refresh(); }
  });
  return (
    <form className="ad-form stack" onSubmit={(e) => { e.preventDefault(); save(); }} data-testid={`profile-${p?.id ?? 'new'}`}>
      <div className="ad-fields">
        <div className="field ad-field"><label className="label" htmlFor={`${idp}-op`}>Issuer</label><input className="input" id={`${idp}-op`} value={v.operator} onChange={(e) => setV({ ...v, operator: e.target.value })} required /></div>
        <div className="field ad-field"><label className="label" htmlFor={`${idp}-nm`}>Name</label><input className="input" id={`${idp}-nm`} value={v.name} onChange={(e) => setV({ ...v, name: e.target.value })} required /></div>
        <div className="field ad-field"><label className="label" htmlFor={`${idp}-k`}>Kind of notice</label><select className="select" id={`${idp}-k`} value={v.kind} onChange={(e) => setV({ ...v, kind: e.target.value as Kind })}>{KINDS.map(([k, t]) => <option key={k} value={k}>{t}</option>)}</select></div>
        <div className="field ad-field"><label className="label" htmlFor={`${idp}-l`}>Layout</label><select className="select" id={`${idp}-l`} value={v.layout} onChange={(e) => setV({ ...v, layout: e.target.value as 'single' })}>
          <option value="statement">A statement: one line per trip</option><option value="single">One notice: one offence</option><option value="auto">Find out from the text</option></select></div>
        <div className="field ad-field"><label className="label" htmlFor={`${idp}-do`}>Dates are written</label><select className="select" id={`${idp}-do`} value={v.date_order} onChange={(e) => setV({ ...v, date_order: e.target.value as 'auto' })}>
          <option value="auto">Find out from the dates</option><option value="ymd">Year, month, day</option><option value="mdy">Month, day, year</option><option value="dmy">Day, month, year</option></select></div>
        <div className="field ad-field"><label className="label" htmlFor={`${idp}-au`}>Issuer name on every line (empty: read it)</label><input className="input" id={`${idp}-au`} value={v.authority} onChange={(e) => setV({ ...v, authority: e.target.value })} /></div>
        <div className="field ad-field"><label className="label" htmlFor={`${idp}-pr`}>Order (lower is tried first)</label><input className="input" id={`${idp}-pr`} inputMode="numeric" value={v.priority} onChange={(e) => setV({ ...v, priority: e.target.value })} /></div>
        <div className="field ad-field"><label className="check" htmlFor={`${idp}-act`}><input id={`${idp}-act`} type="checkbox" checked={v.is_active} onChange={(e) => setV({ ...v, is_active: e.target.checked })} /> <span>In use</span></label></div>
      </div>
      {T('detect', 'Words that identify this issuer (one a line)', v.detect, (s) => setV({ ...v, detect: s }), 3, 'A notice whose text has the most of these words is read with this profile.')}
      <fieldset className="tr-fieldset"><legend className="label">Labels in front of each value (one a line; the longest that matches wins)</legend>
        <div className="tr-grid">{FIELDS.map((k) => T(`f-${k}`, FIELD_LABELS[k], v.fields[k], (s) => setV({ ...v, fields: { ...v.fields, [k]: s } }), 2))}</div></fieldset>
      {v.layout !== 'single' && <div className="tr-grid">
        {T('skip', 'Lines that are not trips (words, one a line)', v.skip, (s) => setV({ ...v, skip: s }), 4)}
        {T('fees', 'Statement fees, kept apart (words, one a line)', v.fees, (s) => setV({ ...v, fees: s }), 4)}
        <div className="field ad-field"><label className="label" htmlFor={`${idp}-am`}>The amount of a trip is</label><select className="select" id={`${idp}-am`} value={v.amount} onChange={(e) => setV({ ...v, amount: e.target.value as 'last' })}>
          <option value="last">The last amount on the line (its total); the rest are fees</option><option value="first">The first amount on the line</option><option value="sum">Every amount on the line added up</option></select></div>
      </div>}
      {T('notes', 'Notes', v.notes, (s) => setV({ ...v, notes: s }), 2)}
      {T('sample', 'Try it: paste the text of a notice', v.sample, (s) => setV({ ...v, sample: s }), 8, 'Copy the text from the PDF (select all, copy) and paste it here. It is kept with the profile as an example.')}
      {trial && <div className="small" role="status" data-testid={`profile-trial-${p?.id ?? 'new'}`}>
        <p>{trial.layout === 'statement' ? 'Statement' : 'One notice'}: {trial.lines.length} line(s){trial.statement_number ? `, statement ${trial.statement_number}` : ''}{trial.due_on ? `, due ${trial.due_on}` : ''}{trial.total_cents != null ? `, total ${money(trial.total_cents, { cents: true })}` : ''}.</p>
        <ul>{trial.lines.slice(0, 20).map((l, i) => <li key={i}>{[l.notice_number, l.plate ?? 'no plate', l.occurred_at?.replace('T', ' ').slice(0, 16), l.entry && l.exit ? `${l.entry} to ${l.exit}` : l.place, l.amount_cents != null ? money(l.amount_cents, { cents: true }) : 'no amount', `${l.confidence}%`].filter(Boolean).join(' · ')}</li>)}</ul>
        {trial.problems.length > 0 && <p className="ad-late">{trial.problems.join('; ')}</p>}</div>}
      <div className="row"><button className="btn btn--primary btn--sm" type="submit" disabled={pending}>{pending ? 'Saving' : p ? 'Save the profile' : 'Add the profile'}</button></div>
      {msg && <p className={`alert ${msg.ok ? 'alert--ok' : 'alert--error'}`} role={msg.ok ? 'status' : 'alert'}><span>{msg.text}</span></p>}
    </form>
  );
}

export function ProfileList({ profiles }: { profiles: Row[] }) {
  const text = profiles.filter((p) => p.source === 'pdf_text');
  const csv = profiles.filter((p) => p.source === 'csv');
  return (
    <div className="stack" data-testid="toll-profiles">
      {text.map((p) => (
        <details key={p.id} className="pt-card ad-card"><summary className="link"><b>{p.name}</b> <span className="small muted">({p.operator}, {p.rules.layout ?? 'auto'}, {p.reads} read{p.reads === 1 ? '' : 's'}{p.is_active ? '' : ', not in use'})</span></summary>
          {p.notes && <p className="small muted">{p.notes}</p>}<ProfileEditor p={p} /></details>))}
      <details className="pt-card ad-card"><summary className="link"><b>Add a profile</b></summary><ProfileEditor p={null} /></details>
      <section className="pt-card ad-card" aria-labelledby="pf-csv"><h2 className="d4" id="pf-csv">CSV column mappings</h2>
        {csv.length ? <ul className="small">{csv.map((p) => <li key={p.id}>{p.operator}: {Object.values(p.mapping ?? {}).filter(Boolean).join(', ')}{p.date_format ? `; dates ${p.date_format}` : ''}</li>)}</ul>
          : <p className="small muted">None saved yet. A mapping is saved from the CSV import.</p>}</section>
    </div>
  );
}
