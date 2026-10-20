'use client';
import { useRouter } from 'next/navigation';
import { useState, useTransition } from 'react';
import { saveAddon, uploadAddonPhoto } from '@/server/actions/addons';
import { money } from '@/lib/format';
import { photoUrl } from '@/lib/photo';
import { addonPrice } from './model';

// Admin > Settings > Add-ons (an Admin edits everything) and Fleet > Add-ons (stock only), migration 0066.
export interface AddonRow {
  id: string; code: string; name: string; description: string | null; photo_path: string | null; pricing_unit: 'per_trip' | 'per_day' | 'per_hour';
  price_cents: number | null; price_overrides: Array<{ classes?: string[]; body_types?: string[]; price_cents: number }>; max_days: number | null; cap_cents: number | null;
  min_hours: number | null; hst_applies: boolean; active: boolean; vehicle_classes: string[]; vehicle_ids: string[]; excluded_vehicle_ids: string[];
  excluded_fuel_types: string[]; available_months: number[]; lead_time_hours: number; stock_count: number | null; max_per_booking: number;
  needs_confirmation: boolean; needs_prep: boolean; prep_note: string | null; handover_note: string | null; prepaid_fuel: boolean;
  non_refundable_after_lead: boolean; sort_order: number; booked_next_30_days: number; out_now: number | null;
}
export interface AddonsData { may_edit: boolean; may_stock: boolean; cutoff_hours: number; classes: string[]; fuel_types: string[]; vehicles: Array<{ id: string; name: string; plate: string | null }>; addons: AddonRow[] }

const MONTHS = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
const UNIT: Record<string, string> = { per_trip: 'Per trip', per_day: 'Per day', per_hour: 'Per hour' };
const dollars = (c: number | null | undefined) => (c === null || c === undefined ? '' : (c / 100).toFixed(2));
const toCents = (s: string) => { const t = s.replace(/[$,\s]/g, ''); return t === '' ? null : Math.round(Number(t) * 100); };
const words = (s: string) => s.replace(/_/g, ' ');

function Stock({ a }: { a: AddonRow }) {
  const router = useRouter();
  const [v, setV] = useState(a.stock_count === null ? '' : String(a.stock_count));
  const [msg, setMsg] = useState<string | null>(null);
  const [pending, start] = useTransition();
  return (
    <form className="row" style={{ gap: 'var(--s-2)', alignItems: 'end', flexWrap: 'wrap' }} onSubmit={(e) => { e.preventDefault(); start(async () => {
      const r = await saveAddon({ id: a.id, stock_count: v.trim() === '' ? null : Number(v) }); setMsg(r.ok ? 'Saved.' : r.message); if (r.ok) router.refresh(); }); }}>
      <div className="field"><label className="label" htmlFor={`st-${a.code}`}>In stock</label>
        <input className="input" id={`st-${a.code}`} inputMode="numeric" style={{ width: '6rem' }} value={v} onChange={(e) => setV(e.target.value.replace(/\D/g, ''))} placeholder="Not counted" data-testid={`stock-${a.code}`} /></div>
      <button className="btn btn--ghost btn--sm" type="submit" disabled={pending}>Save</button>
      {msg && <span className="small" role="status">{msg}</span>}
    </form>
  );
}

