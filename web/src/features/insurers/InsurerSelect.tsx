'use client';
import { useState } from 'react';
import { INSURANCE_COMPANIES, OTHER_INSURER, OTHER_INSURER_LABEL, matchInsurer } from './companies';

// The renter's own insurer: a drop-down of Canadian auto insurers, and "Other (type it)" with a text box. The value is
// the plain name (as typed before this list existed); a saved name not on the list opens as Other with that name.
export function InsurerSelect({ id, value, onChange, testId, required, disabled, otherLabel = 'Insurer’s name' }: {
  id: string; value: string; onChange: (name: string) => void; testId?: string; required?: boolean; disabled?: boolean; otherLabel?: string;
}) {
  const known = matchInsurer(value);
  const [other, setOther] = useState(() => !!value.trim() && !known);
  const choice = other ? OTHER_INSURER : (known ?? '');
  return (
    <>
      <select className="input" id={id} value={choice} required={required} disabled={disabled} data-testid={testId}
        onChange={(e) => { const v = e.target.value; if (v === OTHER_INSURER) { setOther(true); onChange(''); } else { setOther(false); onChange(v); } }}>
        <option value="">Choose the insurer</option>
        {INSURANCE_COMPANIES.map((n) => <option key={n} value={n}>{n}</option>)}
        <option value={OTHER_INSURER}>{OTHER_INSURER_LABEL}</option>
      </select>
      {other && <input className="input" id={`${id}-other`} aria-label={otherLabel} placeholder={otherLabel} value={value} maxLength={120} required={required} disabled={disabled}
        onChange={(e) => onChange(e.target.value)} data-testid={testId ? `${testId}-other` : undefined} style={{ marginTop: 'var(--s-2)' }} />}
    </>
  );
}
