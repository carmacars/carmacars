import Link from 'next/link';
import { CtaBand, PageHead } from '@/components/Blocks';
import { Faq } from '@/components/Faq';
import { JsonLd } from '@/components/JsonLd';
import { Affiliate } from '@/features/coverage/Affiliate';
import { CardTable } from '@/features/coverage/CardTable';
import { cardFaq, checkedOn, reaching, type CardList } from '@/features/coverage/cards';
import { breadcrumbLd, faqLd, type Trail, seoMeta } from '@/features/seo/meta';
import { rpc } from '@/lib/db/repo';

// Which credit cards include rental car damage coverage (0131, docs/changes/2026-10-24-credit-card-coverage.md): the list
// of Admin > Settings > Card coverage, with the value limits first (many of the cars are priced above them), what to do
// at the counter, and the plain rule that the card's issuer decides every claim.
export const revalidate = 3600;
const PATH = '/credit-card-rental-coverage';
const trail: Trail = [['Home', '/'], ['Requirements and coverage', '/requirements'], ['Credit card rental coverage']];
const load = async () => ((await rpc('card_coverage_public', {})) as unknown as CardList | null) ?? { cards: [], checked: null, oldest: null };

export async function generateMetadata() {
  return seoMeta({ title: 'Credit cards with rental car coverage in Canada | CarmaCars', path: PATH,
    description: 'Which Canadian and US credit cards include rental car damage coverage: car value limits (MSRP), longest rental, exclusions and each issuer’s guide.' });
}

export default async function CardCoverage() {
  const list = await load();
  const ca = list.cards.filter((c) => c.country === 'CA' && c.coverage !== 'none');
  const at = (n: number) => ca.filter((c) => c.max_msrp_cents === n * 100).length;
  const high = reaching(ca, 100000);
  const faq = cardFaq(list.cards);
  return (
    <div className="p-req p-cards">
      <JsonLd graph={[breadcrumbLd(trail, PATH), faqLd(faq)]} />
      <PageHead trail={trail} h1="Credit cards with rental car coverage." lead="Coverage option 2: the damage coverage some credit cards include. Here is what each card allows, so you can check yours before you book." />
      <section className="section" aria-labelledby="cc-first">
        <div className="wrap grid">
          <div className="c-4 stack"><h2 className="d2" id="cc-first">Check the car’s value first</h2></div>
          <div className="c-8 stack-lg">
            <div className="alert alert--error" data-testid="card-coverage-limits">
              <span className="alert__title">Most cards stop at $65,000 or $85,000</span>
              <span>Credit card coverage only applies to a car priced under the card’s limit: its manufacturer’s suggested retail price (MSRP) for its model year and trim, before taxes. Many luxury cars, including many Mercedes-Benz models, are priced above these limits, and some makes (Porsche, for example) are excluded outright by many cards. If the car you want is over your card’s limit, choose OPCF 27 on your own auto policy or the CarmaCars Protection Plan instead.</span>
            </div>
            <div className="cc-limits">
              <div><p className="cc-limits__n">{at(65000)}</p><p className="small">Canadian cards in this list stop at <b>$65,000</b> MSRP</p></div>
              <div><p className="cc-limits__n">{at(85000)}</p><p className="small">stop at <b>$85,000</b> MSRP</p></div>
              <div><p className="cc-limits__n">{high.length}</p><p className="small">reach <b>$100,000</b>{high.length ? `: ${high.map((c) => `${c.issuer} ${c.card}`).join(', ')}` : ''}</p></div>
            </div>
            <p className="small muted measure">Not sure what the car is priced at? Ask us for its model year and trim before you book, and we will tell you.</p>
          </div>
        </div>
      </section>
      <section className="section on-grey" aria-labelledby="cc-list">
        <div className="wrap stack-lg">
          <div className="stack">
            <h2 className="d2" id="cc-list">The cards</h2>
            <div className="alert" data-testid="card-coverage-confirm">
              <span className="alert__title">Confirm with your card issuer before you rent</span>
              <span>This list is a summary to help you check, not a promise of coverage. Benefits change, and only your card’s issuer and its insurer decide a claim. CarmaCars does not decide claims and is not an insurer. Call the number on the back of your card and ask about a rental from a rental company in Ontario, for this car and these dates.</span>
            </div>
            <p className="small muted">{list.checked ? `Last checked ${checkedOn(list.checked)}. ` : ''}“In the issuer’s document” means we read the numbers in the issuer’s own guide that day; “Unverified” means they come from a published summary and the issuer’s guide may differ. Holding a card issued in the US? Check that it covers rentals in Canada.</p>
          </div>
          <CardTable rows={list.cards} />
        </div>
      </section>
      <section className="section" aria-labelledby="cc-check">
        <div className="wrap grid">
          <div className="c-4 stack"><h2 className="d2" id="cc-check">Before you rent</h2><p className="muted">What most cards ask of you, and what we check.</p></div>
          <div className="c-8 stack-lg">
            <ol className="ticks ticks--n" data-testid="card-coverage-checklist">
              <li><b>Pay the whole rental with that card.</b> It must be a credit card in your name, not a debit or prepaid card, and the same card pays for the booking.</li>
              <li><b>Decline other damage waivers only if your card’s terms say so.</b> Most benefits apply only when you decline the rental company’s collision or loss damage waiver.</li>
              <li><b>Check the car and the dates.</b> The car must be under the card’s value limit and not an excluded type or make, and the rental no longer than the card allows (often 31 or 48 days, counted from the first day).</li>
              <li><b>Bring proof of coverage.</b> Ask your issuer for a letter or the benefits certificate that shows rental car damage coverage, and add it to your booking before pickup.</li>
              <li><b>Keep the paperwork.</b> If the car is damaged, you pay what your rental agreement says, then claim it from your card’s coverage with the rental agreement, the receipt and the damage report.</li>
            </ol>
            <Affiliate placement="card_guide" />
            <p className="small muted measure">Cards usually exclude rentals from peer-to-peer marketplaces where you rent a private person’s car. You rent from CarmaCars, under CarmaCars’ rental agreement; still ask your issuer to confirm that a CarmaCars rental qualifies. See every coverage option on <Link className="link" href="/requirements#coverage">Requirements and coverage</Link>.</p>
          </div>
        </div>
      </section>
      <section className="section on-grey" aria-labelledby="cc-faq">
        <div className="wrap grid">
          <div className="c-4"><h2 className="d2" id="cc-faq">Questions</h2></div>
          <div className="c-8"><Faq items={faq} /></div>
        </div>
      </section>
      <CtaBand h="Found your card?" p="Pick a car and send a request. Choose option 2, and we check your card before pickup." />
    </div>
  );
}
