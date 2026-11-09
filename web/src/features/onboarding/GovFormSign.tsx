'use client';
import { useMemo, useState } from 'react';
import { PackageSignForm, type PackageInput, type PackageResult } from '@/features/signing/PackageSignForm';
import type { EsignDoc } from '@/features/signing/types';
import type { Spec } from '@/features/official-forms/fill';
import { GovFormPreview } from './GovFormPreview';
import { needsSignature, signBadge, type SignState } from './sign-state';

// The owner signs each government form that applies to a car (r35, 1000). Each form is shown as the official PDF with its
// boxes filled; the owner checks it and confirms it, one by one; then the signing steps of every signature on the site
// (the reading, the consents, the drawn signature) record one signature per form, with the date, IP address and device.
// The signature is never put on the official PDF: it is kept with us beside the form, and the printed form is still signed
// in ink at the registry.
export interface SignForm {
  fill: string; form_code: string; title: string | null; sha256: string; state: SignState; signable: boolean; official: boolean; missing: string[];
  signed_at: string | null; field_values: Record<string, string | null>; field_map: Record<string, Spec | string>; data_sheet: Array<{ label: string; value: string | null }>;
}
const when = (iso: string) => new Intl.DateTimeFormat('en-CA', { timeZone: 'America/Toronto', month: 'short', day: 'numeric', year: 'numeric', hour: 'numeric', minute: '2-digit' }).format(new Date(iso));
const nameOf = (f: SignForm) => `${f.form_code}${f.title ? `: ${f.title.replace(f.form_code, '').replace(/^[\s:,-]+/, '')}` : ''}`;

export function GovFormSign({ forms, signerName, action }: { forms: SignForm[]; signerName: string; action: (specs: Array<{ fill: string; sha: string; title: string }>, input: PackageInput) => Promise<PackageResult> }) {
  const todo = useMemo(() => forms.filter((f) => needsSignature(f.state, f.signable)), [forms]);
  const [checked, setChecked] = useState<Record<string, boolean>>({});
  const all = todo.length > 0 && todo.every((f) => checked[f.fill]);
  const docs: EsignDoc[] = todo.map((f) => ({ kind: 'govform', ref: f.fill, sha: f.sha256, title: nameOf(f) }));
  const specs = todo.map((f) => ({ fill: f.fill, sha: f.sha256, title: nameOf(f) }));
  return (
    <div className="gf-sign" data-testid="gov-form-sign">
      {forms.map((f) => {
        const b = signBadge(f.state, f.signable);
        const mine = needsSignature(f.state, f.signable);
        return (
          <section key={f.fill} className="pt-card stack" aria-labelledby={`gfs-${f.fill}`} data-testid="gov-form-sign-card" data-code={f.form_code} data-state={f.state}>
            <div className="pt-card__head"><h2 className="d4" id={`gfs-${f.fill}`}>{nameOf(f)}</h2>{b && <span className={`badge ${b.tone === 'todo' || b.tone === 'warn' ? 'badge--red' : 'badge--outline'}`} data-testid="gov-form-sign-badge">{b.text}</span>}</div>
            {f.state === 'signed' && f.signed_at && <p className="small">You signed this form on {when(f.signed_at)}.</p>}
            {f.state === 'changed' && <p className="small" data-testid="gov-form-sign-changed">A value on this form changed after you signed it. Check it again and sign it again.</p>}
            {!f.signable && f.state !== 'ink' && <p className="small">Some values are still missing, so it cannot be signed yet. We will ask you when it is ready.</p>}
            {f.state === 'ink' && <p className="small">Signed in ink already: nothing to sign on screen.</p>}
            <GovFormPreview fill={f.fill} formCode={f.form_code} official={f.official} fieldValues={f.field_values} fieldMap={f.field_map} dataSheet={f.data_sheet} />
            {mine && <label className="check"><input type="checkbox" checked={!!checked[f.fill]} onChange={(e) => setChecked((x) => ({ ...x, [f.fill]: e.target.checked }))} data-testid="gov-form-checked" />
              <span>I have checked every value on {f.form_code} and it is right.</span></label>}
          </section>);
      })}
      {todo.length === 0 && <p className="alert alert--ok" role="status" data-testid="gov-form-all-signed"><span>Every government form for this car is signed. Print them and sign them in ink at the registry visit.</span></p>}
      {todo.length > 0 && !all && <p className="small muted" data-testid="gov-form-check-first">Check each form above to sign.</p>}
      {all && (
        <section className="pt-card stack" aria-labelledby="gfs-sign" data-testid="gov-form-sign-box">
          <h2 className="d4" id="gfs-sign">Sign {todo.length === 1 ? 'the form' : `the ${todo.length} forms`}</h2>
          <PackageSignForm docs={docs.map((d) => ({ key: d.ref, title: d.title }))} signerName={signerName} esign={{ kind: 'documents', docs, role: 'owner' }}
            consent={`I have checked each government form and I sign each one electronically: ${specs.map((s) => s.title).join('; ')}. My signature is a record of my agreement to the values on the form; it is not put on the official form, and I sign the printed form in ink at the registry.`}
            button={todo.length === 1 ? 'Sign the form' : `Sign the ${todo.length} forms`} action={(input) => action(specs, input)} testId="gov-form-sign-form" />
        </section>)}
    </div>
  );
}
