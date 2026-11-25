import Link from '@/components/Link';
import { pageMeta } from '@/features/seo/meta';
import { page } from '@/server/admin/api';
import { Act } from '@/features/admin/Act';
import { PageHead } from '@/features/admin/ui';
import { LibraryUpload } from '@/features/admin/investor-library/LibraryUpload';
import { shownKinds, versionLine, type Library } from '@/features/investor/library';

export const dynamic = 'force-dynamic';
export const metadata = pageMeta({ title: 'Investor documents', path: '/admin/investors/documents', noindex: true, description: 'The business documents investors see in their portal.' });

const when = (s: string) => new Intl.DateTimeFormat('en-CA', { dateStyle: 'medium', timeStyle: 'short', timeZone: 'America/Toronto' }).format(new Date(s));

// Admin > Investors > Documents (r50, migration 4300): the business plan, the financial forecast, the pitch deck, the
// feature decks and any section added here. Add a document, or replace one: every version is kept below it, investors see
// the latest with its date, and every active investor is told by email and in their portal.
export default async function AdminInvestorDocuments() {
  const { read } = await page('/admin/investors/documents');
  const lib = await read<Library>('investor_library');
  const kinds = shownKinds(lib, true);
  return (<>
    <PageHead title="Investor documents"><Link className="btn btn--ghost btn--sm" href="/investor/documents?tab=library" prefetch={false} data-testid="library-as-investors">Open as investors see it</Link><Link className="btn btn--ghost btn--sm" href="/admin/investors" prefetch={false}>Investors</Link></PageHead>
    <section className="ad-card" aria-labelledby="lib-add" data-testid="library-add">
      <h2 className="d4" id="lib-add">Add a document</h2>
      <p className="small muted">CarmaCars documents only. PDFs are stored privately and opened by signed-in investors through a link that works for 5 minutes.</p>
      <LibraryUpload kinds={kinds.map((k) => ({ key: k.key, label: k.label }))} testId="library-new" />
    </section>
    {kinds.map((k) => (
      <section key={k.key} className="ad-card stack" aria-labelledby={`alib-${k.key}`} data-testid={`admin-library-${k.key}`}>
        <h2 className="d4" id={`alib-${k.key}`}>{k.label}</h2>
        {!k.items.length && <p className="small muted">Nothing in this section yet: investors do not see it.</p>}
        {k.items.map((i) => (
          <article key={i.id} className="stack" data-testid="admin-library-item">
            <div className="row" style={{ justifyContent: 'space-between', flexWrap: 'wrap', gap: 'var(--s-2)' }}>
              <div><p className="strong">{i.title}{i.archived && <span className="small muted"> (hidden from investors)</span>}</p><p className="small muted">{versionLine(i)}</p></div>
              <span className="row" style={{ gap: 'var(--s-2)', flexWrap: 'wrap' }}>
                <LibraryUpload item={i.id} title={i.title} testId={`library-replace-${i.id}`} />
                <Act action="investor_library_archive" payload={{ item: i.id, archived: !i.archived }} label={i.archived ? 'Show to investors' : 'Hide from investors'}
                  confirm={i.archived ? 'Investors will see this document again.' : 'Investors will no longer see this document. Its versions are kept.'} refresh={['/admin/investors/documents', '/investor/documents']} testId={`library-archive-${i.id}`} />
              </span>
            </div>
            <details><summary className="small">Version history ({i.history?.length ?? 0})</summary>
              <ul className="small" data-testid="library-history">{(i.history ?? []).map((h) => (
                <li key={h.id}><a className="link" href={`/admin/investors/documents/${h.id}`}>Version {h.version}</a>, {h.file_kind === 'link' ? 'a link' : 'a PDF'}, {when(h.created_at)}{h.uploaded_by ? ` by ${h.uploaded_by}` : ''}{h.note ? `: ${h.note}` : ''}</li>))}</ul>
            </details>
          </article>
        ))}
      </section>
    ))}
  </>);
}
