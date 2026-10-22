'use client';
import Link from 'next/link';
import { useEffect, useId, useRef, useState } from 'react';
import { vinClassHint, vinFacts, vinModels } from '@/server/actions/vin';
import { COLOURS, FUEL_WORDS, MAKES, carName, cleanVin, detailLine, vinMessage, vinState, yearChoices } from './vin';
import { decoded, effectiveCar, type CarEdits, type VinValue } from './entry';
export { effectiveCar, emptyVin, vinPayload, vinProblem, type VinValue } from './entry';

// VIN-first entry (migration 0082), shared by Admin > Add a car and Add a car for an owner (an Admin or an assistant):
// the VIN, decoded at the 17th character into one summary line with an Edit link; the plate instead when the VIN is not
// at hand (year, make and model then from lists); the colour in one tap; the class inferred, editable. The owner's own
// application uses the same pieces (ColourSwatches, the summary) through its own VIN lookup.
export const CLASSES = ['economy', 'standard', 'premium', 'suv', 'luxury', 'exotic'] as const;
const CLASS_LABEL: Record<string, string> = { economy: 'Economy', standard: 'Standard', premium: 'Premium', suv: 'SUV', luxury: 'Luxury', exotic: 'Exotic' };

export function ColourSwatches({ value, onChange, prefix, hint, err, legend = 'Colour' }: { value: string; onChange: (c: string) => void; prefix: string; hint?: string; err?: string; legend?: string }) {
  const uid = useId().replace(/[^\w-]/g, '');
  const known = COLOURS.some((c) => c.name.toLowerCase() === value.trim().toLowerCase());
  const [other, setOther] = useState(!!value && !known);
  return (
    <fieldset className={`field vin-colours${err ? ' has-error' : ''}`} data-testid={`${prefix}-colour`} aria-describedby={[hint ? `${uid}-h` : '', `${uid}-e`].filter(Boolean).join(' ')}>
      <legend className="label">{legend}</legend>
      <div className="vin-swatches" role="radiogroup" aria-label={legend}>
        {COLOURS.map((c) => {
          const on = value.trim().toLowerCase() === c.name.toLowerCase();
          return (
            <label key={c.name} className={`vin-swatch${on ? ' is-on' : ''}`} title={c.name}>
              <input type="radio" name={`${uid}-colour`} value={c.name} checked={on} onChange={() => { setOther(false); onChange(c.name); }} data-testid={`${prefix}-colour-${c.name.toLowerCase()}`} />
              <span className="vin-swatch__dot" style={{ background: c.hex }} aria-hidden="true" /><span className="vin-swatch__name">{c.name}</span>
            </label>);
        })}
        <label className={`vin-swatch${other ? ' is-on' : ''}`}>
          <input type="radio" name={`${uid}-colour`} checked={other} onChange={() => { setOther(true); if (known) onChange(''); }} data-testid={`${prefix}-colour-other`} />
          <span className="vin-swatch__dot vin-swatch__dot--other" aria-hidden="true" /><span className="vin-swatch__name">Other</span>
        </label>
      </div>
      {other && <input className="input" aria-label="Colour, in words" value={value} onChange={(e) => onChange(e.target.value)} placeholder="For example Dark teal" data-testid={`${prefix}-colour-text`} />}
      {hint && <p className="hint" id={`${uid}-h`}>{hint}</p>}
      <p className="error" role="alert" id={`${uid}-e`}>{err ?? ''}</p>
    </fieldset>
  );
}

