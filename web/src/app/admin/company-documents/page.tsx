import Link from '@/components/Link';
import { pageMeta } from '@/features/seo/meta';
import { page } from '@/server/admin/api';
import { Act } from '@/features/admin/Act';
import { Badge, PageHead } from '@/features/admin/ui';
import { CompanyDocUpload } from '@/features/admin/company-documents/CompanyDocUpload';
import { statusLabel, type CompanyDocs, type CompanyDocVersion } from '@/features/company-documents/model';

export const dynamic = 'force-dynamic';
export const metadata = pageMeta({ title: 'Company documents', path: '/admin/company-documents', noindex: true, description: 'CarmaCars corporate documents, for Admins only.' });

const when = (s: string) => new Intl.DateTimeFormat('en-CA', { dateStyle: 'medium', timeStyle: 'short', timeZone: 'America/Toronto' }).format(new Date(s));
const tone = (s: CompanyDocVersion['status']) => (s === 'to_sign' ? 'awaiting_signature' : s === 'signed' ? 'approved' : s === 'draft' ? 'draft' : 'done');
const what = (v: CompanyDocVersion) => (v.file_kind === 'signable' ? `a text to sign, ${statusLabel(v.status).toLowerCase()}` : 'a PDF');

// Admin > Company documents (r50, migration 5060): the shareholder agreement, the articles, the franchise agreement, the
// insurance policy, the lease and other corporate documents. Admins only: no staff function, investor, owner or renter
// sees them. Every version is kept; each opens through a link that works for 5 minutes. A text to sign is signed on its
// own page by the Admins named as signers.
export default async function AdminCompanyDocuments() {
  const { read } = await page('/admin/company-documents');
  const docs = await read<CompanyDocs>('company_documents');
  return (<>
    <PageHead title="Company documents" kicker="Settings" purpose="CarmaCars's own corporate documents. Only Admins can see them." />
    <section className="ad-card stack" aria-labelledby="cdoc-add" data-testid="cdoc-add">
      <h2 className="d4" id="cdoc-add">Add a document</h2>
      <p className="small muted">A PDF (under 20 MB) is stored privately. A text to sign is signed here by the Admins you name, with the same signature as every agreement on the site.</p>
      <CompanyDocUpload kinds={docs.kinds.map((k) => ({ key: k.key, label: k.label }))} admins={docs.admins} testId="cdoc-new" />
    </section>
    {docs.kinds.map((k) => (
      <section key={k.key} className="ad-card stack" aria-labelledby={`cdoc-${k.key}`} data-testid={`cdoc-kind-${k.key}`}>
        <h2 className="d4" id={`cdoc-${k.key}`}>{k.label}</h2>
        {!k.documents.length && <p className="ad-empty small muted">No {k.label.toLowerCase()} yet. Add one above.</p>}
        {k.documents.map((d) => (
          <article key={d.id} className="stack" data-testid="cdoc-item">
            <div className="row" style={{ justifyContent: 'space-between', flexWrap: 'wrap', gap: 'var(--s-2)' }}>
              <div>
                <p className="strong"><Link className="link" prefetch={false} href={`/admin/company-documents/${d.id}`} data-testid="cdoc-title">{d.title}</Link>{d.archived && <span className="small muted"> (archived)</span>}</p>
                <p className="small muted">Version {d.version}, {what(d.current)}, {d.updated_on}{d.notes ? `. ${d.notes}` : ''}</p>
              </div>
              <span className="row" style={{ gap: 'var(--s-2)', flexWrap: 'wrap', alignItems: 'center' }}>
                <Badge s={tone(d.current.status)}>{statusLabel(d.current.status)}</Badge>
                {d.current.has_file && <a className="btn btn--ghost btn--sm" href={`/admin/company-documents/file/${d.current.id}`} target="_blank" rel="noreferrer" data-testid="cdoc-open">Open</a>}
                {d.current.file_kind === 'pdf' && <CompanyDocUpload admins={docs.admins} document={d.id} testId={`cdoc-replace-${d.id}`} />}
                {d.current.file_kind === 'signable' && <Link className="btn btn--ghost btn--sm" prefetch={false} href={`/admin/company-documents/${d.id}`} data-testid="cdoc-sign-link">{d.current.status === 'to_sign' ? 'Sign or follow' : 'Open'}</Link>}
                <Act action="company_document_archive" payload={{ document: d.id, archived: !d.archived }} label={d.archived ? 'Bring back' : 'Archive'}
                  confirm={d.archived ? 'The document comes back to the list.' : 'The document moves to the end of its section. Its versions are kept.'} refresh={['/admin/company-documents']} testId={`cdoc-archive-${d.id}`} />
              </span>
            </div>
            <details><summary className="small">Version history ({d.history.length})</summary>
              <ul className="small" data-testid="cdoc-history">{d.history.map((h) => (
                <li key={h.id}>{h.has_file ? <a className="link" href={`/admin/company-documents/file/${h.id}`} target="_blank" rel="noreferrer">Version {h.version}</a> : <>Version {h.version}</>}, {what(h)}, {when(h.created_at)}{h.uploaded_by ? ` by ${h.uploaded_by}` : ''}{h.note ? `: ${h.note}` : ''}</li>))}</ul>
            </details>
          </article>
        ))}
      </section>
    ))}
  </>);
}
