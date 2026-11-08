import Link from '@/components/Link';
import { OfficialForm, type Official } from '@/features/official-forms/OfficialForm';
import type { StaffFill } from '@/server/government-forms';
import { GovFormEditor, GovFormVersions } from './GovFormEditor';

// One government form of an owner's car for an Admin or staff (r34, 0822; r35, 0870): the official ServiceOntario form
// filled in the browser from the values on record (or its data sheet while the form is not in use as a PDF), the values
// that may be changed by hand with a reason, and every version.
export function GovFormPage({ f, base }: { f: StaffFill; base: '/admin' | '/staff' }) {
  const paths = [`${base}/government-forms/${f.id}`, `${base}/owners/${f.owner_id}`];
  return (<>
    <header className="stack"><p className="pt-kicker"><Link prefetch={false} className="link" href={`${base}/owners/${f.owner_id}#gov-forms`}>{f.owner_name}</Link></p>
      <h1 className="d2">{f.form_code}{f.title ? `: ${f.title.replace(f.form_code, '').trim()}` : ''}</h1>
      <p className="muted" data-testid="gov-form-version-now">{f.vehicle_name}{f.version ? `, version ${f.version}` : ''}{f.current ? '' : ' (an earlier version)'}</p></header>
    {f.official ? <OfficialForm f={f as unknown as Official} templateHref={`${base}/government-forms/${f.id}/template`} docBase={`${base}/documents`} />
      : <p className="small">This form is not in use as the official PDF yet: the owner gets its data sheet.</p>}
    <p className="small"><Link prefetch={false} className="link" href={`${base}/government-forms/${f.id}/sheet`}>The data sheet (PDF)</Link></p>
    {f.fields && <GovFormEditor fill={f.id} canEdit={!!f.can_edit} fields={f.fields} edits={f.edits ?? []} refresh={paths} base={base} />}
    {f.versions && <GovFormVersions versions={f.versions} base={base} />}
  </>);
}
