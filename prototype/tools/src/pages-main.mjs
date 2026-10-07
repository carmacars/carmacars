// Home, fleet and car pages.
import { CARS, FEATURED, bySlug, RULES } from './data.mjs';
import { doc, slotPic, carImg, carShots, carCard, plate, faq, faqLd, crumbs, crumbsLd, dateRange, timeSelect, icon, money, SITE, esc } from './layout.mjs';

const minDaily = Math.min(...CARS.map((c) => c.rates.daily));

export const REQUIREMENTS_ROWS = [
  ['Age', '18 or older at pickup. Drivers aged 18 to 20 can book the cars we mark for them.'],
  ['Licence', 'A valid Ontario G2 or G licence, carried for the whole rental. Other licences are reviewed before we confirm.'],
  ['Card', 'A credit card in your own name. It pays for the booking and stays on file for the rental.'],
  ['Coverage', 'One of three coverage options, confirmed before pickup.'],
  ['Deposit', '$500, $1,000 or $2,500 depending on the car. Taken at pickup, not when you book.'],
  ['Young driver fee', '$35 a day for ages 18 to 20 (up to $350). $20 a day for ages 21 to 25 (up to $200).']
];
export const COVERAGE_OPTIONS = [
  ['OPCF 27 on your own auto policy', 'If your Ontario auto insurance includes the OPCF 27 endorsement, it can cover a rental. Send us the policy page or a letter from your insurer.'],
  ['Your credit card’s rental coverage', 'Many cards include it. The rental has to be paid with that card, and the benefit has to cover the car and the length of the rental.'],
  ['Coverage bought through CarmaCars', 'No policy and no card benefit? Add coverage to your booking. A third-party provider supplies it on its own terms, which we send you before you buy.']
];
export const HOW_STEPS = [
  ['Send a request', 'Choose the car, your dates and whether you want it delivered. No card and no payment at this point.', 'You'],
  ['We confirm, or adjust', 'A person checks the car’s calendar and your details, then sends the full price with fees and HST. If something has to change, such as the pickup time or the car, we say what and why. That price is an offer, open for 24 hours. It does not hold the car.', 'CarmaCars'],
  ['You approve, sign and pay', 'Sign the rental agreement online and pay through our checkout with a credit card in your name. The car is booked once the payment goes through, and not before. If someone else pays for the same car and dates first, we tell you and offer another car or other dates.', 'You'],
  ['We check your licence and coverage', 'Send a photo of your licence, front and back, a selfie holding it, and proof of your coverage option. We need these at least 24 hours before pickup.', 'You, then CarmaCars'],
  ['Pick up, or we deliver', 'Bring your original licence and the card you paid with. The deposit is taken before the keys change hands, and we photograph the car together.', 'Both']
];
export const HOME_FAQ = [
  ['Do I pay anything when I send a request?', 'No. A request needs no card and takes no payment. You pay only after we confirm the car and price and you approve it.'],
  ['Does a request reserve the car?', 'No. The price we send is an offer that stays open for 24 hours. The car is booked only when you approve, sign and pay. If someone else pays for the same car and dates first, we tell you and offer another car or other dates.'],
  ['How old do I have to be?', '18 or older, with an Ontario G2 or G licence. Drivers aged 18 to 20 can book the cars marked for them and pay a young driver fee of $35 a day, up to $350. Drivers aged 21 to 25 pay $20 a day, up to $200.'],
  ['What coverage do I need?', 'Third-party liability coverage is included in the rate. For damage to the car you need one of three options before pickup: OPCF 27 on your own auto policy, rental coverage on your credit card, or coverage bought through us. <a class="link" href="requirements.html#coverage">Compare the three options</a>.'],
  ['When is the deposit taken, and when do I get it back?', 'At pickup, before we hand over the keys. For rentals of 7 days or less it is a hold on your card. For longer rentals it is charged and refunded. We release the balance within 7 business days after you return the car.'],
  ['Can you bring the car to me?', 'Yes. Delivery and pickup each cost $75 to $200 depending on the car. The exact fee is on every car’s page. <a class="link" href="delivery.html">How delivery works</a>.'],
  ['What happens if I cancel?', 'It depends on timing. Cancel 48 hours or more before pickup and you get 75% back, or 95% if that is also within 24 hours of booking. Between 24 and 48 hours you get 50%. Inside 24 hours there is no refund. <a class="link" href="cancellation.html">Read the cancellation policy</a>.']
];

