// Forms C and D of the Title Agreement (migration 0040), signed on screen only since 0720 (the owner's decision of
// November 7, 2026: no paper signature for anyone): Form C with one witness and Form D with two, each beside the owner
// on the same device. A form signed on paper before 0720 stays on file as it was.
export interface WForm { code: 'C' | 'D1'; vehicle_id: string | null; vehicle_name: string | null; title: string; witnesses: number; status: 'needed' | 'uploaded' | 'approved' | 'rejected'; reject_reason: string | null; uploaded_at: string | null }
const STATUS: Record<WForm['status'], string> = { needed: 'To sign', uploaded: 'Waiting for our review', approved: 'Signed', rejected: 'To sign again' };

function One({ f }: { f: WForm }) {
  const href = f.code === 'C' ? (f.vehicle_id ? `/owner/documents/form-c/${f.vehicle_id}` : null) : '/owner/documents/form-d';
  const open = f.status === 'needed' || f.status === 'rejected';
  return (
    <li className="pt-up stack" data-testid={`witnessed-${f.code}${f.vehicle_id ? `-${f.vehicle_id}` : ''}`}>
      <div className="pt-card__head"><h3 className="d4">{f.title}</h3><span className="badge badge--outline">{STATUS[f.status]}</span></div>
      {f.vehicle_name && <p className="small">{f.vehicle_name}</p>}
      {f.status === 'rejected' && f.reject_reason && <p className="alert alert--error" role="alert"><span className="alert__title">What to fix</span><span>{f.reject_reason}</span></p>}
      {open && href && <>
        <p className="small">Sign it on screen with {f.witnesses === 2 ? 'your two witnesses' : 'your witness'} beside you on the same device: you sign, then {f.witnesses === 2 ? 'each witness types their name' : 'your witness types their name'}.</p>
        <p><a className="btn btn--primary btn--sm" href={href} data-testid={f.code === 'C' ? 'form-c-screen-link' : 'form-d-screen-link'}>Sign {f.code === 'C' ? 'Form C' : 'Form D'} on screen</a></p>
      </>}
    </li>
  );
}

export function WitnessedForms({ forms }: { forms: WForm[] }) {
  if (!forms.length) return null;
  return <ul className="stack" style={{ listStyle: 'none', padding: 0 }} data-testid="witnessed-forms">{forms.map((f) => <One key={`${f.code}:${f.vehicle_id ?? ''}`} f={f} />)}</ul>;
}
