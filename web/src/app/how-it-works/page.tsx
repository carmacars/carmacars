import Link from 'next/link';
import { CtaBand, PageHead } from '@/components/Blocks';
import { JsonLd } from '@/components/JsonLd';
import { SlotPicture } from '@/components/Picture';
import { breadcrumbLd, type Trail, seoMeta } from '@/features/seo/meta';
import { fill, getTokens, listItems, slotPhoto } from '@/lib/site';

export const revalidate = 3600;
const trail: Trail = [['Home', '/'], ['How it works']];
type Step = { title: string; body: string; who: string };

export async function generateMetadata() {
  const t = await getTokens();
  return seoMeta({ title: fill('How booking works | {{brand}} car rental, {{city}}', t), path: '/how-it-works',
    description: fill('How renting from {{brand}} in {{city}} works: send a request, get a confirmed price, sign and pay online, then pick up the car or have it delivered.', t) });
}

const DETAIL: [string, string[]][] = [
  ['What you tell us', ['The car, pickup and return dates and times, any time of day with at least {{notice}}’ notice', 'Where you get it and return it: our location, the car owner’s location where offered, an address or an airport', 'The driver’s name, age and contact details', 'Licence class and which coverage option you plan to use']],
  ['What we check and send back', ['That the car is free and the trip is {{maxDays}} days or less', 'The rental charge, delivery and pickup fees, any young driver or additional driver fee, extras and {{hst}} HST', 'The deposit amount, shown separately because it is taken about {{depLead}} before pickup', 'The price of coverage bought through us, if you chose it', 'Anything we need to adjust, and why', 'The price is an offer, open for {{offerHours}} hours. It does not hold the car']],
  ['What you do to confirm', ['Sign the rental agreement online and tick the four consents', 'Pay the total through our checkout with a credit card in your own name', 'Choose non-refundable if you want {{nonRef}} off the rental charge', 'The car is booked at this moment. If someone else pays for the same car and dates first, we tell you and offer another car or other dates']],
  ['What we need before pickup', ['A photo of each driver’s licence, front and back', 'A selfie of each driver holding their licence', 'Proof of your coverage, or payment for the Protection Plan', 'All of it at least {{verifyHours}} hours before pickup']],
  ['What happens at handover', ['We hand the car only to the renter, in person', 'We check your original licence and the physical card you paid with', 'We take the deposit about {{depLead}} before pickup: a card hold for {{holdDays}} days or less, a refundable charge for longer', 'We complete the condition report and photo set together, and you both sign it']]
];

export default async function How() {
  const [t, steps, photo] = await Promise.all([getTokens(), listItems<Step>('home.how_steps'), slotPhoto('how.handover')]);
  const F = (x: string) => fill(x, t);
  return (
    <div className="p-how">
      <JsonLd graph={[breadcrumbLd(trail, '/how-it-works'), { '@type': 'HowTo', name: F('How to rent a car from {{brand}}'), step: steps.map((s, i) => ({ '@type': 'HowToStep', position: i + 1, name: s.title, text: F(s.body) })) }]} />
      <PageHead trail={trail} h1="Choose, request, drive." lead="Booking a car here takes five steps. The first costs nothing. The car is yours once you have approved, signed and paid." />
      <section className="section"><div className="wrap">
        <ol className="how-full">
          {steps.map((s, i) => (
            <li className="how-full__step" key={s.title}>
              <div className="how-full__n" aria-hidden="true">{i + 1}</div>
              <div className="how-full__main stack"><h2 className="d2">{s.title}</h2><p className="lead">{F(s.body)}</p><span className="seq__who">{s.who}</span></div>
              {DETAIL[i] && <div className="how-full__detail"><h3 className="small strong">{DETAIL[i][0]}</h3><ul className="ticks">{DETAIL[i][1].map((x) => <li key={x}>{F(x)}</li>)}</ul></div>}
            </li>
          ))}
        </ol>
      </div></section>
      <section className="band on-dark" aria-labelledby="hw-ret">
        <div className="band__media photo fx-drift"><SlotPicture p={photo} /></div>
        <div className="wrap band__inner"><div className="band__copy stack">
          <h2 className="d1" id="hw-ret">Bringing it back</h2>
          <p className="lead">Return the car on time, with the same fuel or charge, and all the keys. We inspect it with you and compare it with the pickup photos.</p>
          <dl className="band__facts"><div><dt>Deposit released</dt><dd>{F('Within {{releaseDays}}')}</dd></div><div><dt>Grace period</dt><dd>{t.grace}</dd></div></dl>
          <p className="small muted">Need it longer? Ask before your return time. An extension has to be confirmed in writing and paid before then.</p>
        </div></div>
      </section>
      <section className="section" aria-labelledby="hw-after">
        <div className="wrap grid">
          <div className="c-6 stack-lg">
            <h2 className="d2" id="hw-after">After the rental</h2>
            <table className="spec"><tbody>
              <tr><th scope="row">At return</th><td>We check kilometres, fuel or charge, cleanliness, keys and any new damage, with you there</td></tr>
              <tr><th scope="row">{F('Within {{hiddenHours}} hours')}</th><td>We tell you about any damage that could not be seen at return</td></tr>
              <tr><th scope="row">{F('Within {{releaseDays}}')}</th><td>You get an itemized statement and the balance of your deposit</td></tr>
              <tr><th scope="row">{F('Up to {{holdbackDays}}')}</th><td>We may hold back the amount expected for an open toll, ticket or claim, then apply or release it</td></tr>
              <tr><th scope="row">Later</th><td>Tolls and tickets that arrive afterwards are billed with a copy of the notice</td></tr>
            </tbody></table>
          </div>
          <div className="c-5 s-8 stack-lg">
            <h2 className="d2">What you agree to when you sign</h2>
            <p className="muted">Four consents sit beside the signature. Every box starts unticked.</p>
            <ol className="cover__opts">
              <li><h3>Tracking and disabling</h3><p className="muted small">Every car has a GPS tracker. It records location, speed and distance, not sound or video. A moving car is never disabled.</p></li>
              <li><h3>Identity verification</h3><p className="muted small">We check your licence against a live photo of your face. You can ask for a staff review instead of the automated match.</p></li>
              <li><h3>Electronic signature</h3><p className="muted small">You sign and receive the agreement and notices electronically.</p></li>
              <li><h3>Card authorization</h3><p className="muted small">We may hold or charge your card for the total, the deposit and later charges such as tolls.</p></li>
            </ol>
            <p className="small"><Link className="link" href="/privacy">How we handle your information</Link></p>
          </div>
        </div>
      </section>
      <CtaBand h="Find the car first." p="The request takes a few minutes and costs nothing." />
    </div>
  );
}
