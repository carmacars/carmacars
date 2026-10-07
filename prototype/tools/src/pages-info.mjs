// How it works, requirements and coverage, delivery, FAQ, legal pages.
import fs from 'node:fs';
import path from 'node:path';
import { CARS } from './data.mjs';
import { doc, slotPic, crumbs, crumbsLd, icon, money, faq, faqLd, esc, ROOT, EMAIL } from './layout.mjs';
import { HOW_STEPS, REQUIREMENTS_ROWS, COVERAGE_OPTIONS } from './pages-main.mjs';
import { OWNER_FAQ } from './pages-flow.mjs';

const head = (trail, h1, lead) => `<section class="page-head on-dark"><div class="wrap">${crumbs(trail)}<h1 class="d1">${h1}</h1><p class="lead muted">${lead}</p></div></section>`;
const cta = (h, p, btn = ['Find a car', 'fleet.html']) => `<section class="section--tight on-red cta-band"><div class="wrap cta-band__in"><div><h2 class="d2">${h}</h2><p class="lead">${p}</p></div><a class="btn btn--light btn--lg" href="${btn[1]}">${btn[0]}</a></div></section>`;

// ---------------------------------------------------------------- how it works
export function how() {
  const trail = [['Home', 'index.html'], ['How it works']];
  const detail = [
    ['What you tell us', ['The car, pickup and return dates and times', 'Collecting it yourself, or delivery to an address', 'The driver’s name, age and contact details', 'Licence class and which coverage option you plan to use']],
    ['What we check and send back', ['That the car is free and the trip is 30 days or less', 'The rental charge, delivery and pickup fees, any young driver or additional driver fee, extras and 13% HST', 'The deposit amount, shown separately because it is taken at pickup', 'Anything we need to adjust, and why']],
    ['What you do to confirm', ['Sign the rental agreement online and tick the four consents', 'Pay the total through our checkout with a credit card in your own name', 'Choose non-refundable if you want 10% off the rental charge']],
    ['What we need before pickup', ['A photo of each driver’s licence, front and back', 'A selfie of each driver holding their licence', 'Proof of your coverage option, or payment for coverage bought through us', 'All of it at least 24 hours before pickup']],
    ['What happens at handover', ['We hand the car only to the renter, in person', 'We check your original licence and the physical card you paid with', 'We take the deposit: a card hold for 7 days or less, a refundable charge for longer', 'We complete the condition report and photo set together, and you both sign it']]
  ];
  const main = `
${head(trail, 'Request, confirm, drive.', 'Booking a car here takes five steps. The first one costs nothing and the second one is on us.')}
<section class="section">
  <div class="wrap">
    <ol class="how-full">
      ${HOW_STEPS.map(([t, b, w], i) => `<li class="how-full__step">
        <div class="how-full__n" aria-hidden="true">${i + 1}</div>
        <div class="how-full__main stack"><h2 class="d2">${t}</h2><p class="lead">${b}</p><span class="seq__who">${w}</span></div>
        <div class="how-full__detail"><h3 class="small strong">${detail[i][0]}</h3><ul class="ticks">${detail[i][1].map((x) => `<li>${x}</li>`).join('')}</ul></div>
      </li>`).join('')}
    </ol>
  </div>
</section>
<section class="band on-dark" aria-labelledby="hw-ret">
  <div class="band__media photo fx-drift">${slotPic('how.handover')}</div>
  <div class="wrap band__inner"><div class="band__copy stack">
    <h2 class="d1" id="hw-ret">Bringing it back</h2>
    <p class="lead">Return the car on time, with the same fuel or charge, and all the keys. We inspect it with you and compare it with the pickup photos.</p>
    <dl class="band__facts"><div><dt>Deposit released</dt><dd>Within 7 business days</dd></div><div><dt>Grace period</dt><dd>30 minutes</dd></div></dl>
    <p class="small muted">Need it longer? Ask before your return time. An extension has to be confirmed in writing and paid before then.</p>
  </div></div>
</section>
<section class="section" aria-labelledby="hw-after">
  <div class="wrap grid">
    <div class="c-6 stack-lg">
      <h2 class="d2" id="hw-after">After the rental</h2>
      <table class="spec"><tbody>
        <tr><th scope="row">At return</th><td>We check kilometres, fuel or charge, cleanliness, keys and any new damage, with you there</td></tr>
        <tr><th scope="row">Within 48 hours</th><td>We tell you about any damage that could not be seen at return</td></tr>
        <tr><th scope="row">Within 7 business days</th><td>You get an itemized statement and the balance of your deposit</td></tr>
        <tr><th scope="row">Up to 30 days</th><td>We may hold back the amount expected for an open toll, ticket or claim, then apply or release it</td></tr>
        <tr><th scope="row">Later</th><td>Tolls and tickets that arrive afterwards are billed with a copy of the notice</td></tr>
      </tbody></table>
    </div>
    <div class="c-5 s-8 stack-lg">
      <h2 class="d2">What you agree to when you sign</h2>
      <p class="muted">Four consents sit beside the signature. Every box starts unticked.</p>
      <ol class="cover__opts">
        <li><h3>Tracking and disabling</h3><p class="muted small">Every car has a GPS tracker. It records location, speed and distance, not sound or video. A moving car is never disabled.</p></li>
        <li><h3>Identity verification</h3><p class="muted small">We check your licence against a live photo of your face. You can ask for a staff review instead of the automated match.</p></li>
        <li><h3>Electronic signature</h3><p class="muted small">You sign and receive the agreement and notices electronically.</p></li>
        <li><h3>Card authorization</h3><p class="muted small">We may hold or charge your card for the total, the deposit and later charges such as tolls.</p></li>
      </ol>
      <p class="small"><a class="link" href="privacy.html">How we handle your information</a></p>
    </div>
  </div>
</section>
${cta('Start with a request.', 'No card, no payment. Just the car and the dates.')}`;
  return doc({ file: 'how-it-works.html', title: 'How booking works | CarmaCars car rental, Toronto', desc: 'How to rent from CarmaCars: send a request, get a confirmed price, sign and pay online, verify your licence and coverage, then pick up or have the car delivered.', main, bodyClass: 'p-how', ld: [crumbsLd(trail, 'how-it-works.html'), { '@type': 'HowTo', name: 'How to rent a car from CarmaCars', step: HOW_STEPS.map(([t, b], i) => ({ '@type': 'HowToStep', position: i + 1, name: t, text: b })) }] });
}

