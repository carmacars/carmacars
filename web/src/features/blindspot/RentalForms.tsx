'use client';
import { useState, useTransition } from 'react';
import { useRouter } from 'next/navigation';
import Link from 'next/link';
import { staffDo, uploadRentalForm, uploadRentalSignature } from '@/server/actions/staff-tools';

// Admin > Settings > Forms (0127): the forms filled for every booking. Blind Spot's rental agreement is the second
// agreement of each booking: upload Blind Spot's blank PDF, download the filled sample, then "Checked: use for bookings".
// The authorized company representative's name is written on it in a script hand; an uploaded image of the signature
// is used instead when there is one.
export interface RentalForm {
  form_code: string;
  current: { id: string; version: string; title: string | null; notes: string | null; file_name: string | null; has_file: boolean; sha256: string | null; page_count: number | null;
    verified: boolean; verified_at: string | null; verified_by_name: string | null; uploaded_at: string | null; uploaded_by_name: string | null } | null;
  versions: number;
  rep: { name: string; full_name: string | null; has_signature: boolean; signature_at: string | null; signature_by_name: string | null } | null;
  bookings: { open: number; signed: number };
  mailing_address: string | null;
  hst_number: string | null;
}

function Msg({ m }: { m: { ok: boolean; text: string } | null }) {
  return m ? <p className={`alert ${m.ok ? 'alert--ok' : 'alert--error'}`} role={m.ok ? 'status' : 'alert'}><span>{m.text}</span></p> : null;
}