function Editor({ a, data, onDone }: { a: AddonRow | null; data: AddonsData; onDone: () => void }) {
  const router = useRouter();
  const [pending, start] = useTransition();
  const [err, setErr] = useState<string | null>(null);
  const [f, setF] = useState(() => ({
    name: a?.name ?? '', description: a?.description ?? '', pricing_unit: a?.pricing_unit ?? 'per_trip', price: dollars(a?.price_cents), cap: dollars(a?.cap_cents),
    max_days: a?.max_days ? String(a.max_days) : '', min_hours: a?.min_hours ? String(a.min_hours) : '', lead: String(a?.lead_time_hours ?? 0),
    stock: a?.stock_count === null || a?.stock_count === undefined ? '' : String(a.stock_count), max_per: String(a?.max_per_booking ?? 1), sort: String(a?.sort_order ?? 100),
    prep_note: a?.prep_note ?? '', handover_note: a?.handover_note ?? '',
    overrides: (a?.price_overrides ?? []).map((o) => `${[...(o.classes ?? []), ...(o.body_types ?? []).map((b) => `body:${b}`)].join(' ')} = ${dollars(o.price_cents)}`).join('\n')
  }));
  const [b, setB] = useState(() => ({ active: a?.active ?? false, hst: a?.hst_applies ?? true, confirm: a?.needs_confirmation ?? false, prep: a?.needs_prep ?? false,
    fuel: a?.prepaid_fuel ?? false, nonref: a?.non_refundable_after_lead ?? false }));
  const [classes, setClasses] = useState<string[]>(a?.vehicle_classes ?? []);
  const [fuels, setFuels] = useState<string[]>(a?.excluded_fuel_types ?? []);
  const [months, setMonths] = useState<number[]>(a?.available_months ?? []);
  const [only, setOnly] = useState<string[]>(a?.vehicle_ids ?? []);
  const [without, setWithout] = useState<string[]>(a?.excluded_vehicle_ids ?? []);
  const id = (k: string) => `ae-${a?.code ?? 'new'}-${k}`;
  const t = (k: keyof typeof f, label: string, o: { hint?: string; area?: boolean; mode?: 'decimal' | 'numeric' } = {}) => (
    <div className={`field ad-field${o.area ? ' ad-field--wide' : ''}`}><label className="label" htmlFor={id(k)}>{label}</label>
      {o.area ? <textarea className="input ad-textarea" id={id(k)} value={f[k]} onChange={(e) => setF((s) => ({ ...s, [k]: e.target.value }))} aria-describedby={o.hint ? `${id(k)}-h` : undefined} />
        : <input className="input" id={id(k)} inputMode={o.mode} value={f[k]} onChange={(e) => setF((s) => ({ ...s, [k]: e.target.value }))} aria-describedby={o.hint ? `${id(k)}-h` : undefined} data-testid={`ae-${k}`} />}
      {o.hint && <p className="hint" id={`${id(k)}-h`}>{o.hint}</p>}</div>);
  const c = (k: keyof typeof b, label: string) => (
    <label className="check ad-field" htmlFor={id(k)}><input type="checkbox" id={id(k)} checked={b[k]} onChange={(e) => setB((s) => ({ ...s, [k]: e.target.checked }))} data-testid={`ae-${k}`} /> <span>{label}</span></label>);
  const chips = <T extends string | number>(list: T[], all: Array<[T, string]>, set: (x: T[]) => void, label: string, key: string) => (
    <fieldset className="ad-field ad-field--wide"><legend className="label">{label}</legend>
      <div className="ad-chip-row">{all.map(([v, l]) => (
        <label key={String(v)} className="check" htmlFor={id(`${key}-${v}`)}><input type="checkbox" id={id(`${key}-${v}`)} checked={list.includes(v)} onChange={(e) => set(e.target.checked ? [...list, v] : list.filter((x) => x !== v))} /> <span>{l}</span></label>))}</div>
    </fieldset>);
  const parseOverrides = () => f.overrides.split('\n').map((l) => l.trim()).filter(Boolean).map((l) => {
    const [lhs, rhs] = l.split('=');
    const tokens = (lhs ?? '').trim().split(/\s+/).filter(Boolean);
    return { classes: tokens.filter((x) => !x.startsWith('body:')), body_types: tokens.filter((x) => x.startsWith('body:')).map((x) => x.slice(5)), price_cents: toCents(rhs ?? '') ?? 0 };
  });
  const save = () => start(async () => {
    setErr(null);
    const p: Record<string, unknown> = {
      ...(a ? { id: a.id } : {}), name: f.name.trim(), description: f.description.trim(), pricing_unit: f.pricing_unit, price_cents: toCents(f.price),
      cap_cents: toCents(f.cap), max_days: f.max_days ? Number(f.max_days) : null, min_hours: f.min_hours ? Number(f.min_hours) : null,
      lead_time_hours: Number(f.lead || 0), stock_count: f.stock.trim() === '' ? null : Number(f.stock), max_per_booking: Number(f.max_per || 1), sort_order: Number(f.sort || 100),
      prep_note: f.prep_note, handover_note: f.handover_note, price_overrides: parseOverrides(),
      active: b.active, hst_applies: b.hst, needs_confirmation: b.confirm, needs_prep: b.prep, prepaid_fuel: b.fuel, non_refundable_after_lead: b.nonref,
      vehicle_classes: classes, excluded_fuel_types: fuels, available_months: months, vehicle_ids: only, excluded_vehicle_ids: without
    };
    if (!a) { const r0 = await saveAddon({ name: p.name, pricing_unit: p.pricing_unit, price_cents: p.price_cents }); if (!r0.ok) { setErr(r0.message); return; } p.id = r0.data.id; }
    const r = await saveAddon(p);
    if (!r.ok) { setErr(r.message); return; }
    router.refresh(); onDone();
  });
  const cars = data.vehicles.map((v) => [v.id, `${v.name}${v.plate ? ` ${v.plate}` : ''}`] as [string, string]);
  return (
    <form className="ad-form stack" noValidate aria-label={a ? `Edit ${a.name}` : 'Add an add-on'} data-testid={`addon-edit-${a?.code ?? 'new'}`} onSubmit={(e) => { e.preventDefault(); save(); }}>
      <div className="ad-fields">
        {t('name', 'Name')}
        {t('description', 'Short description', { hint: 'Shown to renters under the name. Up to 300 characters.' })}
        <div className="field ad-field"><label className="label" htmlFor={id('unit')}>Priced</label>
          <select className="select" id={id('unit')} value={f.pricing_unit} onChange={(e) => setF((s) => ({ ...s, pricing_unit: e.target.value as AddonRow['pricing_unit'] }))} data-testid="ae-unit">
            <option value="per_trip">Per trip</option><option value="per_day">Per day</option><option value="per_hour">Per hour</option></select></div>
        {t('price', 'Price ($)', { mode: 'decimal' })}
        {f.pricing_unit !== 'per_trip' && t('cap', 'Most per trip ($, optional)', { mode: 'decimal', hint: 'For each item, whatever the length' })}
        {f.pricing_unit === 'per_day' && t('max_days', 'Most days charged (optional)', { mode: 'numeric' })}
        {f.pricing_unit === 'per_hour' && t('min_hours', 'Minimum hours', { mode: 'decimal' })}
        {t('overrides', 'Price by car (optional)', { area: true, hint: 'One line each, the first that matches wins: classes or body types, then the price. Example: suv premium = 110 or body:van = 110' })}
        {t('lead', 'Notice needed (hours)', { mode: 'numeric', hint: '0 for none. Renters cannot ask for it later than this before pickup.' })}
        {t('stock', 'In stock (empty: not counted)', { mode: 'numeric', hint: 'Physical items: checked against every booking over the same dates' })}
        {t('max_per', 'Most on one booking', { mode: 'numeric' })}
        {t('sort', 'Order', { mode: 'numeric' })}
        {t('prep_note', 'What Fleet does to get it ready', { area: true })}
        {t('handover_note', 'Note for field staff at the handover', { area: true })}
      </div>
      <div className="ad-fields">
        {c('active', 'On (offered to renters)')}{c('hst', 'HST applies')}{c('confirm', 'Needs staff confirmation (for example a chauffeur)')}
        {c('prep', 'Fleet gets a task to get it ready')}{c('fuel', 'Prepaid fuel: no fuel charge at the return')}{c('nonref', 'Not refunded on a cancellation once its notice has started')}
      </div>
      {chips(classes, data.classes.map((x) => [x, words(x)] as [string, string]), setClasses, 'Only these classes (none ticked: every class)', 'cls')}
      {chips(fuels, data.fuel_types.map((x) => [x, words(x)] as [string, string]), setFuels, 'Not for these fuel types', 'fuel')}
      {chips(months, MONTHS.map((m, i) => [i + 1, m] as [number, string]), setMonths, 'Only in these months (none ticked: all year)', 'mon')}
      <details className="ad-field--wide"><summary className="link">Cars ({only.length ? `${only.length} only` : 'all'}{without.length ? `, ${without.length} left out` : ''})</summary>
        {chips(only, cars, setOnly, 'Only these cars (none ticked: every car)', 'only')}
        {chips(without, cars, setWithout, 'Leave out these cars', 'without')}
      </details>
      {err && <p className="alert alert--error" role="alert"><span>{err}</span></p>}
      <div className="row"><button className="btn btn--primary btn--sm" type="submit" disabled={pending} data-testid="ae-save">{pending ? 'Saving' : 'Save'}</button>
        <button className="btn btn--quiet btn--sm" type="button" onClick={onDone}>Cancel</button></div>
    </form>
  );
}

