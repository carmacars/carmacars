import Link from 'next/link';
import { CtaBand, PageHead } from '@/components/Blocks';
import { Faq } from '@/components/Faq';
import { JsonLd } from '@/components/JsonLd';
import { breadcrumbLd, faqLd, type Trail } from '@/features/seo/meta';
import { PartnerSignupForm } from './PartnerSignupForm';
import { rateWords, REFERRAL_COOKIE_DAYS, type PartnerKind } from './model';

// The referral program's public pages (migration 0164): /partners/body-shops and /partners/tow-trucks. What the program pays,
// how a referral is tied to the business, when it is paid, and the sign-up. Nothing here promises a customer coverage or a price.
export interface Variant { path: string; kind: PartnerKind; noun: string; nounPlural: string; h1: string; lead: string; who: string; moment: string }
export const VARIANTS: Record<'body-shops' | 'tow-trucks', Variant> = {
  'body-shops': { path: '/partners/body-shops', kind: 'body_shop', noun: 'body shop', nounPlural: 'body shops', h1: 'Referral program for body shops.',
    lead: 'Your customer needs a car while theirs is being repaired. Send them to CarmaCars and earn a fee on every rental that is completed and paid.',
    who: 'a customer whose car is in your shop', moment: 'when you give the estimate or book the repair' },
  'tow-trucks': { path: '/partners/tow-trucks', kind: 'tow_truck', noun: 'tow truck company', nounPlural: 'tow truck companies', h1: 'Referral program for tow truck companies.',
    lead: 'The person you just towed needs a way to get around. Hand them a card with a QR code: CarmaCars delivers a rental, and you earn a fee on every rental that is completed and paid.',
    who: 'a driver you have just towed', moment: 'at the roadside or when you drop the car off' }
};

export function partnerFaq(v: Variant, rate: string) {
  return [
    { question: 'What does it cost to join?', answer: 'Nothing. We approve each business before it can earn.' },
    { question: 'How much do we earn?', answer: `${rate} on each rental that came through your link or code, once the rental is finished and paid in full. We show the rate on your private page.` },
    { question: 'When are we paid?', answer: 'After a rental is finished and paid in full, the fee waits for our approval and is then paid by e-Transfer, cheque or bank transfer, as you choose when we set you up. Nothing is paid automatically.' },
    { question: 'What earns nothing?', answer: 'A rental that is cancelled, refunded or charged back, a renewal of an earlier rental, and your own rentals. If a fee is paid and the rental is later refunded or charged back, it comes off your next payment.' },
    { question: 'How does a rental get tied to us?', answer: `Through your link or QR code (kept for ${REFERRAL_COOKIE_DAYS} days in the customer's browser), or your code typed in the request form or given to us by phone. A rental already tied to someone else is not tied to two.` },
    { question: 'What can we see?', answer: 'A private page, with a link only you hold: your referrals by the customer\'s first name and the month, what is waiting, approved and paid. Never anything more about a customer.' },
    { question: 'Do we advise customers about insurance?', answer: 'No. Leave coverage questions to us and their insurer. Our requirements and coverage options are on the Requirements page; we confirm everything with the customer before they pick up the car.' }
  ];
}

export function PartnerLanding({ v, flatCents }: { v: Variant; flatCents: number }) {
  const rate = rateWords('flat', flatCents, 0);
  const trail: Trail = [['Home', '/'], ['Referral program'], [v.nounPlural.replace(/^./, (c) => c.toUpperCase())]];
  const faq = partnerFaq(v, rate);
  return (
    <div className="p-partners">
      <JsonLd graph={[breadcrumbLd(trail, v.path), faqLd(faq)]} />
      <PageHead trail={trail} h1={v.h1} lead={v.lead} />
      <section className="section" aria-labelledby="pp-how">
        <div className="wrap grid">
          <div className="c-4 stack"><h2 className="d2" id="pp-how">How it works</h2><p className="muted">Free to join. We approve each business before it earns.</p></div>
          <div className="c-8 stack-lg">
            <ol className="ticks ticks--n" data-testid="partner-steps">
              <li><b>Sign up below.</b> A person at CarmaCars checks the details and approves your business.</li>
              <li><b>Get your link, your code and your flyer.</b> A short link and QR code that are yours, and a one-page flyer to print for your counter.</li>
              <li><b>Hand them to {v.who}</b>, {v.moment}. They scan the code, choose a car and send a request; or they give your code to us.</li>
              <li><b>We do the rest.</b> A person confirms the car and the price with the customer before anything is charged.</li>
              <li><b>You earn {rate}</b> once the rental is finished and paid in full. We approve it and pay you by hand.</li>
            </ol>
            <div className="alert" data-testid="partner-rate"><span className="alert__title">The rate: {rate}</span><span>Agreed with you when we approve your business, and shown on your private page. A rental that is cancelled, refunded or charged back earns nothing.</span></div>
          </div>
        </div>
      </section>
      <section className="section on-grey" aria-labelledby="pp-join">
        <div className="wrap grid">
          <div className="c-4 stack"><h2 className="d2" id="pp-join">Sign up</h2><p className="muted">It takes a minute.</p></div>
          <div className="c-8"><PartnerSignupForm kind={v.kind} noun={v.noun} /></div>
        </div>
      </section>
      <section className="section" aria-labelledby="pp-faq">
        <div className="wrap grid">
          <div className="c-4"><h2 className="d2" id="pp-faq">Questions</h2></div>
          <div className="c-8 stack-lg"><Faq items={faq} />
            <p className="small muted measure">CarmaCars does not give insurance advice and is not an insurer. Referral fees are paid to businesses, never to the customer. Other businesses (dealerships, insurance brokers): <Link className="link" href="/contact">contact us</Link>.</p></div>
        </div>
      </section>
      <CtaBand h="Already a partner?" p="We send your private page link when we approve your business. Lost it? Write to us and we send a new one." btn={['Contact us', '/contact']} />
    </div>
  );
}