function Card({ f }: { f: RentalForm }) {
  const router = useRouter();
  const [pending, start] = useTransition();
  const [msg, setMsg] = useState<{ ok: boolean; text: string } | null>(null);
  const [name, setName] = useState(f.rep?.name ?? 'Ahmad');
  const [full, setFull] = useState(f.rep?.full_name ?? '');
  const t = f.current; const code = f.form_code;
  const inUse = !!t?.has_file && t.verified;
  const upload = (kind: 'pdf' | 'png') => async (e: React.ChangeEvent<HTMLInputElement>) => {
    const file = e.target.files?.[0]; if (!file) return;
    setMsg(null);
    const fd = new FormData(); fd.set('file', file); fd.set('form_code', code);
    start(async () => {
      let r: Awaited<ReturnType<typeof uploadRentalForm>> | Awaited<ReturnType<typeof uploadRentalSignature>>;
      try { r = kind === 'pdf' ? await uploadRentalForm(fd) : await uploadRentalSignature(fd); }
      catch { setMsg({ ok: false, text: 'The upload did not go through. Check the file (a PDF under 15 MB) and try again.' }); return; }
      setMsg(r.ok ? { ok: true, text: kind === 'pdf' ? ((r.data as { same?: boolean }).same ? 'That is the PDF already stored.' : 'Stored. Download the filled sample, then press "Checked: use for bookings".') : 'Signature stored: it is used on every new agreement.' } : { ok: false, text: r.message });
      if (r.ok) router.refresh();
    });
    e.target.value = '';
  };
  const check = (checked: boolean) => start(async () => {
    const r = await staffDo('rental_form_check', { template: t!.id, checked }, ['/admin/settings/forms', '/admin']);
    setMsg(r.ok ? { ok: true, text: checked ? 'In use: each booking gets it with its rental agreement from now on.' : 'No longer used for new agreements.' } : { ok: false, text: r.message });
    if (r.ok) router.refresh();
  });
  const saveRep = (clear = false) => start(async () => {
    const r = await staffDo('rental_form_rep', clear ? { form_code: code, clear_signature: true } : { form_code: code, rep_name: name, rep_full_name: full }, ['/admin/settings/forms']);
    setMsg(r.ok ? { ok: true, text: clear ? 'Signature image removed: the name is written in a script hand.' : 'Saved.' } : { ok: false, text: r.message });
    if (r.ok) router.refresh();
  });
  return (
    <section className="pt-card ad-card" aria-labelledby={`rf-${code}`} data-testid={`rental-form-${code}`}>
      <div className="pt-card__head"><h2 className="d4" id={`rf-${code}`}>{t?.title ?? code}</h2>
        <span className={`ad-b ${inUse ? 'ad-b--dark' : t?.has_file ? 'ad-b--amber' : 'ad-b--light'}`} data-testid={`rental-form-state-${code}`}>{inUse ? 'In use for bookings' : t?.has_file ? 'To check' : 'No PDF yet'}</span></div>
      <p className="small">The second agreement of every booking, beside CarmaCars&apos; rental agreement: filled from the booking, the renter and the car, and signed by the renter with the same one signature. The old address (top left and twice in box 15) is replaced by the mailing address, box 1 by CarmaCars&apos; HST number, and the representative&apos;s signature in box 21.</p>
      <p className="small">{t?.has_file ? `${t.file_name ?? 'PDF'}${t.page_count ? `, ${t.page_count} pages` : ''}, version ${t.version}${t.uploaded_by_name ? `, uploaded by ${t.uploaded_by_name}` : ''}.` : 'Upload Blind Spot\'s blank PDF. It is stored privately, never on the website.'}
        {t?.verified_at ? ` Checked by ${t.verified_by_name ?? 'an Admin'}.` : ''} Bookings: {f.bookings.open} waiting to sign, {f.bookings.signed} signed.</p>
      <ul className="small">
        <li>Mailing address: {f.mailing_address ?? <b>not set</b>} <Link prefetch={false} className="link" href="/admin/settings/site">Site settings</Link></li>
        <li>HST number (box 1): {f.hst_number ?? <b>not set, left blank</b>} <Link prefetch={false} className="link" href="/admin/settings/program">Program settings</Link></li>
      </ul>
      <div className="field"><label className="label" htmlFor={`rf-up-${code}`}>{t?.has_file ? 'Upload a new version of the PDF' : 'Upload Blind Spot\'s PDF'}</label>
        <input className="input" id={`rf-up-${code}`} type="file" accept="application/pdf" disabled={pending} onChange={upload('pdf')} data-testid={`rental-form-upload-${code}`} /></div>
      {t?.has_file && <div className="row">
        <a className="btn btn--ghost btn--sm" href={`/api/staff/rental-form/${t.id}`} target="_blank" rel="noopener" data-testid={`rental-form-sample-${code}`}>Download the filled sample</a>
        <a className="btn btn--ghost btn--sm" href={`/api/staff/rental-form/${t.id}?insurer=1`} target="_blank" rel="noopener">Sample billed to an insurer</a>
        {t.verified ? <button className="btn btn--ghost btn--sm" type="button" disabled={pending} onClick={() => check(false)}>Stop using it</button>
          : <button className="btn btn--primary btn--sm" type="button" disabled={pending} onClick={() => check(true)} data-testid={`rental-form-check-${code}`}>Checked: use for bookings</button>}
      </div>}
      <fieldset className="stack" data-testid={`rental-form-rep-${code}`}>
        <legend className="label">Authorized company representative (box 21)</legend>
        <p className="small muted">{f.rep?.has_signature ? `Signature image uploaded${f.rep.signature_by_name ? ` by ${f.rep.signature_by_name}` : ''}: it is used in box 21.` : `No signature image: "${f.rep?.name ?? 'Ahmad'}" is written in box 21 in a script hand. Upload a PNG of the signature to use it instead.`}</p>
        <div className="row">
          <div className="field"><label className="label" htmlFor={`rf-name-${code}`}>Name written in box 21</label><input className="input" id={`rf-name-${code}`} value={name} maxLength={60} onChange={(e) => setName(e.target.value)} /></div>
          <div className="field"><label className="label" htmlFor={`rf-full-${code}`}>Full name, for the signature record</label><input className="input" id={`rf-full-${code}`} value={full} maxLength={120} onChange={(e) => setFull(e.target.value)} /></div>
          <button className="btn btn--ghost btn--sm" type="button" disabled={pending} onClick={() => saveRep(false)}>Save</button>
        </div>
        <div className="field"><label className="label" htmlFor={`rf-sig-${code}`}>Signature image (PNG, optional)</label>
          <input className="input" id={`rf-sig-${code}`} type="file" accept="image/png" disabled={pending} onChange={upload('png')} /></div>
        {f.rep?.has_signature && <button className="btn btn--ghost btn--sm" type="button" disabled={pending} onClick={() => saveRep(true)}>Remove the image</button>}
      </fieldset>
      <Msg m={msg} />
    </section>
  );
}

export function RentalForms({ forms }: { forms: RentalForm[] }) {
  if (!forms.length) return null;
  return <div className="stack" data-testid="rental-forms">{forms.map((f) => <Card key={f.form_code} f={f} />)}</div>;
}