function Photo({ a }: { a: AddonRow }) {
  const router = useRouter();
  const [pending, start] = useTransition();
  const [msg, setMsg] = useState<string | null>(null);
  return (
    <form className="row" style={{ gap: 'var(--s-2)', flexWrap: 'wrap' }} onSubmit={(e) => { e.preventDefault(); const fd = new FormData(e.currentTarget); fd.set('id', a.id);
      start(async () => { const r = await uploadAddonPhoto(fd); setMsg(r.ok ? 'Photo saved.' : r.message); if (r.ok) router.refresh(); }); }}>
      <label className="sr-only" htmlFor={`ph-${a.code}`}>Photo for {a.name}</label>
      <input className="input" id={`ph-${a.code}`} name="file" type="file" accept="image/jpeg,image/webp" style={{ maxWidth: '100%' }} />
      <button className="btn btn--ghost btn--sm" type="submit" disabled={pending}>{a.photo_path ? 'Replace photo' : 'Add a photo'}</button>
      {a.photo_path && <button className="btn btn--quiet btn--sm" type="button" disabled={pending} onClick={() => start(async () => { await saveAddon({ id: a.id, photo_path: null }); router.refresh(); })}>Remove photo</button>}
      {msg && <span className="small" role="status">{msg}</span>}
    </form>
  );
}

