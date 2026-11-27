'use client';
import { useEffect, useRef, useState } from 'react';
import { useRouter } from 'next/navigation';
import { money } from '@/lib/format';
import { staffRead } from '@/server/actions/staff-tools';
import { logExpense } from '@/server/actions/ops-uploads';
import { PHOTO_ACCEPT } from '@/features/uploads/formats';
import { mergeReads, normalizeReceipt, type ReceiptRead } from './receipt-read';
import { WhyDisabled } from '@/components/WhyDisabled';
import { DateInput } from '@/components/DateInput';

// Log an expense from its receipt (migration 5143), phone first: take the photo (or several, or upload them), the vision model
// reads the amount, the tax, the date, the vendor, the category and the car; the person checks the fields and saves. The car's
// program owner pays by default (the owner's next statement); "CarmaCars pays" makes it a company expense on the car.
type Car = { id: string; name: string; plate: string | null; vin: string | null; owner_id: string | null; owner_name: string | null; owner_pays: boolean };
type Ctx = { categories: Array<{ code: string; label: string }>; cars: Car[]; vision: boolean };
type Shot = { key: string; blob: Blob; url: string; state: 'reading' | 'read' | 'not_read'; read?: ReceiptRead; note?: string };
type Form = { amount: string; tax: string; date: string; vendor: string; category: string; car: string; payer: 'owner' | 'company'; paid: 'company' | 'own' };
const today = () => new Intl.DateTimeFormat('en-CA', { timeZone: 'America/Toronto' }).format(new Date());
const dollars = (c: number | null | undefined) => (c == null ? '' : (c / 100).toFixed(2));
const cents = (s: string) => { const t = s.replace(/[$,\s]/g, ''); return /^\d+(\.\d{0,2})?$/.test(t) ? Math.round(Number(t) * 100) : null; };
const EMPTY: Form = { amount: '', tax: '', date: '', vendor: '', category: '', car: '', payer: 'company', paid: 'company' };

