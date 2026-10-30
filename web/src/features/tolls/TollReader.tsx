'use client';
import { useEffect, useState } from 'react';
import { useRouter } from 'next/navigation';
import { staffDo, staffRead, uploadNotice } from '@/server/actions/staff-tools';
import { useDoor } from '@/features/admin/door';
import { CSV_TARGETS, csvLines, parseCsv, pickProfile, readText, type Kind, type Profile, type ReadLine, type Rules } from './parse';
import { normalizeTollVision } from './vision-schema';

// Read a notice or a statement (migration 0042). The file is stored first (it is the proof a renter or owner is
// sent), then read in this browser: a CSV with its column mapping, a PDF from its text with the issuer's reading
// profile, a scan or a photo by the vision model, page by page. What was read is saved as lines to check beside
// the file on the next screen. Nothing is imported until a person confirms.
type Ctx = { profiles: Profile[]; plates: string[]; transponders: string[]; settings: { min_confidence: number; auto_charge: boolean; max_pages: number; vision: boolean };
  vision: { allowed?: boolean; used: number; limit: number } };
type Save = { method: 'csv' | 'pdf_text' | 'vision' | 'manual'; profile_id?: string | null; authority?: string | null; kind: Kind; statement_number?: string | null; account_number?: string | null;
  statement_date?: string | null; due_on?: string | null; total_cents?: number | null; page_count?: number | null; model?: string | null; neurons?: number; problems: string[]; lines: ReadLine[] };

