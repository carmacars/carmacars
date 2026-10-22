import Link from 'next/link';
import { notFound, permanentRedirect } from 'next/navigation';
import { Suspense } from 'react';
import { CarCard } from '@/components/CarCard';
import { Crumbs } from '@/components/Crumbs';
import { Faq } from '@/components/Faq';
import { Icon } from '@/components/Icon';
import { JsonLd } from '@/components/JsonLd';
import { BookBar, CarBooking } from '@/features/car/CarBooking';
import { Gallery } from '@/features/car/Gallery';
import { carFaq, perDayFees } from '@/features/car/faq';
import { absUrl, breadcrumbLd, faqLd, type Trail, seoMeta } from '@/features/seo/meta';
import { getSeoLinks } from '@/features/seo/data';
import { rpc } from '@/lib/db/repo';
import { money, FUEL_LABEL } from '@/lib/format';
import { fill, getClasses, getFacts, getFleet, getSettings, getTokens, listItems, photoUrl, siteUrl } from '@/lib/site';
import type { CarPage as Car } from '@/lib/types';
import { makePage, type MakePage } from '@/features/vehicles/data';
import { MakeView, makeMeta } from '@/features/vehicles/views';

export const revalidate = 3600;
export const dynamicParams = true;

// On demand with the page cache (ISR, an hour), not at build time: one slow database moment must not stop a deploy
// (the /rent/[hub] build failure of October 19, 2026). The first visitor of the hour waits for one database call.
export async function generateStaticParams() { return []; }

type Params = { params: Promise<{ slug: string }> };
// /cars/<slug> is a car of the fleet, or else a make's vehicle page (/cars/toyota, migration 0092): a car's address
// always carries its model, so it is never a make's.
async function loadAny(slug: string): Promise<Car | MakePage> {
  const page = (await rpc('car_page', { p_slug: slug })) as unknown as (Car & { redirect?: string; status_code?: number }) | null;
  if (!page) { const mk = await makePage(slug); if (mk) return mk; notFound(); }
  if (page.redirect) {
    // listing_redirects (docs/blueprint/14-seo.md section 11): 301 to the hub or twin; 410 shows the not-found page.
    if (page.status_code === 301) permanentRedirect(page.redirect);
    notFound();
  }
  return page;
}
const isMake = (x: Car | MakePage): x is MakePage => (x as MakePage).level === 'make';
const name = (c: Car) => `${c.make} ${c.model}`;

export async function generateMetadata({ params }: Params) {
  const x = await loadAny((await params).slug);
  if (isMake(x)) return makeMeta(x);
  const c = x;
  const t = await getTokens();
  // The listing's own SEO text when it is a usable length, else built from the car; the longest parts are
  // dropped first so the title stays near 60 characters and the description near 155.
  const fit = (max: number, ...tries: string[]) => tries.map((x) => fill(x, t).replace(/\s+/g, ' ').trim()).find((x) => x.length <= max) ?? fill(tries[tries.length - 1]!, t);
  // 0073: every car's search text is built the same way as the sample cars' (from the car and its price), unless a
  // person wrote and locked it on the car copy
  const locked = new Set(c.copy_locked ?? []);
  // 0074: a car that shares its year, make and model with another car on the site gets its distinguishing part (its
  // colour or a short code) in both, so no two cars have the same title or description
  const nm = `${name(c)}${c.seo_mark ? ` (${c.seo_mark})` : ''}`;
  const title = locked.has('seo_title') && c.copy?.seo_title && c.copy.seo_title.length <= 70 ? c.copy.seo_title
    : fit(65, `Rent a ${c.year} ${nm} in {{city}} from ${money(c.daily_rate_cents)} a day | {{brand}}`, `${c.year} ${nm} rental in {{city}}, ${money(c.daily_rate_cents)} a day | {{brand}}`, `${c.year} ${nm} rental in {{city}} | {{brand}}`);
  const spec = [c.seats ? `${c.seats} seats` : '', (c.transmission ?? '').toLowerCase(), `${c.km_allowance_per_day} km a day included`].filter(Boolean).join(', ');
  const description = locked.has('meta_description') && c.copy?.meta_description && c.copy.meta_description.length >= 70 && c.copy.meta_description.length <= 170 ? c.copy.meta_description
    : fit(160, `Rent the ${c.year} ${nm} in {{city}}: ${money(c.daily_rate_cents)} a day, ${money(c.weekly_rate_cents)} a week. ${spec}. Pickup or delivery, no payment to request.`,
      `Rent the ${c.year} ${nm} in {{city}}: ${money(c.daily_rate_cents)} a day, ${money(c.weekly_rate_cents)} a week, ${spec}. No payment to request.`,
      `Rent the ${c.year} ${nm} in {{city}} from ${money(c.daily_rate_cents)} a day, ${spec}. Request with no payment up front.`);
  return seoMeta({
    title, description,
    path: c.canonical_path, image: c.photos[0] ? absUrl(c.photos[0].path) : null,
    imageSize: c.photos[0]?.width && c.photos[0]?.height ? [c.photos[0].width, c.photos[0].height] : undefined, imageAlt: c.photos[0]?.alt ?? undefined,
    noindex: !c.indexable
  });
}