// ---------------------------------------------------------------- requirements + coverage
export function requirements() {
  const trail = [['Home', 'index.html'], ['Requirements and coverage']];
  const young = CARS.filter((c) => c.young);
  const main = `
${head(trail, 'What you need, and how you’re covered.', 'The rules are short. Here they are in full, with the numbers.')}
<nav class="car-nav" aria-label="On this page"><div class="wrap"><ul><li><a href="#drivers">Drivers</a></li><li><a href="#coverage">Coverage</a></li><li><a href="#damage">Damage</a></li><li><a href="#deposit">Deposit</a></li><li><a href="#fees">Fees</a></li><li><a href="#rules">Rules of the road</a></li></ul></div></nav>
<section class="section" id="drivers" aria-labelledby="rq-d">
  <div class="wrap grid">
    <div class="c-4"><h2 class="d2" id="rq-d">Drivers</h2></div>
    <div class="c-8 stack-lg">
      <table class="spec"><tbody>${REQUIREMENTS_ROWS.slice(0, 3).map(([k, v]) => `<tr><th scope="row">${k}</th><td>${v}</td></tr>`).join('')}
        <tr><th scope="row">Identity check</th><td>Before pickup, each driver sends a photo of their licence, front and back, and a selfie holding it. If we cannot verify a driver, we refund what you paid.</td></tr>
        <tr><th scope="row">Additional drivers</th><td>$10 a day each, up to $70 per rental. Each one meets the same rules, is verified, and signs the agreement.</td></tr>
        <tr><th scope="row">At pickup</th><td>Your original licence and the physical card you paid with. We hand the car only to the renter, in person.</td></tr>
      </tbody></table>
      <div class="table-scroll" tabindex="0" role="region" aria-label="Young driver fees">
      <table class="data data--min"><caption>Young driver fees, by age at pickup</caption><thead><tr><th scope="col">Age</th><th scope="col">Which cars</th><th scope="col" class="r">Fee per day</th><th scope="col" class="r">Most per rental</th></tr></thead>
        <tbody><tr><td>18 to 20</td><td>Cars marked “Ages 18+”</td><td class="r">$35</td><td class="r">$350</td></tr><tr><td>21 to 25</td><td>Any car</td><td class="r">$20</td><td class="r">$200</td></tr><tr><td>26 and over</td><td>Any car</td><td class="r">None</td><td class="r">None</td></tr></tbody></table>
      </div>
      <p class="small">Open to ages 18 to 20 right now: ${young.map((c) => `<a class="link" href="car-${c.slug}.html">${c.name}</a>`).join(', ')}. <span class="muted">(Sample fleet.)</span></p>
    </div>
  </div>
</section>
<section class="section on-grey" id="coverage" aria-labelledby="rq-c">
  <div class="wrap grid">
    <div class="c-4 stack"><h2 class="d2" id="rq-c">Coverage</h2><p class="muted">Liability is included. Damage to the car is on you, so you need one of three options in place before we release it.</p></div>
    <div class="c-8 stack-lg">
      <div class="alert alert--ok"><span class="alert__title">Included in every rate</span><span>Third-party liability coverage at the minimum limits Ontario law requires, and basic 24-hour roadside assistance for mechanical breakdown. Liability coverage does not cover damage to the rental car or your belongings.</span></div>
      <div class="table-scroll" tabindex="0" role="region" aria-label="Coverage options compared">
      <table class="data cov-table"><thead><tr><th scope="col">Option</th><th scope="col">What it is</th><th scope="col">What we need from you</th><th scope="col">What we check</th></tr></thead><tbody>
        <tr><th scope="row">1. OPCF 27</th><td>Rental vehicle coverage on your own active auto policy</td><td>The policy page or an insurer letter showing OPCF 27</td><td>It is active to your return date and covers this car and every driver</td></tr>
        <tr><th scope="row">2. Credit card</th><td>Rental car coverage that comes with your credit card</td><td>The card’s benefits certificate</td><td>The same card pays for the rental, and the benefit covers this class of car and the length of the trip</td></tr>
        <tr><th scope="row">3. Through CarmaCars</th><td>Coverage you buy with your booking, supplied by a third-party provider on its own terms</td><td>Payment for it. We send the provider’s terms before you buy.</td><td>We activate it and confirm. The price is in your quote.</td></tr>
      </tbody></table></div>
      <p class="small muted measure">For options 1 and 2 it is your job to check that the coverage really applies to the car, the rental and every driver. No confirmed option at pickup counts as cancelling at that moment. CarmaCars is not an insurer.</p>
    </div>
  </div>
</section>
<section class="section" id="damage" aria-labelledby="rq-dm">
  <div class="wrap grid">
    <div class="c-4"><h2 class="d2" id="rq-dm">If the car is damaged</h2></div>
    <div class="c-8 stack-lg">
      <div class="twofacts">
        <div><p class="twofacts__n">Under $2,500</p><h3>billed at cost</h3><p class="muted small">You pay the repair estimate or invoice from our approved shop, plus towing, storage and loss of use if any, and a $50 administration fee.</p></div>
        <div><p class="twofacts__n">$2,500 or more</p><h3>you pay the deductible</h3><p class="muted small">We claim on our fleet policy and bill you the $2,500 deductible and a $75 administration fee. You then claim that back from your coverage option.</p></div>
      </div>
      <p class="measure">You are responsible for damage during your rental whoever is at fault, except mechanical failure you did not cause. The limit above does not apply if the insurer denies the claim because of an unapproved driver, impaired driving, a prohibited use or false information.</p>
      <h3 class="d4">After an accident, theft or vandalism</h3>
      <ol class="ticks ticks--n"><li>Call 911 if anyone is hurt. Report to police or a Collision Reporting Centre where the law requires, and always for theft.</li><li>Call our 24-hour line as soon as it is safe, and within 24 hours.</li><li>Get everyone’s details, take photos, and do not admit fault or settle.</li><li>Send us a written report, your photos and all the keys within 48 hours.</li></ol>
    </div>
  </div>
</section>
<section class="section on-grey" id="deposit" aria-labelledby="rq-dp">
  <div class="wrap grid">
    <div class="c-4"><h2 class="d2" id="rq-dp">Deposit</h2></div>
    <div class="c-8 stack-lg">
      <div class="table-scroll" tabindex="0" role="region" aria-label="Deposit by class">
      <table class="data"><thead><tr><th scope="col">Car class</th><th scope="col" class="r">Deposit</th><th scope="col">In the fleet</th></tr></thead><tbody>
        <tr><td>Economy and Standard</td><td class="r">$500</td><td>${CARS.filter((c) => c.deposit === 500).map((c) => c.model).join(', ')}</td></tr>
        <tr><td>Premium and SUV</td><td class="r">$1,000</td><td>${CARS.filter((c) => c.deposit === 1000).map((c) => c.model).join(', ')}</td></tr>
        <tr><td>Luxury and exotic</td><td class="r">$2,500</td><td>${CARS.filter((c) => c.deposit === 2500).map((c) => c.model).join(', ')}</td></tr>
      </tbody></table></div>
      <table class="spec"><tbody>
        <tr><th scope="row">When</th><td>At pickup, before handover. Never at request or booking.</td></tr>
        <tr><th scope="row">How</th><td>A card hold for rentals of 7 days or less. Charged, then refunded, for longer rentals.</td></tr>
        <tr><th scope="row">Back to you</th><td>The balance within 7 business days after you return the car</td></tr>
        <tr><th scope="row">Held back</th><td>Only the amount expected for an open toll, ticket or claim, for up to 30 days</td></tr>
        <tr><th scope="row">Worth knowing</th><td>The deposit secures what you owe. It is not a cap on it.</td></tr>
      </tbody></table>
    </div>
  </div>
</section>
<section class="section" id="fees" aria-labelledby="rq-f">
  <div class="wrap grid">
    <div class="c-4 stack"><h2 class="d2" id="rq-f">Fees you might meet</h2><p class="muted">Standard amounts, before HST. The amounts in your own rental agreement are the ones that apply.</p></div>
    <div class="c-8">
      <div class="table-scroll" tabindex="0" role="region" aria-label="Schedule of fees">
      <table class="data"><thead><tr><th scope="col">Fee</th><th scope="col">When</th><th scope="col" class="r">Amount</th></tr></thead><tbody>
        <tr><td>Delivery, pickup</td><td>Each way, if you choose it</td><td class="r">$75 to $200 by car</td></tr>
        <tr><td>Winter tires</td><td>On request</td><td class="r">$15 a day, up to $150</td></tr>
        <tr><td>Baby seat</td><td>Each seat</td><td class="r">$12 a day, up to $70</td></tr>
        <tr><td>Extra kilometres</td><td>Over your allowance</td><td class="r">$0.35 per km; $0.75 to $1.50 luxury</td></tr>
        <tr><td>Late return</td><td>More than 30 minutes late</td><td class="r">$25 an hour, plus the extra day</td></tr>
        <tr><td>Fuel</td><td>Less fuel than at pickup</td><td class="r">Pump price + 25%, + $25</td></tr>
        <tr><td>Recharging</td><td>Less charge than at pickup</td><td class="r">$10 per 10% of battery, + $25</td></tr>
        <tr><td>Cleaning</td><td>More than a standard clean</td><td class="r">$75; $250 if heavy</td></tr>
        <tr><td>Pet cleaning</td><td>Hair, odour or soiling</td><td class="r">$150</td></tr>
        <tr><td>Smoking</td><td>Evidence of smoking or vaping</td><td class="r">$300</td></tr>
        <tr><td>Lost key or fob</td><td>Each one</td><td class="r">Replacement cost + $50</td></tr>
        <tr><td>Tolls</td><td>Each toll invoice, on top of the toll</td><td class="r">$15</td></tr>
        <tr><td>Tickets, fines, towing, impound</td><td>Each item, on top of its amount</td><td class="r">$40</td></tr>
        <tr><td>Declined payment</td><td>Once per declined charge</td><td class="r">$40</td></tr>
      </tbody></table></div>
    </div>
  </div>
</section>
<section class="section on-dark" id="rules" aria-labelledby="rq-r">
  <div class="wrap grid">
    <div class="c-4"><h2 class="d2" id="rq-r">Rules of the road</h2></div>
    <div class="c-8"><table class="spec"><tbody>
      <tr><th scope="row">Where</th><td>The car stays in Ontario unless we agree in writing first</td></tr>
      <tr><th scope="row">Who drives</th><td>Only you and the additional drivers on the booking</td></tr>
      <tr><th scope="row">Not allowed</th><td>Ride-hailing or delivery work, re-renting, towing, racing or track use, driving off maintained roads</td></tr>
      <tr><th scope="row">Smoking and pets</th><td>No smoking or vaping. Pets need our approval first. Service animals are always welcome.</td></tr>
      <tr><th scope="row">Tracking</th><td>Every car has a GPS tracker that records location for the whole rental. The car’s owner can see its location too.</td></tr>
      <tr><th scope="row">Tolls and tickets</th><td>Yours to pay, including Highway 407 ETR</td></tr>
      <tr><th scope="row">Longest booking</th><td>30 days. To keep the car longer, you renew with a new booking before the current one ends.</td></tr>
    </tbody></table></div>
  </div>
</section>
${cta('Ready when you are.', 'Pick a car and send a request. We take it from there.')}`;
  return doc({ file: 'requirements.html', title: 'Rental requirements and coverage | CarmaCars, Toronto', desc: 'Who can rent from CarmaCars and how you are covered: age 18 and up, Ontario G2 or G licence, three coverage options, deposits from $500 taken at pickup, and the full fee list.', main, bodyClass: 'p-req', ld: [crumbsLd(trail, 'requirements.html')] });
}

