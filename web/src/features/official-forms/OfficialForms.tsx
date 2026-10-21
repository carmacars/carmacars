'use client';
import { useMemo, useState, useTransition } from 'react';
import { useRouter } from 'next/navigation';
import { staffDo, staffRead, uploadFormTemplate } from '@/server/actions/staff-tools';
import type { PdfField, Spec } from './fill';
import { FormReview } from './FormReview';

// Admin > Settings > Forms (migration 0042): the official ServiceOntario PDFs. Upload the fillable PDF of a form;
// its fields are read here in the browser; choose what goes in each field; preview it filled for a car; then
// "Use for owners": every owner's form not signed yet is filled again from it, and owners get the official PDF to
// sign or download instead of the data sheet.
type Tpl = { id: string; version: string; kind?: 'acroform' | 'overlay' | 'generated'; notes?: string | null; title: string | null; file_key: string | null; file_name: string | null; page_count: number | null; field_names: PdfField[]; field_map: Record<string, Spec | string>;
  verified: boolean; verified_at: string | null; verified_by_name: string | null; mapped_at: string | null; mapped_by_name: string | null };
export type FormsData = { forms: Array<{ form_code: string; current: Tpl | null; versions: number; fills: { pdf: number; data_sheet: number } }>;
  sources: Array<{ path: string; label: string; section: string }>; transforms: string[]; vehicles: Array<{ id: string; name: string; owner: string }> };
const TRANSFORM: Record<string, string> = { upper: 'CAPITALS', lower: 'lower case', postal: 'Postal code (A1A 1A1)', phone: 'Phone ((416) 555-0100)', yesno: 'Yes or No',
  'date:YYYY-MM-DD': 'Date 2026-10-14', 'date:DD/MM/YYYY': 'Date 14/10/2026', 'date:MM/DD/YYYY': 'Date 10/14/2026', 'date:YYYY': 'Year only', 'date:MM': 'Month only', 'date:DD': 'Day only' };
const spec = (s: Spec | string | undefined): Spec => (typeof s === 'string' ? { source: s } : s ?? {});

function Upload({ code }: { code: string }) {
  const router = useRouter();
  const [busy, setBusy] = useState(false);
  const [msg, setMsg] = useState<{ ok: boolean; text: string } | null>(null);
  const id = `fu-${code}`;
  return (
    <div className="field"><label className="label" htmlFor={id}>Upload the official fillable PDF</label>
      <input className="input" id={id} type="file" accept="application/pdf" disabled={busy} data-testid={`form-upload-${code}`} onChange={async (e) => {
        const f = e.target.files?.[0]; if (!f) return;
        setBusy(true); setMsg(null);
        try {
          const { readFields } = await import('./fill');
          const { fields, pages } = await readFields(await f.arrayBuffer());
          if (!fields.length) throw new Error('This PDF has no fillable fields. Download the fillable version of the form from ServiceOntario and upload that one.');
          const fd = new FormData(); fd.set('file', f); fd.set('form_code', code); fd.set('fields', JSON.stringify(fields)); fd.set('page_count', String(pages));
          const r = await uploadFormTemplate(fd);
          if (!r.ok) throw new Error(r.message);
          setMsg({ ok: true, text: `Read ${fields.length} fields on ${pages} page${pages === 1 ? '' : 's'}. Choose what goes in each one below.` });
          router.refresh();
        } catch (x) { setMsg({ ok: false, text: x instanceof Error ? x.message : 'The PDF could not be read.' }); } finally { setBusy(false); e.target.value = ''; }
      }} />
      {msg && <p className={`small ${msg.ok ? '' : 'ad-err'}`} role={msg.ok ? 'status' : 'alert'}>{msg.text}</p>}
    </div>
  );
}

