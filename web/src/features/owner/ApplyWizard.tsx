'use client';
import { PasswordInput } from '@/features/forms/PasswordInput';
import Link from 'next/link';
import { useCallback, useEffect, useRef, useState } from 'react';
import { money, pct } from '@/lib/format';
import { AddressInput } from '@/features/forms/AddressInput';
import { Turnstile, freshTurnstileToken } from '@/features/forms/Turnstile';
import { emailResumeLink, lookupVin, methodOptions, saveApplyDraft, submitApplication, type MethodOption, type SubmitResult } from '@/server/actions/apply';
import { CaptureNote, useCapture } from '@/features/capture/useCapture';
import { blankVehicle, cleanVin, ownerErrors, planErrors, STEPS, vehicleErrors, type ApplyOwner, type ApplyState, type ApplyVehicle } from './apply-schema';

// The owner application (04-owner.md section 3, steps 1 to 3): about you once, then each vehicle,
// then how each one will work (management mode, onboarding method, the registry estimate the owner
// pays directly), then review and submit. Every change autosaves (form_drafts); a link by email
// continues on another device. Built for a phone first.
export interface ProgramFacts {
  install_fee_cents: number; hst_bps: number; trackers_available: boolean;
  /** The payout day of Program settings in words (0051), for example "10th". */
  payout_day_text?: string;
  grid: Array<{ min_vehicles: number; max_vehicles: number | null; insurance_fee_cents: number; tracker_fee_cents: number; revenue_share_bps: number }>;
}

const FUELS = [['gasoline', 'Gasoline'], ['hybrid', 'Hybrid'], ['plug_in_hybrid', 'Plug-in hybrid'], ['electric', 'Electric'], ['diesel', 'Diesel']] as const;
const PROVINCES = ['ON', 'QC', 'BC', 'AB', 'MB', 'SK', 'NS', 'NB', 'NL', 'PE', 'YT', 'NT', 'NU'];
const MODES = [
  { v: 'managed', t: 'Managed', b: 'We do everything: pricing, renters, handovers, cleaning. You are paid on the {payout} of each month, less the Revenue Share.' },
  { v: 'self_managed', t: 'Self-Managed', b: 'You find and hand over to your own renters; they book and pay through CarmaCars. No Revenue Share.' },
  { v: 'turo_only', t: 'Turo-Only', b: 'We rent it on our Turo account. You keep your registration and your own insurance. No fees.' }
] as const;

type Errs = Record<string, string>;
const uid = () => Math.random().toString(36).slice(2, 10);
const vName = (v: ApplyVehicle) => [v.year, v.make, v.model].filter(Boolean).join(' ') || 'New vehicle';

function Field({ id, label, err, hint, optional, children }: { id: string; label: string; err?: string; hint?: string; optional?: boolean; children: React.ReactNode }) {
  return (
    <div className={`field${err ? ' has-error' : ''}`}>
      <label className="label" htmlFor={id}>{label}{optional && <> <span className="opt">optional</span></>}</label>
      {children}
      {hint && <p className="hint" id={`${id}-hint`}>{hint}</p>}
      <p className="error" role="alert" id={`${id}-err`}>{err ?? ''}</p>
    </div>
  );
}
const aria = (id: string, err?: string, hint?: string) => ({ id, 'aria-invalid': !!err || undefined, 'aria-describedby': [hint ? `${id}-hint` : '', `${id}-err`].filter(Boolean).join(' ') });

function Choice<T extends string>({ name, legend, value, options, onChange, err }: { name: string; legend: string; value: T | ''; options: ReadonlyArray<readonly [T, string]>; onChange: (v: T) => void; err?: string }) {
  return (
    <fieldset className={`field${err ? ' has-error' : ''}`} style={{ border: 0, padding: 0, margin: 0 }} aria-describedby={`${name}-err`}>
      <legend className="label">{legend}</legend>
      <div className="seg" style={{ gridAutoFlow: options.length > 3 ? 'row' : 'column' }}>
        {options.map(([v, l]) => <label key={v}><input type="radio" name={name} value={v} checked={value === v} onChange={() => onChange(v)} />{l}</label>)}
      </div>
      <p className="error" role="alert" id={`${name}-err`}>{err ?? ''}</p>
    </fieldset>
  );
}