// ---------------------------------------------------------------- delivery
export function delivery() {
  const trail = [['Home', 'index.html'], ['Delivery']];
  const groups = [...new Set(CARS.map((c) => c.delivery))].sort((a, b) => a - b);
  const main = `
<section class="band band--hero on-dark">
  <div class="band__media photo fx-drift">${slotPic('delivery.hero', { eager: true })}</div>
  <div class="wrap band__inner"><div class="band__copy stack">${crumbs(trail)}<h1 class="d1">The car comes to you.</h1><p class="lead">We deliver to homes, offices and hotels, and we can collect the car at the end. Each way costs $75 to $200, set per car.</p><p><a class="btn btn--primary btn--lg" href="fleet.html?mode=delivery">Find a car for delivery</a></p></div></div>
</section>
<section class="section" aria-labelledby="dl-how">
  <div class="wrap grid">
    <div class="c-5"><div class="how__sticky stack"><h2 class="d1" id="dl-how">How delivery works</h2><p class="lead">The same handover as collecting it yourself, at your door.</p></div></div>
    <div class="c-7 how__steps"><span class="how__line fx-grow-y" aria-hidden="true"></span>
      <ol class="seq">
        <li><div><h3>Add your address to the request</h3><p>Tick delivery, pickup at the end, or both. We confirm the address and the time with your booking.</p></div></li>
        <li><div><h3>We message you the day before</h3><p>A reminder with the time, the place and what to bring: your original licence and the card you paid with.</p></div></li>
        <li><div><h3>Handover at your door</h3><p>We take the deposit, check your licence and card, then walk around the car with you and photograph it. You both sign the condition report.</p></div></li>
        <li><div><h3>At the end, we come back</h3><p>If you chose pickup, meet our driver with the car and all the keys. The return inspection happens there, with you.</p></div></li>
      </ol>
    </div>
  </div>
</section>
<section class="section on-grey" aria-labelledby="dl-fee">
  <div class="wrap grid">
    <div class="c-4 stack"><h2 class="d2" id="dl-fee">What it costs</h2><p class="muted">One fee for delivery, the same again for pickup at the end. Before HST. Collecting and returning the car yourself is free.</p></div>
    <div class="c-8 stack-lg">
      <div class="table-scroll" tabindex="0" role="region" aria-label="Delivery fee by car">
      <table class="data"><thead><tr><th scope="col">Each way</th><th scope="col">Cars</th></tr></thead><tbody>
        ${groups.map((g) => `<tr><td class="num strong">${money(g)}</td><td>${CARS.filter((c) => c.delivery === g).map((c) => `<a class="link" href="car-${c.slug}.html">${c.name}</a>`).join(', ')}</td></tr>`).join('')}
      </tbody></table></div>
      <p class="proto-note"><b>Sample fees.</b> Real fees are set per car between $75 and $200.</p>
      <table class="spec"><tbody>
        <tr><th scope="row">Who receives the car</th><td>The renter, in person. We cannot leave a car with someone else.</td></tr>
        <tr><th scope="row">Where</th><td>Tell us the address in your request. We confirm whether we can deliver there before you pay.</td></tr>
        <tr><th scope="row">Cancelling</th><td>Delivery and pickup fees are refunded on the same tiers as the rest of the booking</td></tr>
        <tr><th scope="row">Leaving it somewhere else</th><td>A car left anywhere other than the agreed place has not been returned</td></tr>
      </tbody></table>
    </div>
  </div>
</section>
${cta('Delivery is one tick in the request.', 'Pick the car first. The delivery fee is on its page.')}`;
  return doc({ file: 'delivery.html', title: 'Car rental delivery in Toronto | CarmaCars', desc: 'CarmaCars delivers rental cars to your home, office or hotel in the Toronto area and can pick them up at the end. $75 to $200 each way depending on the car.', main, bodyClass: 'p-delivery', ld: [crumbsLd(trail, 'delivery.html')] });
}

