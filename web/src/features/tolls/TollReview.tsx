'use client';
import Link from 'next/link';
import { useMemo, useState, useTransition } from 'react';
import { useRouter } from 'next/navigation';
import { money } from '@/lib/format';
import { staffDo } from '@/server/actions/staff-tools';
import { KINDS, type Box } from './parse';
import { SourceView } from './SourceView';

// Check what was read from a notice (migration 0042): each line beside the file, corrected where it was misread,
// marked checked or left out with a reason; then "Confirm and import": the lines go through the toll import of
// 0021 (duplicates, validation, matching to the booking, the owner or staff), renters matched with high
// confidence are charged with the administration fee when ticked, and anything not imported stays here as an
// exception with its reason.
export type RLine = {
  id: string; line_no: number; kind: string | null; authority: string | null; notice_number: string | null; plate: string | null; transponder: string | null;
  occurred_at: string | null; time_unknown: boolean; place: string | null; entry: string | null; exit: string | null; amount_cents: number | null; fees_cents: number | null;
  due_on: string | null; confidence: number; problems: string[]; source_text: string | null; page: number | null; box: Box | null; vehicle_name: string | null;
  status: 'pending' | 'checked' | 'excluded' | 'imported' | 'duplicate' | 'exception'; result_reason: string | null; toll_ticket_id: string | null; edited: boolean;
  ticket: { id: string; status: string; matched_to: string; match_confidence: string | null; booking_number: string | null; charged_at: string | null } | null;
};
export type Read = {
  id: string; read_number: string; method: string; file_name: string | null; mime_type: string | null; document_id: string | null; authority: string | null; kind: string;
  statement_number: string | null; account_number: string | null; statement_date: string | null; due_on: string | null; total_cents: number | null; page_count: number | null;
  model: string | null; neurons: number; problems: string[]; status: 'in_review' | 'confirmed' | 'discarded'; created_at: string; created_by_name: string | null;
  confirmed_at: string | null; confirmed_by_name: string | null; discard_reason: string | null; min_confidence: number; auto_charge: boolean; profile_name: string | null;
  result: { imported?: number; duplicates?: number; exceptions?: number; charged?: number } | null; lines: RLine[];
};

const METHOD: Record<string, string> = { pdf_text: 'The text of the PDF', vision: 'The vision model', csv: 'CSV columns', manual: 'Typed by staff' };
const STATUS: Record<RLine['status'], string> = { pending: 'To check', checked: 'Checked', excluded: 'Left out', imported: 'Imported', duplicate: 'Already logged', exception: 'Not imported' };
const toronto = (iso: string | null) => {
  if (!iso) return '';
  const p = Object.fromEntries(new Intl.DateTimeFormat('en-CA', { timeZone: 'America/Toronto', year: 'numeric', month: '2-digit', day: '2-digit', hour: '2-digit', minute: '2-digit', hourCycle: 'h23' })
    .formatToParts(new Date(iso)).map((x) => [x.type, x.value]));
  return `${p.year}-${p.month}-${p.day}T${p.hour}:${p.minute}`;
};
const omit = <T,>(o: Record<string, T>, k: string) => Object.fromEntries(Object.entries(o).filter(([x]) => x !== k));
const dollars = (c: number | null) => (c == null ? '' : (c / 100).toFixed(2));
type Draft = { kind: string; authority: string; notice_number: string; plate: string; transponder: string; when: string; time_unknown: boolean; place: string; entry: string; exit: string; amount: string; fees: string; due_on: string };
const draftOf = (l: RLine): Draft => ({ kind: l.kind ?? '', authority: l.authority ?? '', notice_number: l.notice_number ?? '', plate: l.plate ?? '', transponder: l.transponder ?? '', when: toronto(l.occurred_at),
  time_unknown: l.time_unknown, place: l.place ?? '', entry: l.entry ?? '', exit: l.exit ?? '', amount: dollars(l.amount_cents), fees: dollars(l.fees_cents), due_on: l.due_on ?? '' });