type Opt = { title: string; body: string };
const DRIVE: Record<string, string> = { 'All-wheel drive': 'AllWheelDriveConfiguration', 'Four-wheel drive': 'FourWheelDriveConfiguration', 'Front-wheel drive': 'FrontWheelDriveConfiguration', 'Rear-wheel drive': 'RearWheelDriveConfiguration' };
// the VIN decoder's words ("FWD/Front-Wheel Drive") read as the sample cars' ("Front-wheel drive"); the database stores them so since 0073
const driveOf = (d: string | null) => (!d ? null : /all.?wheel|awd/i.test(d) ? 'All-wheel drive' : /four.?wheel|4wd|4x4/i.test(d) ? 'Four-wheel drive'
  : /front.?wheel|fwd/i.test(d) ? 'Front-wheel drive' : /rear.?wheel|rwd/i.test(d) ? 'Rear-wheel drive' : d);

export default async function CarPage({ params }: Params) {
  const { slug } = await params;
  const x = await loadAny(slug);
  if (isMake(x)) return <MakeView p={x} />;
  const c = x;
  const [s, f, t, fleet, classes, cover, places, terms, links] = await Promise.all([
    getSettings(), getFacts(), getTokens(), getFleet(), getClasses(), listItems<Opt>('home.coverage_options'),
    rpc('handover_places', { p_vehicle: c.vehicle_id }) as unknown as Promise<{ owner_location: boolean; area: string | null } | null>,
    perDayFees(c.vehicle_id), getSeoLinks()
  ]);
  const F = (x: string) => fill(x, t);
  const labels = Object.fromEntries(classes.map((k) => [k.code, k.label]));
  const classText = c.classes.map((k) => labels[k] ?? k).join(', ');
  const ev = c.fuel === 'electric';
  const ydA = terms.young_driver_18_20 ?? null; const ydB = terms.young_driver_21_25 ?? null; const addPerDay = terms.additional_driver ?? null;
  // the car's own questions after the common ones, never the same question twice
  const common = carFaq(c, { ydA, ydB, ev }, t);
  const key = (q: string) => q.toLowerCase().replace(/[^a-z0-9]+/g, ' ').trim();
  const faq = [...common, ...c.faq.filter((q) => !common.some((x) => key(x.question) === key(q.question)))];
  const similar = fleet.filter((x) => x.slug !== c.slug)
    .map((x) => ({ x, d: (x.class === c.class ? 0 : 6000) + Math.abs(x.daily_rate_cents - c.daily_rate_cents) }))
    .sort((a, b) => a.d - b.d).slice(0, 3).map((o) => o.x);
  const trail: Trail = [['Home', '/'], ['Fleet', '/cars'], [name(c), c.model_hub_path], [[c.year, name(c), c.trim].filter(Boolean).join(' ')]];
  // 0073: real cars render exactly like the sample cars. The written copy feeds the listing's headline, blurb,
  // features and questions (synced by the database); its other parts are not shown, as the samples have none.
  const drive = driveOf(c.drivetrain);
  const rv = c.reviews ?? { count: 0, average: null, min_for_rating: 3, items: [] };
  // the landing pages this car belongs on (only those that may be indexed), for the links under the car
  const has = (k: string) => c.classes.includes(k);
  const want = new Set(['toronto', 'car-delivery', 'monthly', 'weekly', ...(has('suv') ? ['suv'] : []), ...(has('luxury') || has('premium') || has('exotic') ? ['luxury'] : []),
    ...((c.seats ?? 0) >= 7 ? ['minivan'] : []), ...(['electric', 'hybrid', 'plug_in_hybrid'].includes(c.fuel) ? ['electric'] : []), ...(has('economy') || has('standard') ? ['economy'] : []),
    ...(c.allows_18_to_20 ? ['young-drivers'] : [])]);
  const landing = links.filter((l) => want.has(l.slug));
  const url = siteUrl() + c.canonical_path;
  const abs = (p: string) => (/^https?:/.test(photoUrl(p)) ? photoUrl(p) : siteUrl() + photoUrl(p));
  const consumption = typeof c.specs.consumption === 'string' ? c.specs.consumption : null;
  const bags = typeof c.specs.luggage_bags === 'number' ? c.specs.luggage_bags : c.luggage ? Number(c.luggage) : null;
  const ld = {
    '@type': ['Product', 'Car'], '@id': `${url}#car`, name: `${c.year} ${name(c)}${c.trim ? ' ' + c.trim : ''}`, description: c.description ?? undefined, url,
    image: c.photos.slice(0, 5).map((g) => abs(g.path)), brand: { '@type': 'Brand', name: c.make }, manufacturer: { '@type': 'Organization', name: c.make },
    model: c.model, vehicleConfiguration: c.trim ?? undefined, vehicleModelDate: String(c.year), bodyType: c.body_style ?? undefined, color: c.colour ?? undefined,
    fuelType: FUEL_LABEL[c.fuel] ?? c.fuel, vehicleTransmission: c.transmission ?? undefined,
    ...(drive && DRIVE[drive] ? { driveWheelConfiguration: `https://schema.org/${DRIVE[drive]}` } : {}),
    seatingCapacity: c.seats ?? undefined, numberOfDoors: c.doors ?? undefined, itemCondition: 'https://schema.org/UsedCondition',
    ...(rv.count >= rv.min_for_rating && rv.average !== null ? {
      // only this car's own reviews, collected on the site after a completed rental and shown in full on this page
      aggregateRating: { '@type': 'AggregateRating', ratingValue: String(rv.average), reviewCount: rv.count, bestRating: 5, worstRating: 1 },
      review: rv.items.slice(0, 5).map((r) => ({ '@type': 'Review', author: { '@type': 'Person', name: r.name ?? 'Renter' }, datePublished: r.month,
        reviewRating: { '@type': 'Rating', ratingValue: r.rating, bestRating: 5, worstRating: 1 }, ...(r.body ? { reviewBody: r.body } : {}), ...(r.title ? { name: r.title } : {}) }))
    } : {}),
    offers: {
      '@type': 'Offer', url, businessFunction: 'http://purl.org/goodrelations/v1#LeaseOut', priceCurrency: 'CAD', price: (c.daily_rate_cents / 100).toFixed(2),
      priceSpecification: [['DAY', c.daily_rate_cents, 'per day'], ['WEE', c.weekly_rate_cents, 'per week'], ['MON', c.monthly_rate_cents, `per ${f.max_rental_days} days`]].map(([u, p, txt]) => ({ '@type': 'UnitPriceSpecification', price: ((p as number) / 100).toFixed(2), priceCurrency: 'CAD', unitCode: u, unitText: txt, valueAddedTaxIncluded: false })),
      availability: c.taking_requests ? 'https://schema.org/InStock' : 'https://schema.org/OutOfStock',
      eligibleDuration: { '@type': 'QuantitativeValue', minValue: 1, maxValue: f.max_rental_days, unitCode: 'DAY' },
      areaServed: { '@type': 'City', name: s.city }, seller: { '@id': `${siteUrl()}/#business` }
    }
  };
  const tokens = { nonRef: t.nonRef!, addDrvPct: t.addDrvPct!, notice: t.notice!, turnaround: t.turnaround!, offerHours: t.offerHours!, hst: t.hst!, fullAge: t.fullAge!, youngA: t.youngA!, youngB: t.youngB! };

  return (
    <div className="p-car" data-page="car">
      <JsonLd graph={[breadcrumbLd(trail, c.canonical_path), ld, faqLd(faq.map((q) => ({ question: F(q.question), answer: F(q.answer) })))]} />
      <section className="car-top on-dark">
        <div className="wrap car-top__crumbs"><Crumbs trail={trail} /></div>
        <div className="car-top__grid">
          <Gallery name={name(c)} photos={c.photos} />
          <div className="car-top__info">
            <p className="row"><span className="small muted">{classText}</span>{c.is_sample && <span className="badge badge--outline car-top__example" data-testid="example-car-badge">Example car</span>}</p>
            <h1 className="d1 car-top__name"><span>{c.make}</span> {c.model}</h1>
            <p className="lead muted">{[c.year, c.trim].filter(Boolean).join(' ')}{c.colour ? `, ${c.colour}` : ''}. For rent in {s.city}.</p>
            {(c.description ?? '').split(/\n{2,}/).filter(Boolean).map((x, i) => <p key={i} className="car-top__blurb">{x}</p>)}
            <dl className="keyspecs">
              <div><dt>Seats</dt><dd className="num">{c.seats}</dd></div>
              <div><dt>Gearbox</dt><dd>{/^automatic/i.test(c.transmission ?? '') ? 'Auto' : c.transmission}</dd></div>
              <div><dt>{ev ? 'Power' : 'Fuel'}</dt><dd>{ev ? 'Electric' : c.fuel === 'gasoline' ? 'Gas' : FUEL_LABEL[c.fuel]}</dd></div>
              <div><dt>Km a day</dt><dd className="num">{c.km_allowance_per_day}</dd></div>
            </dl>
            <div className="car-top__cta">
              <p className="car-top__price"><span className="small muted">From</span> <b className="num">{money(c.daily_rate_cents)}</b> <span className="small muted">a day</span></p>
              {c.taking_requests ? <a className="btn btn--primary btn--lg" href="#dates">Check dates and price</a> : <p className="alert alert--warn"><span>Not taking requests right now.</span></p>}
              {c.is_sample
                ? <p className="small car-top__example-note" data-testid="example-car-note">This is an example of the cars we rent. Send your dates and we suggest a similar real car with its price. Nothing is booked or charged.</p>
                : <p className="small muted">Request to book. No payment until we confirm and you approve. A request does not hold the car.</p>}
            </div>
          </div>
        </div>
      </section>

      <nav className="car-nav" aria-label="On this page"><div className="wrap"><ul>
        {[['rates', 'Rates'], ['dates', 'Dates and price'], ['specs', 'Specs'], ['need', 'Requirements'], ['coverage', 'Coverage'], ['delivery', 'Delivery'], ['cancel', 'Cancelling'], ['questions', 'Questions']].map(([id, l]) => <li key={id}><a href={`#${id}`}>{l}</a></li>)}
      </ul></div></nav>

      <div className="wrap car-body">
        <div className="car-body__main">
          <section id="rates" className="car-sec" aria-labelledby="h-rates">
            <h2 className="d2" id="h-rates">Rates</h2>
            <dl className="rates">
              <div><dt>Daily</dt><dd className="num">{money(c.daily_rate_cents)}</dd><dd className="rates__n">Monday to Thursday, and Sunday</dd></div>
              <div><dt>Weekend day</dt><dd className="num">{money(c.weekend_rate_cents)}</dd><dd className="rates__n">Days starting Friday or Saturday</dd></div>
              <div><dt>Weekly</dt><dd className="num">{money(c.weekly_rate_cents)}</dd><dd className="rates__n">{F(`${money(Math.round(c.weekly_rate_cents / 7))} a day for {{weekFrom}} to {{maxDaysLess1}} days`)}</dd></div>
              <div><dt>Monthly</dt><dd className="num">{money(c.monthly_rate_cents)}</dd><dd className="rates__n">{F('{{maxDays}} days, the longest single booking')}</dd></div>
            </dl>
            <p className="small muted measure">{F('A day is 24 hours from your pickup time, and a part day counts as a day. Trips of 1 to {{weekFromLess1}} days are capped at the weekly rate, and {{weekFrom}} to {{maxDaysLess1}} days at the monthly rate. Rates are before {{hst}} HST.')}</p>
          </section>

          {c.taking_requests && (
            // the anchor of "Check dates and price" and "Change dates" stays in the page whether the booking box has
            // streamed in or not
            <div id="dates">
            <Suspense fallback={<section className="car-sec"><h2 className="d2">Dates and price</h2><div className="skeleton sk-img" /></section>}>
              <CarBooking vehicleId={c.vehicle_id} slug={c.slug} name={name(c)} deliveryFee={c.delivery_fee_cents} pickupFee={c.pickup_fee_cents}
                rates={{ daily: c.daily_rate_cents, weekend: c.weekend_rate_cents, weekly: c.weekly_rate_cents, monthly: c.monthly_rate_cents }}
                maxDays={f.max_rental_days} noticeMinutes={f.booking_min_notice_minutes} tokens={tokens} allowsYoung={c.allows_18_to_20} />
            </Suspense>
            </div>
          )}

          <section id="specs" className="car-sec" aria-labelledby="h-specs">
            <h2 className="d2" id="h-specs">Specs</h2>
            <div className="grid specs-grid">
              <table className="spec c-6"><caption className="vh">Vehicle</caption><tbody>
                <tr><th scope="row">Model year</th><td>{c.year}</td></tr>
                {c.trim && <tr><th scope="row">Trim</th><td>{c.trim}</td></tr>}
                {c.body_style && <tr><th scope="row">Body</th><td>{c.body_style}</td></tr>}
                {c.colour && <tr><th scope="row">Colour</th><td>{c.colour}</td></tr>}
                <tr><th scope="row">Seats</th><td>{c.seats}</td></tr>
                {c.doors && <tr><th scope="row">Doors</th><td>{c.doors}</td></tr>}
              </tbody></table>
              <table className="spec c-6"><caption className="vh">Driving</caption><tbody>
                <tr><th scope="row">Transmission</th><td>{c.transmission}</td></tr>
                {drive && <tr><th scope="row">Drive</th><td>{drive}</td></tr>}
                <tr><th scope="row">{ev ? 'Power' : 'Fuel'}</th><td>{FUEL_LABEL[c.fuel]}</td></tr>
                {consumption && <tr><th scope="row">{ev ? 'Range' : 'Consumption'}</th><td>{consumption}</td></tr>}
                {bags && <tr><th scope="row">Luggage</th><td>{bags} large {bags === 1 ? 'bag' : 'bags'}</td></tr>}
                <tr><th scope="row">Classes</th><td>{classText}</td></tr>
              </tbody></table>
            </div>
            {c.features.length > 0 && <><h3 className="d4 specs-feat">In this car</h3><ul className="featlist">{c.features.map((x) => <li key={x}>{x}</li>)}</ul></>}
            <p className="xs muted">Photos are representative. Colour, trim and features may differ.</p>
          </section>

          <section id="included" className="car-sec" aria-labelledby="h-inc">
            <h2 className="d2" id="h-inc">Kilometres and deposit</h2>
            <div className="twofacts">
              <div><p className="twofacts__n num" data-count>{c.km_allowance_per_day} km</p><h3>included each day</h3><p className="muted small">Your allowance is {c.km_allowance_per_day} km times the days you book, used however you like across the trip. Past that it is {money(c.overage_cents_per_km, { cents: true })} a kilometre.</p></div>
              <div><p className="twofacts__n num" data-count>{money(c.deposit_cents)}</p><h3>deposit before pickup</h3><p className="muted small">{F('Taken about {{depLead}} before pickup, never when you book. A card hold for rentals of {{holdDays}} days or less, charged and refunded for longer ones. We release the balance within {{releaseDays}} after return.')}</p></div>
            </div>
          </section>

          <section id="need" className="car-sec" aria-labelledby="h-need">
            <h2 className="d2" id="h-need">What you need</h2>
            <table className="spec"><tbody>
              <tr><th scope="row">Age</th><td>{F('{{minAge}} or older at pickup')}</td></tr>
              <tr><th scope="row">Licence</th><td>{F('Ontario {{licence}}, valid for the whole rental')}</td></tr>
              <tr><th scope="row">Card</th><td>A credit card in your name</td></tr>
              <tr><th scope="row">Young driver fee</th><td>{F(`${c.allows_18_to_20 && ydA !== null ? `${money(ydA)} a day for ages {{youngA}}, ` : ''}${ydB !== null ? `${money(ydB)} a day for ages {{youngB}}. ` : ''}No maximum.`)}</td></tr>
              {addPerDay !== null && <tr><th scope="row">Additional drivers</th><td>{F(`${money(addPerDay)} a day each ({{addDrvPct}} of the daily rate), no maximum. Each one meets the same rules and signs the agreement.`)}</td></tr>}
              <tr><th scope="row">At pickup</th><td>Your original licence and the card you paid with</td></tr>
            </tbody></table>
            <p><Link className="link link--go" href="/requirements">Requirements in full <Icon name="arrow" /></Link></p>
          </section>

          <section id="coverage" className="car-sec" aria-labelledby="h-cover">
            <h2 className="d2" id="h-cover">Coverage</h2>
            <p className="measure">Third-party liability coverage is included in the rate. For damage to the {c.model} itself, have one of these in place before pickup.</p>
            <ol className="cover__opts cover__opts--row">{cover.map((o, i) => <li key={o.title}><span className="cover__n">Option {i + 1}</span><h3>{o.title}</h3><p className="muted small">{F(o.body)}</p></li>)}</ol>
            <p className="small measure">{F('If the car is damaged: under {{deductible}} you are billed the repair at cost. At {{deductible}} or more we claim on our fleet policy and you pay the {{deductible}} deductible.')} <Link className="link" href="/requirements#coverage">More on coverage</Link>.</p>
          </section>

          <section id="delivery" className="car-sec" aria-labelledby="h-del">
            <h2 className="d2" id="h-del">Pickup and delivery</h2>
            <table className="spec"><tbody>
              <tr><th scope="row">Delivered to an address</th><td><span className="num">{money(c.delivery_fee_cents)}</span> plus distance from our location</td></tr>
              <tr><th scope="row">Picked up from you at the end</th><td><span className="num">{money(c.pickup_fee_cents)}</span> plus distance</td></tr>
              <tr><th scope="row">{F('At {{airports}}')}</th><td>The same, plus distance. An airport surcharge may apply</td></tr>
              <tr><th scope="row">Collect it yourself</th><td>No charge, at our location{places?.owner_location ? ' or at the car owner’s location' : ''}</td></tr>
            </tbody></table>
            <p className="small muted measure">Delivery goes anywhere. We price the distance in your offer. Whichever you choose, we hand the car to you in person, check your licence and card, and walk around the car together. <Link className="link" href="/delivery">How delivery works</Link>.</p>
          </section>

          <section id="cancel" className="car-sec" aria-labelledby="h-can">
            <h2 className="d2" id="h-can">Cancelling</h2>
            <table className="spec spec--num"><tbody>
              <tr><th scope="row">{F('Within {{cGrace}} hours of booking, and {{cEarly}} hours or more before pickup')}</th><td>{F('{{c1}} back')}</td></tr>
              <tr><th scope="row">{F('{{cEarly}} hours or more before pickup')}</th><td>{F('{{c2}} back')}</td></tr>
              <tr><th scope="row">{F('{{cLate}} to {{cEarly}} hours before pickup')}</th><td>{F('{{c3}} back')}</td></tr>
              <tr><th scope="row">{F('Less than {{cLate}} hours, or a no-show')}</th><td>No refund</td></tr>
            </tbody></table>
            <p className="small muted measure">{F('The first row that fits applies. A non-refundable booking takes {{nonRef}} off the rental charge and is not refunded if you cancel. If we cancel, you get everything back.')} <Link className="link" href="/cancellation-policy">Cancellation policy</Link>.</p>
          </section>

          {rv.count > 0 && (
            <section id="reviews" className="car-sec" aria-labelledby="h-rv">
              <h2 className="d2" id="h-rv">Reviews of this car</h2>
              <p className="small muted">{rv.count} {rv.count === 1 ? 'review' : 'reviews'} from renters of this car{rv.average !== null ? `, ${rv.average} out of 5 on average` : ''}. Every review comes from a completed rental and is published in full.</p>
              <ul className="linklist">{rv.items.map((r, i) => (
                <li key={i}><p><b>{r.rating} out of 5</b>{r.title ? `: ${r.title}` : ''}</p>{r.body && <p className="small">{r.body}</p>}
                  <p className="xs muted">{r.name ?? 'A renter'}, {new Intl.DateTimeFormat('en-CA', { month: 'long', year: 'numeric', timeZone: 'UTC' }).format(new Date(r.month))}</p>
                  {r.reply && <p className="small muted">Our reply: {r.reply}</p>}</li>))}</ul>
            </section>
          )}

          <section id="questions" className="car-sec" aria-labelledby="h-q">
            <h2 className="d2" id="h-q">Questions about the {c.model}</h2>
            <Faq items={faq.map((q) => ({ question: F(q.question), answer: F(q.answer) }))} />
          </section>
        </div>
      </div>

      <section className="section on-grey" aria-labelledby="h-sim">
        <div className="wrap">
          {landing.length > 0 && <nav className="car-landing" aria-label="Rent in your area or your way"><ul className="chips">{landing.map((l) => <li key={l.slug}><Link prefetch={false} className="chip" href={l.path}>{l.kind === 'location' ? `Car rental in ${l.name}` : l.name}</Link></li>)}</ul></nav>}
          <div className="section-head"><h2 className="d2" id="h-sim">Similar cars</h2><Link className="link link--go" href={c.model_hub_path}>More {c.make} {c.model} <Icon name="arrow" /></Link> <Link className="link link--go" href="/cars">See every car <Icon name="arrow" /></Link></div>
          <ul className="fleet-grid fleet-grid--3">{similar.map((x) => <li key={x.slug}><CarCard c={x} labels={labels} /></li>)}</ul>
        </div>
      </section>
      {c.taking_requests && <BookBar name={name(c)} daily={c.daily_rate_cents} slug={c.slug} />}
    </div>
  );
}