/** Year, make and model from lists (the fallback when the VIN is not decoded, or a car added by its plate). */
export function YearMakeModel({ value, onChange, prefix, errs = {} }: { value: CarEdits; onChange: (e: CarEdits) => void; prefix: string; errs?: Record<string, string | undefined> }) {
  const uid = useId().replace(/[^\w-]/g, '');
  // the models of that make and year (null while they load); a make or model not on the lists is typed
  const [loaded, setLoaded] = useState<{ key: string; list: string[] } | null>(null);
  const [otherMake, setOtherMake] = useState(!!value.make && !MAKES.includes(value.make));
  const [otherModel, setOtherModel] = useState(false);
  const year = Number(value.year);
  const key = value.make && year && !otherMake ? `${value.make}|${year}` : '';
  const models: string[] | null = !key ? [] : loaded?.key === key ? loaded.list : null;
  useEffect(() => {
    if (!key) return;
    let live = true;
    const [make] = key.split('|');
    void vinModels(make!, year).then((r) => {
      if (!live) return;
      const list = r.ok ? r.data : [];
      setLoaded({ key, list });
      setOtherModel(list.length === 0 || (!!value.model && !list.includes(value.model)));
    }).catch(() => { if (live) { setLoaded({ key, list: [] }); setOtherModel(true); } });
    return () => { live = false; };
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [key]);
  const typedModel = otherMake || (models !== null && (otherModel || (!models.length && !!value.make && !!year)));
  const field = (k: string, label: string, el: React.ReactNode) => (
    <div className={`field ad-field${errs[k] ? ' has-error' : ''}`}><label className="label" htmlFor={`${uid}-${k}`}>{label}</label>{el}<p className="error" role="alert">{errs[k] ?? ''}</p></div>);
  return (
    <div className="ad-fields" data-testid={`${prefix}-ymm`}>
      {field('year', 'Year', <select className="select" id={`${uid}-year`} value={value.year ?? ''} onChange={(e) => onChange({ ...value, year: e.target.value })} data-testid={`${prefix}-year`}>
        <option value="">Choose</option>{yearChoices().map((y) => <option key={y} value={y}>{y}</option>)}</select>)}
      {field('make', 'Make', otherMake
        ? <input className="input" id={`${uid}-make`} value={value.make ?? ''} onChange={(e) => onChange({ ...value, make: e.target.value })} data-testid={`${prefix}-make`} />
        : <select className="select" id={`${uid}-make`} value={value.make ?? ''} onChange={(e) => { if (e.target.value === '__other') { setOtherMake(true); onChange({ ...value, make: '', model: '' }); } else onChange({ ...value, make: e.target.value, model: '' }); }} data-testid={`${prefix}-make`}>
            <option value="">Choose</option>{MAKES.map((m) => <option key={m} value={m}>{m}</option>)}<option value="__other">Another make</option></select>)}
      {field('model', 'Model', typedModel
        ? <input className="input" id={`${uid}-model`} value={value.model ?? ''} onChange={(e) => onChange({ ...value, model: e.target.value })} data-testid={`${prefix}-model`} />
        : <select className="select" id={`${uid}-model`} value={value.model ?? ''} disabled={!models?.length} onChange={(e) => { if (e.target.value === '__other') { setOtherModel(true); onChange({ ...value, model: '' }); } else onChange({ ...value, model: e.target.value }); }} data-testid={`${prefix}-model`}>
            <option value="">{models === null ? 'Loading the models' : value.make && year ? 'Choose' : 'Year and make first'}</option>{(models ?? []).map((m) => <option key={m} value={m}>{m}</option>)}<option value="__other">Another model</option></select>)}
    </div>
  );
}

export function VinEntry({ value, onChange, prefix = 'vin', allowPlate = true, showClass = true, carHref, err }: {
  value: VinValue; onChange: (v: VinValue) => void; prefix?: string; allowPlate?: boolean; showClass?: boolean;
  /** the link to a car already in the fleet (Admin) */ carHref?: (id: string) => string; err?: string;
}) {
  const uid = useId().replace(/[^\w-]/g, '');
  const [busy, setBusy] = useState(false);
  const [problem, setProblem] = useState<string | null>(null);
  const [editing, setEditing] = useState(false);
  const asked = useRef('');
  const vref = useRef(value);
  useEffect(() => { vref.current = value; }, [value]);
  const set = (p: Partial<VinValue>) => onChange({ ...vref.current, ...p });
  const st = vinState(value.vin);

  // the 17th character: look it up at once (a VIN is decoded once and kept)
  useEffect(() => {
    if (value.mode !== 'vin' || (st.kind !== 'ok' && st.kind !== 'check_digit')) { asked.current = ''; return; }
    const vin = st.vin;
    if (asked.current === vin || value.facts?.vin === vin) return;
    asked.current = vin;
    setBusy(true); setProblem(null);
    void vinFacts(vin).then((r) => {
      if (asked.current !== vin) return;
      setBusy(false);
      if (!r.ok) { setProblem(r.message); return; }
      const f = r.data;
      const cur = vref.current;
      onChange({ ...cur, facts: f, edits: {}, ...(cur.classSource === 'person' ? {} : { class: f.class?.class ?? cur.class, classWhy: f.class?.why ?? null }), rate: f.rates });
      setEditing(false);
    }).catch(() => { setBusy(false); setProblem('The lookup did not answer. Enter the year, make and model.'); });
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [value.mode, st.kind, value.vin]);

  // year, make and model typed or edited: the class follows (unless a person chose it)
  const c = effectiveCar(value);
  const hintKey = `${c.year}|${c.make}|${c.model}|${c.trim}|${value.class}|${value.classSource}`;
  useEffect(() => {
    if (!c.year || !c.make || !c.model) return;
    const d = value.facts?.decode;
    if (decoded(value) && !value.edits.year && !value.edits.make && !value.edits.model && value.classSource === 'inferred') return; // the decode's own answer
    const t = setTimeout(() => {
      void vinClassHint({ year: c.year ?? undefined, make: c.make ?? undefined, model: c.model ?? undefined, trim: c.trim ?? undefined, body: d?.body_class ?? d?.body ?? undefined,
        class: value.classSource === 'person' ? value.class : undefined }).then((r) => {
        if (!r.ok) return;
        const cur = vref.current;
        onChange({ ...cur, rate: r.data.rates, ...(cur.classSource === 'person' ? {} : { class: r.data.class.class, classWhy: r.data.class.why }) });
      });
    }, 300);
    return () => clearTimeout(t);
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [hintKey]);

  const d = value.facts?.decode ?? null;
  const notDecoded = value.mode === 'vin' && !!value.facts && !d;
  const msg = problem ?? (busy ? 'Looking up the VIN' : vinMessage(st));
  const fuelOptions = Object.entries(FUEL_WORDS);
  return (
    <div className="stack vin-entry" data-testid={`${prefix}-entry`}>
      {value.mode === 'vin' ? (
        <div className={`field${err || st.kind === 'bad_chars' || st.kind === 'too_long' ? ' has-error' : ''}`}>
          <label className="label" htmlFor={`${uid}-vin`}>VIN</label>
          <input className="input vin-input" id={`${uid}-vin`} value={value.vin} maxLength={24} autoComplete="off" autoCapitalize="characters" spellCheck={false}
            onChange={(e) => set({ vin: e.target.value.toUpperCase(), ...(cleanVin(e.target.value) !== value.facts?.vin ? { facts: null, edits: {}, rate: null } : {}) })}
            aria-describedby={`${uid}-vin-m`} aria-invalid={err ? true : undefined} data-testid={`${prefix}-vin`} placeholder="17 characters" />
          <p className={st.kind === 'check_digit' ? 'hint vin-warn' : 'hint'} id={`${uid}-vin-m`} role="status" data-testid={`${prefix}-vin-status`}>
            {msg ?? 'On the ownership permit, the insurance slip and the driver\'s door frame. The car\'s details come from it.'}</p>
          {err && <p className="error" role="alert">{err}</p>}
          {allowPlate && <button type="button" className="link vin-switch" onClick={() => { setProblem(null); set({ mode: 'plate', facts: null, edits: {} }); }} data-testid={`${prefix}-use-plate`}>No VIN at hand? Add the car by its plate</button>}
        </div>
      ) : (
        <div className="field">
          <label className="label" htmlFor={`${uid}-plate`}>Plate</label>
          <input className="input" id={`${uid}-plate`} value={value.plate} onChange={(e) => set({ plate: e.target.value.toUpperCase() })} autoCapitalize="characters" data-testid={`${prefix}-plate`} />
          <p className="hint">The car&apos;s checklist asks for the VIN later; its details fill in once it is entered.</p>
          <button type="button" className="link vin-switch" onClick={() => set({ mode: 'vin', edits: {} })} data-testid={`${prefix}-use-vin`}>Use the VIN instead</button>
        </div>
      )}

      {value.facts?.taken && value.mode === 'vin' && (
        <p className="alert alert--error" role="alert" data-testid={`${prefix}-taken`}><span>Already in the fleet: {value.facts.taken.name} ({value.facts.taken.supply}{value.facts.taken.retired ? ', retired' : ''}).
          {carHref && <> <Link prefetch={false} className="link" href={carHref(value.facts.taken.vehicle_id)}>Open it</Link></>}</span></p>)}

      {d && !editing && (
        <div className="vin-sum" data-testid={`${prefix}-summary`}>
          <p className="vin-sum__name"><b>{carName(c)}</b> <button type="button" className="link" onClick={() => setEditing(true)} data-testid={`${prefix}-edit`}>Edit</button></p>
          <p className="small muted vin-sum__line">{detailLine(c) || 'No further details in the VIN.'}</p>
          {(d.trim_candidates?.length ?? 0) > 1 && (
            <div className="field" role="group" aria-labelledby={`${uid}-trims`} data-testid={`${prefix}-trims`}>
              <p className="label" id={`${uid}-trims`}>Which trim is it? The VIN fits {d.trim_candidates!.length}.</p>
              <div className="row">{d.trim_candidates!.map((t) => (
                <button key={t} type="button" className={`btn btn--sm ${value.edits.trim === t ? 'btn--primary' : 'btn--ghost'}`} aria-pressed={value.edits.trim === t}
                  onClick={() => set({ edits: { ...value.edits, trim: t } })} data-testid={`${prefix}-trim-pick`}>{t}</button>))}
                <button type="button" className={`btn btn--sm ${value.edits.trim === '' ? 'btn--primary' : 'btn--quiet'}`} aria-pressed={value.edits.trim === ''}
                  onClick={() => set({ edits: { ...value.edits, trim: '' } })}>Not sure</button></div>
              <p className="hint">Not sure: the car is saved without a trim and Admin &gt; Today asks again.</p>
            </div>)}
        </div>)}
      {d && editing && (
        <div className="stack" data-testid={`${prefix}-edit-fields`}>
          <div className="ad-fields">
            {(['year', 'make', 'model', 'trim'] as const).map((k) => (
              <div key={k} className="field ad-field"><label className="label" htmlFor={`${uid}-e-${k}`}>{k[0]!.toUpperCase() + k.slice(1)}{k === 'trim' ? ' (optional)' : ''}</label>
                <input className="input" id={`${uid}-e-${k}`} inputMode={k === 'year' ? 'numeric' : undefined} value={value.edits[k] ?? String(d[k] ?? '')}
                  onChange={(e) => set({ edits: { ...value.edits, [k]: e.target.value } })} data-testid={`${prefix}-edit-${k}`} /></div>))}
            <div className="field ad-field"><label className="label" htmlFor={`${uid}-e-fuel`}>Fuel</label>
              <select className="select" id={`${uid}-e-fuel`} value={value.edits.fuel ?? d.fuel ?? ''} onChange={(e) => set({ edits: { ...value.edits, fuel: e.target.value } })}>
                <option value="">Choose</option>{fuelOptions.map(([k, l]) => <option key={k} value={k}>{l}</option>)}</select></div>
          </div>
          <p className="small"><button type="button" className="link" onClick={() => setEditing(false)}>Done</button> <span className="muted">Seats, doors and the rest stay as decoded; change them on the car&apos;s listing.</span></p>
        </div>)}
      {(notDecoded || value.mode === 'plate') && (
        <div className="stack" data-testid={`${prefix}-fallback`}>
          {notDecoded && <p className="small" role="status">The VIN could not be read by the decoder. Choose the year, make and model; it is saved all the same and the rest fills in when the VIN is decoded later.</p>}
          <YearMakeModel value={value.edits} onChange={(e) => set({ edits: e })} prefix={prefix} />
        </div>)}

      {showClass && (c.make || value.mode === 'plate' || notDecoded) && (
        <div className="field" style={{ maxWidth: '24rem' }}>
          <label className="label" htmlFor={`${uid}-class`}>Class</label>
          <select className="select" id={`${uid}-class`} value={value.class} onChange={(e) => set({ class: e.target.value, classSource: 'person', classWhy: null })} data-testid={`${prefix}-class`}>
            {CLASSES.map((k) => <option key={k} value={k}>{CLASS_LABEL[k]}</option>)}</select>
          <p className="hint" data-testid={`${prefix}-class-why`}>{value.classSource === 'person' ? 'Chosen by you.' : value.classWhy ? `${value.classWhy}. Change it if it is wrong.` : 'Set from the make and model.'}
            {value.rate ? ` Rates start at ${value.rate.text}.` : ''}</p>
        </div>)}
    </div>
  );
}
