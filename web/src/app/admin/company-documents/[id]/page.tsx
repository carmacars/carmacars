import Link from '@/components/Link';
import { notFound } from 'next/navigation';
import { pageMeta } from '@/features/seo/meta';
import { page } from '@/server/admin/api';
import { Badge, Card, PageHead } from '@/features/admin/ui';
import { AgreementView } from '@/features/agreement/AgreementView';
import { CompanyDocUpload } from '@/features/admin/company-documents/CompanyDocUpload';
import { CompanyDocFields, CompanyDocRetry, CompanyDocSign } from '@/features/admin/company-documents/CompanyDocSign';
import { bodyBlocks, fieldLabel, statusLabel, type CompanyDocAdmin, type CompanyDocPage, type CompanyDocs } from '@/features/company-documents/model';

export const dynamic = 'force-dynamic';
export const metadata = pageMeta({ title: 'Company document', path: '/admin/company-documents', noindex: true, description: 'One CarmaCars corporate document, for Admins only.' });

const when = (s: string) => new Intl.DateTimeFormat('en-CA', { dateStyle: 'medium', timeStyle: 'short', timeZone: 'America/Toronto' }).format(new Date(s));

// Admin > Company documents > one document (r50, migration 5060). A text to sign: its fill-ins (until the first signature),
// who signs and who has signed, and for a listed signer the document read to the end, the tick and the platform's signing
// steps. When everyone signed, the signed copy is the version's PDF. A change after the first signature is a new version.
export default async function AdminCompanyDocument({ params }: { params: Promise<{ id: string }> }) {
  const { id } = await params;
  if (!/^[0-9a-f-]{36}$/.test(id)) notFound();
  const { read } = await page(`/admin/company-documents/${id}`);
  const [d, list] = await Promise.all([read<CompanyDocPage>('company_document', { document: id }).catch(() => null), read<CompanyDocs>('company_documents')]);
  if (!d) notFound();
  const admins: CompanyDocAdmin[] = list.admins;
  const v = d.current;
  const signable = v.file_kind === 'signable' && !!v.body_md;
  const keys = v.placeholders ?? [];
  const mine = d.me && d.me.request_id && d.me.status === 'sent' && v.status === 'to_sign' ? d.me : null;
  return (<>
    <PageHead title={d.title} kicker={<Link className="link" prefetch={false} href="/admin/company-documents">Company documents</Link>}
      purpose={`${d.kind_label}. Version ${v.version}, ${v.file_kind === 'signable' ? statusLabel(v.status).toLowerCase() : 'a PDF'}. Only Admins can see it.`}>
      {v.has_file && <a className="btn btn--ghost btn--sm" href={`/admin/company-documents/file/${v.id}`} target="_blank" rel="noreferrer" data-testid="cdoc-open-current">{v.status === 'signed' ? 'Open the signed copy' : 'Open'}</a>}
    </PageHead>
    {signable && (
      <Card title="Who signs" aside={<Badge s={v.status === 'signed' ? 'approved' : v.status === 'to_sign' ? 'awaiting_signature' : 'draft'}>{statusLabel(v.status)}</Badge>} testId="cdoc-signers">
        <ul className="ow-rows">{(v.signers ?? []).map((s) => (
          <li key={s.user_id}><span><b>{s.name}</b>, {s.role_label}</span><span className="ow-meta" data-testid="cdoc-signer-state">{s.signed ? `Signed ${s.signed_at ? when(s.signed_at) : ''}` : v.status === 'to_sign' ? 'Not signed yet' : 'Not sent yet'}</span></li>))}</ul>
        {v.status === 'draft' && !v.missing?.length && <CompanyDocRetry document={d.id} version={v.id} what="send" label="Send for signing" />}
        {v.status === 'signed' && !v.has_file && <CompanyDocRetry document={d.id} version={v.id} what="signed_copy" label="Make the signed copy" />}
      </Card>
    )}
    {signable && keys.length > 0 && (
      <Card title="Fill-ins" testId="cdoc-fillins">
        {v.frozen || v.status === 'signed'
          ? <table className="ad-table"><tbody>{keys.map((k) => <tr key={k}><th scope="row">{fieldLabel(k)}</th><td>{v.fields[k] ?? ''}</td></tr>)}</tbody></table>
          : <CompanyDocFields document={d.id} version={v.id} keys={keys} values={v.fields} sent={v.status === 'to_sign'} />}
        {v.frozen && v.status !== 'signed' && <p className="small muted">Signing has started: the text and the fill-ins are frozen. To change them, add a new version below; the signing starts again.</p>}
      </Card>
    )}
    {signable && (
      <Card title={mine ? `Read and sign as ${mine.role_label}` : 'The document'} testId="cdoc-body">
        {mine
          ? <CompanyDocSign document={d.id} version={v.id} request={mine.request_id!} sha={mine.sha256!} title={mine.title ?? d.title} signerName={mine.signer_name ?? ''} role={mine.role_label}>
              <AgreementView blocks={bodyBlocks(v.body_md!, v.fields)} id="cdoc-text" label={d.title} /></CompanyDocSign>
          : <div style={{ maxHeight: '60dvh', overflowY: 'auto' }} tabIndex={0} role="region" aria-label={d.title}><AgreementView blocks={bodyBlocks(v.body_md!, v.fields)} id="cdoc-text" label={d.title} /></div>}
        {d.me?.status === 'signed' && <p className="small" data-testid="cdoc-you-signed">You signed{d.me.signed_at ? ` on ${when(d.me.signed_at)}` : ''}.</p>}
      </Card>
    )}
    <Card title="New version" testId="cdoc-new-version">
      <p className="small muted">{signable ? 'A change to the text, the signers or a signed document is a new version: the earlier ones are kept, and the signing starts again on the new one.' : 'The earlier versions are kept.'}</p>
      <CompanyDocUpload admins={admins} document={d.id} signable={signable} signers={(v.signers ?? []).map((x) => ({ user_id: x.user_id, role_label: x.role_label }))} testId="cdoc-version" />
    </Card>
    <Card title={`Version history (${d.history.length})`} testId="cdoc-history">
      <ul className="small">{d.history.map((h) => (
        <li key={h.id}>{h.has_file ? <a className="link" href={`/admin/company-documents/file/${h.id}`} target="_blank" rel="noreferrer">Version {h.version}</a> : <>Version {h.version}</>}, {h.file_kind === 'signable' ? `a text to sign, ${statusLabel(h.status).toLowerCase()}` : 'a PDF'}, {when(h.created_at)}{h.uploaded_by ? ` by ${h.uploaded_by}` : ''}{h.note ? `: ${h.note}` : ''}</li>))}</ul>
    </Card>
  </>);
}