// SAMPLE review content. Not real customers. Shown only when the prototype toggle is on.
const SAMPLE_REVIEWS = [
  { name: 'Sample renter A', car: 'Mercedes-Benz C300', when: 'Sample date', text: 'Sample review text. A renter’s own words about the booking, the handover and the car will appear here once real trips are complete.' },
  { name: 'Sample renter B', car: 'Toyota Corolla', when: 'Sample date', text: 'Sample review text. Two or three sentences, shown exactly as the renter wrote them, with the car they rented and the month of the trip.' },
  { name: 'Sample renter C', car: 'Mercedes-Benz GLC300', when: 'Sample date', text: 'Sample review text. Longer reviews are cut after four lines with a link to read the rest, so the row stays even.' }
];
export const reviewsBlock = () => `
  <div class="reviews">
    <div class="reviews__empty" data-state-of="reviews" data-state="off">
      <p class="d3">No reviews yet.</p>
      <p class="muted measure">Renters can leave a review after a completed trip. The first ones will appear here.</p>
    </div>
    <ul class="reviews__list" data-state-of="reviews" data-state="on" hidden>
      ${SAMPLE_REVIEWS.map((r) => `<li class="review"><span class="badge badge--hatch">Sample, not a real review</span><blockquote><p>${r.text}</p></blockquote><p class="review__by"><b>${r.name}</b><span class="muted small">${r.car}, ${r.when}</span></p></li>`).join('')}
    </ul>
    <p class="proto-note"><label class="switch"><input type="checkbox" data-toggle-state="reviews"> <span><b>Prototype control.</b> Show how this section looks with reviews. The content is sample text.</span></label></p>
  </div>`;