// ---------------------------------------------------------------- FAQ
export function faqPage() {
  const trail = [['Home', 'index.html'], ['FAQ']];
  const G = [
    ['Booking', 'booking', [
      ['How does request to book work?', 'You send a request with the car and dates. A person checks it and sends back the full price. If you approve, you sign the rental agreement online and pay. That is when the booking is confirmed. <a class="link" href="how-it-works.html">See every step</a>.'],
      ['Do I pay anything when I send a request?', 'No. No card, no payment, no hold. You pay only after we confirm the car and the price and you approve.'],
      ['How fast will I hear back?', 'Our target is 15 minutes during opening hours. Requests sent outside opening hours are answered when we reopen.'],
      ['Is the price on the car’s page the final price?', 'It is an estimate built from that car’s real rates and the standard fees. The confirmed price we send you is the one that counts. You see the total with HST, the deposit and the agreement before you pay.'],
      ['How are multi-day prices worked out?', 'A day is 24 hours from your pickup time, and a part day counts as a day. For 1 to 6 days, each day costs the daily rate, or the weekend rate if it starts on a Friday or Saturday, and the total never exceeds the weekly rate. For 7 to 29 days, each day costs one-seventh of the weekly rate, never more than the monthly rate. 30 days is the monthly rate.'],
      ['What is the longest I can rent for?', '30 days in one booking. To keep the car longer, you make a new booking and sign a new agreement before the current one ends.'],
      ['Can I extend once I have the car?', 'Ask before your return time. An extension counts only when we confirm it in writing and you have paid for it. The whole booking is repriced at its new length and you pay the difference.']
    ]],
    ['Drivers and licences', 'drivers', [
      ['How old do I have to be?', '18 or older at pickup. Drivers aged 18 to 20 can book the cars we mark “Ages 18+”. From 21 you can book any car.'],
      ['Is there a young driver fee?', 'Yes. $35 a day for ages 18 to 20, up to $350 per rental. $20 a day for ages 21 to 25, up to $200 per rental.'],
      ['Can I rent with a G2?', 'Yes. We accept Ontario G2 and G licences. The licence has to be valid for the whole rental.'],
      ['I have a licence from outside Ontario. Can I rent?', 'Possibly. Other licences are reviewed by a person before we confirm. Choose “Something else” in the request and we will tell you.'],
      ['Can someone else drive too?', 'Yes, as an additional driver: $10 a day, up to $70 per rental. They meet the same age and licence rules, pass the identity check and sign the agreement.'],
      ['How do you verify my identity?', 'Each driver sends a photo of their licence, front and back, and a selfie holding it. We need this at least 24 hours before pickup. If we cannot verify a driver, we refund what you paid.']
    ]],
    ['Coverage and damage', 'coverage', [
      ['Is insurance included?', 'Third-party liability coverage is included in every rate, at the minimum limits Ontario law requires. It does not cover damage to the rental car.'],
      ['What coverage do I need for the car itself?', 'One of three: OPCF 27 on your own auto policy, rental coverage on your credit card (with the rental paid on that card), or coverage bought through CarmaCars. <a class="link" href="requirements.html#coverage">Compare them</a>.'],
      ['What is OPCF 27?', 'An endorsement on an Ontario auto policy that extends your coverage to vehicles you rent. Your insurer or broker can tell you if you have it and send you proof.'],
      ['What do I pay if the car is damaged?', 'If the damage costs under $2,500, you pay the repair at cost plus a $50 administration fee. If it costs $2,500 or more, we claim on our fleet policy and you pay the $2,500 deductible plus a $75 administration fee. Your coverage option is how you recover that.'],
      ['What if the car breaks down?', 'Call our 24-hour line. Roadside assistance for mechanical breakdown is included. If the breakdown is not your fault, we give you a replacement car or refund the unused time.']
    ]],
    ['Payment and deposit', 'payment', [
      ['How do I pay?', 'Through our online checkout, with a credit card in the renter’s own name. That card stays on file for the rental.'],
      ['How much is the deposit?', '$500 for economy and standard cars, $1,000 for premium cars and SUVs, and $2,500 for luxury cars. Each car’s page shows its own.'],
      ['When is the deposit taken?', 'At pickup, before handover. For rentals of 7 days or less it is a hold on your card. For longer rentals it is charged and later refunded.'],
      ['When do I get the deposit back?', 'We release the balance within 7 business days after you return the car. If a toll, ticket or claim is still open, we can hold back the amount we expect it to cost for up to 30 days.'],
      ['Are prices before or after tax?', 'Rates and fees are shown before 13% HST. Your estimate and your confirmed price show the HST and the total.']
    ]],
    ['Delivery, pickup and return', 'delivery', [
      ['Do you deliver?', 'Yes. Delivery and pickup each cost $75 to $200 depending on the car. <a class="link" href="delivery.html">How delivery works</a>.'],
      ['What do I bring to pickup?', 'Your original licence and the physical card you paid with. We hand the car only to the renter, in person.'],
      ['What if I am late bringing it back?', 'There is a 30 minute grace period. After that you owe the rental charge for each extra day or part day, plus a late fee of $25 an hour counted from the return time. If you know you will be late, ask for an extension first.'],
      ['Do I need to refuel or recharge?', 'Return it with the same level it had at pickup. Otherwise we refuel at the pump price plus 25%, or recharge at $10 per 10% of battery, plus a $25 service fee either way.']
    ]],
    ['On the road', 'road', [
      ['How many kilometres can I drive?', 'Each car has a daily allowance, shown on its page, multiplied by the days you book. Extra kilometres cost $0.35 each, or $0.75 to $1.50 for luxury cars.'],
      ['Can I leave Ontario?', 'Only with our written consent. Ask in your request.'],
      ['Can I bring a pet?', 'With our approval, yes. Mention it in the request. Service animals do not need approval. A pet cleaning fee of $150 applies if the car comes back with hair, odour or soiling.'],
      ['Can I smoke or vape in the car?', 'No. A $300 fee applies if there is evidence of it.'],
      ['Who pays tolls and tickets?', 'You do, including Highway 407 ETR. If one reaches us, we pay it and charge you the amount plus $15 per toll invoice or $40 per ticket, with a copy of the notice.'],
      ['Are the cars tracked?', 'Yes. Every car has a GPS tracker that records location, speed and distance for the whole rental. It does not record sound or video. The car’s owner can see its location. <a class="link" href="privacy.html#tracking">Read how tracking works</a>.']
    ]],
    ['Cancelling', 'cancelling', [
      ['What is the cancellation policy?', '95% back if you cancel within 24 hours of booking and 48 hours or more before pickup. 75% back at 48 hours or more. 50% between 24 and 48 hours. Nothing inside 24 hours or for a no-show. <a class="link" href="cancellation.html">Full policy</a>.'],
      ['What is a non-refundable booking?', 'You take 10% off the rental charge and give up the refund if you cancel, miss pickup or return early. If we cancel, you still get everything back.'],
      ['What if CarmaCars cancels?', 'If we cannot supply the car you booked or a comparable one you accept, we refund everything you paid.'],
      ['Do I get money back if I return early?', 'No. Returning early earns no refund.']
    ]],
    ['Owners', 'owners', OWNER_FAQ.slice(0, 5)]
  ];
  const all = G.flatMap((g) => g[2]);
  const main = `
${head(trail, 'Straight answers.', `${all.length} questions, sorted by topic. Type a word to narrow them down.`)}
<section class="section">
  <div class="wrap grid">
    <aside class="c-4">
      <div class="how__sticky stack-lg">
        <div class="field"><label class="label" for="faq-q">Search the answers</label><input class="input" id="faq-q" type="search" data-faq-filter placeholder="deposit, G2, delivery" autocomplete="off"><p class="hint" data-faq-count aria-live="polite"></p></div>
        <nav aria-label="Topics"><ul class="toc">${G.map(([t, id, q]) => `<li><a href="#${id}">${t}<span class="num muted">${q.length}</span></a></li>`).join('')}</ul></nav>
      </div>
    </aside>
    <div class="c-8 stack-lg">
      ${G.map(([t, id, q]) => `<section id="${id}" data-faq-group aria-labelledby="fq-${id}" class="stack"><h2 class="d3" id="fq-${id}">${t}</h2>${faq(q)}</section>`).join('')}
      <div class="empty" data-faq-none hidden><p class="d3">Nothing matches that.</p><p class="muted">Try one word, like “deposit”. Or <a class="link" href="contact.html">ask us directly</a>.</p></div>
    </div>
  </div>
</section>
${cta('Ask a person.', 'We would rather answer now than surprise you later.', ['Contact us', 'contact.html'])}`;
  return doc({ file: 'faq.html', title: 'FAQ: renting a car from CarmaCars in Toronto', desc: 'Answers about booking, age and licence rules, coverage, deposits, delivery, kilometres, tolls, cancelling and listing your car with CarmaCars.', main, bodyClass: 'p-faq', ld: [crumbsLd(trail, 'faq.html'), faqLd(all)] });
}

