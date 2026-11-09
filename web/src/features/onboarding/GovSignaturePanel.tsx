import type { StaffFill } from '@/server/government-forms';
import { signBadge, signatureLine, signSummary, type SignState } from './sign-state';

// The owner's on-screen signature of one government form, beside the form and never on it (r35, 1000). The official PDF
// and the print-ready form carry no signature: this card shows who signed, how and when, the version signed, and whether
// the form changed since (the owner then has one To do to sign again). Admin and staff portals.
const when = (iso: string) => new Intl.DateTimeFormat('en-CA', { timeZone: 'America/Toronto', month: 'short', day: 'numeric', year: 'numeric', hour: 'numeric', minute: '2-digit' }).format(new Date(iso));

export function GovSignaturePanel({ f, base }: { f: StaffFill; base: '/admin' | '/staff' }) {
  const state = (f.sign_state ?? 'unsigned') as SignState;
  const badge = signBadge(state, f.missing.length === 0);
  const sig = f.signature ?? null;
  const labelOf = (name: string) => f.fields?.find((x) => x.name === name)?.label ?? name;
  return (
    <aside className="pt-card stack gf-sig" aria-labelledby="gf-sig-h" data-testid="gov-form-signature" data-state={state}>
      <h2 className="d4" id="gf-sig-h">{"Owner's signature"}</h2>
      {badge && <p><span className={`badge ${badge.tone === 'todo' || badge.tone === 'warn' ? 'badge--red' : 'badge--outline'}`} data-testid="gov-form-sign-state">{badge.text}</span></p>}
      {state === 'ink' && <p className="small">This form was signed in ink and is kept as it is.{sig ? '' : ' No signature was asked on screen.'}</p>}
      {state === 'unsigned' && <p className="small" data-testid="gov-form-unsigned">The owner has not signed this form on screen yet. {f.missing.length ? 'A value is still missing, so they are not asked yet.' : 'They have one To do in the onboarding checklist and one reminder email.'}</p>}
      {sig && (
        <div className="stack gf-sig__box">
          {sig.method === 'drawn' && sig.signature_path
            // eslint-disable-next-line @next/next/no-img-element
            ? <img className="gf-sig__img" src={`${base}/government-forms/${f.id}/signature`} alt={`${sig.signer_name}'s drawn signature`} width={320} height={120} data-testid="gov-form-signature-image" />
            : <p className="gf-sig__typed" data-testid="gov-form-signature-typed">{sig.typed_name ?? sig.signer_name}</p>}
          <p className="small" data-testid="gov-form-signature-line">{signatureLine({ ...sig, typed_name: sig.typed_name ?? null }, when)}</p>
          <p className="small muted">{sig.ip ? `From IP address ${sig.ip}. ` : ''}{sig.user_agent ? `Device: ${sig.user_agent.slice(0, 120)}.` : ''}</p>
        </div>)}
      {state === 'changed' && sig && (
        <p className="alert alert--error" role="status" data-testid="gov-form-changed"><span>
          <b>Changed since signed.</b> {sig.changed.length ? `Changed: ${sig.changed.slice(0, 8).map(labelOf).join(', ')}${sig.changed.length > 8 ? ` and ${sig.changed.length - 8} more` : ''}. ` : ''}
          The owner has one To do to sign the form again; the earlier signature stays below.</span></p>)}
      {f.signatures && f.signatures.length > 1 && (
        <details><summary className="link">Every signature ({f.signatures.length})</summary>
          <ul className="ad-list small" data-testid="gov-form-signatures">{f.signatures.map((x) => <li key={x.id}>{x.signer_name}, {x.method === 'typed' ? 'typed name' : 'drawn'}, {when(x.signed_at)}{x.form_version ? `, version ${x.form_version}` : ''}{x.ip ? `, ${x.ip}` : ''}</li>)}</ul>
        </details>)}
      <p className="small muted" data-testid="gov-form-signature-note">{signSummary([{ sign_state: state, signable: f.missing.length === 0 }], 'staff') || 'Signed on screen.'} This signature is a record kept beside the form. It is never printed on the official form: the print-ready form has no signature, and the owner signs it in ink at the registry.</p>
    </aside>
  );
}