export function ApplyWizard({ initial, facts, signedIn, ownerOnFile }: { initial: ApplyState; facts: ProgramFacts; signedIn: boolean; ownerOnFile: boolean }) {
  const [s, setS] = useState<ApplyState>(initial);
  const [errs, setErrs] = useState<Errs>({});
  const [saved, setSaved] = useState<{ at: string | null; state: 'idle' | 'saving' | 'saved' | 'error' }>({ at: null, state: 'idle' });
  const [options, setOptions] = useState<Record<string, MethodOption[]>>({});
  const [vinMsg, setVinMsg] = useState<Record<string, string>>({});
  const [password, setPassword] = useState('');
  const [resumeEmail, setResumeEmail] = useState(initial.owner.email);
  const [resumeMsg, setResumeMsg] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);
  const [problem, setProblem] = useState<string | null>(null);
  const [done, setDone] = useState<SubmitResult | null>(null);
  const top = useRef<HTMLDivElement>(null);
  const first = useRef(true);

  // autosave, 1.2 s after the last change
  useEffect(() => {
    if (first.current) { first.current = false; return; }
    if (done) return;
    const t = setTimeout(async () => {
      setSaved((x) => ({ ...x, state: 'saving' }));
      const r = await saveApplyDraft(s).catch(() => null);
      setSaved(r && r.ok ? { at: r.data.savedAt, state: 'saved' } : { at: null, state: 'error' });
    }, 1200);
    return () => clearTimeout(t);
  }, [s, done]);

  const o = s.owner;
  // contact capture (0090): the name, email and phone are saved as each becomes valid; the server finds this draft by its cookie
  const cap = useCapture('owner_application');
  const setOwner = (p: Partial<ApplyOwner>) => setS((x) => ({ ...x, owner: { ...x.owner, ...p } }));
  const setVehicle = (i: number, p: Partial<ApplyVehicle>) => setS((x) => ({ ...x, vehicles: x.vehicles.map((v, k) => (k === i ? { ...v, ...p } : v)) }));
  const clearErr = (k: string) => setErrs((e) => (e[k] ? { ...e, [k]: '' } : e));
  const go = (step: number) => { setErrs({}); setProblem(null); setS((x) => ({ ...x, step })); requestAnimationFrame(() => { top.current?.scrollIntoView({ behavior: 'smooth', block: 'start' }); top.current?.focus({ preventScroll: true }); }); };
  const focusFirstError = () => requestAnimationFrame(() => document.querySelector<HTMLElement>('[aria-invalid="true"], fieldset.has-error input')?.focus());

  const loadOptions = useCallback(async (v: ApplyVehicle) => {
    if (!v.held_by || !v.title_status || !v.management_mode) return;
    const key = `${v.held_by}:${v.title_status}:${v.management_mode}`;
    if (options[key]) return;
    const r = await methodOptions(v.held_by, v.title_status, v.management_mode);
    if (r.ok) setOptions((x) => ({ ...x, [key]: r.data }));
  }, [options]);
  useEffect(() => { if (s.step === 2) s.vehicles.forEach((v) => void loadOptions(v)); }, [s.step, s.vehicles, loadOptions]);
  const optsFor = (v: ApplyVehicle) => options[`${v.held_by}:${v.title_status}:${v.management_mode}`] ?? null;

  // ------------------------------------------------------------ step navigation
  const nextFromOwner = () => {
    const e = ownerErrors(o);
    setErrs(e);
    if (Object.keys(e).length) { focusFirstError(); return; }
    if (!s.vehicles.length) setS((x) => ({ ...x, vehicles: [blankVehicle(uid())], active: 0 }));
    go(1);
  };
  const vehicleErr = (i: number) => vehicleErrors(s.vehicles[i]!, o.owner_type);
  const saveVehicle = (i: number): boolean => {
    const e = vehicleErr(i);
    const prefixed = Object.fromEntries(Object.entries(e).map(([k, v]) => [`v${i}.${k}`, v]));
    setErrs(prefixed);
    if (Object.keys(e).length) { focusFirstError(); return false; }
    return true;
  };
  const addVehicle = () => { if (s.active >= 0 && !saveVehicle(s.active)) return; setS((x) => ({ ...x, vehicles: [...x.vehicles, blankVehicle(uid())], active: x.vehicles.length })); };
  const nextFromVehicles = () => {
    if (s.active >= 0 && !saveVehicle(s.active)) return;
    const bad = s.vehicles.findIndex((_, i) => Object.keys(vehicleErr(i)).length);
    if (bad >= 0) { setS((x) => ({ ...x, active: bad })); saveVehicle(bad); return; }
    setS((x) => ({ ...x, active: -1 }));
    go(2);
  };
  const nextFromPlan = () => {
    const e: Errs = {};
    s.vehicles.forEach((v, i) => { for (const [k, m] of Object.entries(planErrors(v))) e[`v${i}.${k}`] = m; });
    setErrs(e);
    if (Object.keys(e).length) { focusFirstError(); return; }
    go(3);
  };

  const checkVin = async (i: number) => {
    const v = s.vehicles[i]!;
    const vin = cleanVin(v.vin);
    setVinMsg((m) => ({ ...m, [v.key]: 'Checking' }));
    const r = await lookupVin(vin);
    if (!r.ok) { setVinMsg((m) => ({ ...m, [v.key]: '' })); setErrs((e) => ({ ...e, [`v${i}.vin`]: r.message })); return; }
    clearErr(`v${i}.vin`);
    const d = r.data.decode;
    if (d && d.make) {
      setVehicle(i, { vin, year: v.year || String(d.year ?? ''), make: v.make || d.make || '', model: v.model || d.model || '', trim: v.trim || d.trim || '', fuel: v.fuel || d.fuel || '', decoded: true });
      setVinMsg((m) => ({ ...m, [v.key]: `Found: ${[d.year, d.make, d.model, d.trim].filter(Boolean).join(' ')}. Check the details below.` }));
    } else setVinMsg((m) => ({ ...m, [v.key]: 'VIN checked. Enter the year, make and model from the ownership permit.' }));
  };

  const submit = async (e: React.FormEvent<HTMLFormElement>) => {
    e.preventDefault();
    setProblem(null);
    if (!signedIn && password.length < 10) { setErrs({ password: 'Choose a password of at least 10 characters.' }); focusFirstError(); return; }
    setBusy(true);
    const form = e.currentTarget;
    let token = await freshTurnstileToken(form);
    if (!token) { setBusy(false); setProblem('Our security check did not load in this browser (a content blocker or a privacy setting such as iCloud Private Relay can block it). Turn it off for carmacars.ca or try another browser; your answers are kept.'); return; }
    let r = await submitApplication(s, password, token);
    // a token refused (expired or already used): one more try with a new one, without asking the owner to reload
    if (!r.ok && r.code === 'turnstile') { token = await freshTurnstileToken(form); if (token) r = await submitApplication(s, password, token); }
    setBusy(false);
    if (r.ok) { setDone(r.data); requestAnimationFrame(() => top.current?.focus()); return; }
    setProblem(r.message);
    if (r.fieldErrors) {
      setErrs(r.fieldErrors);
      const k = Object.keys(r.fieldErrors)[0] ?? '';
      const step = /^v\d+\.(management_mode|onboarding_method|finance_permission|new_corporation_name)$/.test(k) ? 2 : /^v\d+\./.test(k) ? 1 : k === 'password' ? 3 : 0;
      if (step !== 3) { setS((x) => ({ ...x, step, active: step === 1 ? Number(k.slice(1, k.indexOf('.'))) : x.active })); }
      focusFirstError();
    }
  };

  const sendLink = async () => {
    setResumeMsg(null);
    const r = await emailResumeLink(resumeEmail);
    setResumeMsg(r.ok ? `Sent to ${resumeEmail}. The link works once, for 24 hours.` : r.message);
  };

  // what CarmaCars itself bills before enrollment, on the standard grid (the signed schedule governs)
  const count = s.vehicles.length;
  const tier = facts.grid.find((g) => count >= g.min_vehicles && (g.max_vehicles === null || count <= g.max_vehicles)) ?? facts.grid[0];

  if (done) {
    return (
      <div className="pt-card pt-card--next" tabIndex={-1} ref={top} data-testid="apply-done">
        <p className="pt-kicker">Application {done.applicationNumber}</p>
        <h2 className="d2">Application received</h2>
        <p>{done.vehicles - done.declined} vehicle{done.vehicles - done.declined === 1 ? '' : 's'} with our team. We reply within 1 business day with the terms for each one; then you sign your agreements and pay the upfront invoice in your owner portal.</p>
        {done.declined > 0 && <p className="ow-warn">{done.declined} vehicle{done.declined === 1 ? ' was' : 's were'} not accepted: a rebuilt, salvage or irreparable brand is not eligible (Enrollment Agreement 3.1).</p>}
        {done.checkEmail
          ? <p className="pt-note" data-testid="apply-check-email">We already had your email from an earlier booking request, so your sign-in is set up on that record. Open the email we just sent and choose your password: your owner portal and your earlier requests are there. The link works for 24 hours.</p>
          : done.confirmEmail
            ? <div className="pt-note" data-testid="apply-confirm-email"><p><strong>One more step: confirm your email.</strong> We sent a link to {done.confirmEmail} with the subject &quot;Confirm your CarmaCars account&quot;. Open it within 24 hours: it confirms your email and opens your owner portal.</p><p className="small">No email after a few minutes? Check spam, or go to <Link className="link" href="/sign-in">Sign in</Link>, enter your email and password, and press &quot;Send a new confirmation link&quot;.</p></div>
            : <p><Link className="btn btn--primary" href="/owner?applied=1">Go to your owner portal</Link></p>}
      </div>
    );
  }

  const savedText = saved.state === 'saving' ? 'Saving' : saved.state === 'saved' && saved.at ? `Saved ${new Date(saved.at).toLocaleTimeString('en-CA', { hour: 'numeric', minute: '2-digit' })}` : saved.state === 'error' ? 'Not saved. Check your connection.' : 'Saved as you go';

  return (
    <div className="stack-lg">
      <div ref={top} tabIndex={-1} className="stack" style={{ outline: 'none' }}>
        <ol className="ow-progress" aria-label="Steps">
          {STEPS.map((t, i) => <li key={t} className={i < s.step ? 'is-done' : i === s.step ? 'is-on' : ''} aria-current={i === s.step ? 'step' : undefined}>{i + 1}<span>. {t}</span></li>)}
        </ol>
        <div className="row" style={{ justifyContent: 'space-between' }}>
          <h2 className="d3" style={{ margin: 0 }}>{STEPS[s.step]}</h2>
          <p className={`ow-saved${saved.state === 'saved' ? ' is-saved' : ''}`} role="status" aria-live="polite" data-testid="autosave">{savedText}</p>
        </div>
      </div>

      {s.step === 0 && (
        <section className="pt-card" aria-label="About you" onBlur={() => cap.capture({ name: [o.first_name, o.middle_name, o.last_name].map((x) => x.trim()).filter(Boolean).join(' '), email: o.email, phone: o.phone })}>
          {ownerOnFile && <p className="pt-note">You already have an owner account. These vehicles are added to it; details you change here update your record.</p>}
          <Choice name="ow_type" legend="I am enrolling as" value={o.owner_type} options={[['individual', 'An individual'], ['corporation', 'A corporation']] as const} onChange={(v) => { setOwner({ owner_type: v }); clearErr('owner_type'); }} err={errs.owner_type} />
          <div className="field-row field-row--3">
            <Field id="ap-first" label="First name" err={errs.first_name}><input className="input" {...aria('ap-first', errs.first_name)} value={o.first_name} onChange={(e) => { setOwner({ first_name: e.target.value }); clearErr('first_name'); }} autoComplete="given-name" /></Field>
            <Field id="ap-middle" label="Middle name" optional><input className="input" id="ap-middle" value={o.middle_name} onChange={(e) => setOwner({ middle_name: e.target.value })} autoComplete="additional-name" /></Field>
            <Field id="ap-last" label="Last name" err={errs.last_name}><input className="input" {...aria('ap-last', errs.last_name)} value={o.last_name} onChange={(e) => { setOwner({ last_name: e.target.value }); clearErr('last_name'); }} autoComplete="family-name" /></Field>
          </div>
          {o.owner_type === 'corporation' && (
            <>
              <div className="field-row">
                <Field id="ap-corp" label="Corporation name" err={errs.corporation_name}><input className="input" {...aria('ap-corp', errs.corporation_name)} value={o.corporation_name} onChange={(e) => { setOwner({ corporation_name: e.target.value }); clearErr('corporation_name'); }} autoComplete="organization" /></Field>
                <Field id="ap-corpno" label="Corporation number" err={errs.corporation_number}><input className="input" {...aria('ap-corpno', errs.corporation_number)} value={o.corporation_number} onChange={(e) => { setOwner({ corporation_number: e.target.value }); clearErr('corporation_number'); }} /></Field>
              </div>
              <Field id="ap-title" label="Your title at the corporation" err={errs.signing_officer_title} hint="You sign for the corporation and confirm you have authority to bind it."><input className="input" {...aria('ap-title', errs.signing_officer_title, 'hint')} value={o.signing_officer_title} onChange={(e) => { setOwner({ signing_officer_title: e.target.value }); clearErr('signing_officer_title'); }} placeholder="Director" autoComplete="organization-title" /></Field>
            </>
          )}
          <Field id="ap-addr" label="Find your address" hint="Start typing and choose it. Then check each line below.">
            <AddressInput id="ap-addr" name="address" value={{ label: o.address, placeId: '' }} describedBy="ap-addr-hint"
              onChange={(v) => {
                if (!v.placeId) { setOwner({ address: v.label }); return; }
                const parts = v.label.split(',').map((x) => x.trim());
                const prov = parts.find((x) => PROVINCES.includes(x.split(' ')[0] ?? ''))?.split(' ')[0] ?? o.province;
                const street = parts.find((x) => /^\d/.test(x)) ?? parts[0] ?? '';
                const city = parts[parts.indexOf(street) + 1] && !PROVINCES.includes((parts[parts.indexOf(street) + 1] ?? '').split(' ')[0] ?? '') ? parts[parts.indexOf(street) + 1]! : o.city;
                setOwner({ address: v.label, address_line1: street, city, province: prov });
                clearErr('address_line1'); clearErr('city');
              }} />
          </Field>
          <Field id="ap-line1" label="Street address" err={errs.address_line1}><input className="input" {...aria('ap-line1', errs.address_line1)} value={o.address_line1} onChange={(e) => { setOwner({ address_line1: e.target.value }); clearErr('address_line1'); }} autoComplete="address-line1" /></Field>
          <Field id="ap-line2" label="Apartment or unit" optional><input className="input" id="ap-line2" value={o.address_line2} onChange={(e) => setOwner({ address_line2: e.target.value })} autoComplete="address-line2" /></Field>
          <div className="field-row field-row--3">
            <Field id="ap-city" label="City" err={errs.city}><input className="input" {...aria('ap-city', errs.city)} value={o.city} onChange={(e) => { setOwner({ city: e.target.value }); clearErr('city'); }} autoComplete="address-level2" /></Field>
            <Field id="ap-prov" label="Province"><select className="select" id="ap-prov" value={o.province} onChange={(e) => setOwner({ province: e.target.value })} autoComplete="address-level1">{PROVINCES.map((p) => <option key={p} value={p}>{p}</option>)}</select></Field>
            <Field id="ap-postal" label="Postal code" err={errs.postal_code}><input className="input" {...aria('ap-postal', errs.postal_code)} value={o.postal_code} onChange={(e) => { setOwner({ postal_code: e.target.value.toUpperCase() }); clearErr('postal_code'); }} autoComplete="postal-code" /></Field>
          </div>
          <div className="field-row">
            <Field id="ap-email" label="Email" err={errs.email}><input className="input" type="email" {...aria('ap-email', errs.email)} value={o.email} onChange={(e) => { setOwner({ email: e.target.value }); setResumeEmail(e.target.value); clearErr('email'); }} autoComplete="email" readOnly={signedIn && !!o.email} /></Field>
            <Field id="ap-phone" label="Mobile" err={errs.phone}><input className="input" type="tel" {...aria('ap-phone', errs.phone)} value={o.phone} onChange={(e) => { setOwner({ phone: e.target.value }); clearErr('phone'); }} autoComplete="tel" /></Field>
          </div>
          <CaptureNote reply={cap.reply} next="/list-your-car/apply" />
          {o.owner_type === 'individual' && (
            <div className="field-row">
              <Field id="ap-lic" label="Driver's licence number" err={errs.licence_number} hint="It goes on the registry forms. Never saved in a draft: enter it again if you come back later."><input className="input" {...aria('ap-lic', errs.licence_number, 'hint')} value={o.licence_number} onChange={(e) => { setOwner({ licence_number: e.target.value.toUpperCase() }); clearErr('licence_number'); }} placeholder="A1234-12345-12345" autoComplete="off" /></Field>
              <Field id="ap-dob" label="Date of birth" err={errs.date_of_birth}><input className="input" type="date" {...aria('ap-dob', errs.date_of_birth)} value={o.date_of_birth} onChange={(e) => { setOwner({ date_of_birth: e.target.value }); clearErr('date_of_birth'); }} autoComplete="bday" /></Field>
            </div>
          )}
          <div className="field-row">
            <Field id="ap-hst" label="HST number" optional err={errs.hst_number} hint="With an HST number on file, HST is added to your payouts."><input className="input" {...aria('ap-hst', errs.hst_number, 'hint')} value={o.hst_number} onChange={(e) => { setOwner({ hst_number: e.target.value.toUpperCase() }); clearErr('hst_number'); }} placeholder="123456789RT0001" /></Field>
            <Field id="ap-ref" label="Who referred you" optional><input className="input" id="ap-ref" value={o.referred_by} onChange={(e) => setOwner({ referred_by: e.target.value })} /></Field>
          </div>
          <div className="ow-actions"><span /><button className="btn btn--primary btn--lg" type="button" onClick={nextFromOwner}>Continue to vehicles</button></div>
        </section>
      )}

      {s.step === 1 && (
        <section className="stack-lg" aria-label="Your vehicles">
          {s.vehicles.length > 1 || s.active < 0 ? (
            <ul className="ow-vlist">{s.vehicles.map((v, i) => (
              <li key={v.key} className={i === s.active ? 'is-on' : ''}>
                <span><b>{vName(v)}</b>{v.plate ? ` · ${v.plate.toUpperCase()}` : ''}</span>
                <span className="row">
                  {i !== s.active && <button type="button" className="btn btn--quiet btn--sm" onClick={() => { if (s.active >= 0 && !saveVehicle(s.active)) return; setS((x) => ({ ...x, active: i })); }}>Edit</button>}
                  <button type="button" className="btn btn--quiet btn--sm" onClick={() => setS((x) => ({ ...x, vehicles: x.vehicles.filter((_, k) => k !== i), active: x.active === i ? -1 : x.active > i ? x.active - 1 : x.active }))} aria-label={`Remove ${vName(v)}`}>Remove</button>
                </span>
              </li>))}</ul>
          ) : null}
          {s.active >= 0 && s.vehicles[s.active] && (() => {
            const i = s.active; const v = s.vehicles[i]!; const e = (k: string) => errs[`v${i}.${k}`]; const id = (k: string) => `ap-v${i}-${k}`;
            const set = (p: Partial<ApplyVehicle>, k?: string) => { setVehicle(i, p); if (k) clearErr(`v${i}.${k}`); };
            return (
              <div className="pt-card" data-testid="vehicle-editor">
                <h3 className="d4">Vehicle {i + 1}{v.make ? `: ${vName(v)}` : ''}</h3>
                <Field id={id('vin')} label="VIN" err={e('vin')} hint={vinMsg[v.key] || 'On the ownership permit and the driver\'s door frame. We look up the year, make and model.'}>
                  <div className="ow-vin"><input className="input" {...aria(id('vin'), e('vin'), 'hint')} value={v.vin} onChange={(ev) => set({ vin: ev.target.value.toUpperCase(), decoded: false }, 'vin')} onBlur={() => { if (cleanVin(v.vin).length === 17 && !v.decoded) void checkVin(i); }} autoComplete="off" autoCapitalize="characters" spellCheck={false} maxLength={20} />
                    <button type="button" className="btn btn--ghost" onClick={() => void checkVin(i)}>Look up</button></div>
                </Field>
                <div className="field-row field-row--3">
                  <Field id={id('year')} label="Year" err={e('year')}><input className="input" inputMode="numeric" {...aria(id('year'), e('year'))} value={v.year} onChange={(ev) => set({ year: ev.target.value.replace(/\D/g, '').slice(0, 4) }, 'year')} /></Field>
                  <Field id={id('make')} label="Make" err={e('make')}><input className="input" {...aria(id('make'), e('make'))} value={v.make} onChange={(ev) => set({ make: ev.target.value }, 'make')} /></Field>
                  <Field id={id('model')} label="Model" err={e('model')}><input className="input" {...aria(id('model'), e('model'))} value={v.model} onChange={(ev) => set({ model: ev.target.value }, 'model')} /></Field>
                </div>
                <div className="field-row field-row--3">
                  <Field id={id('trim')} label="Trim" optional><input className="input" id={id('trim')} value={v.trim} onChange={(ev) => set({ trim: ev.target.value })} /></Field>
                  <Field id={id('colour')} label="Colour" err={e('colour')}><input className="input" {...aria(id('colour'), e('colour'))} value={v.colour} onChange={(ev) => set({ colour: ev.target.value }, 'colour')} /></Field>
                  <Field id={id('fuel')} label="Fuel" err={e('fuel')}><select className="select" {...aria(id('fuel'), e('fuel'))} value={v.fuel} onChange={(ev) => set({ fuel: ev.target.value }, 'fuel')}><option value="">Choose</option>{FUELS.map(([k, l]) => <option key={k} value={k}>{l}</option>)}</select></Field>
                </div>
                <div className="field-row field-row--3">
                  <Field id={id('plate')} label="Plate" err={e('plate')}><input className="input" {...aria(id('plate'), e('plate'))} value={v.plate} onChange={(ev) => set({ plate: ev.target.value.toUpperCase() }, 'plate')} autoCapitalize="characters" /></Field>
                  <Field id={id('odo')} label="Odometer (km)" err={e('odometer_km')}><input className="input" inputMode="numeric" {...aria(id('odo'), e('odometer_km'))} value={v.odometer_km} onChange={(ev) => set({ odometer_km: ev.target.value.replace(/[^\d]/g, '') }, 'odometer_km')} /></Field>
                  <Field id={id('ins')} label="Current insurer" err={e('current_insurer')}><input className="input" {...aria(id('ins'), e('current_insurer'))} value={v.current_insurer} onChange={(ev) => set({ current_insurer: ev.target.value }, 'current_insurer')} /></Field>
                </div>
                <Choice name={id('held')} legend="The ownership permit is in the name of" value={v.held_by} options={[['individual', 'Me personally'], ['corporation', 'My corporation']] as const} onChange={(x) => set({ held_by: x, onboarding_method: '' }, 'held_by')} err={e('held_by')} />
                <Choice name={id('title')} legend="The vehicle is" value={v.title_status} options={[['owned_outright', 'Owned outright'], ['financed', 'Financed'], ['leased', 'Leased']] as const} onChange={(x) => set({ title_status: x, onboarding_method: '', owners_lien: '' }, 'title_status')} err={e('title_status')} />
                {v.title_status && v.title_status !== 'owned_outright' && (
                  <div className="field-row">
                    <Field id={id('lender')} label={v.title_status === 'leased' ? 'Lease company' : 'Lender'} err={e('finance_party_name')}><input className="input" {...aria(id('lender'), e('finance_party_name'))} value={v.finance_party_name} onChange={(ev) => set({ finance_party_name: ev.target.value }, 'finance_party_name')} /></Field>
                    <Field id={id('acct')} label="Loan or lease account" optional><input className="input" id={id('acct')} value={v.finance_party_account} onChange={(ev) => set({ finance_party_account: ev.target.value })} /></Field>
                  </div>
                )}
                <Choice name={id('brand')} legend="Has it ever been branded rebuilt, salvage or irreparable?" value={v.branded} options={[['no', 'No'], ['yes', 'Yes']] as const} onChange={(x) => set({ branded: x }, 'branded')} err={e('branded')} />
                {v.branded === 'yes' && <p className="ow-warn">A vehicle with a rebuilt, salvage or irreparable brand is not eligible (Enrollment Agreement 3.1). You can still submit your other vehicles.</p>}
                <Choice name={id('damage')} legend="Any open recall, or structural, flood or fire damage?" value={v.damage} options={[['no', 'No'], ['yes', 'Yes']] as const} onChange={(x) => set({ damage: x }, 'damage')} err={e('damage')} />
                {v.damage === 'yes' && <Field id={id('dmg')} label="What was it?" err={e('damage_details')}><textarea className="textarea" {...aria(id('dmg'), e('damage_details'))} value={v.damage_details} onChange={(ev) => set({ damage_details: ev.target.value }, 'damage_details')} /></Field>}
              </div>
            );
          })()}
          <div className="ow-actions">
            <button className="btn btn--ghost" type="button" onClick={() => go(0)}>Back</button>
            <button className="btn btn--ghost" type="button" onClick={addVehicle}>Add another vehicle</button>
            <button className="btn btn--primary btn--lg" type="button" onClick={nextFromVehicles} disabled={!s.vehicles.length}>Continue</button>
          </div>
        </section>
      )}

      {s.step === 2 && (
        <section className="stack-lg" aria-label="How it will work">
          {s.vehicles.map((v, i) => {
            const e = (k: string) => errs[`v${i}.${k}`]; const set = (p: Partial<ApplyVehicle>, k?: string) => { setVehicle(i, p); if (k) clearErr(`v${i}.${k}`); };
            const opts = optsFor(v);
            const chosen = opts?.find((x) => x.method === v.onboarding_method) ?? null;
            const estimate = chosen ? (v.owners_lien === 'elect' && chosen.estimate_with_lien_cents ? chosen.estimate_with_lien_cents : chosen.estimate_cents) : null;
            return (
              <div key={v.key} className="pt-card" data-testid="plan-vehicle">
                <h3 className="d4">{vName(v)}</h3>
                <fieldset className={`field${e('management_mode') ? ' has-error' : ''}`} style={{ border: 0, padding: 0, margin: 0 }}>
                  <legend className="label">How do you want it rented?</legend>
                  <div className="ow-compare">{MODES.map((m) => (
                    <label key={m.v} className="option"><input type="radio" name={`ap-mode-${i}`} value={m.v} checked={v.management_mode === m.v} onChange={() => set({ management_mode: m.v, onboarding_method: m.v === 'turo_only' ? 'none' : '' }, 'management_mode')} />
                      <span className="option__title">{m.t}</span><span className="option__body">{m.b.replace('{payout}', facts.payout_day_text ?? 'payout day')}</span></label>))}</div>
                  <p className="error" role="alert">{e('management_mode') ?? ''}</p>
                </fieldset>
                {v.management_mode !== 'turo_only' && (
                  <fieldset className={`field${e('onboarding_method') ? ' has-error' : ''}`} style={{ border: 0, padding: 0, margin: 0 }}>
                    <legend className="label">How the registration works</legend>
                    {!opts ? <div className="skeleton sk-line" aria-hidden="true" /> : opts.length === 0 ? <p className="small">No method is open for this combination. Call us and we will look at it with you.</p> : (
                      <div className="stack">{opts.map((m) => (
                        <label key={m.method} className="option"><input type="radio" name={`ap-method-${i}`} value={m.method} checked={v.onboarding_method === m.method} onChange={() => set({ onboarding_method: m.method }, 'onboarding_method')} />
                          <span className="option__title">{m.label}{m.recommended ? ' (recommended)' : ''}</span>
                          <span className="option__body">About {money(m.estimate_cents)}{m.plus_tax ? ' plus any tax' : ''}, paid by you to the registry and inspection station. {m.government_forms.length ? `Forms: ${m.government_forms.join(', ')}.` : m.sign_back_on_permit ? 'You sign the back of the ownership permit.' : ''}</span></label>))}</div>
                    )}
                    <p className="error" role="alert">{e('onboarding_method') ?? ''}</p>
                  </fieldset>
                )}
                {chosen?.estimate_with_lien_cents && <Choice name={`ap-lien-${i}`} legend="Register an Owner's Lien on the vehicle (optional, about $10)?" value={v.owners_lien} options={[['elect', 'Yes, register it'], ['decline', 'No']] as const} onChange={(x) => set({ owners_lien: x })} />}
                {v.onboarding_method === 'lease_new_owner_corporation' && <Field id={`ap-newcorp-${i}`} label="Proposed name of your new corporation" err={e('new_corporation_name')} hint='Or type "numbered".'><input className="input" {...aria(`ap-newcorp-${i}`, e('new_corporation_name'), 'hint')} value={v.new_corporation_name} onChange={(ev) => set({ new_corporation_name: ev.target.value }, 'new_corporation_name')} /></Field>}
                {v.title_status && v.title_status !== 'owned_outright' && (
                  <fieldset className={`field${e('finance_permission') ? ' has-error' : ''}`} style={{ border: 0, padding: 0, margin: 0 }}>
                    <legend className="label">Permission from your {v.title_status === 'leased' ? 'lease company' : 'lender'}</legend>
                    <div className="stack">
                      {([['attached', 'I have it in writing', 'Send it to us with your ownership permit.'], ['not_obtained', 'I do not have it yet', 'We help you ask for it before the registry visit.'], ['proceed', 'I will proceed without it', 'Read the warning below first.']] as const).map(([k, t, b]) => (
                        <label key={k} className="option"><input type="radio" name={`ap-perm-${i}`} checked={v.finance_permission === k} onChange={() => set({ finance_permission: k }, 'finance_permission')} /><span className="option__title">{t}</span><span className="option__body">{b}</span></label>))}
                    </div>
                    <p className="error" role="alert">{e('finance_permission') ?? ''}</p>
                    {v.finance_permission === 'proceed' && <div className="ow-warn" role="note"><b>Form C warning</b><span>Moving the registration of a financed or leased vehicle without written permission may breach your loan or lease. Your lender may demand the full balance or repossess the vehicle, and its insurance terms may be affected. You bear every consequence. You sign Form C, on paper with a witness, to confirm this before anything changes at the registry.</span></div>}
                  </fieldset>
                )}
                {(v.management_mode === 'turo_only' || chosen) && (
                  <div className="ow-estimate" data-testid="estimate">
                    <b>What it costs to start</b>
                    {v.management_mode === 'turo_only' ? <p>Turo-Only: no registry change, no Fees and no upfront invoice.</p> : <>
                      <dl className="pt-dl pt-dl--money">
                        <div><dt>Registry, inspection and appraisal estimate (you pay them directly)</dt><dd>{money(estimate)}{chosen?.plus_tax ? ' + tax' : ''}</dd></div>
                        {tier && v.management_mode && <div><dt>CarmaCars upfront: first and last month&apos;s Insurance Fee, before HST</dt><dd>{money(2 * tier.insurance_fee_cents)}</dd></div>}
                        {facts.trackers_available && tier && <div><dt>Tracker Install Fee, its own invoice, before HST</dt><dd>{money(facts.install_fee_cents)}</dd></div>}
                      </dl>
                      {!facts.trackers_available && <p className="small">A {money(facts.install_fee_cents)} Tracker Install Fee applies when trackers become available. We bill it then, on its own invoice.</p>}
                      <p className="small"><b>You pay registry fees, the safety inspection and the appraisal directly to ServiceOntario, the inspection station and the appraiser. CarmaCars does not collect them. Amounts are estimates and may vary.</b> Any tax is calculated on the appraised value at the registry counter. Safety repairs are extra.</p>
                    </>}
                  </div>
                )}
              </div>
            );
          })}
          {tier && <p className="small muted">Standard terms for {count} vehicle{count === 1 ? '' : 's'}: {money(tier.insurance_fee_cents)} Insurance Fee{facts.trackers_available ? ` and ${money(tier.tracker_fee_cents)} Tracker Fee` : ''} a month per vehicle, plus HST; {pct(tier.revenue_share_bps)} Revenue Share on Managed vehicles. We confirm each vehicle&apos;s terms in its Vehicle Schedule.</p>}
          <div className="ow-actions">
            <button className="btn btn--ghost" type="button" onClick={() => go(1)}>Back</button>
            <button className="btn btn--primary btn--lg" type="button" onClick={nextFromPlan}>Review</button>
          </div>
        </section>
      )}

      {s.step === 3 && (
        <form className="stack-lg" noValidate onSubmit={submit} aria-label="Review and submit">
          <section className="pt-card" aria-label="You">
            <div className="pt-card__head"><h3 className="d4">{[o.first_name, o.middle_name, o.last_name].filter(Boolean).join(' ')}</h3><button type="button" className="btn btn--quiet btn--sm" onClick={() => go(0)}>Edit</button></div>
            <p className="small">{o.owner_type === 'corporation' ? `For ${o.corporation_name} (no. ${o.corporation_number}), as ${o.signing_officer_title}. ` : ''}{[o.address_line1, o.address_line2, o.city, o.province, o.postal_code].filter(Boolean).join(', ')}. {o.email}, {o.phone}.</p>
            {o.owner_type === 'individual' && !o.licence_number && <p className="ow-warn">Enter your driver&apos;s licence number again in step 1 (it is never kept in a saved draft).</p>}
          </section>
          {s.vehicles.map((v, i) => (
            <section key={v.key} className="pt-card" aria-label={vName(v)}>
              <div className="pt-card__head"><h3 className="d4">{vName(v)}</h3><button type="button" className="btn btn--quiet btn--sm" onClick={() => { setS((x) => ({ ...x, active: i })); go(1); }}>Edit</button></div>
              <p className="small">{cleanVin(v.vin)} · {v.plate.toUpperCase()} · {v.colour} · {Number(v.odometer_km || 0).toLocaleString('en-CA')} km · {MODES.find((m) => m.v === v.management_mode)?.t}{v.onboarding_method && v.onboarding_method !== 'none' ? ` · ${optsFor(v)?.find((m) => m.method === v.onboarding_method)?.label ?? v.onboarding_method.replace(/_/g, ' ')}` : ''}</p>
            </section>
          ))}
          {!signedIn && (
            <section className="pt-card" aria-label="Your owner account">
              <h3 className="d4">Your owner account</h3>
              <p className="small">You sign in with {o.email} to follow each vehicle, sign your agreements and pay your invoices.</p>
              <Field id="ap-pw" label="Choose a password" err={errs.password} hint="At least 10 characters."><PasswordInput className="input" {...aria('ap-pw', errs.password, 'hint')} value={password} onChange={(e) => { setPassword(e.target.value); clearErr('password'); }} autoComplete="new-password" /></Field>
              <p className="small muted">Already have an account? <Link href={`/sign-in?next=${encodeURIComponent('/list-your-car/apply')}`}>Sign in</Link> and your answers are kept.</p>
            </section>
          )}
          <p className="small muted">By submitting you confirm the answers are true. Nothing is charged now. We set the terms for each vehicle, then you sign and pay the upfront invoice in your owner portal.</p>
          <Turnstile action="owner_application" />
          {problem && <p className="alert alert--error" role="alert"><span>{problem}</span></p>}
          <div className="ow-actions">
            <button className="btn btn--ghost" type="button" onClick={() => go(2)}>Back</button>
            <button className="btn btn--primary btn--lg" type="submit" disabled={busy}>{busy ? 'Sending' : 'Submit application'}</button>
          </div>
        </form>
      )}

      <details className="pt-card">
        <summary className="link">Continue on another device</summary>
        <div className="stack">
          <p className="small">We email you a link that opens these answers on your phone or computer. It works once, for 24 hours.</p>
          <div className="ow-vin">
            <input className="input" type="email" aria-label="Email for the link" value={resumeEmail} onChange={(e) => setResumeEmail(e.target.value)} autoComplete="email" />
            <button type="button" className="btn btn--ghost" onClick={() => void sendLink()}>Email me a link</button>
          </div>
          {resumeMsg && <p className="small" role="status">{resumeMsg}</p>}
        </div>
      </details>
    </div>
  );
}