// ---------------------------------------------------------------- legal (rendered from docs/source)
function md(src) {
  const inline = (s) => esc(s)
    .replace(/\[●\]/g, '<span class="tbc">to be added</span>')
    .replace(/\*\*(.+?)\*\*/g, '<strong>$1</strong>')
    .replace(/\[([^\]]+)\]\((https?:[^)]+)\)/g, '<a class="link" href="$2" rel="noopener">$1</a>')
    .replace(/priv\.gc\.ca/g, '<a class="link" href="https://www.priv.gc.ca/" rel="noopener">priv.gc.ca</a>')
    .replace(/ \u2013 /g, ': ').replace(/[\u2013\u2014]/g, '-');
  const lines = src.split('\n'); let out = ''; let i = 0; const slug = (s) => s.toLowerCase().replace(/^\d+\.\s*/, '').replace(/[^a-z0-9]+/g, '-').replace(/^-|-$/g, '');
  while (i < lines.length) {
    const l = lines[i];
    if (!l.trim()) { i++; continue; }
    if (/^### /.test(l)) { const t = l.slice(4); out += `<h2 class="d4" id="${slug(t)}">${inline(t)}</h2>`; i++; continue; }
    if (/^\|/.test(l)) {
      const rows = []; while (i < lines.length && /^\|/.test(lines[i])) { rows.push(lines[i].split('|').slice(1, -1).map((c) => c.trim())); i++; }
      const [h, , ...body] = rows;
      out += `<div class="table-scroll" tabindex="0" role="region" aria-label="Table"><table class="data"><thead><tr>${h.map((c) => `<th scope="col">${inline(c)}</th>`).join('')}</tr></thead><tbody>${body.map((r) => `<tr>${r.map((c, j) => j === 0 ? `<th scope="row">${inline(c)}</th>` : `<td>${inline(c)}</td>`).join('')}</tr>`).join('')}</tbody></table></div>`; continue;
    }
    if (/^- /.test(l)) { out += '<ul>'; while (i < lines.length && /^- /.test(lines[i])) { out += `<li>${inline(lines[i].slice(2))}</li>`; i++; } out += '</ul>'; continue; }
    const m = l.match(/^\*\*(\d+)\. (.+?)\.\*\*\s*(.*)$/);
    if (m) { out += `<h2 class="d4" id="s${m[1]}">${m[1]}. ${inline(m[2])}</h2>${m[3] ? `<p>${inline(m[3])}</p>` : ''}`; i++; continue; }
    out += `<p>${inline(l)}</p>`; i++;
  }
  return out;
}
function legalParts() {
  const src = fs.readFileSync(path.join(ROOT, '../docs/source/website_terms_policies.md'), 'utf8').split('\n---')[0];
  const parts = src.split(/^## Part \d . .+$/m).slice(1);
  return { terms: parts[0], privacy: parts[1], cancel: parts[2] };
}
const legalDoc = ({ file, title, desc, h1, lead, body, toc, extraTop = '' }) => {
  const trail = [['Home', 'index.html'], [h1]];
  const heads = [...body.matchAll(/<h2 class="d4" id="([^"]+)">(.*?)<\/h2>/g)].map((m) => [m[1], m[2].replace(/<[^>]+>/g, '')]);
  const main = `
${head(trail, h1, lead)}
<section class="section">
  <div class="wrap grid">
    <aside class="c-4"><div class="how__sticky stack-lg">
      <p class="alert alert--warn"><span class="alert__title">Draft for legal review</span><span>This text is the working draft of October 6, 2026. Hatched blanks are filled in before launch.</span></p>
      ${toc !== false && heads.length ? `<nav aria-label="Sections"><ul class="toc">${heads.map(([id, t]) => `<li><a href="#${id}">${t}</a></li>`).join('')}</ul></nav>` : ''}
      <ul class="toc toc--plain"><li><a href="terms.html">Terms of use</a></li><li><a href="privacy.html">Privacy policy</a></li><li><a href="cancellation.html">Cancellation policy</a></li></ul>
    </div></aside>
    <article class="c-8 prose">${extraTop}${body}</article>
  </div>
</section>`;
  return doc({ file, title, desc, main, bodyClass: 'p-legal', ld: [crumbsLd(trail, file)] });
};
export function terms() { const p = legalParts(); return legalDoc({ file: 'terms.html', title: 'Terms of use | CarmaCars', desc: 'The terms that apply to everyone who uses carmacars.ca and its renter, owner and staff portals.', h1: 'Terms of use', lead: 'The rules for using this site. Each rental is governed by the rental agreement you sign for it.', body: md(p.terms) }); }
export function privacy() { const p = legalParts(); return legalDoc({ file: 'privacy.html', title: 'Privacy policy | CarmaCars', desc: 'What personal information CarmaCars collects, why, who it is shared with, how long it is kept, and how GPS tracking works during a rental.', h1: 'Privacy policy', lead: 'What we collect, why we need it, and what you can ask us to do with it.', body: md(p.privacy) }); }
export function cancellation() {
  const p = legalParts();
  const ex = `<h2 class="d4" id="examples">Worked examples</h2><p>A booking with a $600 rental charge and $78 HST, $678 paid.</p>
  <div class="table-scroll" tabindex="0" role="region" aria-label="Worked examples"><table class="data"><thead><tr><th scope="col">What happened</th><th scope="col">Tier</th><th scope="col" class="r">Refund</th><th scope="col" class="r">Kept</th></tr></thead><tbody>
  <tr><th scope="row">Booked 10 days ahead, cancelled 5 hours after booking</th><td>95%</td><td class="r">$644.10</td><td class="r">$33.90</td></tr>
  <tr><th scope="row">Cancelled 3 days before pickup</th><td>75%</td><td class="r">$508.50</td><td class="r">$169.50</td></tr>
  <tr><th scope="row">Booked 30 hours before pickup, cancelled 1 hour later</th><td>50%</td><td class="r">$339.00</td><td class="r">$339.00</td></tr></tbody></table></div>`;
  let body = md(p.cancel); const cut = body.indexOf('<ul>'); body = body.slice(0, cut) + '<h2 class="d4" id="details">The details</h2>' + body.slice(cut);
  body = body.replace('<p>This policy does not limit', ex + '<p>This policy does not limit').replace('<div class="table-scroll"', '<h2 class="d4" id="tiers">Refund by timing</h2><div class="table-scroll"');
  return legalDoc({ file: 'cancellation.html', title: 'Cancellation and refund policy | CarmaCars', desc: 'CarmaCars refunds by timing: 95% within 24 hours of booking, 75% at 48 hours or more before pickup, 50% between 24 and 48 hours, none inside 24 hours.', h1: 'Cancellation policy', lead: 'Your refund depends on when we receive your cancellation. Four tiers, first match wins.', body });
}
