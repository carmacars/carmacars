import Link from 'next/link';
import { pageMeta } from '@/features/seo/meta';
import { PageHeader } from '@/features/portal/Chrome';
import { day } from '@/features/owner/Blocks';
import { ownerDocuments, ownerForms, requireOwner } from '@/server/owner/data';
import { rpc } from '@/lib/db/repo';
import { WitnessedForms, type WForm } from '@/features/owner/WitnessedForms';

export const dynamic = 'force-dynamic';
export const metadata = pageMeta({ title: 'Documents', path: '/owner/documents', noindex: true, description: 'Your agreements, schedules and registry form data.' });

const KIND: Record<string, string> = { form_a_trust_declaration: 'Form A', form_b_lease_summary: 'Form B', form_c_finance_permission_ack: 'Form C, signed', form_d_power_of_attorney: 'Form D, signed', enrollment_agreement: 'Enrollment Agreement', title_agreement: 'Title-Holding and Lease Agreement', additional_vehicle_schedule: 'Additional Vehicle Schedule', vehicle_schedule: 'Vehicle Schedule', ownership_permit: 'Ownership permit', insurer_confirmation: 'Insurer confirmation', owner_invoice: 'Invoice', owner_statement: 'Statement', registry_form: 'Registry form' };

export default async function OwnerDocuments() {
  const { user, home } = await requireOwner('/owner/documents');
  const [docs, forms, witnessed, screen] = await Promise.all([ownerDocuments(user), ownerForms(user),
    rpc('owner_witnessed_forms', { p_by: user.id }, { role: 'service_role' }).then((x) => (x ?? []) as unknown as WForm[]).catch(() => [] as WForm[]),
    // Forms A and B, signed on screen (migration 0044)
    rpc('owner_screen_forms', { p_by: user.id }, { role: 'service_role' }).then((x) => (x ?? []) as unknown as Array<{ code: string; title: string; status: string; method: string | null; signed_at: string | null; document_id: string | null }>).catch(() => [])]);
  const name = (id: string | null) => home.vehicles.find((v) => v.vehicle_id === id)?.name;
  return (
    <>
      <PageHeader title="Documents" purpose="Your signed agreements and schedules, and the values for each vehicle's registry forms." />
      <div className="pt-split">
        <div className="stack-lg">
        {screen.length > 0 && <section className="stack" aria-labelledby="ow-ab"><h2 className="pt-section-title" id="ow-ab">Forms to sign on screen</h2>
          <ul className="ow-rows" data-testid="owner-screen-forms">{screen.map((f) => (
            <li key={f.code}><Link prefetch={false} className="ow-row-link" href={`/owner/documents/screen/${f.code.toLowerCase()}`}>{f.title}</Link>
              <span className="ow-meta"><span className={`badge ${f.status === 'signed' ? 'badge--outline' : 'badge--red'}`} data-testid="screen-form-status">{f.status === 'signed' ? `Signed ${f.method === 'paper' ? 'on paper' : 'on screen'}` : 'To sign'}</span>{f.signed_at && <span>{day(f.signed_at)}</span>}</span></li>))}</ul></section>}
        {witnessed.length > 0 && <section className="stack" aria-labelledby="ow-wit"><h2 className="pt-section-title" id="ow-wit">Forms to sign with witnesses</h2>
          <p className="small muted">Form D of your Title Agreement is signed on paper in front of two witnesses. Form C is signed on paper in front of one witness, or on screen with your witness beside you. {witnessed.every((f) => f.status === 'approved') ? 'All approved.' : `${witnessed.filter((f) => f.status !== 'approved').length} still to finish.`}</p>
          <WitnessedForms forms={witnessed} />
        </section>}
        <section className="stack" aria-labelledby="ow-docs"><h2 className="pt-section-title" id="ow-docs">Agreements and files</h2>
          {docs.length ? <ul className="ow-rows" data-testid="owner-docs">{docs.map((d) => <li key={d.id}><a className="ow-row-link" href={`/owner/documents/${d.id}`}>{d.title ?? KIND[d.kind] ?? d.kind}</a><span className="small muted">PDF</span><span className="ow-meta"><span>{KIND[d.kind] ?? d.kind.replace(/_/g, ' ')}</span>{name(d.vehicle_id) && <span>{name(d.vehicle_id)}</span>}<span>{day(d.created_at)}</span></span></li>)}</ul>
            : <p className="pt-empty muted">Your agreements appear here once they are ready to sign. {home.signing.needed && <Link prefetch={false} href="/owner/sign">Sign them now</Link>}</p>}
        </section>
        </div>
        <aside className="pt-split__aside">
          <section className="pt-card" aria-labelledby="ow-forms"><h2 className="d4" id="ow-forms">Government forms</h2>
            {forms.length ? <ul className="ow-rows" data-testid="owner-gov-forms">{forms.map((f) => <li key={f.id}><a className="ow-row-link" href={f.official ? `/owner/documents/forms/${f.id}/official` : `/owner/documents/forms/${f.id}`}>{f.form_code}</a><span className="small muted">{f.official ? (f.status === 'signed' || f.status === 'filed' ? 'Official form, signed' : 'Official form, filled for you') : f.has_pdf ? 'Pre-filled PDF' : 'Data sheet'}</span><span className="ow-meta"><span>{f.vehicle_name}</span>{f.missing.length > 0 && <span>Missing: {f.missing.join(', ')}</span>}</span></li>)}</ul>
              : <p className="small muted">Prepared for each vehicle once its onboarding method is set.</p>}
            <p className="small muted">You pay ServiceOntario, the inspection station and the appraiser directly. CarmaCars does not collect these amounts.</p>
          </section>
        </aside>
      </div>
    </>
  );
}