function Mapping({ code, t, d }: { code: string; t: Tpl; d: FormsData }) {
  const router = useRouter();
  const [pending, start] = useTransition();
  // a coordinates-based template (a form with no fillable field): each value is drawn in the box the field list gives
  const [map, setMap] = useState<Record<string, Spec>>(() => Object.fromEntries(t.field_names.map((f) => [f.name,
    t.kind === 'overlay' && f.rect && f.page ? { ...spec(t.field_map[f.name]), box: { page: f.page, rect: f.rect } } : spec(t.field_map[f.name])])));
  const [vehicle, setVehicle] = useState(d.vehicles[0]?.id ?? '');
  const [msg, setMsg] = useState<{ ok: boolean; text: string } | null>(null);
  const sections = useMemo(() => [...new Set(d.sources.map((s) => s.section))], [d.sources]);
  const yesNo = d.sources.filter((s) => /\(yes or no\)/.test(s.label));
  const cleaned = () => Object.fromEntries(Object.entries(map).filter(([, s]) => s.type === 'signature' || s.source).map(([k, s]) => [k, Object.fromEntries(Object.entries(s).filter(([, v]) => v !== undefined && v !== '' && v !== false))]));
  const mapped = Object.keys(cleaned()).length;
  const save = (verify: boolean) => start(async () => {
    const r = await staffDo<{ refilled: number }>('form_template_map', { template: t.id, field_map: cleaned(), verify }, ['/admin/settings/forms']);
    setMsg(r.ok ? { ok: true, text: verify ? `Checked and in use: ${r.data.refilled} owner form(s) filled again from it.` : 'Mapping saved. Owners keep the data sheet until you use it for owners.' } : { ok: false, text: r.message });
    if (r.ok) router.refresh();
  });
  const preview = () => start(async () => {
    setMsg(null);
    const v = await staffRead<{ values: Record<string, string | null>; field_map: Record<string, Spec> }>('form_template_preview', { template: t.id, vehicle });
    if (!v.ok) { setMsg({ ok: false, text: v.message }); return; }
    const file = await fetch(`/api/staff/form-template/${t.id}`);
    if (!file.ok) { setMsg({ ok: false, text: 'The PDF could not be opened.' }); return; }
    const { fillPdf } = await import('./fill');
    // the preview uses the mapping on screen once saved; before that the values of the saved mapping
    const out = await fillPdf(await file.arrayBuffer(), v.data.values, v.data.field_map);
    const url = URL.createObjectURL(new Blob([out.bytes as unknown as BlobPart], { type: 'application/pdf' }));
    const a = document.createElement('a'); a.href = url; a.download = `${code}-preview.pdf`; a.click();
    setTimeout(() => URL.revokeObjectURL(url), 30_000);
    setMsg({ ok: true, text: `Preview downloaded: ${out.filled.length} field(s) filled${out.missing.length ? `; not found in the PDF: ${out.missing.join(', ')}` : ''}.` });
  });
  return (
    <div className="stack" data-testid={`form-map-${code}`}>
      <div className="table-scroll ad-scroll" tabIndex={0} role="region" aria-label={`Fields of ${code}`}>
        <table className="ad-table ad-table--dense"><thead><tr><th scope="col">Field in the PDF</th><th scope="col">What goes in it</th><th scope="col">Format</th><th scope="col">Only when</th><th scope="col">Needed</th></tr></thead>
          <tbody>{t.field_names.map((f, i) => { const s = map[f.name] ?? {}; const set = (x: Partial<Spec>) => setMap({ ...map, [f.name]: { ...s, ...x } }); const idb = `fm-${code}-${i}`; return (
            <tr key={f.name}>
              <th scope="row"><label htmlFor={`${idb}-s`} className="pt-mono">{f.name}</label><br /><span className="small muted">{f.type}{f.page ? `, page ${f.page}` : ''}</span></th>
              <td><select className="select" id={`${idb}-s`} value={s.type === 'signature' ? '@signature' : s.source ?? ''} data-testid={`map-${f.name}`}
                onChange={(e) => set(e.target.value === '@signature' ? { type: 'signature', source: undefined } : { source: e.target.value || undefined, type: f.type === 'checkbox' ? 'checkbox' : f.type === 'dropdown' ? 'dropdown' : f.type === 'radio' ? 'radio' : 'text' })}>
                <option value="">Leave empty</option>
                {(f.type === 'signature' || f.type === 'text') && <option value="@signature">The owner signs here (drawn on screen)</option>}
                {sections.map((sec) => <optgroup key={sec} label={sec}>{d.sources.filter((x) => x.section === sec).map((x) => <option key={x.path} value={x.path}>{x.label}</option>)}</optgroup>)}
              </select></td>
              <td><label className="vh" htmlFor={`${idb}-t`}>Format of {f.name}</label><select className="select" id={`${idb}-t`} value={s.transform ?? ''} disabled={s.type === 'signature' || f.type === 'checkbox'} onChange={(e) => set({ transform: e.target.value || undefined })}>
                <option value="">As it is</option>{d.transforms.map((x) => <option key={x} value={x}>{TRANSFORM[x] ?? x}</option>)}</select></td>
              <td><label className="vh" htmlFor={`${idb}-w`}>Condition for {f.name}</label><select className="select" id={`${idb}-w`} value={s.when ?? ''} disabled={s.type === 'signature'} onChange={(e) => set({ when: e.target.value || undefined })}>
                <option value="">Always</option>{yesNo.map((x) => <option key={x.path} value={x.path}>{x.label.replace(/ \(yes or no\)/, '')}</option>)}</select></td>
              <td><label className="check" htmlFor={`${idb}-r`}><input id={`${idb}-r`} type="checkbox" checked={!!s.required} disabled={s.type === 'signature'} onChange={(e) => set({ required: e.target.checked || undefined })} /> <span className="vh">{f.name} is needed</span></label></td>
            </tr>); })}</tbody></table></div>
      <p className="small muted">{mapped} of {t.field_names.length} fields filled from the records. A needed field left empty keeps the owner&apos;s form waiting, with the reason.</p>
      <div className="row">
        <button className="btn btn--ghost btn--sm" type="button" disabled={pending} onClick={() => save(false)} data-testid={`form-save-${code}`}>Save the mapping</button>
        <button className="btn btn--primary btn--sm" type="button" disabled={pending || !mapped} onClick={() => save(true)} data-testid={`form-verify-${code}`}>{t.verified ? 'Save and keep in use' : 'Checked: use for owners'}</button>
      </div>
      {d.vehicles.length > 0 && <div className="row">
        <label className="label" htmlFor={`fp-${code}`}>Preview with</label>
        <select className="select" id={`fp-${code}`} value={vehicle} onChange={(e) => setVehicle(e.target.value)}>{d.vehicles.map((v) => <option key={v.id} value={v.id}>{v.name} ({v.owner})</option>)}</select>
        <button className="btn btn--ghost btn--sm" type="button" disabled={pending || !vehicle} onClick={preview} data-testid={`form-preview-${code}`}>Download a filled preview</button>
      </div>}
      {msg && <p className={`alert ${msg.ok ? 'alert--ok' : 'alert--error'}`} role={msg.ok ? 'status' : 'alert'}><span>{msg.text}</span></p>}
    </div>
  );
}

