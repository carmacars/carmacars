import { BrandMark } from '@/components/BrandMark';
import { SignOutOrExit } from '@/features/access/Access';
import { pendingTerms } from '@/server/terms';
import { TermsAccept } from './TermsAccept';

// "We've updated our terms" (0721, the owner's decision of November 7, 2026): a full-screen step on the portal until the
// person accepts each new version that binds them (renters, owners, investors, staff and field). It shows what changed
// (the summary) and the new text, and records the acceptance (who, when, the IP address, the version). It voids no signed
// agreement and asks no renter to sign a past booking's agreement again: it is a click-through acceptance.
export async function TermsGate({ userId, portal, children }: { userId: string; portal: 'renter' | 'owner' | 'investor' | 'staff' | 'field'; children: React.ReactNode }) {
  const pending = await pendingTerms(userId).catch(() => []);
  if (!pending.length) return <>{children}</>;
  const v = pending[0]!;
  const date = new Intl.DateTimeFormat('en-CA', { timeZone: 'America/Toronto', month: 'long', day: 'numeric', year: 'numeric' }).format(new Date(v.published_at));
  return (
    <div className="tg" role="dialog" aria-modal="true" aria-labelledby="tg-title" data-testid="terms-gate">
      <div className="tg__in stack">
        <div className="tg__brand"><BrandMark size={36} /><span>CarmaCars</span>{pending.length > 1 && <span className="tg__count">{`1 of ${pending.length}`}</span>}</div>
        <header className="stack"><h1 className="d2" id="tg-title">{"We've updated our terms"}</h1>
          <p className="muted">{v.title}, version {v.version}, published {date}. Accept it to continue to your portal.</p></header>
        <section className="tg__summary stack" aria-labelledby="tg-what"><h2 className="d4" id="tg-what">What changed</h2><p data-testid="terms-summary">{v.summary}</p></section>
        <section className="stack" aria-labelledby="tg-text"><h2 className="d4" id="tg-text">The new text</h2>
          <div className="tg__text prose" tabIndex={0} role="region" aria-label={`${v.title}, the new text`} dangerouslySetInnerHTML={{ __html: v.html }} /></section>
        <p className="small muted">This does not change an agreement you already signed or a past booking: it is the version that applies from now on.</p>
        <TermsAccept id={v.id} sha={v.body_sha256} portal={portal} title={v.title.toLowerCase()} last={pending.length === 1} />
        <SignOutOrExit className="btn btn--ghost" />
      </div>
    </div>
  );
}
