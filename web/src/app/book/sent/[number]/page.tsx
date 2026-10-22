import Link from 'next/link';
import { notFound } from 'next/navigation';
import { ConfCoverage, ConfEmail, ConfName, ConfRows } from '@/features/booking/Confirmation';
import { pageMeta } from '@/features/seo/meta';
import { fill, getFacts, getSettings, getTokens } from '@/lib/site';
import { rpc } from '@/lib/db/repo';

// The request received page (docs/blueprint/02-booking-and-renter.md, /book/sent/[bookingNumber]).
export const revalidate = 3600;
export const dynamicParams = true;
export async function generateStaticParams() { return []; }
export const metadata = pageMeta({ title: 'Request sent', path: '/book/sent', noindex: true, description: 'Your booking request has been sent. Nothing has been charged. Here is what happens next.' });

export default async function Sent({ params }: { params: Promise<{ number: string }> }) {
  const { number: raw } = await params;
  const number = decodeURIComponent(raw);
  if (!/^[A-Z0-9-]{3,30}$/i.test(number)) notFound();
  const [s, f, t] = await Promise.all([getSettings(), getFacts(), getTokens()]);
  const F = (x: string) => fill(x, t);
  const bookings = f.email_aliases.bookings;
  // a request on a sample car (0065) is an enquiry: EQ-1001, answered with a similar real car
  // 0102: a real car was free for the enquiry's dates (kept on the enquiry): we say so, rather than implying we have none
  const hasMatch = /^EQ-/i.test(number) ? !!(await rpc('enquiry_has_match', { p_reference: number }).catch(() => false)) : false;
  if (/^EQ-/i.test(number)) return (
    <div className="p-conf" data-page="confirmation">
      <section className="page-head on-dark conf-head">
        <div className="wrap">
          <p className="row"><span className="plate plate--dark plate--lg" data-testid="request-number">{number}</span><span className="small muted">Your enquiry number</span></p>
          <h1 className="d1" data-testid="enquiry-sent">Enquiry sent<ConfName number={number} />.</h1>
          {hasMatch
            ? <p className="lead" data-testid="enquiry-match">The car you chose is an example of the cars we rent. We have a similar car for your dates; we’ll confirm it within 2 hours. Nothing is booked or charged.</p>
            : <p className="lead">The car you chose is an example of the cars we rent. A person at {s.brand_name} is finding a similar real car for your dates. Nothing is booked or charged.</p>}
        </div>
      </section>
      <section className="section">
        <div className="wrap grid">
          <div className="c-7 stack-lg">
            <h2 className="d2">What happens next</h2>
            <ol className="seq">
              <li><div><h3>{hasMatch ? 'We confirm the similar car' : 'We find a similar real car'}</h3><p>{F('The same kind of car at a similar price, free for your dates. {{reply}}, day or night.')}</p><span className="seq__who">{s.brand_name}</span></div></li>
              <li><div><h3>You get the car and its price</h3><p>By email<ConfEmail number={number} /> or by phone, with every fee and HST. If you like it, we send the offer to approve.</p><span className="seq__who">{s.brand_name}</span></div></li>
              <li><div><h3>You decide</h3><p>Nothing is booked until you approve, sign and pay. If it is not right, tell us and we look again.</p><span className="seq__who">You</span></div></li>
            </ol>
          </div>
          <aside className="c-4 s-8 stack-lg" aria-label="Your enquiry">
            <div className="stack"><h2 className="d4">Questions?</h2><p className="small">{bookings && <>Email <a className="link" href={`mailto:${bookings}`}>{bookings}</a> with your enquiry number</>}{s.phone && <>, or call <a className="link" href={`tel:${s.phone}`}>{s.phone_display}</a></>}.</p></div>
            <p className="row"><Link className="btn" href="/cars">Back to the fleet</Link></p>
          </aside>
        </div>
      </section>
    </div>
  );
  return (
    <div className="p-conf" data-page="confirmation">
      <section className="page-head on-dark conf-head">
        <div className="wrap">
          <p className="row"><span className="plate plate--dark plate--lg" data-testid="request-number">{number}</span><span className="small muted">Your request number</span></p>
          <h1 className="d1">Request sent<ConfName number={number} />.</h1>
          <p className="lead">Nothing has been charged, and the car is not booked yet. A person at {s.brand_name} is checking it now.</p>
        </div>
      </section>
      <section className="section">
        <div className="wrap grid">
          <div className="c-7 stack-lg">
            <h2 className="d2">What happens next</h2>
            <ol className="seq">
              <li><div><h3>We check the car and your details</h3><p>{F('We look at the calendar, your dates and the place you chose. {{reply}}, day or night.')}</p><span className="seq__who">{s.brand_name}</span></div></li>
              <li><div><h3>You get the confirmed price</h3><p>By email<ConfEmail number={number} />, with every fee and HST. If we had to adjust anything, the message says what changed. {F('That price is an offer and stays open for {{offerHours}} hours. It does not hold the car.')}</p><span className="seq__who">{s.brand_name}</span></div></li>
              <li><div><h3>You approve, sign and pay</h3><p>Reply yes and we send the rental agreement to sign online and a secure payment link. Use a credit card in your own name. The car is booked when the payment goes through. If someone else pays for the same car and dates before you do, we tell you and offer another car or other dates.</p><span className="seq__who">You</span></div></li>
              <li><div><h3>You send your licence and coverage proof</h3><p>{F('A photo of your licence, front and back, and a selfie holding it, at least {{verifyHours}} hours before pickup.')}<ConfCoverage number={number} /></p><span className="seq__who">You</span></div></li>
              <li><div><h3>Pickup day</h3><p>{F('We take the deposit about {{depLead}} before pickup. Bring your original licence and the card you paid with. We walk around the car with you and hand over the keys.')}</p><span className="seq__who">Both</span></div></li>
            </ol>
          </div>
          <aside className="c-4 s-8 stack-lg" aria-label="Your request">
            <ConfRows number={number} depLead={t.depLead!} />
            <div className="stack"><h2 className="d4">Need to change something?</h2><p className="small">{bookings && <>Email <a className="link" href={`mailto:${bookings}`}>{bookings}</a> with your request number</>}{s.phone && <>, or call <a className="link" href={`tel:${s.phone}`}>{s.phone_display}</a></>}. Nothing is locked in until you sign and pay.</p></div>
            <p className="row"><Link className="btn" href="/cars">Back to the fleet</Link><Link className="btn btn--ghost" href="/how-it-works">How it works</Link></p>
          </aside>
        </div>
      </section>
    </div>
  );
}