// Open while the mapping is being checked; it stays as the person left it when the page refreshes after "Checked:
// use for owners", so the confirmation under the table stays in view.
function FieldsPanel({ startOpen, children }: { startOpen: boolean; children: React.ReactNode }) {
  const [open, setOpen] = useState(startOpen);
  return <details open={open} onToggle={(e) => setOpen((e.currentTarget as HTMLDetailsElement).open)}><summary className="link">Fields and what goes in them</summary>{children}</details>;
}

export function OfficialForms({ d }: { d: FormsData }) {
  return (
    <div className="stack" data-testid="official-forms">
      <p className="small muted">Until a form&apos;s official PDF is uploaded, mapped and checked, owners get a data sheet with every value to copy onto the form. Upload the fillable PDF from ServiceOntario, choose what goes in each field, download a preview for one car, then use it for owners.</p>
      {d.forms.map((f) => {
        const t = f.current; const official = !!t?.file_key;
        return (
          <section key={f.form_code} id={`form-card-${f.form_code}`} className="pt-card ad-card" aria-labelledby={`of-${f.form_code}`} data-testid={`form-${f.form_code}`}>
            <div className="pt-card__head"><h2 className="d4" id={`of-${f.form_code}`}>{f.form_code}{t?.title && !t.title.startsWith(f.form_code) ? `: ${t.title}` : t?.title ? `: ${t.title.slice(f.form_code.length).trim()}` : ''}</h2>
              <span className={`ad-b ${t?.verified && official ? 'ad-b--dark' : official ? 'ad-b--amber' : 'ad-b--light'}`}>{t?.verified && official ? 'Official PDF in use' : official ? 'Mapping to check' : 'Data sheet in use'}</span></div>
            <p className="small">{official ? `${t!.file_name ?? 'PDF'}, ${t!.field_names.length} fields${t!.page_count ? ` on ${t!.page_count} page(s)` : ''}, version ${t!.version}` : 'No official PDF yet.'}
              {t?.verified_at ? ` Checked by ${t.verified_by_name ?? 'an Admin'}.` : ''} Owners now: {f.fills.pdf} with the official PDF, {f.fills.data_sheet} with the data sheet.</p>
            {official && t!.kind === 'overlay' && <p className="small" data-testid={`form-overlay-${f.form_code}`}>This form has no fillable fields (the publisher&apos;s PDF is an Adobe dynamic form). It was laid out as a plain PDF, and each value is printed in the box of its field.</p>}
            {official && t!.notes && <p className="small muted">{t!.notes}</p>}
            {official && !t!.verified && t!.field_names.length > 0 && <FormReview code={f.form_code} templateId={t!.id} fieldMap={t!.field_map} vehicles={d.vehicles} />}
            <Upload code={f.form_code} />
            {official && t!.field_names.length > 0 && <FieldsPanel startOpen={!t!.verified}><Mapping key={t!.id} code={f.form_code} t={t!} d={d} /></FieldsPanel>}
          </section>);
      })}
    </div>
  );
}