// ---------------------------------------------------------------- home
export function home() {
  const feat = FEATURED.map(bySlug);
  const main = `
<section class="hero on-dark">
  <div class="hero__media">${slotPic('home.hero', { eager: true })}</div>
  <div class="wrap hero__inner">
    <div class="hero__copy">
      <h1 class="d-hero">Toronto car rental, <br class="br-xl">confirmed by a person.</h1>
      <p class="lead">Pick a car and your dates. We check it and send you a confirmed price. You pay only after you approve.</p>
    </div>
    <form class="search" data-search aria-label="Find a car">
      <div class="field search__dates">${dateRange({ id: 'hs' })}<p class="error" role="alert"></p></div>
      <div class="search__times">${timeSelect('tf', 'Pickup time', 'hs-tf', '10:00')}${timeSelect('tt', 'Return time', 'hs-tt', '10:00')}</div>
      <fieldset class="field search__mode"><legend class="label">Pickup or delivery</legend>
        <div class="seg"><label><input type="radio" name="mode" value="pickup" checked>I’ll collect it</label><label><input type="radio" name="mode" value="delivery">Deliver it to me</label></div>
      </fieldset>
      <button class="btn btn--primary btn--lg search__go" type="submit">Show cars</button>
    </form>
  </div>
</section>

<section class="facts on-dark" aria-label="The short version">
  <div class="wrap"><dl class="facts__list">
    <div><dt>Drivers</dt><dd>18 and up</dd></div>
    <div><dt>Licence</dt><dd>G2 or G</dd></div>
    <div><dt>Booking length</dt><dd>1 to 30 days</dd></div>
    <div><dt>Delivery</dt><dd>$75 to $200 each way</dd></div>
    <div><dt>At request</dt><dd>No payment</dd></div>
  </dl></div>
</section>

<section class="section on-dark fleet-rail" aria-labelledby="h-fleet" data-rail>
  <div class="wrap section-head">
    <div><h2 class="d1" id="h-fleet">The fleet</h2><p class="lead muted">${CARS.length} cars, from ${money(minDaily)} a day. Every car has its own calendar, so what you see is what you can request.</p></div>
    <div class="row rail-ctrl"><button type="button" class="icon-btn" data-rail-prev aria-label="Previous cars">${icon('left')}</button><button type="button" class="icon-btn" data-rail-next aria-label="More cars">${icon('right')}</button></div>
  </div>
  <ul class="rail" tabindex="0" aria-label="Featured cars, scroll sideways">
    ${feat.map((c, i) => `<li>${carCard(c, { i })}</li>`).join('')}
    <li class="rail__end"><a href="fleet.html"><span class="d2">All ${CARS.length} cars</span><span class="link--go">Open the fleet ${icon('arrow')}</span></a></li>
  </ul>
  <div class="wrap"><div class="rail-progress" aria-hidden="true"><i></i></div></div>
</section>

<section class="section how" aria-labelledby="h-how">
  <div class="wrap grid">
    <div class="c-5 how__intro">
      <div class="how__sticky stack">
        <h2 class="d1" id="h-how">Request first. Pay once it’s confirmed.</h2>
        <p class="lead">Every booking starts as a request. Nobody takes your money until a person has checked the car and you have agreed to the price.</p>
        <p><a class="link link--go" href="how-it-works.html">The full walkthrough ${icon('arrow')}</a></p>
      </div>
    </div>
    <div class="c-7 how__steps">
      <span class="how__line fx-grow-y" aria-hidden="true"></span>
      <ol class="seq">${HOW_STEPS.map(([t, b, w]) => `<li><div><h3>${t}</h3><p>${b}</p><span class="seq__who">${w}</span></div></li>`).join('')}</ol>
    </div>
  </div>
</section>

<section class="band on-dark" aria-labelledby="h-deliv">
  <div class="band__media photo fx-drift">${slotPic('home.delivery')}</div>
  <div class="wrap band__inner">
    <div class="band__copy stack">
      <h2 class="d1" id="h-deliv">We bring it to you.</h2>
      <p class="lead">Home, office or hotel. Tell us the address in your request and we confirm it with your booking.</p>
      <dl class="band__facts"><div><dt>Delivery</dt><dd class="num">$75 to $200</dd></div><div><dt>Pickup at the end</dt><dd class="num">$75 to $200</dd></div></dl>
      <p class="small muted">The fee is set per car and shown on its page before you request.</p>
      <p><a class="btn btn--light" href="delivery.html">How delivery works</a></p>
    </div>
  </div>
</section>

<section class="section" aria-labelledby="h-req">
  <div class="wrap grid">
    <div class="c-6 stack-lg">
      <h2 class="d2" id="h-req">What you need to rent</h2>
      <table class="spec"><tbody>${REQUIREMENTS_ROWS.map(([k, v]) => `<tr><th scope="row">${k}</th><td>${v}</td></tr>`).join('')}</tbody></table>
      <p><a class="link link--go" href="requirements.html">Requirements in full ${icon('arrow')}</a></p>
    </div>
    <div class="c-5 s-8 stack-lg cover">
      <h2 class="d2" id="h-cov">Coverage, in plain terms</h2>
      <p>Third-party liability coverage is included in every rate. For damage to the car itself, you choose one of these before pickup.</p>
      <ol class="cover__opts">${COVERAGE_OPTIONS.map(([t, b], i) => `<li><span class="cover__n">Option ${i + 1}</span><h3>${t}</h3><p class="muted small">${b}</p></li>`).join('')}</ol>
      <p class="small">Damage under $2,500 is billed at cost. At $2,500 or more we claim on our fleet policy and you pay the $2,500 deductible.</p>
    </div>
  </div>
</section>

<section class="owner-band on-red" aria-labelledby="h-own">
  <div class="wrap owner-band__grid">
    <div class="stack">
      <h2 class="d1" id="h-own">Your car could be on this fleet.</h2>
      <p class="lead">Enrol it and we handle the renters, the handovers and the paperwork. It goes on our fleet insurance policy, and you are paid on the 10th of each month. No minimum term.</p>
      <p><a class="btn btn--light btn--lg" href="owners.html">List your car</a></p>
    </div>
    <div class="owner-band__media photo fx-wipe">${slotPic('home.owner', { sizes: '(min-width: 48rem) 50vw, 100vw' })}</div>
  </div>
</section>

<section class="section" aria-labelledby="h-rev">
  <div class="wrap grid">
    <div class="c-4"><h2 class="d2" id="h-rev">Reviews</h2></div>
    <div class="c-8">${reviewsBlock()}</div>
  </div>
</section>

<section class="section on-grey" aria-labelledby="h-faq">
  <div class="wrap grid">
    <div class="c-4 stack"><h2 class="d2" id="h-faq">Questions people ask first</h2><p><a class="link link--go" href="faq.html">All questions ${icon('arrow')}</a></p></div>
    <div class="c-8">${faq(HOME_FAQ)}</div>
  </div>
</section>`;
  return doc({
    file: 'index.html', title: 'CarmaCars | Car rental in Toronto, pickup or delivery', bodyClass: 'p-home',
    desc: `Rent a car in Toronto from ${money(minDaily)} a day. Request a car, get a confirmed price, then sign and pay online. Pickup or delivery. Drivers 18 and up with a G2 or G licence.`,
    main, ld: [{ '@type': 'AutoRental', '@id': SITE + '#org', name: 'CarmaCars', url: SITE, legalName: '18122211 Canada Inc.', areaServed: 'Toronto, Ontario', priceRange: '$$', email: 'info@carmacars.ca' }, { '@type': 'WebSite', url: SITE, name: 'CarmaCars' }, faqLd(HOME_FAQ)]
  });
}

