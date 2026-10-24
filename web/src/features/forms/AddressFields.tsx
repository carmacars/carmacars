'use client';
import { useState } from 'react';
import { AddressInput, type AddressValue } from './AddressInput';
import type { AddressParts } from './address-parts';

// An address kept field by field (migration 0130's autofill everywhere): a lookup line that fills street, unit, city,
// province, postal code and country from the chosen suggestion, then each line, editable. The lookup is optional: over
// Google's daily cap (or with no match) the person types the lines; nothing else changes. The keys of the form's own
// object are mapped (address_line1, address_line2, city, province, postal_code, country by default).
export type AddressKeys = { street: string; unit?: string; city: string; province: string; postal_code: string; country?: string };
const DEFAULT: AddressKeys = { street: 'address_line1', unit: 'address_line2', city: 'city', province: 'province', postal_code: 'postal_code', country: 'country' };

export function AddressFields({ idp, value, onChange, errors = {}, keys = DEFAULT, disabled, lookupLabel = 'Find the address', streetLabel = 'Street address', testId }: {
  idp: string; value: Record<string, unknown>; onChange: (patch: Record<string, string>) => void; errors?: Record<string, string | undefined>; keys?: AddressKeys;
  disabled?: boolean; lookupLabel?: string; streetLabel?: string; testId?: string;
}) {
  const [look, setLook] = useState<AddressValue>({ label: '', placeId: '' });
  const v = (k?: string) => (k ? String(value[k] ?? '') : '');
  const fill = (p: AddressParts) => {
    const patch: Record<string, string> = {};
    if (p.street) patch[keys.street] = p.street;
    if (keys.unit && p.unit) patch[keys.unit] = p.unit;
    if (p.city) patch[keys.city] = p.city;
    if (p.province) patch[keys.province] = p.province;
    if (p.postal_code) patch[keys.postal_code] = p.postal_code;
    if (keys.country && p.country) patch[keys.country] = p.country;
    onChange(patch);
  };
  const input = (k: string | undefined, label: string, auto: string, opt = false) => k ? (
    <div className={`field${errors[k] ? ' has-error' : ''}`}>
      <label className="label" htmlFor={`${idp}-${k}`}>{label}{opt ? <span className="muted"> (optional)</span> : null}</label>
      <input className="input" id={`${idp}-${k}`} name={k} value={v(k)} onChange={(e) => onChange({ [k]: e.target.value })} autoComplete={auto} disabled={disabled}
        aria-invalid={errors[k] ? true : undefined} aria-describedby={errors[k] ? `${idp}-${k}-err` : undefined} data-testid={`${idp}-${k}`} />
      {errors[k] && <p className="error" role="alert" id={`${idp}-${k}-err`}>{errors[k]}</p>}
    </div>) : null;
  return (
    <div className="stack" data-testid={testId ?? `${idp}-address`}>
      {!disabled && <div className="field">
        <label className="label" htmlFor={`${idp}-lookup`}>{lookupLabel}</label>
        <AddressInput id={`${idp}-lookup`} name={`${idp}-lookup`} value={look} onChange={setLook} onParts={fill} describedBy={`${idp}-lookup-hint`} placeholder="Start typing the street address" testId={`${idp}-lookup`} />
        <p className="hint" id={`${idp}-lookup-hint`}>Start typing and choose it: the lines below fill in. Check them, or type them yourself.</p>
      </div>}
      {input(keys.street, streetLabel, 'address-line1')}
      {input(keys.unit, 'Apartment or unit', 'address-line2', true)}
      <div className="field-row field-row--3">
        {input(keys.city, 'City', 'address-level2')}
        {input(keys.province, 'Province or state', 'address-level1')}
        {input(keys.postal_code, 'Postal code', 'postal-code')}
      </div>
      {input(keys.country, 'Country', 'country-name')}
    </div>
  );
}

/** The lookup line alone, above a form's own address fields: the chosen suggestion fills them (0130). */
export function AddressLookup({ idp, onParts, label = 'Find the address', hint = 'Start typing and choose it: the address fields fill in. Check them.' }: { idp: string; onParts: (p: AddressParts, label: string) => void; label?: string; hint?: string }) {
  const [look, setLook] = useState<AddressValue>({ label: '', placeId: '' });
  return (
    <div className="field ad-field--wide" data-testid={`${idp}-lookup-field`}>
      <label className="label" htmlFor={`${idp}-lookup`}>{label}</label>
      <AddressInput id={`${idp}-lookup`} name={`${idp}-lookup`} value={look} onChange={setLook} onParts={onParts} describedBy={`${idp}-lookup-hint`} placeholder="Start typing the street address" testId={`${idp}-lookup`} />
      <p className="hint" id={`${idp}-lookup-hint`}>{hint}</p>
    </div>
  );
}