export function TollReader({ base }: { base: '/admin' | '/staff' }) {
  const router = useRouter();
  const { act } = useDoor();
  const [ctx, setCtx] = useState<Ctx | null>(null);
  const [file, setFile] = useState<File | null>(null);
  const [profileId, setProfileId] = useState('auto');
  const [steps, setSteps] = useState<string[]>([]);
  const [err, setErr] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);
  const [csv, setCsv] = useState<{ rows: string[][]; map: Record<string, string>; profile: Profile | null; operator: string; kind: Kind; order: Rules['date_order'] } | null>(null);
  useEffect(() => { void staffRead<Ctx>('toll_read_context').then((r) => (r.ok ? setCtx(r.data) : setErr(r.message))); }, []);
  const say = (s: string) => setSteps((x) => [...x, s]);
  const textProfiles = (ctx?.profiles ?? []).filter((p) => p.source === 'pdf_text');

  async function save(docId: string | null, s: Save) {
    say('Saving what was read');
    const r = await staffDo<{ id: string }>('toll_read_save', { ...s, document_id: docId, file_name: file?.name ?? null, mime_type: file?.type || null });
    if (!r.ok) throw new Error(r.message);
    router.push(`${base}/tolls/read/${r.data.id}`);
  }

  async function vision(pages: Array<() => Promise<string>>, fallbackKind: Kind): Promise<Save> {
    const lines: ReadLine[] = []; const problems: string[] = [];
    let head: Partial<Save> = {}; let model: string | null = null; let neurons = 0;
    if (!ctx!.settings.vision) return { method: 'manual', kind: fallbackKind, problems: ['Reading with the vision model is off in Program settings: type the lines beside the notice'], lines: [] };
    for (let i = 0; i < pages.length; i++) {
      say(`Reading page ${i + 1} of ${pages.length} with the vision model`);
      const img = await pages[i]!();
      const r = await (await import('./pdf')).askVision('toll_read', img);
      if (!r.ok) { problems.push(`Page ${i + 1} was not read: ${r.message}`); if (r.reason === 'off' || r.reason === 'quota') break; continue; }
      model = r.model; neurons += r.neurons;
      const v = normalizeTollVision(r.data, { page: i + 1, plates: ctx!.plates, fallbackKind });
      problems.push(...v.problems.map((p) => `Page ${i + 1}: ${p}`));
      lines.push(...v.lines);
      head = { authority: head.authority ?? v.authority, kind: head.kind ?? v.kind, statement_number: head.statement_number ?? v.statement_number,
        account_number: head.account_number ?? v.account_number, due_on: head.due_on ?? v.due_on, total_cents: head.total_cents ?? v.total_cents };
    }
    if (!lines.length && !model) return { method: 'manual', kind: fallbackKind, problems: [...problems, 'Type the lines beside the notice'], lines: [] };
    return { method: 'vision', kind: head.kind ?? fallbackKind, authority: head.authority ?? null, statement_number: head.statement_number ?? null, account_number: head.account_number ?? null,
      due_on: head.due_on ?? null, total_cents: head.total_cents ?? null, page_count: pages.length, model, neurons, problems, lines };
  }

  async function read() {
    if (!file || !ctx) return;
    setBusy(true); setErr(null); setSteps([]);
    try {
      const isCsv = /\.csv$/i.test(file.name) || file.type === 'text/csv';
      if (isCsv) {
        const rows = parseCsv(await file.text());
        if (rows.length < 2) throw new Error('The CSV file has no rows under its header.');
        const sig = rows[0]!.map((h) => h.trim().toLowerCase()).join('|');
        const saved = ctx.profiles.find((p) => p.source === 'csv' && p.header_signature === sig) ?? null;
        const map: Record<string, string> = saved?.mapping ? { ...saved.mapping } : {};
        if (!saved) rows[0]!.forEach((x, i) => { const s = x.toLowerCase(); const t = s.includes('plate') ? 'plate' : s.includes('transponder') || s.includes('tag') ? 'transponder' : s.includes('fee') ? 'fees' : s.includes('amount') || s.includes('charge') || s.includes('total') || s.includes('toll') ? 'amount'
          : s.includes('date') && s.includes('time') ? 'occurred_at' : s.includes('date') ? 'date' : s.includes('time') ? 'time' : s.includes('trip') || s.includes('transaction') || s.includes('notice') ? 'notice_number' : s.includes('entry') ? 'entry' : s.includes('exit') ? 'exit' : s.includes('location') || s.includes('place') ? 'place' : '';
          if (t && !Object.values(map).includes(t)) map[String(i)] = t; });
        setCsv({ rows, map, profile: saved, operator: saved?.operator ?? '407 ETR', kind: 'toll_invoice', order: (saved?.date_format as Rules['date_order']) ?? 'auto' });
        say(saved ? `The saved column mapping for ${saved.operator} was applied: check it, then read the rows` : 'Match each column, then read the rows');
        setBusy(false);
        return;
      }
      say('Storing the file');
      const up = new FormData(); up.set('file', file); up.set('title', file.name);
      const doc = await uploadNotice(up);
      if (!doc.ok) throw new Error(doc.message);
      const chosen = profileId === 'auto' ? null : textProfiles.find((p) => p.id === profileId) ?? null;
      if (file.type === 'application/pdf' || /\.pdf$/i.test(file.name)) {
        say('Opening the PDF');
        const { openPdf, pdfLines, pageJpeg } = await import('./pdf');
        const pdf = await openPdf(await file.arrayBuffer());
        const t = await pdfLines(pdf);
        const pages = Array.from({ length: Math.min(pdf.numPages, ctx.settings.max_pages) }, (_, i) => () => pageJpeg(pdf, i + 1));
        if (t.chars >= 80) {
          const profile = chosen ?? pickProfile(t.lines.map((l) => l.text).join('\n'), textProfiles);
          say(`The PDF has text: reading it with the profile "${profile?.name ?? 'none'}"`);
          const r = readText(t.lines, profile, { plates: ctx.plates, transponders: ctx.transponders });
          if (r.lines.length) {
            await save(doc.data.id, { method: 'pdf_text', profile_id: profile?.id ?? null, authority: r.authority, kind: r.kind, statement_number: r.statement_number, account_number: r.account_number,
              statement_date: r.statement_date, due_on: r.due_on, total_cents: r.total_cents, page_count: t.pages,
              problems: [...r.problems, ...r.statement_fees.map((f) => `Not a trip, left out: ${f.text}`)], lines: r.lines });
            return;
          }
          say('No lines were found in the text: trying the vision model');
        } else say('This PDF has no text layer (a scan)');
        await save(doc.data.id, await vision(pages, chosen?.notice_kind ?? 'fine'));
        return;
      }
      const { imageJpeg } = await import('./pdf');
      await save(doc.data.id, await vision([async () => (await imageJpeg(file)).dataUrl], chosen?.notice_kind ?? 'fine'));
    } catch (e) {
      setErr(e instanceof Error ? e.message : 'The file could not be read.');
      setBusy(false);
    }
  }

  async function readCsv() {
    if (!csv || !file || !ctx) return;
    setBusy(true); setErr(null);
    try {
      say('Storing the file');
      const up = new FormData(); up.set('file', file); up.set('title', file.name);
      const doc = await uploadNotice(up);
      if (!doc.ok) throw new Error(doc.message);
      const lines = csvLines(csv.rows, csv.map, { kind: csv.kind, authority: csv.operator, dateOrder: csv.order, plates: ctx.plates, amountUnit: csv.profile?.amount_unit });
      await save(doc.data.id, { method: 'csv', profile_id: csv.profile?.id ?? null, authority: csv.operator, kind: csv.kind, problems: [], lines });
    } catch (e) { setErr(e instanceof Error ? e.message : 'The file could not be read.'); setBusy(false); }
  }

  return (
    <div className="stack" data-testid="toll-reader">
      <section className="pt-card ad-card ad-form" aria-labelledby="tr-1"><h2 className="d4" id="tr-1">The notice or statement</h2>
        <p className="small muted">A PDF with text is read from its text with the issuer&apos;s reading profile. A scan or a photo is read by the vision model{ctx ? ` (${ctx.vision.used.toLocaleString('en-CA')} of ${ctx.vision.limit.toLocaleString('en-CA')} neurons used today)` : ''}. A CSV uses its column mapping. You check every line beside the file before anything is imported.</p>
        <div className="ad-fields">
          <div className="field ad-field ad-field--wide"><label className="label" htmlFor="tr-file">File (PDF, JPEG, PNG or CSV, under 15 MB)</label>
            <input className="input" id="tr-file" type="file" accept="application/pdf,image/jpeg,image/png,.csv,text/csv" data-testid="toll-read-file" disabled={busy}
              onChange={(e) => { setFile(e.target.files?.[0] ?? null); setCsv(null); setSteps([]); setErr(null); }} /></div>
          <div className="field ad-field"><label className="label" htmlFor="tr-prof">Reading profile</label>
            <select className="select" id="tr-prof" value={profileId} onChange={(e) => setProfileId(e.target.value)} disabled={busy}>
              <option value="auto">Find it from the text</option>{textProfiles.map((p) => <option key={p.id} value={p.id}>{p.name}</option>)}</select></div>
        </div>
        <div className="row"><button className="btn btn--primary btn--sm" type="button" disabled={!file || !ctx || busy} onClick={read} data-testid="toll-read-run">{busy ? 'Reading' : 'Read it'}</button></div>
      </section>
      {csv && (
        <section className="pt-card ad-card ad-form" aria-labelledby="tr-2"><h2 className="d4" id="tr-2">Columns</h2>
          <div className="ad-fields">
            <div className="field ad-field"><label className="label" htmlFor="tr-op">Issuer</label><input className="input" id="tr-op" value={csv.operator} onChange={(e) => setCsv({ ...csv, operator: e.target.value })} /></div>
            <div className="field ad-field"><label className="label" htmlFor="tr-k">Kind</label><select className="select" id="tr-k" value={csv.kind} onChange={(e) => setCsv({ ...csv, kind: e.target.value as Kind })}>
              <option value="toll_invoice">Tolls</option><option value="ticket">Tickets</option><option value="camera_offence">Camera offences</option><option value="parking">Parking</option></select></div>
            <div className="field ad-field"><label className="label" htmlFor="tr-o">Dates are written</label><select className="select" id="tr-o" value={csv.order ?? 'auto'} onChange={(e) => setCsv({ ...csv, order: e.target.value as Rules['date_order'] })}>
              <option value="auto">Find out from the dates</option><option value="ymd">Year, month, day</option><option value="mdy">Month, day, year</option><option value="dmy">Day, month, year</option></select></div>
          </div>
          <div className="ad-mapping">{csv.rows[0]!.map((h, i) => (
            <div key={i} className="field"><label className="label" htmlFor={`tr-c${i}`}>{h || `Column ${i + 1}`}</label>
              <select className="select" id={`tr-c${i}`} value={csv.map[String(i)] ?? ''} onChange={(e) => setCsv({ ...csv, map: { ...csv.map, [String(i)]: e.target.value } })}><option value="">Not used</option>{CSV_TARGETS.map(([a, b]) => <option key={a} value={a}>{b}</option>)}</select>
              <span className="small muted">{csv.rows[1]?.[i]}</span></div>))}</div>
          <div className="row">
            <button className="btn btn--ghost btn--sm" type="button" disabled={busy} onClick={async () => { const sig = csv.rows[0]!.map((h) => h.trim().toLowerCase()).join('|');
              const r = await act<{ id: string }>('toll_profile_save', { profile: { operator: csv.operator, name: csv.operator, header_signature: sig, mapping: csv.map, date_format: csv.order } });
              say(r.ok ? `Mapping saved for ${csv.operator}` : r.message); }}>Save this mapping</button>
            <button className="btn btn--primary btn--sm" type="button" disabled={busy} onClick={readCsv} data-testid="toll-read-csv">{`Read ${csv.rows.length - 1} rows`}</button>
          </div>
        </section>
      )}
      {steps.length > 0 && <ol className="small ad-steps" role="status" aria-live="polite" data-testid="toll-read-steps">{steps.map((s, i) => <li key={i}>{s}</li>)}</ol>}
      {err && <p className="alert alert--error" role="alert"><span>{err}</span></p>}
    </div>
  );
}
