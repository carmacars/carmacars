'use client';
import { useEffect, useId, useState } from 'react';
import Link from 'next/link';
import { useAct } from '@/features/portal/useAct';
import { money } from '@/lib/format';
import { lookupVin } from '@/server/actions/apply';
import { addCarFacts, pickOwner, staffAddOwnerCar } from '@/server/actions/owner-billing';
import { InvoiceChoice, inv, type Inv } from './ApproveStep';
import { dollars, pctOf, toCents } from './shared';

// Add a car for an owner (migration 0067): Admin, customer service and fleet enter everything for the owner in one
// flow: the owner (found, or new), the car (VIN decode), the documents, who sourced the owner, how the owner signs, and
// for an Admin the terms and first invoices (an assistant's go to an Admin as a proposal). The owner then gets one
// email to review, correct and sign (or signs on paper).
type Owner = { id: string; legal_name: string; email: string | null; phone: string | null; cars?: number };
type Facts = { admin: boolean; today: string; hst_bps: number; trackers_available: boolean; owner: (Owner & { has_account: boolean }) | null;
  terms: { insurance_fee_cents: number; tracker_fee_cents: number; revenue_share_bps: number; install_fee_cents: number; first_last_cents: number; sources: Record<string, string> } | null;
  standard: { insurance_fee_cents: number; tracker_fee_cents: number; revenue_share_bps: number; install_fee_cents: number } | null };
const DOCS: Array<[string, string, string]> = [['ownership_permit', 'Ownership permit', 'Both sides. A photo or a PDF.'], ['owner_insurance_proof', 'Insurance slip', 'The current pink slip.'],
  ['finance_party_permission', 'Lender or lessor information', 'The lender\'s permission or the loan or lease statement.']];