export function TollReview({ read, base }: { read: Read; base: '/admin' | '/va' }) {
  const router = useRouter();
  const [pending, start] = useTransition();
  const [focus, setFocus] = useState<string | null>(read.lines[0]?.id ?? null);
  const [drafts, setDrafts] = useState<Record<string, Draft>>({});
  const [errs, setErrs] = useState<Record<string, string>>({});
  const [msg, setMsg] = useState<{ ok: boolean; text: string } | null>(null);
  const [charge, setCharge] = useState(read.auto_charge);
  const [discard, setDiscard] = useState('');
  const [exclude, setExclude] = useState<Record<string, string>>({});
  // a long statement is shown 30 lines at a time (the page stays light to render)
  const [shown, setShown] = useState(30);
  const open = read.status === 'in_review';
  const here = [`${base}/tolls/read/${read.id}`];
  const focused = read.lines.find((l) => l.id === focus) ?? null;
  const mark = useMemo(() => (focused ? (focused.box ? { ...focused.box, line: focused.line_no } : focused.page ? { page: focused.page, y: 0, h: 0, line: focused.line_no } : { page: 1, y: 0, h: 0, line: focused.line_no }) : null), [focused]);
  const goes = read.lines.filter((l) => l.status === 'checked' || (l.status === 'pending' && !l.problems.length));
  const stays = read.lines.filter((l) => l.status === 'pending' && l.problems.length);
  const sum = read.lines.filter((l) => l.status !== 'excluded').reduce((n, l) => n + (l.amount_cents ?? 0), 0);

  const values = (l: RLine) => {
    const d = drafts[l.id]; if (!d) return null;
    const o = draftOf(l); const v: Record<string, unknown> = {};
    const cents = (s: string) => (s.trim() ? Math.round(Number(s.replace(/[$,\s]/g, '')) * 100) : null);
    if (d.kind !== o.kind) v.kind = d.kind || null;
    for (const k of ['authority', 'notice_number', 'plate', 'transponder', 'place', 'entry', 'exit', 'due_on'] as const) if (d[k] !== o[k]) v[k] = d[k] || null;
    if (d.when !== o.when) v.occurred_at = d.when ? `${d.when}:00` : null;
    if (d.time_unknown !== o.time_unknown) v.time_unknown = d.time_unknown;
    if (d.amount !== o.amount) { const c = cents(d.amount); if (c != null && !Number.isFinite(c)) return 'Enter the amount in dollars'; v.amount_cents = c; }
    if (d.fees !== o.fees) { const c = cents(d.fees); if (c != null && !Number.isFinite(c)) return 'Enter the fees in dollars'; v.fees_cents = c; }
    return v;
  };
  const saveLine = (l: RLine, status?: 'checked' | 'excluded' | 'pending') => start(async () => {
    const v = values(l);
    if (typeof v === 'string') { setErrs({ ...errs, [l.id]: v }); return; }
    const r = await staffDo('toll_read_line', { line: l.id, values: v ?? {}, ...(status ? { status } : {}), ...(status === 'excluded' ? { reason: exclude[l.id] ?? '' } : {}) }, here);
    if (!r.ok) { setErrs({ ...errs, [l.id]: r.message }); return; }
    setErrs({ ...errs, [l.id]: '' }); setDrafts((x) => omit(x, l.id)); router.refresh();
  });
  const act = (fn: () => Promise<{ ok: boolean; message?: string }>, ok: string) => start(async () => { const r = await fn(); setMsg(r.ok ? { ok: true, text: ok } : { ok: false, text: r.message ?? 'Refused.' }); if (r.ok) router.refresh(); });

  const F = (l: RLine, k: keyof Draft, label: string, props: React.InputHTMLAttributes<HTMLInputElement> = {}) => {
    const d = drafts[l.id] ?? draftOf(l);
    const id = `rl-${l.line_no}-${k}`;
    return (
      <div className="field tr-f"><label className="label" htmlFor={id}>{label}</label>
        <input className="input" id={id} value={String(d[k])} disabled={!editable(l) || pending} data-testid={`line-${l.line_no}-${k}`}
          onFocus={() => setFocus(l.id)} onChange={(e) => setDrafts({ ...drafts, [l.id]: { ...d, [k]: e.target.value } })} {...props} /></div>
    );
  };
  const editable = (l: RLine) => read.status !== 'discarded' && ['pending', 'checked', 'exception'].includes(l.status);

  return (
    <div className="tr-review" data-testid="toll-review" data-status={read.status}>
      <div className="tr-review__source"><SourceView src={`/api/staff/toll-read/${read.id}/file`} mime={read.mime_type} name={read.file_name} mark={read.document_id ? mark : null} /></div>
      <div className="stack tr-review__lines">
        <section className="pt-card ad-card" aria-labelledby="tr-sum"><div className="pt-card__head"><h2 className="d4" id="tr-sum">{read.read_number}: {read.authority ?? 'Issuer not read'}</h2>
          <span className={`ad-b ${read.status === 'in_review' ? 'ad-b--amber' : read.status === 'confirmed' ? 'ad-b--dark' : 'ad-b--light'}`}>{read.status === 'in_review' ? 'To check' : read.status === 'confirmed' ? 'Confirmed' : 'Discarded'}</span></div>
          <dl className="pt-dl ad-kv">
            <div><dt>Read from</dt><dd>{METHOD[read.method] ?? read.method}{read.model ? ` (${read.model}, ${read.neurons} neurons)` : ''}{read.profile_name ? `, profile "${read.profile_name}"` : ''}</dd></div>
            {read.file_name && <div><dt>File</dt><dd>{read.file_name}</dd></div>}
            {read.statement_number && <div><dt>Statement</dt><dd>{read.statement_number}{read.account_number ? `, account ${read.account_number}` : ''}</dd></div>}
            {read.due_on && <div><dt>Due</dt><dd>{read.due_on}</dd></div>}
            <div><dt>Lines</dt><dd>{read.lines.length}, {money(sum, { cents: true })}{read.total_cents != null ? `; the statement says ${money(read.total_cents, { cents: true })}${read.total_cents !== sum ? ' (check the difference)' : ''}` : ''}</dd></div>
            {read.confirmed_at && <div><dt>Confirmed</dt><dd>{read.confirmed_by_name ?? ''}: {read.result?.imported ?? 0} imported, {read.result?.duplicates ?? 0} already logged, {read.result?.exceptions ?? 0} not imported{read.result?.charged ? `, ${read.result.charged} charged to the renter` : ''}</dd></div>}
            {read.discard_reason && <div><dt>Discarded</dt><dd>{read.discard_reason}</dd></div>}
          </dl>
          {read.problems.length > 0 && <ul className="small tr-problems" data-testid="read-problems">{read.problems.map((p, i) => <li key={i}>{p}</li>)}</ul>}
          {open && <div className="stack">
            <label className="check"><input type="checkbox" checked={charge} onChange={(e) => setCharge(e.target.checked)} data-testid="read-charge" /> <span>Charge renters matched with high confidence now (the notice and the administration fee)</span></label>
            <p className="small muted">{goes.length} line(s) will be imported. {stays.length ? `${stays.length} line(s) with a problem not checked by a person stay here as exceptions.` : ''} Lines read at {read.min_confidence}% or more with nothing missing need no check.</p>
            <div className="row">
              <button className="btn btn--primary btn--sm" type="button" disabled={pending || !read.lines.some((l) => l.status !== 'excluded') || Object.keys(drafts).length > 0} data-testid="read-confirm"
                onClick={() => act(async () => staffDo('toll_read_confirm', { read: read.id, charge }, [...here, `${base}/tolls`]), 'Confirmed: the lines went to the toll work queue.')}>{pending ? 'Working' : 'Confirm and import'}</button>
              {Object.keys(drafts).length > 0 && <span className="small ad-err">Save or undo your changes first.</span>}
              <button className="btn btn--ghost btn--sm" type="button" disabled={pending} data-testid="read-add" onClick={() => act(async () => staffDo('toll_read_line_add', { read: read.id }, here), 'A line was added.')}>Add a line</button>
            </div>
            <details><summary className="link small">Discard this read</summary>
              <div className="field"><label className="label" htmlFor="tr-disc">Why</label><input className="input" id="tr-disc" value={discard} onChange={(e) => setDiscard(e.target.value)} /></div>
              <button className="btn btn--ghost btn--sm" type="button" disabled={pending || !discard.trim()} onClick={() => act(async () => staffDo('toll_read_discard', { read: read.id, reason: discard }, here), 'Discarded.')}>Discard</button>
            </details>
          </div>}
          {msg && <p className={`alert ${msg.ok ? 'alert--ok' : 'alert--error'}`} role={msg.ok ? 'status' : 'alert'}><span>{msg.text}</span></p>}
          {read.status === 'confirmed' && <Link prefetch={false} className="btn btn--ghost btn--sm" href={`${base}/tolls`}>Open the toll work queue</Link>}
        </section>

        {read.lines.length === 0 && <p className="pt-note small">No lines were read. Add each trip or offence by hand, with the notice beside it.</p>}
        <ol className="tr-lines">{read.lines.slice(0, shown).map((l) => {
          const d = drafts[l.id] ?? draftOf(l);
          const low = l.confidence < read.min_confidence;
          return (
            <li key={l.id} className={`pt-card ad-card tr-line is-${l.status}${focus === l.id ? ' is-focus' : ''}`} data-testid={`read-line-${l.line_no}`} data-status={l.status} onClick={() => setFocus(l.id)}>
              <div className="pt-card__head"><h3 className="d5">Line {l.line_no}</h3>
                <span className="row"><span className={`ad-b ${low ? 'ad-b--amber' : 'ad-b--light'}`} title="How sure the reading is">{l.confidence}% sure</span>
                  <span className={`ad-b ${l.status === 'imported' ? 'ad-b--dark' : l.status === 'exception' ? 'ad-b--red' : l.status === 'checked' ? 'ad-b--grey' : 'ad-b--wait'}`}>{STATUS[l.status]}</span></span></div>
              {l.problems.length > 0 && ['pending', 'checked', 'exception'].includes(l.status) && <p className="small ad-late" data-testid={`line-${l.line_no}-problems`}>{l.problems.join('; ')}</p>}
              {l.result_reason && l.status !== 'exception' && <p className="small muted">{l.result_reason}</p>}
              {l.status === 'exception' && l.result_reason && <p className="small ad-late">Not imported: {l.result_reason}</p>}
              <div className="tr-grid">
                <div className="field tr-f"><label className="label" htmlFor={`rl-${l.line_no}-kind`}>Kind</label>
                  <select className="select" id={`rl-${l.line_no}-kind`} value={d.kind} disabled={!editable(l) || pending} onFocus={() => setFocus(l.id)} onChange={(e) => setDrafts({ ...drafts, [l.id]: { ...d, kind: e.target.value } })}>
                    <option value="">As the read</option>{KINDS.map(([k, t]) => <option key={k} value={k}>{t}</option>)}</select></div>
                {F(l, 'authority', 'Issuer')}{F(l, 'notice_number', 'Notice number')}{F(l, 'plate', 'Plate', { autoCapitalize: 'characters' })}
                {F(l, 'when', 'Date and time (Toronto)', { type: 'datetime-local' })}
                <div className="field tr-f"><label className="check" htmlFor={`rl-${l.line_no}-tu`}><input id={`rl-${l.line_no}-tu`} type="checkbox" checked={d.time_unknown} disabled={!editable(l) || pending}
                  onChange={(e) => setDrafts({ ...drafts, [l.id]: { ...d, time_unknown: e.target.checked } })} /> <span>Time not on the notice</span></label></div>
                {F(l, 'amount', 'Amount ($)', { inputMode: 'decimal' })}{F(l, 'fees', 'Of which fees ($)', { inputMode: 'decimal' })}
                {F(l, 'entry', 'Entry')}{F(l, 'exit', 'Exit')}{F(l, 'place', 'Location')}{F(l, 'transponder', 'Transponder')}{F(l, 'due_on', 'Due date', { type: 'date' })}
              </div>
              <p className="small muted">{l.vehicle_name ? `Car: ${l.vehicle_name}` : l.plate ? 'No car of the fleet has this plate on that date' : ''}{l.source_text ? ` · Read as: ${l.source_text}` : ''}</p>
              {l.ticket && <p className="small">Logged: <Link prefetch={false} className="link" href={`${base}/tolls${base === '/admin' ? `/${l.ticket.id}` : ''}`}>{l.ticket.status.replace(/_/g, ' ')}</Link>, matched to {l.ticket.matched_to.replace(/_/g, ' ')}{l.ticket.booking_number ? ` ${l.ticket.booking_number}` : ''}{l.ticket.match_confidence ? ` (${l.ticket.match_confidence})` : ''}{l.ticket.charged_at ? ', charged' : ''}</p>}
              {errs[l.id] && <p className="small ad-err" role="alert">{errs[l.id]}</p>}
              {editable(l) && <div className="row tr-actions">
                {drafts[l.id] && <><button className="btn btn--primary btn--sm" type="button" disabled={pending} onClick={() => saveLine(l)} data-testid={`line-${l.line_no}-save`}>Save</button>
                  <button className="btn btn--ghost btn--sm" type="button" disabled={pending} onClick={() => setDrafts((x) => omit(x, l.id))}>Undo</button></>}
                {open && l.status !== 'checked' && <button className="btn btn--ghost btn--sm" type="button" disabled={pending} onClick={() => saveLine(l, 'checked')} data-testid={`line-${l.line_no}-check`}>{drafts[l.id] ? 'Save as checked' : 'Checked against the notice'}</button>}
                {read.status === 'confirmed' && ['exception', 'pending', 'checked'].includes(l.status) && !drafts[l.id] && <button className="btn btn--primary btn--sm" type="button" disabled={pending} data-testid={`line-${l.line_no}-import`}
                  onClick={() => act(async () => staffDo('toll_read_line_import', { line: l.id }, here), `Line ${l.line_no} imported.`)}>Import this line</button>}
                <span className="tr-excl"><label className="vh" htmlFor={`rl-${l.line_no}-why`}>Why line {l.line_no} is left out</label>
                  <input className="input input--sm" id={`rl-${l.line_no}-why`} placeholder="Why it is left out" value={exclude[l.id] ?? ''} onChange={(e) => setExclude({ ...exclude, [l.id]: e.target.value })} />
                  <button className="btn btn--ghost btn--sm" type="button" disabled={pending || !(exclude[l.id] ?? '').trim()} onClick={() => saveLine(l, 'excluded')}>Leave out</button></span>
              </div>}
              {open && l.status === 'excluded' && <div className="row"><button className="btn btn--ghost btn--sm" type="button" disabled={pending} onClick={() => saveLine(l, 'pending')}>Put it back</button></div>}
            </li>);
        })}</ol>
        {read.lines.length > shown && <button type="button" className="btn btn--ghost btn--sm" onClick={() => setShown(shown + 30)} data-testid="read-more">Show {Math.min(30, read.lines.length - shown)} more of {read.lines.length - shown} lines</button>}
      </div>
    </div>
  );
}