// ---------------------------------------------------------------- fleet
export function fleet() {
  const classes = ['Economy', 'Standard', 'Premium', 'SUV', 'Luxury'];
  const maxP = Math.ceil(Math.max(...CARS.map((c) => c.rates.daily)) / 10) * 10;
  const trail = [['Home', 'index.html'], ['Fleet']];
  const main = `
<div data-page="fleet">
<section class="page-head on-dark">
  <div class="wrap">
    ${crumbs(trail)}
    <h1 class="d1">The fleet</h1>
    <p class="lead muted">${CARS.length} cars in and around Toronto. Add your dates to see what is free and what it costs for the whole trip.</p>
  </div>
</section>
<section class="fleet-bar" aria-label="Dates and sorting">
  <div class="wrap fleet-bar__in">
    <div class="field fleet-bar__dates">${dateRange({ id: 'fl' })}</div>
    ${timeSelect('tf', 'Pickup time', 'fl-tf', '10:00')}${timeSelect('tt', 'Return time', 'fl-tt', '10:00')}
    <div class="field fleet-bar__sort"><label class="label" for="fl-sort">Sort by</label><select class="select" id="fl-sort" name="sort"><option value="featured">Our order</option><option value="price-asc">Price, low to high</option><option value="price-desc">Price, high to low</option><option value="seats">Seats, most first</option><option value="name">Name, A to Z</option></select></div>
    <button type="button" class="btn btn--ghost fleet-bar__filters" data-filters-open aria-expanded="false" aria-controls="filter-panel">${icon('filter')}Filters<b></b></button>
  </div>
</section>
<section class="section--tight fleet-main">
  <div class="wrap fleet-layout">
    <aside class="filters" id="filter-panel" aria-label="Filters">
      <form id="filters">
        <div class="filters__head"><h2 class="d3">Filters</h2><button type="button" class="modal__close" data-filters-close aria-label="Close filters">×</button></div>
        <fieldset class="filters__group"><legend>Type</legend>
          ${classes.map((c) => `<label class="check"><input type="checkbox" name="cls" value="${c}"><span>${c} <span class="muted num">${CARS.filter((x) => x.cls === c).length}</span></span></label>`).join('')}
        </fieldset>
        <fieldset class="filters__group"><legend>Seats</legend>
          <div class="seg"><label><input type="radio" name="seats" value="any" checked>Any</label><label><input type="radio" name="seats" value="2">2</label><label><input type="radio" name="seats" value="5">5+</label><label><input type="radio" name="seats" value="7">7+</label></div>
        </fieldset>
        <fieldset class="filters__group"><legend>Transmission</legend>
          <div class="seg"><label><input type="radio" name="trans" value="any" checked>Any</label><label><input type="radio" name="trans" value="Automatic">Automatic</label><label><input type="radio" name="trans" value="Manual">Manual</label></div>
        </fieldset>
        <div class="filters__group"><label class="filters__legend" for="fl-max">Daily rate</label>
          <input class="range" type="range" id="fl-max" name="max" min="60" max="${maxP}" step="10" value="${maxP}" aria-describedby="fl-max-out"><p class="small strong num" id="fl-max-out" data-max-out>Any price</p>
        </div>
        <div class="filters__group">
          <label class="check"><input type="checkbox" name="young"><span>Open to drivers aged 18 to 20</span></label>
          <label class="check"><input type="checkbox" name="showBooked"><span>Also show cars booked for my dates</span></label>
        </div>
        <div class="filters__foot"><button type="button" class="btn btn--quiet" data-clear>Clear all</button><button type="button" class="btn btn--primary" data-filters-count>Show cars</button></div>
      </form>
    </aside>
    <div class="fleet-results">
      <div class="fleet-results__head"><p class="d3" data-fleet-count aria-live="polite">${CARS.length} cars</p><div class="chips" data-chips></div></div>
      <p class="alert" data-fleet-booked hidden><span></span> <button type="button" class="link" data-show-booked>Show them anyway</button></p>
      <ul class="fleet-grid fleet-grid--skeleton" data-fleet-skeleton hidden aria-hidden="true">${Array.from({ length: 6 }, () => `<li><div class="skeleton sk-img"></div><div class="skeleton sk-title"></div><div class="skeleton sk-line" style="width:40%"></div><div class="skeleton sk-line" style="width:80%"></div></li>`).join('')}</ul>
      <ul class="fleet-grid" id="fleet-grid">
        ${CARS.map((c, i) => `<li data-slug="${c.slug}" data-name="${esc(c.name)}" data-seats="${c.seats}" data-i="${i}">${carCard(c, { tag: 'h2' })}</li>`).join('')}
      </ul>
      <div class="empty" data-fleet-empty hidden>
        <p class="d2">No cars match.</p>
        <p class="muted measure">Nothing in the fleet fits every filter for those dates. Loosen a filter, or change the dates by a day or two.</p>
        <div class="row"><button type="button" class="btn" data-clear>Clear filters</button><button type="button" class="btn btn--ghost" data-clear-dates>Clear dates</button></div>
      </div>
      <p class="proto-note fleet-note"><b>Sample fleet.</b> Cars, rates and booked dates on this prototype are stand-ins.</p>
    </div>
  </div>
</section>
<section class="band band--short on-dark" aria-label="Delivery">
  <div class="band__media photo fx-drift">${slotPic('fleet.band')}</div>
  <div class="wrap band__inner"><div class="band__copy stack"><h2 class="d2">Tell us the trip. We’ll pick the car.</h2><p class="lead">How many people, how far, how long. We suggest a car and send a price.</p><p><a class="btn btn--light" href="contact.html">Ask us</a></p></div></div>
</section>
</div>`;
  return doc({
    file: 'fleet.html', title: `Cars to rent in Toronto: ${CARS.length} cars from ${money(minDaily)} a day | CarmaCars`, bodyClass: 'p-fleet',
    desc: `Browse the CarmaCars fleet in Toronto: economy cars, sedans, SUVs and luxury. Filter by type, seats, transmission and price, and check availability for your dates.`,
    main, ld: [crumbsLd(trail, 'fleet.html'), { '@type': 'ItemList', name: 'CarmaCars fleet', itemListElement: CARS.map((c, i) => ({ '@type': 'ListItem', position: i + 1, url: `${SITE}car-${c.slug}.html`, name: `${c.year} ${c.name}` })) }]
  });
}

