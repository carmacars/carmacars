import Link from '@/components/Link';
import './onboarding.css';
import { MakeAgain } from './MakeAgain';
import { readableMissing } from './missing';
import type { Viewer } from './steps';
import { needsSignature, signBadge, signSummary, type SignState } from './sign-state';

// The government (ServiceOntario) registration forms of an owner's cars, or of one car (r34, 0822): each form the car
// needs, filled in by itself from the records, with its status, what it still misses, when it was made and its
// download. An Admin can make a car's forms again. In the owner portal (Documents), on the owner page and on the car
// page of Admin and staff.
export interface GovForm { id: string; form_code: string; title: string | null; status: string; mode: string; missing: string[]; generated_at: string; official: boolean; by: string; signed_document_id: string | null;
  /** r35 (0870), staff only: the version and the values changed by hand */ version?: number; edits?: number;
  /** r35 (1000): the owner's on-screen signature of this form */ sign_state?: SignState | null; signable?: boolean; signed_at?: string | null }
export interface GovCar { vehicle_id: string; name: string; plate: string | null; due: boolean; turo_only: boolean; method: string | null; needed: string[]; forms: GovForm[]; /** r35 (1000): forms waiting for the owner's signature */ to_sign?: number }
export interface GovData { owner_id: string; admin: boolean; cars: GovCar[]; /** r35 (0870): an Admin or fleet may change values and make the forms again */ can_edit?: boolean }

const STATUS: Record<string, string> = { draft: 'Something is missing', ready: 'Ready to print', printed: 'Printed', signed: 'Signed in ink', filed: 'Filed at the registry' };
const when = (iso: string) => new Intl.DateTimeFormat('en-CA', { timeZone: 'America/Toronto', month: 'short', day: 'numeric', year: 'numeric', hour: 'numeric', minute: '2-digit' }).format(new Date(iso));

export function formHref(viewer: Viewer, f: Pick<GovForm, 'id' | 'official'>): string {
  if (viewer === 'owner') return f.official ? `/owner/documents/forms/${f.id}/official` : `/owner/documents/forms/${f.id}`;
  const base = viewer === 'admin' ? '/admin' : '/staff';
  // r35: staff open the form's page (the official form or its data sheet, the values and the versions)
  return `${base}/government-forms/${f.id}`;
}

export function GovernmentForms({ data, viewer, refresh, title = 'Government forms', only }: { data: GovData | null; viewer: Viewer; refresh: string[]; title?: string; only?: string }) {
  if (!data) return null;
  const cars = data.cars.filter((c) => !only || c.vehicle_id === only);
  return (
    <section className="pt-card stack" id="gov-forms" aria-labelledby="gov-forms-h" data-testid="government-forms">
      <h2 className="d4" id="gov-forms-h">{title}</h2>
      <p className="small muted">The ServiceOntario registration forms each car needs, filled in by themselves from {viewer === 'owner' ? 'your' : 'the owner\'s'} application and the car as soon as the terms are approved, and again whenever a value changes. {viewer === 'owner' ? 'Sign each one on screen, then print them and sign them in ink at the registry; the fees are paid to ServiceOntario directly.' : 'The owner signs each one on screen (the signature is kept beside the form, never on it) and then in ink at the registry; the fees are paid to ServiceOntario directly.'}</p>
      {cars.length === 0 && <p className="small muted">No car yet.</p>}
      {cars.map((c) => (
        <div key={c.vehicle_id} className="stack" data-testid="government-forms-car" data-vehicle={c.vehicle_id}>
          {!only && <h3 className="d5">{c.name}{c.plate ? <span className="small muted"> {c.plate}</span> : null}</h3>}
          {c.turo_only ? <p className="small muted">Turo-Only: no registry form is needed.</p>
            : !c.due ? <p className="small muted" data-testid="government-forms-later">Made by themselves once the terms are approved.</p>
            : c.needed.length === 0 ? <p className="small muted" data-testid="government-forms-none">No registry form is needed for this method{c.method === 'transfer' ? ': the ownership is transferred on the back of the permit' : ''}.</p>
            : (
              <div className="table-scroll ad-scroll" tabIndex={0} role="region" aria-label={`Government forms of the ${c.name}`}>
                <table className="ad-table ad-table--dense ad-table--cards ob-forms" role="table">
                  <thead role="rowgroup"><tr role="row"><th role="columnheader" scope="col">Form</th><th role="columnheader" scope="col">Status</th><th role="columnheader" scope="col">Signature</th><th role="columnheader" scope="col">Made</th><th role="columnheader" scope="col"><span className="vh">Download</span></th></tr></thead>
                  <tbody role="rowgroup">{c.needed.map((code) => {
                    const f = c.forms.find((x) => x.form_code === code);
                    return (
                      <tr key={code} role="row" data-testid="government-form" data-code={code}>
                        <th role="rowheader" scope="row"><b>{code}</b>{f?.title ? <><br /><span className="small">{f.title.replace(code, '').replace(/^[\s:,-]+/, '')}</span></> : null}</th>
                        <td role="cell" data-label="Status">{f ? <><span className={`badge ${f.status === 'draft' ? 'badge--red' : 'badge--outline'}`} data-testid="government-form-status">{STATUS[f.status] ?? f.status}</span>
                          {f.missing.length > 0 && <><br /><span className="small">Missing: {readableMissing(f.missing).join(', ')}</span></>}</> : <span className="small muted">Not made yet</span>}</td>
                        <td role="cell" data-label="Signature" className="small" data-testid="government-form-signature">{f && (() => { const b = signBadge(f.sign_state, f.signable ?? true); return b ? <><span className={`badge ${b.tone === 'todo' || b.tone === 'warn' ? 'badge--red' : 'badge--outline'}`} data-testid="government-form-sign-state">{b.text}</span>{f.signed_at && f.sign_state !== 'unsigned' ? <><br /><span className="muted">{when(f.signed_at)}</span></> : null}</> : null; })()}</td>
                        <td role="cell" data-label="Made" className="small" data-testid="government-form-made">{f ? <>{when(f.generated_at)}<br /><span className="muted">{f.by === 'automatic' ? 'by itself' : `by ${f.by}`}{viewer !== 'owner' && f.version ? `, version ${f.version}` : ''}{viewer !== 'owner' && f.edits ? `, ${f.edits} changed by hand` : ''}</span></> : ''}</td>
                        <td role="cell" data-label="Download">{f && <>{viewer === 'owner' && needsSignature(f.sign_state, f.signable ?? true) && <Link prefetch={false} className="btn btn--primary btn--sm" href={`/owner/sign/forms/${c.vehicle_id}`} data-testid="government-form-sign">{f.sign_state === 'changed' ? 'Sign again' : 'Sign'}</Link>}{' '}<Link prefetch={false} className="btn btn--ghost btn--sm" href={formHref(viewer, f)} data-testid="government-form-download">{viewer === 'owner' ? (f.official ? 'Official form' : 'Data sheet (PDF)') : 'Open'}</Link></>}</td>
                      </tr>);
                  })}</tbody>
                </table>
              </div>)}
          {c.due && c.needed.length > 0 && (() => { const t = signSummary(c.forms.filter((x) => c.needed.includes(x.form_code)), viewer === 'owner' ? 'owner' : 'staff'); return t ? <p className="small" data-testid="government-forms-sign-summary">{t}</p> : null; })()}
          {(data.can_edit ?? data.admin) && viewer !== 'owner' && c.due && !c.turo_only && c.needed.length > 0 && <MakeAgain vehicleId={c.vehicle_id} name={c.name} refresh={refresh} />}
        </div>
      ))}
    </section>
  );
}
