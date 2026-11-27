import Link from '@/components/Link';
import { notFound } from 'next/navigation';
import { PageHead } from '@/components/Blocks';
import { JsonLd } from '@/components/JsonLd';
import { breadcrumbLd, seoMeta, type Trail } from '@/features/seo/meta';
import { rpc } from '@/lib/db/repo';
import { money } from '@/lib/format';
import { currentUser } from '@/server/portal/data';
import { cardPaymentsOn } from '@/server/card-provider';
import { GiftBuy } from '@/features/gift-cards/GiftBuy';
import type { GiftFacts } from '@/features/gift-cards/model';
import '@/features/gift-cards/gift-cards.css';

// Gift cards (release 49, migration 3600): buy a gift card or a gifted rental for someone. The facts (amounts, limits,
// the cars that can be gifted) come from Program settings and the public listings; switched off: 404. Signed in to pay.
export const dynamic = 'force-dynamic';
const trail: Trail = [['Home', '/'], ['Gift cards']];
const SR = { role: 'service_role' as const };

export async function generateMetadata() {
  return seoMeta({ title: 'CarmaCars Gift Cards | Give a Car Rental in Toronto', path: '/gift-cards',
    description: 'Give a CarmaCars gift card or a gifted rental: any amount, emailed with your message on the day you choose. It never expires and pays the rental, its fees and the HST.' });
}

export default async function GiftCards() {
  const [facts, user, cardsOn] = await Promise.all([rpc('server_gift_cards_facts', {}, SR).then((x) => x as unknown as GiftFacts).catch(() => null), currentUser(), cardPaymentsOn()]);
  if (!facts?.on) notFound();
  const me = user ? ((await rpc('server_my_gift_cards', { p_user: user.id }, SR).catch(() => null)) as unknown as { balance_cents: number } | null) : null;
  const today = new Intl.DateTimeFormat('en-CA', { timeZone: 'America/Toronto', year: 'numeric', month: '2-digit', day: '2-digit' }).format(new Date());
  return (
    <div className="p-gift" data-testid="gift-cards-page">
      <JsonLd graph={[breadcrumbLd(trail, '/gift-cards')]} />
      <PageHead trail={trail} h1="Give the keys." lead={`A CarmaCars gift card for any rental, from ${money(facts.min_cents)} to ${money(facts.max_cents)}, or a car for the days you choose. Emailed with your message, on the day you pick.`} />
      <section className="section section--tight">
        <div className="wrap stack-lg">
          <ul className="gc-points" aria-label="How gift cards work">
            <li>It never expires, and the balance carries over: what is not used stays on the card.</li>
            <li>It pays the rental, its fees and the HST. The refundable deposit is held on the driver&apos;s own card.</li>
            <li>A gifted rental is a credit for that car and those days, in the account with the email you give, usable on any car.</li>
          </ul>
          {me && me.balance_cents > 0 && <p className="small" data-testid="gift-my-balance">You have {money(me.balance_cents, { cents: true })} on your gift cards. <Link prefetch={false} className="link" href="/account/gift-cards">See them</Link></p>}
          {/* r50 hotfix2: gift cards are paid by card only: while cards are off the form is not offered */}
          {cardsOn ? <GiftBuy facts={facts} signedIn={!!user} buyerName={''} today={today} />
            : <p className="alert" role="status" data-testid="gift-cards-paused"><span className="alert__title">Gift cards are paused for a short while</span><span>They are paid by card, and card payments are paused. <Link prefetch={false} className="link" href="/contact">Contact us</Link> and we arrange one by e-Transfer.</span></p>}
          <p className="small muted">No HST is charged on a gift card itself: HST is charged on the rental it pays for. Gift cards are not refundable for cash, except where the law requires it. Questions: <Link prefetch={false} className="link" href="/contact">contact us</Link>.</p>
        </div>
      </section>
    </div>
  );
}
