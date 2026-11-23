import Link from '@/components/Link';
import { pageMeta } from '@/features/seo/meta';
import { PageHeader } from '@/features/portal/Chrome';
import { rpc } from '@/lib/db/repo';
import { money } from '@/lib/format';
import { requireUser } from '@/server/portal/data';
import { cardState, ledgerText, type GiftCardRow } from '@/features/gift-cards/model';
import { ClaimGiftCard } from '@/features/gift-cards/ClaimGiftCard';
import '@/features/gift-cards/gift-cards.css';

export const dynamic = 'force-dynamic';
export const metadata = pageMeta({ title: 'Gift cards', path: '/account/gift-cards', noindex: true, description: 'Your CarmaCars gift cards, their balances and the gifts you sent.' });

const fmtDate = (d: string) => new Intl.DateTimeFormat('en-CA', { month: 'short', day: 'numeric', year: 'numeric', timeZone: 'America/Toronto' }).format(new Date(d));
const fmt = (c: number) => money(c, { cents: true });

// The renter's gift cards (migration 3600): every card that is theirs (added with its code, or sent to their verified
// email) with its balance and history, the box to add a code (the email's link fills it), and the gifts they bought.
export default async function MyGiftCards({ searchParams }: { searchParams: Promise<Record<string, string | undefined>> }) {
  const user = await requireUser('/account/gift-cards');
  const sp = await searchParams;
  const g = ((await rpc('server_my_gift_cards', { p_user: user.id }, { role: 'service_role' }).catch(() => null)) as unknown as { cards: GiftCardRow[]; sent: GiftCardRow[]; balance_cents: number } | null) ?? { cards: [], sent: [], balance_cents: 0 };
  return (
    <>
      <PageHeader title="Gift cards" purpose="Your balance is used before your card when you sign and pay. It never pays the deposit." testId="gift-head"
        action={<Link prefetch={false} className="btn btn--ghost btn--sm" href="/gift-cards">Give a gift card</Link>} />
      <div className="pt-split">
        <div className="stack">
          <section className="pt-card stack" aria-labelledby="gc-bal-h" data-testid="gift-balance">
            <p className="pu-eyebrow" id="gc-bal-h">Balance</p>
            <p className="d2 num">{fmt(g.balance_cents)}</p>
            <ClaimGiftCard initial={sp.code ?? ''} />
          </section>
          <section className="pt-card stack" aria-labelledby="gc-mine-h">
            <h2 className="d4" id="gc-mine-h">Your cards</h2>
            {g.cards.length === 0 ? <p className="small muted" data-testid="gift-empty">No gift cards yet. Add a code above, or ask for one as a gift.</p> : (
              <ul className="gc-list" data-testid="gift-cards">
                {g.cards.map((c) => (
                  <li key={c.id} className="gc-item" data-usable={c.usable ? 'true' : 'false'}>
                    <div className="gc-item__top"><span className="gc-item__name">{c.kind_label} ending {c.code_last4}</span><span className="gc-item__bal">{fmt(c.balance_cents)}</span></div>
                    <p className="gc-item__meta">{cardState(c)}. From {c.buyer_name ?? 'CarmaCars'}, {fmt(c.initial_cents)}{c.rental_text ? `, ${c.rental_text}` : ''}. {c.expires_at ? `Ends ${fmtDate(c.expires_at)}.` : 'Never expires.'}</p>
                    {c.message && <p className="small">&ldquo;{c.message}&rdquo;</p>}
                    {c.history && c.history.length > 0 && (
                      <details><summary className="small">Balance history</summary>
                        <ul className="gc-hist">{c.history.map((l, i) => { const t = ledgerText(l, fmt); return <li key={i}><span>{fmtDate(l.at)}: {t.label}</span><span>{t.amount}</span></li>; })}</ul>
                      </details>)}
                  </li>))}
              </ul>)}
          </section>
        </div>
        <aside className="pt-split__aside">
          <section className="pt-card stack" aria-labelledby="gc-sent-h">
            <h2 className="d4" id="gc-sent-h">Gifts you sent</h2>
            {g.sent.length === 0 ? <p className="small muted">None yet. <Link prefetch={false} className="link" href="/gift-cards">Give one</Link>.</p> : (
              <ul className="gc-list" data-testid="gift-sent">
                {g.sent.map((c) => (
                  <li key={c.id} className="gc-item">
                    <div className="gc-item__top"><span className="gc-item__name">{c.recipient_name}</span><span className="gc-item__bal">{fmt(c.initial_cents)}</span></div>
                    <p className="gc-item__meta">{c.kind_label}{c.rental_text ? `, ${c.rental_text}` : ''}. {c.sent_at ? `Emailed ${fmtDate(c.sent_at)}` : c.send_on ? `Emailed on ${fmtDate(`${c.send_on}T12:00:00Z`)}` : 'Waiting'}. {cardState(c)}.</p>
                  </li>))}
              </ul>)}
          </section>
        </aside>
      </div>
    </>
  );
}