// ---------------------------------------------------------------- car
function carFaq(c) {
  const ev = c.fuel === 'Electric';
  return [
    [`How much does it cost to rent the ${c.name}?`, `${money(c.rates.daily)} a day, or ${money(c.rates.weekend)} for a day that starts on a Friday or Saturday. A week is ${money(c.rates.weekly)} and 30 days is ${money(c.rates.monthly)}. Trips of 1 to 6 days never cost more than the weekly rate. HST and any fees are added on top.`],
    [`How much is the deposit for the ${c.name}?`, `${money(c.deposit)}. It is taken at pickup, not when you book. For rentals of 7 days or less it is a hold on your card. We release the balance within 7 business days after you return the car.`],
    [`How many kilometres are included?`, `${c.kmPerDay} km for each day of the rental, added together. A 3 day rental includes ${(c.kmPerDay * 3).toLocaleString('en-CA')} km. Extra kilometres cost ${money(c.overage)} each.`],
    [`Can a driver aged 18 to 20 rent the ${c.name}?`, c.young ? `Yes. This car is open to drivers aged 18 to 20, with a young driver fee of $35 a day, up to $350 per rental.` : `No. Drivers aged 18 to 20 can book the cars we mark for them, and this is not one. Drivers aged 21 to 25 can rent it with a young driver fee of $20 a day, up to $200 per rental. <a class="link" href="fleet.html?young=1">See cars open to ages 18 to 20</a>.`],
    [`Can you deliver the ${c.name}?`, `Yes. Delivery costs ${money(c.delivery)} for this car, and so does pickup at the end if you want it. Give us the address in your request and we confirm it with your booking.`],
    ev ? [`How does charging work?`, `Return the car with the same charge it had at pickup. If it comes back lower, recharging costs $10 for each 10% of battery, plus a $25 service fee. A mobile charging cable is in the car.`]
       : [`What is the fuel policy?`, `Return the car with the same fuel it had at pickup. If it comes back lower, we refuel it at the pump price plus 25%, plus a $25 service fee.`],
    [`Can I take the ${c.name} outside Ontario?`, `The car stays in Ontario unless we agree in writing first. Ask in your request and we will tell you before you pay.`]
  ];
}
export function carPage(c) {
  const shots = carShots(c.slug); const f = carFaq(c);
  const similar = CARS.filter((x) => x.slug !== c.slug).map((x) => ({ x, d: (x.cls === c.cls ? 0 : 60) + Math.abs(x.rates.daily - c.rates.daily) })).sort((a, b) => a.d - b.d).slice(0, 3).map((o) => o.x);
  const trail = [['Home', 'index.html'], ['Fleet', 'fleet.html'], [c.name]];
  const file = `car-${c.slug}.html`;
  const title = `Rent a ${c.year} ${c.name} in Toronto from ${money(c.rates.daily)} a day | CarmaCars`;
  const desc = `${c.year} ${c.name} ${c.trim} for rent in Toronto. ${money(c.rates.daily)} a day, ${money(c.rates.weekly)} a week. ${c.seats} seats, ${c.transmission.toLowerCase()}, ${c.kmPerDay} km a day included. Pickup or delivery. Request to book with no payment up front.`;
  const main = `
<div data-page="car" data-slug="${c.slug}">
<section class="car-top on-dark">
  <div class="wrap car-top__crumbs">${crumbs(trail)}</div>
  <div class="car-top__grid">
    <div class="gallery" aria-roledescription="carousel" aria-label="${esc(c.name)} photos">
      <ul class="gallery__track" tabindex="0" aria-label="Photos. Use the arrow keys to move between them.">
        ${shots.map((g, i) => `<li data-label="${esc(g.label)}" aria-label="${i + 1} of ${shots.length}">${carImg(c.slug, g.shot, { eager: i === 0, sizes: '(min-width: 64rem) 62vw, 100vw' })}</li>`).join('')}
      </ul>
      <div class="gallery__ui">
        <span class="gallery__count"><b class="num" data-gallery-count>1 / ${shots.length}</b> <span data-gallery-label>${shots[0].label}</span></span>
        <span class="row"><button type="button" class="icon-btn" data-gallery-prev aria-label="Previous photo">${icon('left')}</button><button type="button" class="icon-btn" data-gallery-next aria-label="Next photo">${icon('right')}</button></span>
      </div>
      <ul class="gallery__thumbs" aria-label="Choose a photo">
        ${shots.map((g, i) => `<li><button type="button" data-thumb="${i}" aria-label="Photo ${i + 1}: ${esc(g.label)}" aria-current="${i === 0}">${carImg(c.slug, g.shot, { alt: '', sizes: '120px' })}</button></li>`).join('')}
      </ul>
    </div>
    <div class="car-top__info">
      <p class="row">${plate(c.code, 'plate--dark')}<span class="small muted">${c.cls}, ${c.body.toLowerCase()}</span></p>
      <h1 class="d1 car-top__name"><span>${c.make}</span> ${c.model}</h1>
      <p class="lead muted">${c.year} ${c.trim}, ${c.colour}</p>
      <p class="car-top__blurb">${c.blurb}</p>
      <dl class="keyspecs">
        <div><dt>Seats</dt><dd class="num">${c.seats}</dd></div>
        <div><dt>Gearbox</dt><dd>${c.transmission === 'Automatic' ? 'Auto' : 'Manual'}</dd></div>
        <div><dt>${c.fuel === 'Electric' ? 'Power' : 'Fuel'}</dt><dd>${c.fuel === 'Electric' ? 'Electric' : 'Gas'}</dd></div>
        <div><dt>Km a day</dt><dd class="num">${c.kmPerDay}</dd></div>
      </dl>
      <div class="car-top__cta">
        <p class="car-top__price"><span class="small muted">From</span> <b class="num">${money(c.rates.daily)}</b> <span class="small muted">a day</span></p>
        <a class="btn btn--primary btn--lg" href="#dates" data-anchor-native>Check dates and price</a>
        <p class="small muted">Request to book. No payment until we confirm and you approve. A request does not hold the car.</p>
      </div>
      <span data-bar-sentinel></span>
    </div>
  </div>
</section>

<nav class="car-nav" aria-label="On this page"><div class="wrap"><ul><li><a href="#rates">Rates</a></li><li><a href="#dates">Dates and price</a></li><li><a href="#specs">Specs</a></li><li><a href="#need">Requirements</a></li><li><a href="#coverage">Coverage</a></li><li><a href="#delivery">Delivery</a></li><li><a href="#cancel">Cancelling</a></li><li><a href="#questions">Questions</a></li></ul></div></nav>

<div class="wrap car-body">
  <div class="car-body__main">
    <section id="rates" class="car-sec" aria-labelledby="h-rates">
      <h2 class="d2" id="h-rates">Rates</h2>
      <dl class="rates">
        <div><dt>Daily</dt><dd class="num">${money(c.rates.daily)}</dd><dd class="rates__n">Monday to Thursday, and Sunday</dd></div>
        <div><dt>Weekend day</dt><dd class="num">${money(c.rates.weekend)}</dd><dd class="rates__n">Days starting Friday or Saturday</dd></div>
        <div><dt>Weekly</dt><dd class="num">${money(c.rates.weekly)}</dd><dd class="rates__n">${money(Math.round(c.rates.weekly / 7 * 100) / 100)} a day for 7 to 29 days</dd></div>
        <div><dt>Monthly</dt><dd class="num">${money(c.rates.monthly)}</dd><dd class="rates__n">30 days, the longest single booking</dd></div>
      </dl>
      <p class="small muted measure">A day is 24 hours from your pickup time, and a part day counts as a day. Trips of 1 to 6 days are capped at the weekly rate, and 7 to 29 days at the monthly rate. Rates are before 13% HST.</p>
    </section>

    <section id="dates" class="car-sec" aria-labelledby="h-dates" data-booking>
      <h2 class="d2" id="h-dates">Dates and price</h2>
      <p class="alert alert--warn" data-date-clash hidden><span class="alert__title">Those dates are taken</span><span></span></p>
      <div class="booking">
        <div class="booking__cal">
          <div data-cal></div>
          <div class="field-row booking__times">${timeSelect('tf', 'Pickup time', 'car-tf', '10:00')}${timeSelect('tt', 'Return time', 'car-tt', '10:00')}</div>
          <div class="stack booking__opts">
            <label class="check"><input type="checkbox" name="deliver"><span>Deliver it to me <span class="muted num">+${money(c.delivery)}</span></span></label>
            <label class="check"><input type="checkbox" name="collect"><span>Pick it up from me at the end <span class="muted num">+${money(c.delivery)}</span></span></label>
            <div class="field"><label class="label" for="car-age">Driver’s age at pickup</label><select class="select" id="car-age" name="age"><option value="26+">26 or older</option><option value="21-25">21 to 25</option><option value="18-20">18 to 20</option></select></div>
            <p class="alert alert--error" data-age-note hidden><span class="alert__title">Not open to ages 18 to 20</span><span>The ${c.name} can be driven from age 21. <a class="link" href="fleet.html?young=1">See cars open to ages 18 to 20</a>.</span></p>
          </div>
        </div>
        <div class="booking__est">
          <h3 class="d4">Your estimate</h3>
          <div class="estimate" data-estimate aria-live="polite"></div>
          <a class="btn btn--primary btn--lg btn--block" href="request.html?car=${c.slug}" data-book><span data-book-label>Request to book</span></a>
          <p class="small muted booking__assure"><b>No payment now.</b> We confirm the car and send the final price as an offer, open for 24 hours. The car is booked only when you approve, sign and pay. If someone else pays for it first, we offer another car or other dates.</p>
        </div>
      </div>
    </section>

    <section id="specs" class="car-sec" aria-labelledby="h-specs">
      <h2 class="d2" id="h-specs">Specs</h2>
      <div class="grid specs-grid">
        <table class="spec c-6"><caption class="vh">Vehicle</caption><tbody>
          <tr><th scope="row">Model year</th><td>${c.year}</td></tr><tr><th scope="row">Trim</th><td>${c.trim}</td></tr><tr><th scope="row">Body</th><td>${c.body}</td></tr><tr><th scope="row">Colour</th><td>${c.colour}</td></tr><tr><th scope="row">Seats</th><td>${c.seats}</td></tr><tr><th scope="row">Doors</th><td>${c.doors}</td></tr>
        </tbody></table>
        <table class="spec c-6"><caption class="vh">Driving</caption><tbody>
          <tr><th scope="row">Transmission</th><td>${c.transmission}</td></tr><tr><th scope="row">Drive</th><td>${c.drive}</td></tr><tr><th scope="row">${c.fuel === 'Electric' ? 'Power' : 'Fuel'}</th><td>${c.fuel}</td></tr><tr><th scope="row">${c.fuel === 'Electric' ? 'Range' : 'Consumption'}</th><td>${c.l100}</td></tr><tr><th scope="row">Luggage</th><td>${c.bags} large ${c.bags === 1 ? 'bag' : 'bags'}</td></tr><tr><th scope="row">Rental class</th><td>${c.cls}</td></tr>
        </tbody></table>
      </div>
      <h3 class="d4 specs-feat">In this car</h3>
      <ul class="featlist">${c.features.map((x) => `<li>${x}</li>`).join('')}</ul>
      <p class="xs muted">Photos are representative. Colour, trim and features may differ.</p>
    </section>

    <section id="included" class="car-sec" aria-labelledby="h-inc">
      <h2 class="d2" id="h-inc">Kilometres and deposit</h2>
      <div class="twofacts">
        <div><p class="twofacts__n num">${c.kmPerDay} km</p><h3>included each day</h3><p class="muted small">Your allowance is ${c.kmPerDay} km times the days you book, used however you like across the trip. Past that it is ${money(c.overage)} a kilometre.</p></div>
        <div><p class="twofacts__n num">${money(c.deposit)}</p><h3>deposit at pickup</h3><p class="muted small">A card hold for rentals of 7 days or less, charged and refunded for longer ones. Not taken when you book. We release the balance within 7 business days after return.</p></div>
      </div>
    </section>

    <section id="need" class="car-sec" aria-labelledby="h-need">
      <h2 class="d2" id="h-need">What you need</h2>
      <table class="spec"><tbody>
        <tr><th scope="row">Age</th><td>${c.young ? '18 or older. This car is open to drivers aged 18 to 20.' : '21 or older for this car. Drivers aged 18 to 20 can book the cars marked for them.'}</td></tr>
        <tr><th scope="row">Licence</th><td>Ontario G2 or G, valid for the whole rental</td></tr>
        <tr><th scope="row">Card</th><td>A credit card in your name</td></tr>
        <tr><th scope="row">Young driver fee</th><td>${c.young ? '$35 a day for ages 18 to 20, up to $350. ' : ''}$20 a day for ages 21 to 25, up to $200</td></tr>
        <tr><th scope="row">Additional drivers</th><td>$10 a day each, up to $70. Each one meets the same rules and signs the agreement.</td></tr>
        <tr><th scope="row">At pickup</th><td>Your original licence and the card you paid with</td></tr>
      </tbody></table>
      <p><a class="link link--go" href="requirements.html">Requirements in full ${icon('arrow')}</a></p>
    </section>

    <section id="coverage" class="car-sec" aria-labelledby="h-cover">
      <h2 class="d2" id="h-cover">Coverage</h2>
      <p class="measure">Third-party liability coverage is included in the rate. For damage to the ${c.model} itself, have one of these in place before pickup.</p>
      <ol class="cover__opts cover__opts--row">${COVERAGE_OPTIONS.map(([t, b], i) => `<li><span class="cover__n">Option ${i + 1}</span><h3>${t}</h3><p class="muted small">${b}</p></li>`).join('')}</ol>
      <p class="small measure">If the car is damaged: under $2,500 you are billed the repair at cost. At $2,500 or more we claim on our fleet policy and you pay the $2,500 deductible. <a class="link" href="requirements.html#coverage">More on coverage</a>.</p>
    </section>

    <section id="delivery" class="car-sec" aria-labelledby="h-del">
      <h2 class="d2" id="h-del">Delivery</h2>
      <table class="spec"><tbody>
        <tr><th scope="row">Delivered to you</th><td class="num">${money(c.delivery)}</td></tr>
        <tr><th scope="row">Picked up from you at the end</th><td class="num">${money(c.delivery)}</td></tr>
        <tr><th scope="row">Collect it yourself</th><td>No charge. We confirm the place with your booking.</td></tr>
      </tbody></table>
      <p class="small muted measure">Whichever you choose, we hand the car to you in person, check your licence and card, and walk around the car together. <a class="link" href="delivery.html">How delivery works</a>.</p>
    </section>

    <section id="cancel" class="car-sec" aria-labelledby="h-can">
      <h2 class="d2" id="h-can">Cancelling</h2>
      <table class="spec spec--num"><tbody>
        <tr><th scope="row">Within 24 hours of booking, and 48 hours or more before pickup</th><td>95% back</td></tr>
        <tr><th scope="row">48 hours or more before pickup</th><td>75% back</td></tr>
        <tr><th scope="row">24 to 48 hours before pickup</th><td>50% back</td></tr>
        <tr><th scope="row">Less than 24 hours, or a no-show</th><td>No refund</td></tr>
      </tbody></table>
      <p class="small muted measure">The first row that fits applies. A non-refundable booking takes 10% off the rental charge and is not refunded if you cancel. If we cancel, you get everything back. <a class="link" href="cancellation.html">Cancellation policy</a>.</p>
    </section>

    <section id="questions" class="car-sec" aria-labelledby="h-q">
      <h2 class="d2" id="h-q">Questions about the ${c.model}</h2>
      ${faq(f)}
    </section>
  </div>
</div>

<section class="section on-grey" aria-labelledby="h-sim">
  <div class="wrap">
    <div class="section-head"><h2 class="d2" id="h-sim">Similar cars</h2><a class="link link--go" href="fleet.html">All ${CARS.length} cars ${icon('arrow')}</a></div>
    <ul class="fleet-grid fleet-grid--3">${similar.map((x) => `<li>${carCard(x)}</li>`).join('')}</ul>
  </div>
</section>
</div>`;
  const extra = `<div class="bookbar" role="region" aria-label="Request to book">
  <div class="wrap bookbar__in">
    <div class="bookbar__car"><b>${c.name}</b></div>
    <div class="bookbar__price"><b class="num" data-bar-price>From ${money(c.rates.daily)}</b><span class="xs muted" data-bar-sub>a day. Pick dates for a total</span></div>
    <a class="btn btn--quiet btn--sm bookbar__dates" href="#dates">Change dates</a>
    <a class="btn btn--primary" href="request.html?car=${c.slug}" data-book>Request to book</a>
  </div>
</div>`;
  const ld = [crumbsLd(trail, file), {
    '@type': ['Product', 'Car'], '@id': SITE + file + '#car', name: `${c.year} ${c.name} ${c.trim}`, description: c.blurb, url: SITE + file,
    brand: { '@type': 'Brand', name: c.make }, model: c.model, vehicleModelDate: String(c.year), vehicleConfiguration: c.trim, bodyType: c.body, color: c.colour,
    vehicleTransmission: c.transmission, driveWheelConfiguration: c.drive, fuelType: c.fuel, seatingCapacity: c.seats, numberOfDoors: c.doors,
    image: shots.slice(0, 5).map((g) => SITE + g.src),
    offers: { '@type': 'Offer', url: SITE + file, priceCurrency: 'CAD', price: c.rates.daily.toFixed(2), availability: 'https://schema.org/InStock', businessFunction: 'http://purl.org/goodrelations/v1#LeaseOut',
      priceSpecification: [['DAY', c.rates.daily], ['WEE', c.rates.weekly], ['MON', c.rates.monthly]].map(([u, p]) => ({ '@type': 'UnitPriceSpecification', price: p.toFixed(2), priceCurrency: 'CAD', unitCode: u, valueAddedTaxIncluded: false })),
      seller: { '@type': 'AutoRental', '@id': SITE + '#org', name: 'CarmaCars', url: SITE }, areaServed: 'Toronto, Ontario' }
  }, faqLd(f)];
  return doc({ file, title, desc, main, ld, extra, bodyClass: 'p-car' });
}