export function ExpenseCapture() {
  const router = useRouter();
  const [ctx, setCtx] = useState<Ctx | null>(null);
  const [shots, setShotsState] = useState<Shot[]>([]);
  const shotsRef = useRef<Shot[]>([]);
  const setShots = (next: Shot[]) => { shotsRef.current = next; setShotsState(next); };
  const [f, setF] = useState<Form>({ ...EMPTY, date: today() });
  const touched = useRef(new Set<keyof Form>());
  const [busy, setBusy] = useState(false);
  // one id per expense on the screen: a double tap or a retry logs it once (5143)
  const [entryId, setEntryId] = useState(() => crypto.randomUUID());
  const [msg, setMsg] = useState<{ ok: boolean; text: string } | null>(null);
  useEffect(() => { void staffRead<Ctx>('expense_context').then((r) => (r.ok ? setCtx(r.data) : setMsg({ ok: false, text: r.message }))); }, []);
  useEffect(() => () => { for (const s of shotsRef.current) URL.revokeObjectURL(s.url); }, []);

  const set = (k: keyof Form, v: string) => { touched.current.add(k); setF((x) => { const n = { ...x, [k]: v } as Form; if (k === 'car') n.payer = ctx?.cars.find((c) => c.id === v)?.owner_pays ? 'owner' : 'company'; return n; }); };
  // what was read fills the fields the person has not typed in
  const fill = (all: Shot[]) => {
    const m = mergeReads(all.filter((s) => s.read).map((s) => s.read!));
    if (!m || !ctx) return;
    setF((x) => {
      const n = { ...x };
      const put = (k: keyof Form, v: string | null | undefined) => { if (v && !touched.current.has(k)) (n as Record<string, string>)[k] = v; };
      put('amount', dollars(m.amount_cents)); put('tax', dollars(m.hst_cents)); put('date', m.expense_on); put('vendor', m.vendor); put('category', m.category);
      if (m.vehicle_id && !touched.current.has('car')) { n.car = m.vehicle_id; n.payer = ctx.cars.find((c) => c.id === m.vehicle_id)?.owner_pays ? 'owner' : 'company'; }
      return n;
    });
  };

  async function add(files: FileList | null) {
    if (!files?.length || !ctx) return;
    setMsg(null);
    const { toStandardImage } = await import('@/features/uploads/standard-image');
    const { askVision, imageJpeg } = await import('@/features/tolls/pdf');
    for (const file of Array.from(files).slice(0, 10 - shotsRef.current.length)) {
      let blob: Blob;
      try { blob = await toStandardImage(file); } catch { setMsg({ ok: false, text: `${file.name} could not be opened: take the photo again, or upload a JPEG, PNG, HEIC or PDF.` }); continue; }
      const shot: Shot = { key: crypto.randomUUID(), blob, url: URL.createObjectURL(blob), state: ctx.vision ? 'reading' : 'not_read', note: ctx.vision ? undefined : 'Reading is off: type the details' };
      setShots([...shotsRef.current, shot]);
      if (!ctx.vision) continue;
      const img = await imageJpeg(blob, 1600);
      const r = await askVision('receipt_read', img.dataUrl);
      const next = shotsRef.current.map((x) => (x.key !== shot.key ? x : r.ok
        ? { ...x, state: 'read' as const, read: normalizeReceipt(r.data, { cars: ctx.cars, categories: ctx.categories.map((c) => c.code), today: today() }) }
        : { ...x, state: 'not_read' as const, note: r.message }));
      setShots(next);
      fill(next);
    }
  }
  const remove = (key: string) => { const x = shotsRef.current.find((y) => y.key === key); if (x) URL.revokeObjectURL(x.url); setShots(shotsRef.current.filter((y) => y.key !== key)); };

  const amount = cents(f.amount), tax = f.tax.trim() ? cents(f.tax) : 0;
  const car = ctx?.cars.find((c) => c.id === f.car) ?? null;
  const why = !shots.length ? 'Add a photo of the receipt first' : shots.some((s) => s.state === 'reading') ? 'Wait for the photos to be read'
    : amount == null || amount <= 0 ? 'Type the amount before tax' : tax == null ? 'Type the tax in dollars and cents' : !f.category ? 'Choose the category'
    : f.payer === 'owner' && !car?.owner_pays ? 'Choose a car with an owner, or CarmaCars pays' : null;
  const problems = [...new Set(shots.flatMap((s) => s.read?.problems ?? []))];

  async function save() {
    if (why || busy) return;
    setBusy(true); setMsg(null);
    const fd = new FormData();
    shots.forEach((s, i) => fd.append('photos', new File([s.blob], `receipt-${i + 1}.jpg`, { type: 'image/jpeg' })));
    const m = mergeReads(shots.filter((s) => s.read).map((s) => s.read!));
    fd.set('expense', JSON.stringify({ client_entry_id: entryId, amount_cents: amount, hst_cents: tax ?? 0, expense_on: f.date || today(), vendor: f.vendor.trim() || null, category: f.category,
      vehicle_id: f.car || null, payer: f.payer, paid_with: f.payer === 'owner' ? 'company' : f.paid, description: m?.what ? `${m.what}${f.vendor.trim() ? `: ${f.vendor.trim()}` : ''}` : null,
      read: m ? { what: m.what, confidence: m.confidence, problems: m.problems, photos: shots.length } : {} }));
    const r = await logExpense(fd);
    setBusy(false);
    if (!r.ok) { setMsg({ ok: false, text: r.message }); return; }
    setMsg({ ok: true, text: `Saved: ${money(r.data.total_cents, { cents: true })}${r.data.vehicle_name ? ` for the ${r.data.vehicle_name}` : ''}, ${r.data.payer === 'owner' ? 'on the owner\'s next statement' : 'a company expense'}.` });
    for (const s of shots) URL.revokeObjectURL(s.url);
    setShots([]); setF({ ...EMPTY, date: today() }); touched.current.clear(); setEntryId(crypto.randomUUID());
    router.refresh();
  }

  return (
    <section className="pt-card ad-card stack ex-cap" aria-labelledby="ex-cap-h" data-testid="expense-capture">
      <div className="pt-card__head"><h2 className="d4" id="ex-cap-h">Log an expense from the receipt</h2></div>
      <p className="small muted">Take a photo of the receipt, or upload it. We read the amount, the tax, the date, the shop and the car: check them, then save. Several photos for one expense are fine.</p>
      <div className="row ex-cap__pick">
        <label className="btn btn--primary" data-testid="expense-take">Take a photo
          <input className="vh" type="file" accept="image/*" capture="environment" disabled={!ctx || busy || shots.length >= 10} onChange={(e) => { void add(e.target.files); e.target.value = ''; }} /></label>
        <label className="btn btn--ghost" data-testid="expense-upload-label">Upload photos
          <input className="vh" type="file" accept={PHOTO_ACCEPT} multiple disabled={!ctx || busy || shots.length >= 10} data-testid="expense-upload" onChange={(e) => { void add(e.target.files); e.target.value = ''; }} /></label>
      </div>
      {shots.length > 0 && <ul className="ex-cap__shots" aria-label="Receipt photos" data-testid="expense-shots">{shots.map((s, i) => (
        <li key={s.key} className="ex-cap__shot" data-state={s.state}>
          {/* a local photo before it is uploaded */}
          {/* eslint-disable-next-line @next/next/no-img-element */}
          <img src={s.url} alt={`Receipt photo ${i + 1}`} />
          <span className="small">{s.state === 'reading' ? 'Reading' : s.state === 'read' ? 'Read' : s.note ?? 'Not read: type the details'}</span>
          <button type="button" className="btn btn--quiet btn--sm" onClick={() => remove(s.key)} disabled={busy}>Remove<span className="vh"> photo {i + 1}</span></button>
        </li>))}</ul>}
      {problems.length > 0 && <ul className="small ad-late" data-testid="expense-problems">{problems.map((p) => <li key={p}>{p}</li>)}</ul>}
      <div className="ad-fields">
        <div className="field ad-field"><label className="label" htmlFor="ex-amount">Amount before tax ($)</label>
          <input className="input" id="ex-amount" inputMode="decimal" value={f.amount} onChange={(e) => set('amount', e.target.value)} data-testid="expense-amount" /></div>
        <div className="field ad-field"><label className="label" htmlFor="ex-tax">HST ($)</label>
          <input className="input" id="ex-tax" inputMode="decimal" value={f.tax} onChange={(e) => set('tax', e.target.value)} data-testid="expense-tax" /></div>
        <div className="field ad-field"><label className="label" htmlFor="ex-date">Date on the receipt</label>
          <DateInput className="input" id="ex-date" type="date" max={today()} value={f.date} onChange={(e) => set('date', e.target.value)} data-testid="expense-date" /></div>
        <div className="field ad-field"><label className="label" htmlFor="ex-vendor">Shop or vendor</label>
          <input className="input" id="ex-vendor" value={f.vendor} maxLength={160} onChange={(e) => set('vendor', e.target.value)} data-testid="expense-vendor" /></div>
        <div className="field ad-field"><label className="label" htmlFor="ex-cat">Category</label>
          <select className="select" id="ex-cat" value={f.category} onChange={(e) => set('category', e.target.value)} data-testid="expense-category">
            <option value="">Choose</option>{ctx?.categories.map((c) => <option key={c.code} value={c.code}>{c.label}</option>)}</select></div>
        <div className="field ad-field"><label className="label" htmlFor="ex-car">Car</label>
          <select className="select" id="ex-car" value={f.car} onChange={(e) => set('car', e.target.value)} data-testid="expense-car">
            <option value="">No car</option>{ctx?.cars.map((c) => <option key={c.id} value={c.id}>{[c.name, c.plate].filter(Boolean).join(', ')}</option>)}</select></div>
      </div>
      <fieldset className="stack ex-cap__payer"><legend className="label">Who pays</legend>
        <div className="seg">
          <label><input type="radio" name="ex-payer" checked={f.payer === 'owner'} disabled={!car?.owner_pays} onChange={() => set('payer', 'owner')} data-testid="expense-payer-owner" />
            <span>{car?.owner_pays ? `${car.owner_name ?? 'The owner'}: next statement` : 'The car\'s owner'}</span></label>
          <label><input type="radio" name="ex-payer" checked={f.payer === 'company'} onChange={() => set('payer', 'company')} data-testid="expense-payer-company" /><span>CarmaCars</span></label>
        </div>
        {f.payer === 'company' && <label className="check"><input type="checkbox" checked={f.paid === 'own'} onChange={(e) => set('paid', e.target.checked ? 'own' : 'company')} data-testid="expense-own" /> <span>I paid with my own money</span> <span className="small">(paid back to me)</span></label>}
      </fieldset>
      <div className="row">
        <button className="btn btn--primary btn--block" type="button" disabled={!!why || busy} onClick={() => void save()} aria-describedby="why-expense-save" data-testid="expense-save">
          {busy ? 'Saving' : amount ? `Save ${money(amount + (tax ?? 0), { cents: true })}` : 'Save the expense'}</button>
        <WhyDisabled id="why-expense-save" why={why} />
      </div>
      {msg && <p className={`alert ${msg.ok ? 'alert--ok' : 'alert--error'}`} role={msg.ok ? 'status' : 'alert'} data-testid="expense-msg"><span>{msg.text}</span></p>}
    </section>
  );
}
