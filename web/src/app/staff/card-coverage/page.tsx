import Link from 'next/link';
import { pageMeta } from '@/features/seo/meta';
import { vaPage } from '@/server/va';
import { Card, PageHead } from '@/features/admin/ui';
import { CardTable } from '@/features/coverage/CardTable';
import { checkedOn, type CardList } from '@/features/coverage/cards';
import { rpc } from '@/lib/db/repo';

// The staff quick reference for "which credit cards include rental car coverage?" (0131): what to say, what to check on
// a booking with coverage option 2, and the same list as /credit-card-rental-coverage (Admin > Settings > Card coverage).
export const dynamic = 'force-dynamic';
export const metadata = pageMeta({ title: 'Card coverage', path: '/staff/card-coverage', noindex: true, description: 'Which credit cards include rental car coverage: the quick reference for renters\' questions.' });

export default async function VaCardCoverage() {
  await vaPage('/staff/card-coverage');
  const list = ((await rpc('card_coverage_public', {})) as unknown as CardList | null) ?? { cards: [], checked: null, oldest: null };
  return (
    <>
      <PageHead title="Card coverage" kicker={list.checked ? `List checked ${checkedOn(list.checked)}` : undefined} />
      <Card title="When a renter asks which cards include rental car coverage" testId="card-coverage-script">
        <ol className="small stack">
          <li>Send them the page: <Link prefetch={false} className="link" href="/credit-card-rental-coverage">carmacars.ca/credit-card-rental-coverage</Link>. It has the list, the limits and the checklist.</li>
          <li>Ask which car they want. Most Canadian cards stop at a $65,000 or $85,000 MSRP; many of our luxury cars are priced higher. Give them the car&apos;s model year and trim so they can check its MSRP.</li>
          <li>Never say they are covered. Say: &quot;Your card&apos;s issuer decides that. Please call the number on the back of your card and ask about this car and these dates.&quot; CarmaCars does not decide claims and is not an insurer.</li>
          <li>Over the limit, an excluded make, a debit card or a rental longer than the card allows: offer OPCF 27 on their own auto policy, or the CarmaCars Protection Plan.</li>
        </ol>
      </Card>
      <Card title="What we check on a booking with option 2">
        <ul className="small stack">
          <li>The booking was paid with a credit card (not debit or prepaid) in the renter&apos;s name. The coverage review shows the card, its type and whether the name matches.</li>
          <li>The renter ticked that the card covers this kind of car for this many days. A benefits letter or certificate is welcome: check its value limit and longest rental against the car and the dates.</li>
          <li>A card marked &quot;Unverified&quot; in the list came from a published summary, not the issuer&apos;s guide: rely on the renter&apos;s letter from the issuer.</li>
          <li>A list entry looks wrong or out of date? Tell an Admin: they correct it in Settings &gt; Card coverage.</li>
        </ul>
      </Card>
      <CardTable rows={list.cards} />
    </>
  );
}