export function AddonsAdmin({ data }: { data: AddonsData }) {
  const [open, setOpen] = useState<string | null>(null);
  return (
    <div className="stack" data-testid="addons-admin">
      <p className="small muted">Add-ons are offered on the car page, in requests, in offers and rentals staff add, and in the renter&apos;s portal until {data.cutoff_hours} hours before pickup (Program settings, addon_portal_cutoff_hours, or an add-on&apos;s own notice if longer). Their revenue is CarmaCars&apos; own: never Owner Revenue, a partner&apos;s share or a commission.</p>
      <div className="table-scroll ad-scroll" tabIndex={0} role="region" aria-label="Add-ons"><table className="ad-table ad-table--dense" data-testid="addons-table"><caption className="sr-only">Add-ons</caption>
        <thead><tr><th scope="col">Add-on</th><th scope="col">Price</th><th scope="col">On</th><th scope="col">Notice</th><th scope="col">Stock</th><th scope="col">Booked, next 30 days</th>{data.may_edit && <th scope="col"><span className="sr-only">Edit</span></th>}</tr></thead>
        <tbody>{data.addons.map((a) => (
          <tr key={a.id} data-addon={a.code}>
            <td>{a.photo_path && (
              // eslint-disable-next-line @next/next/no-img-element
              <img src={photoUrl(a.photo_path)} alt="" width={40} height={40} style={{ objectFit: 'cover', verticalAlign: 'middle', marginRight: 8 }} />)}
              <b>{a.name}</b>{a.needs_confirmation ? <span className="small muted"> · staff confirm</span> : null}{a.needs_prep ? <span className="small muted"> · Fleet prepares</span> : null}
              {a.prepaid_fuel ? <span className="small muted"> · prepaid fuel</span> : null}</td>
            <td className="num">{a.price_cents === null ? <span className="muted">No price</span> : addonPrice({ ...a, unit_price_cents: a.price_cents })}
              {a.price_overrides.length ? <span className="small muted"><br />{a.price_overrides.map((o) => `${[...(o.classes ?? []), ...(o.body_types ?? [])].join(', ')}: ${money(o.price_cents)}`).join('; ')}</span> : null}
              <span className="small muted"><br />{UNIT[a.pricing_unit]}{a.hst_applies ? ', plus HST' : ', no HST'}</span></td>
            <td>{a.active ? 'Yes' : 'No'}</td>
            <td>{a.lead_time_hours ? `${a.lead_time_hours} h` : 'None'}</td>
            <td>{data.may_stock ? <Stock a={a} /> : a.stock_count ?? 'Not counted'}{a.out_now ? <span className="small muted"><br />{a.out_now} out now</span> : null}</td>
            <td className="num">{a.booked_next_30_days}</td>
            {data.may_edit && <td><button className="btn btn--quiet btn--sm" type="button" onClick={() => setOpen(open === a.id ? null : a.id)} data-testid={`addon-open-${a.code}`}>{open === a.id ? 'Close' : 'Edit'}</button></td>}
          </tr>))}</tbody>
      </table></div>
      {data.may_edit && open && open !== 'new' && (() => { const a = data.addons.find((x) => x.id === open)!; return (
        <section className="pt-card ad-card stack"><h2 className="d4">{a.name}</h2><Editor key={a.id} a={a} data={data} onDone={() => setOpen(null)} /><Photo a={a} /></section>); })()}
      {data.may_edit && (open === 'new'
        ? <section className="pt-card ad-card stack"><h2 className="d4">Add an add-on</h2><Editor a={null} data={data} onDone={() => setOpen(null)} /></section>
        : <p><button className="btn btn--ghost btn--sm" type="button" onClick={() => setOpen('new')} data-testid="addon-new">Add an add-on</button></p>)}
    </div>
  );
}
