'use client';
import { useState } from 'react';
import { UploadCard } from './UploadCard';

// Coverage option 1 (own policy with OPCF 27) or 2 (credit card coverage): the details, then the proof.
export function CoverageUpload({ number, option, status, reason }: { number: string; option: 1 | 2; status?: string | null; reason?: string | null }) {
  const [d, setD] = useState<Record<string, string>>({});
  const f = (k: string, label: string, props: React.InputHTMLAttributes<HTMLInputElement> = {}) => (
    <div className="field"><label className="label" htmlFor={`pt-cov-${k}`}>{label}</label>
      <input className="input" id={`pt-cov-${k}`} value={d[k] ?? ''} onChange={(e) => setD({ ...d, [k]: e.target.value })} {...props} /></div>
  );
  return (
    <div className="stack">
      {option === 1 ? (<>{f('insurer_name', 'Insurer', { required: true })}<div className="field-row">{f('policy_number', 'Policy number', { required: true })}{f('policy_expiry', 'Policy expiry', { type: 'date', required: true })}</div></>)
        : (<div className="field-row">{f('card_issuer', 'Card issuer')}{f('card_last4', 'Last four digits', { inputMode: 'numeric', maxLength: 4 })}</div>)}
      <UploadCard number={number} kind="coverage_proof" driverId={null} status={status} reason={reason} details={{ ...d, coverage_option: String(option) }}
        title={option === 1 ? 'Policy page showing OPCF 27' : 'Card benefits certificate'}
        hint={option === 1 ? 'A photo or PDF of the policy page or your insurer\'s letter. It must run to the return date.' : 'A photo or PDF of the certificate. It must be the card you paid with.'} />
    </div>
  );
}