export function AddOwnerCar({ initial, base }: { initial: Facts; base: '/admin' | '/va' }) {
  const a = useAct<{ application_id: string; application_number: string; owner_id: string; vehicle_id: string; approved: boolean; note: string | null; docs: number }>();
  const uid = `ac-${useId().replace(/[^\w-]/g, '')}`;
  const [facts, setFacts] = useState<Facts>(initial);
  const [owner, setOwner] = useState<Owner | null>(initial.owner);
  const [isNew, setIsNew] = useState(!initial.owner);
  const [q, setQ] = useState('');
  const [hits, setHits] = useState<Owner[]>([]);
  const [o, setO] = useState<Record<string, string>>({ owner_type: 'individual', province: 'ON' });
  const [v, setV] = useState<Record<string, string>>({ title_status: 'owned_outright', management_mode: 'managed' });
  const [decoded, setDecoded] = useState<string | null>(null);
  const [sourced, setSourced] = useState(false);
  const [signing, setSigning] = useState<'email' | 'paper'>('email');
  const t0 = initial.terms ?? (initial.standard ? { ...initial.standard, first_last_cents: initial.standard.insurance_fee_cents * 2, sources: {} } : null);
  const [terms, setTerms] = useState<Record<string, string>>({ ins: dollars(t0?.insurance_fee_cents), trk: dollars(t0?.tracker_fee_cents), share: pctOf(t0?.revenue_share_bps), inst: dollars(t0?.install_fee_cents), fl: dollars(t0?.first_last_cents) });
  const [fl, setFl] = useState<Inv>(inv(initial.today, true, dollars(t0?.first_last_cents)));
  const [reg, setReg] = useState<Inv>({ ...inv(initial.today, false, ''), title: 'Registration fee' });
  const [files, setFiles] = useState<Record<string, File | null>>({});
  const [problem, setProblem] = useState<string | null>(null);

  // a different owner: their negotiated terms (or their other cars') become the defaults
  useEffect(() => {
    if (!owner) return;
    void addCarFacts(owner.id, v.management_mode).then((r) => {
      if (!r.ok) return;
      const f = r.data as unknown as Facts;
      setFacts(f);
      if (f.terms) {
        setTerms({ ins: dollars(f.terms.insurance_fee_cents), trk: dollars(f.terms.tracker_fee_cents), share: pctOf(f.terms.revenue_share_bps), inst: dollars(f.terms.install_fee_cents), fl: dollars(f.terms.first_last_cents) });
        setFl((x) => ({ ...x, amount: dollars(f.terms!.first_last_cents) }));
      }
    });
  }, [owner, v.management_mode]);
  const search = async () => { const r = await pickOwner(q); if (r.ok) setHits(r.data); };
  const decode = async () => {
    setDecoded(null);
    const r = await lookupVin(v.vin ?? '');
    if (!r.ok) { setDecoded(r.message); return; }
    const d = r.data.decode;
    if (d) setV((x) => ({ ...x, year: d.year ? String(d.year) : x.year ?? '', make: d.make ?? x.make ?? '', model: d.model ?? x.model ?? '', trim: d.trim ?? x.trim ?? '' }));
    setDecoded(d ? [d.year, d.make, d.model, d.trim].filter(Boolean).join(' ') : 'No decode for this VIN: enter the year, make and model.');
  };
  const f = (k: string, label: string, opts: { req?: boolean; type?: string; mode?: 'decimal' | 'numeric' | 'email' | 'tel'; obj?: 'o' | 'v'; hint?: string } = {}) => {
    const obj = opts.obj ?? 'v'; const val = obj === 'o' ? o : v; const set = obj === 'o' ? setO : setV;
    return (
      <div className={`field${a.err(k) ? ' has-error' : ''}`}><label className="label" htmlFor={`${uid}-${k}`}>{label}{opts.req ? '' : ' (optional)'}</label>
        <input className="input" id={`${uid}-${k}`} type={opts.type ?? 'text'} inputMode={opts.mode === 'email' || opts.mode === 'tel' ? opts.mode : opts.mode} value={val[k] ?? ''}
          onChange={(e) => set({ ...val, [k]: e.target.value })} data-testid={`addcar-${k}`} aria-describedby={`${uid}-${k}-e${opts.hint ? ` ${uid}-${k}-h` : ''}`} />
        {opts.hint && <p className="hint" id={`${uid}-${k}-h`}>{opts.hint}</p>}
        <p className="error" role="alert" id={`${uid}-${k}-e`}>{a.err(k) ?? ''}</p></div>);
  };
  const submit = () => {
    setProblem(null);
    if (!isNew && !owner) { setProblem('Find the owner, or choose New owner.'); return; }
    const n = { ins: toCents(terms.ins!), trk: toCents(terms.trk!), inst: toCents(terms.inst!), fl: toCents(terms.fl!), share: Math.round(Number(terms.share) * 100) };
    if ([n.ins, n.trk, n.inst, n.fl, n.share].some((x) => !Number.isFinite(x) || x < 0)) { setProblem('Enter every amount of the terms in dollars and cents.'); return; }
    const invoices: Array<Record<string, unknown>> = [];
    const pay = (x: Inv) => (x.action === 'paid' ? { payment: { method: x.method, received_on: x.on_date, reference: x.reference || undefined, amount_cents: x.paid ? toCents(x.paid) : undefined, note: x.method === 'other' ? x.reference : undefined } } : {});
    if (fl.on) invoices.push({ type: 'first_last', amount_cents: toCents(fl.amount), action: fl.action, ...pay(fl) });
    if (reg.on) {
      if (!(toCents(reg.amount) > 0)) { setProblem('Enter the registration fee.'); return; }
      invoices.push({ type: 'registration', amount_cents: toCents(reg.amount), hst: reg.hst, action: reg.action, title: 'Registration fee', ...pay(reg) });
    }
    const payload = {
      owner_id: isNew ? undefined : owner!.id,
      owner: isNew ? { ...o, email: (o.email ?? '').trim().toLowerCase(), first_name: (o.legal_name ?? '').trim().split(/\s+/)[0] } : undefined,
      vehicle: { ...v, vin: (v.vin ?? '').trim().toUpperCase(), year: v.year ? Number(v.year) : undefined, odometer_km: v.odometer_km ? Number(v.odometer_km) : undefined, title_brand_clear: true },
      sourced, signing,
      plan: { terms: { management_mode: v.management_mode, insurance_fee_cents: n.ins, tracker_fee_cents: n.trk, revenue_share_bps: n.share, install_fee_cents: n.inst, first_last_cents: n.fl }, invoices }
    };
    const fd = new FormData();
    fd.set('payload', JSON.stringify(payload));
    for (const [k, file] of Object.entries(files)) if (file) fd.set(`doc_${k}`, file);
    a.run(() => staffAddOwnerCar(fd));
  };
  if (a.res?.ok) {
    const r = a.res.data;
    return (
      <div className="stack" data-testid="addcar-done">
        <p className="alert alert--ok" role="status"><span className="alert__title">{r.approved ? 'The car is set up' : 'Sent to an Admin to approve'}</span>
          <span>Application {r.application_number}{r.docs ? `, ${r.docs} document${r.docs === 1 ? '' : 's'} filed` : ''}. {r.approved ? (r.note ?? (signing === 'paper' ? 'Record the paper signatures on the owner page when they are signed.' : '')) : 'An Admin checks the terms and first invoices you entered, then approves; the owner gets one email then.'}</span></p>
        <div className="row" style={{ flexWrap: 'wrap', gap: 'var(--s-2)' }}>
          {base === '/admin' && <><Link prefetch={false} className="btn btn--primary btn--sm" href={`/admin/applications/${r.application_id}`}>Open the application</Link>
            <Link prefetch={false} className="btn btn--ghost btn--sm" href={`/admin/owners/${r.owner_id}`}>Open the owner</Link></>}
          <Link prefetch={false} className="btn btn--ghost btn--sm" href={`${base}/owners/add-car?owner=${r.owner_id}`} data-testid="addcar-another">Add another car for this owner</Link>
        </div>
      </div>
    );
  }
  return (
    <form className="stack-lg" noValidate aria-label="Add a car for an owner" data-testid="addcar" onSubmit={(e) => { e.preventDefault(); submit(); }}>
      <section className="pt-card stack" aria-labelledby={`${uid}-o`}><h2 className="d4" id={`${uid}-o`}>1. The owner</h2>
        {owner && !isNew ? (
          <p data-testid="addcar-owner"><b>{owner.legal_name}</b>{owner.email ? ` · ${owner.email}` : ''}{owner.phone ? ` · ${owner.phone}` : ''} <button type="button" className="btn btn--quiet btn--sm" onClick={() => { setOwner(null); setHits([]); }}>Change</button></p>
        ) : (<>
          <div className="row" role="radiogroup" aria-label="Owner" style={{ gap: 'var(--s-3)', flexWrap: 'wrap' }}>
            <label className="check" htmlFor={`${uid}-find`}><input type="radio" id={`${uid}-find`} checked={!isNew} onChange={() => setIsNew(false)} /><span>An owner on file</span></label>
            <label className="check" htmlFor={`${uid}-new`}><input type="radio" id={`${uid}-new`} checked={isNew} onChange={() => setIsNew(true)} data-testid="addcar-new-owner" /><span>New owner</span></label>
          </div>
          {!isNew ? (
            <div className="stack">
              <div className="row" style={{ gap: 'var(--s-2)' }}><label className="vh" htmlFor={`${uid}-q`}>Name, email or phone</label>
                <input className="input" id={`${uid}-q`} value={q} onChange={(e) => setQ(e.target.value)} placeholder="Name, email or phone" onKeyDown={(e) => { if (e.key === 'Enter') { e.preventDefault(); void search(); } }} data-testid="addcar-search" />
                <button type="button" className="btn btn--ghost btn--sm" onClick={() => void search()}>Find</button></div>
              {hits.length > 0 && <ul className="ad-list" data-testid="addcar-hits">{hits.map((h) => <li key={h.id}><button type="button" className="link" onClick={() => setOwner(h)}>{h.legal_name}</button><span className="small">{[h.email, h.phone, `${h.cars ?? 0} car${h.cars === 1 ? '' : 's'}`].filter(Boolean).join(' · ')}</span></li>)}</ul>}
            </div>
          ) : (
            <div className="ad-fields ob-terms">
              <div className="field"><label className="label" htmlFor={`${uid}-ot`}>Owner type</label>
                <select className="select" id={`${uid}-ot`} value={o.owner_type} onChange={(e) => setO({ ...o, owner_type: e.target.value })}><option value="individual">An individual</option><option value="corporation">A corporation</option></select></div>
              {f('legal_name', 'Full legal name', { req: true, obj: 'o' })}
              {o.owner_type === 'corporation' && f('corporation_name', 'Corporation name', { req: true, obj: 'o' })}
              {f('email', 'Email', { req: signing === 'email', obj: 'o', mode: 'email', type: 'email', hint: 'The set-up email goes here, with the invitation to choose a password.' })}
              {f('phone', 'Phone', { req: true, obj: 'o', mode: 'tel', type: 'tel' })}
              {f('address_line1', 'Street address', { obj: 'o' })}{f('city', 'City', { obj: 'o' })}{f('postal_code', 'Postal code', { obj: 'o' })}
            </div>)}
        </>)}
      </section>

      <section className="pt-card stack" aria-labelledby={`${uid}-c`}><h2 className="d4" id={`${uid}-c`}>2. The car</h2>
        <div className="row" style={{ gap: 'var(--s-2)', alignItems: 'end', flexWrap: 'wrap' }}>{f('vin', 'VIN (17 characters)', { req: true })}<button type="button" className="btn btn--ghost btn--sm" onClick={() => void decode()} data-testid="addcar-decode">Decode</button></div>
        {decoded && <p className="small" role="status">{decoded}</p>}
        <div className="ad-fields ob-terms">
          {f('year', 'Year', { req: true, mode: 'numeric' })}{f('make', 'Make', { req: true })}{f('model', 'Model', { req: true })}{f('trim', 'Trim')}
          {f('plate', 'Plate')}{f('colour', 'Colour')}{f('odometer_km', 'Odometer (km)', { mode: 'numeric' })}{f('current_insurer', 'Current insurer')}
          <div className="field"><label className="label" htmlFor={`${uid}-ts`}>It is</label>
            <select className="select" id={`${uid}-ts`} value={v.title_status} onChange={(e) => setV({ ...v, title_status: e.target.value })} data-testid="addcar-title_status"><option value="owned_outright">Owned outright</option><option value="financed">Financed</option><option value="leased">Leased</option></select></div>
          {v.title_status !== 'owned_outright' && f('finance_party_name', v.title_status === 'leased' ? 'Lease company' : 'Lender', { req: true })}
          <div className="field"><label className="label" htmlFor={`${uid}-mm`}>How it is rented</label>
            <select className="select" id={`${uid}-mm`} value={v.management_mode} onChange={(e) => setV({ ...v, management_mode: e.target.value })}><option value="managed">Managed</option><option value="self_managed">Self-Managed</option><option value="turo_only">Turo-Only</option></select></div>
        </div>
        <p className="small muted">Photos are optional: the listing shows sample photos until real ones are added on the car&apos;s listing.</p>
        <fieldset className="stack"><legend className="label">Documents (optional)</legend>
          {DOCS.filter(([k]) => k !== 'finance_party_permission' || v.title_status !== 'owned_outright').map(([k, l, h]) => (
            <div key={k} className={`field${a.err(`doc_${k}`) ? ' has-error' : ''}`}><label className="label" htmlFor={`${uid}-d-${k}`}>{l}</label>
              <input className="input" type="file" id={`${uid}-d-${k}`} accept="application/pdf,image/jpeg,image/png" onChange={(e) => setFiles({ ...files, [k]: e.target.files?.[0] ?? null })} data-testid={`addcar-doc-${k}`} aria-describedby={`${uid}-d-${k}-h`} />
              <p className="hint" id={`${uid}-d-${k}-h`}>{h}</p><p className="error" role="alert">{a.err(`doc_${k}`) ?? ''}</p></div>))}
        </fieldset>
      </section>

      <section className="pt-card stack" aria-labelledby={`${uid}-t`}><h2 className="d4" id={`${uid}-t`}>3. Terms and first invoice</h2>
        {!facts.admin && <p className="small muted">An Admin checks these and approves; they are your proposal.</p>}
        {v.management_mode !== 'turo_only' && (<>
          <div className="ad-fields ob-terms">
            {([['ins', 'Insurance Fee a month ($)'], ['trk', 'Tracker Fee a month ($)'], ['share', 'Revenue Share (%)'], ['inst', 'Install Fee ($)'], ['fl', 'First and last month amount ($)']] as Array<[string, string]>).map(([k, l]) => (
              <div key={k} className="field"><label className="label" htmlFor={`${uid}-t-${k}`}>{l}</label>
                <input className="input" id={`${uid}-t-${k}`} inputMode="decimal" value={terms[k] ?? ''} data-testid={`addcar-terms-${k}`}
                  onChange={(e) => { const val = e.target.value; const nt = { ...terms, [k]: val }; if (k === 'ins' && terms.fl === dollars(toCents(terms.ins!) * 2)) nt.fl = dollars(toCents(val) * 2); setTerms(nt); if (k === 'fl' || nt.fl !== terms.fl) setFl({ ...fl, amount: nt.fl! }); }} /></div>))}
          </div>
          {owner && facts.terms && <p className="small muted">Filled in from {Object.values(facts.terms.sources).includes('owner') ? 'this owner\'s terms' : Object.values(facts.terms.sources).includes('other_car') ? 'this owner\'s other car' : 'the standard grid'}.</p>}
          <InvoiceChoice uid={`${uid}-fl`} label="First and last month" v={fl} hstBps={facts.hst_bps} testId="addcar-inv-first-last" set={(x) => { setFl(x); setTerms({ ...terms, fl: x.amount }); }} />
          <InvoiceChoice uid={`${uid}-rg`} label="Registration fee" v={reg} hstBps={facts.hst_bps} testId="addcar-inv-registration" set={setReg} />
          {fl.on && <p className="small muted">First and last total with HST: {money(toCents(fl.amount) + Math.round(toCents(fl.amount) * facts.hst_bps / 10000), { cents: true })}.</p>}
        </>)}
      </section>

      <section className="pt-card stack" aria-labelledby={`${uid}-s`}><h2 className="d4" id={`${uid}-s`}>4. Who sourced the owner, and signing</h2>
        <div className="row" role="radiogroup" aria-label="Who sourced the owner" style={{ gap: 'var(--s-3)', flexWrap: 'wrap' }}>
          <label className="check" htmlFor={`${uid}-src-c`}><input type="radio" id={`${uid}-src-c`} checked={!sourced} onChange={() => setSourced(false)} /><span>Entered for CarmaCars</span></label>
          <label className="check" htmlFor={`${uid}-src-me`}><input type="radio" id={`${uid}-src-me`} checked={sourced} onChange={() => setSourced(true)} data-testid="addcar-sourced" /><span>I sourced this owner</span></label>
        </div>
        <div className="row" role="radiogroup" aria-label="How the owner signs" style={{ gap: 'var(--s-3)', flexWrap: 'wrap' }}>
          <label className="check" htmlFor={`${uid}-sg-e`}><input type="radio" id={`${uid}-sg-e`} checked={signing === 'email'} onChange={() => setSigning('email')} /><span>Email the owner to review and sign (one email)</span></label>
          <label className="check" htmlFor={`${uid}-sg-p`}><input type="radio" id={`${uid}-sg-p`} checked={signing === 'paper'} onChange={() => setSigning('paper')} data-testid="addcar-paper" /><span>The owner signs on paper (no email now)</span></label>
        </div>
      </section>
      {problem && <p className="alert alert--error" role="alert"><span>{problem}</span></p>}
      {a.res && !a.res.ok && <p className="alert alert--error" role="alert" data-testid="addcar-error"><span>{a.res.message}</span></p>}
      <div className="row"><button className="btn btn--primary" type="submit" disabled={a.pending} data-testid="addcar-submit">{a.pending ? 'Saving' : facts.admin ? 'Add the car and set it up' : 'Add the car and send to an Admin'}</button></div>
    </form>
  );
}
