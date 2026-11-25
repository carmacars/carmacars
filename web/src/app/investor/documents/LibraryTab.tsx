import { door } from '@/server/door';
import { DocumentList, DocumentRow } from '@/components/portal-ui';
import { itemHref, shownKinds, versionLine, type Library } from '@/features/investor/library';

// Documents > Business documents (r50, migration 4300): CarmaCars's business plan, financial forecast, pitch deck, feature
// decks and any other section an Admin adds, each at its latest version with its date. A PDF opens through a short signed
// link made for the signed-in investor (library/[id]); a deck may be a link.
export async function LibraryTab({ userId }: { userId: string }) {
  const lib = await door<Library>(userId, 'investor_read', 'library').catch(() => null);
  const kinds = shownKinds(lib);
  if (!kinds.length) return <div className="pt-empty" data-testid="investor-library-empty" data-guide="investor-library"><p className="d4">No business documents yet</p><p className="muted">The business plan, the financial forecast and the decks appear here as soon as CarmaCars shares them. We email you when one is added or updated.</p></div>;
  return (
    <div className="stack-lg" data-testid="investor-library" data-guide="investor-library">
      {kinds.map((k) => (
        <section key={k.key} className="stack" aria-labelledby={`lib-${k.key}`} data-testid={`library-${k.key}`}>
          <h2 className="pt-section-title" id={`lib-${k.key}`}>{k.label}</h2>
          <DocumentList label={k.label}>
            {k.items.map((i) => (
              <DocumentRow key={i.id} external href={itemHref(i)} badge={i.file_kind === 'link' ? 'DECK' : 'PDF'} title={<span data-guide="library-item">{i.title}</span>} testId={`library-item-${i.id}`} linkTestId="library-open"
                meta={<><span>{k.label}</span><span data-testid="library-version">{versionLine(i)}</span></>} />
            ))}
          </DocumentList>
        </section>
      ))}
      <p className="small muted">These documents are private to CarmaCars investors. Each link works for a few minutes; open it again from here any time. They are not an offer or a solicitation.</p>
    </div>
  );
}
