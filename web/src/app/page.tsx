import Link from 'next/link';
import { Icon } from '@/components/Icon';
import { CarCard } from '@/components/CarCard';
import { Faq } from '@/components/Faq';
import { Html } from '@/components/Html';
import { JsonLd } from '@/components/JsonLd';
import { SlotPicture } from '@/components/Picture';
import { Reviews } from '@/components/Reviews';
import { SearchForm } from '@/features/home/SearchForm';
import { Rail } from '@/features/home/Rail';
import { businessLd } from '@/features/seo/business';
import { faqLd, seoMeta } from '@/features/seo/meta';
import { faqItems, fill, getClasses, getFacts, getFleet, getSettings, getTokens, listItems, slotPhoto, siteUrl } from '@/lib/site';

export const revalidate = 3600;

export async function generateMetadata() {
  const t = await getTokens();
  return seoMeta({
    title: fill('{{brand}} | {{city}} car rental, pickup or delivery', t), path: '/',
    description: fill('{{city}} car rental from {{minDaily}} a day, picked up or delivered. Send a request with no payment and pay once the price is confirmed. Drivers {{minAge}} and up.', t)
  });
}

type Step = { title: string; body: string; who: string };
type Row = { label: string; text: string };
type Opt = { title: string; body: string };

export default async function Home() {
  const [s, f, t, fleet, classes, faq, steps, reqs, cover, hero, deliv, owner] = await Promise.all([
    getSettings(), getFacts(), getTokens(), getFleet(), getClasses(), faqItems('home.faq'), listItems<Step>('home.how_steps'),
    listItems<Row>('home.requirements'), listItems<Opt>('home.coverage_options'), slotPhoto('home.hero'), slotPhoto('home.delivery'), slotPhoto('home.owner')
  ]);
  const F = (x: string) => fill(x, t);
  const labels = Object.fromEntries(classes.map((c) => [c.code, c.label]));
  const tagline = s.tagline ?? '';
  const [t1, t2] = tagline.includes(', ') ? [tagline.slice(0, tagline.indexOf(', ') + 1), tagline.slice(tagline.indexOf(', ') + 2)] : [tagline, ''];
  const airportsShort = f.airports.map((a) => a.name.replace(/ (International|Toronto City) Airport$/, '')).join(' and ');
  return (
    <div className="p-home">
      <JsonLd graph={[businessLd(s, siteUrl()), { '@type': 'WebSite', url: siteUrl(), name: s.brand_name }, faqLd(faq.map((q) => ({ ...q, answer: F(q.answer) })))]} />
      <section className="hero on-dark">
        <div className="hero__media"><SlotPicture p={hero} eager /></div>
        <div className="wrap hero__inner">
          <div className="hero__copy">
            <p className="eyebrow">{s.city} car rental</p>
            <h1 className="d-hero">{t1}{t2 && <> <br className="br-xl" />{t2}</>}</h1>
            <p className="lead">Good cars for rent in {s.city}, picked up or brought to your door. Choose one, send a request, and pay only once the price is confirmed.</p>
          </div>
          <SearchForm maxDays={f.max_rental_days} />
        </div>
      </section>

      <section className="facts on-dark" aria-label="The short version">
        <div className="wrap"><dl className="facts__list">
          <div><dt>Drivers</dt><dd>{F('{{minAge}} and up, {{licence}}')}</dd></div>
          <div><dt>Pickup and return</dt><dd>Any time, day or night</dd></div>
          <div><dt>Booking length</dt><dd>{F('1 to {{maxDays}} days')}</dd></div>
          <div><dt>Delivery</dt><dd>Anywhere, airports too</dd></div>
          <div><dt>At request</dt><dd>No payment</dd></div>
        </dl></div>
      </section>

      <section className="section on-dark fleet-rail" aria-labelledby="h-fleet">
        {fleet.length >= 3 ? (
          <Rail
            head={<div><h2 className="d1" id="h-fleet">Pick your car.</h2><p className="lead muted">{F('City cars, sedans, SUVs and something for the weekend, from {{minDaily}} a day. Every car shows its own calendar and its real rates.')}</p></div>}
            count={7} random={s.featured_mode === 'random'}
            items={fleet.map((c) => ({ key: c.slug, featured: c.is_featured, node: <CarCard c={c} labels={labels} /> }))}
            end={<Link href="/cars"><span className="d2">See every car</span><span className="link--go">Open the fleet <Icon name="arrow" /></span></Link>}
          />
        ) : (
          <div className="wrap section-head"><div><h2 className="d1" id="h-fleet">Pick your car.</h2><p className="lead muted">Our first cars are being photographed. <Link className="link" href="/contact">Ask us</Link> and we will tell you when they are live.</p></div></div>
        )}
      </section>

      <section className="section how" aria-labelledby="h-how">
        <div className="wrap grid">
          <div className="c-5 how__intro"><div className="how__sticky stack">
            <h2 className="d1" id="h-how">Easy to book. Nothing to pay up front.</h2>
            <p className="lead">Send a request in a few minutes, with no card. A person checks the car and sends you the full price. You pay once you have seen it and said yes.</p>
            <p><Link className="link link--go" href="/how-it-works">The full walkthrough <Icon name="arrow" /></Link></p>
          </div></div>
          <div className="c-7 how__steps">
            <span className="how__line fx-grow-y" aria-hidden="true"></span>
            <ol className="seq">{steps.map((st) => <li key={st.title}><div><h3>{st.title}</h3><p>{F(st.body)}</p><span className="seq__who">{st.who}</span></div></li>)}</ol>
          </div>
        </div>
      </section>

      <section className="band on-dark" aria-labelledby="h-deliv">
        <div className="band__media photo fx-drift"><SlotPicture p={deliv} /></div>
        <div className="wrap band__inner"><div className="band__copy stack">
          <h2 className="d1" id="h-deliv">Delivered to your door.</h2>
          <p className="lead">Home, office, hotel or the airport, anywhere. Tell us the address in your request, at any hour, and we price the trip in your offer.</p>
          <dl className="band__facts"><div><dt>Each way</dt><dd className="num">{F('From {{delMin}}')}</dd></div><div><dt>Airports</dt><dd>{airportsShort}</dd></div></dl>
          <p className="small muted">Each car has its own delivery fee, shown on its page, plus the distance from our location. An airport surcharge may apply.</p>
          <p><Link className="btn btn--light" href="/delivery">How delivery works</Link></p>
        </div></div>
      </section>

      <section className="section" aria-labelledby="h-req">
        <div className="wrap grid">
          <div className="c-6 stack-lg">
            <h2 className="d2" id="h-req">What you need to rent</h2>
            <table className="spec"><tbody>{reqs.map((r) => <tr key={r.label}><th scope="row">{r.label}</th><td>{F(r.text)}</td></tr>)}</tbody></table>
            <p><Link className="link link--go" href="/requirements">Requirements in full <Icon name="arrow" /></Link></p>
          </div>
          <div className="c-5 s-8 stack-lg cover">
            <h2 className="d2" id="h-cov">Coverage, in plain terms</h2>
            <p>Third-party liability coverage is included in every rate. For damage to the car itself, you choose one of these before pickup.</p>
            <ol className="cover__opts">{cover.map((o, i) => <li key={o.title}><span className="cover__n">Option {i + 1}</span><h3>{o.title}</h3><p className="muted small">{F(o.body)}</p></li>)}</ol>
            <p className="small">{F('Damage under {{deductible}} is billed at cost. At {{deductible}} or more we claim on our fleet policy and you pay the {{deductible}} deductible.')}</p>
          </div>
        </div>
      </section>

      <section className="owner-band on-red" aria-labelledby="h-own">
        <div className="wrap owner-band__grid">
          <div className="stack">
            <h2 className="d1" id="h-own">Good cars come back around.</h2>
            <p className="lead">{F('List yours with {{brand}} and it earns its keep while you are not driving it. We handle the renters, the handovers and the paperwork, it goes on our fleet insurance policy, and you are paid on the {{payoutDay}} of each month.')}</p>
            <p><Link className="btn btn--light btn--lg" href="/list-your-car">List your car</Link></p>
          </div>
          <div className="owner-band__media photo fx-wipe"><SlotPicture p={owner} sizes="(min-width: 48rem) 50vw, 100vw" /></div>
        </div>
      </section>

      <section className="section" aria-labelledby="h-rev">
        <div className="wrap grid">
          <div className="c-4"><h2 className="d2" id="h-rev">Word gets around.</h2></div>
          <div className="c-8"><Reviews /></div>
        </div>
      </section>

      <section className="section on-grey" aria-labelledby="h-faq">
        <div className="wrap grid">
          <div className="c-4 stack"><h2 className="d2" id="h-faq">Good to know before you book</h2><p><Link className="link link--go" href="/faq">All questions <Icon name="arrow" /></Link></p></div>
          <div className="c-8"><Faq items={faq.map((q) => ({ question: F(q.question), answer: F(q.answer) }))} /></div>
        </div>
      </section>

      <section className="section--tight on-red cta-band" aria-labelledby="h-carma">
        <div className="wrap cta-band__in">
          <div><h2 className="d1" id="h-carma">{t.carma}</h2><Html as="p" className="lead" html="Pick a car, send a request, and pay only once the price is confirmed." /></div>
          <Link className="btn btn--light btn--lg" href="/cars">Find a car</Link>
        </div>
      </section>
    </div>
  );
}
