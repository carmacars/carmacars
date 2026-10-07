// Request to book, confirmation, owner program, sign in, contact, 404.
import { CARS } from './data.mjs';
import { doc, slotPic, crumbs, crumbsLd, timeSelect, icon, money, faq, faqLd, EMAIL } from './layout.mjs';

const MONTHS = ['January', 'February', 'March', 'April', 'May', 'June', 'July', 'August', 'September', 'October', 'November', 'December'];
const field = ({ id, label, name = id, type = 'text', v = 'required', auto = '', hint = '', opt = false, attrs = '', msg = '' }) =>
  `<div class="field"><label class="label" for="${id}">${label}${opt ? ' <span class="opt">optional</span>' : ''}</label><input class="input" id="${id}" name="${name}" type="${type}" ${auto ? `autocomplete="${auto}"` : ''} ${v ? `data-v="${v}"` : ''} ${msg ? `data-msg="${msg}"` : ''} ${attrs}>${hint ? `<p class="hint">${hint}</p>` : ''}<p class="error" role="alert"></p></div>`;

// ---------------------------------------------------------------- request
export function request() {
  const main = `
<div data-page="request" class="req">
  <div class="wrap req__head">
    <p class="small muted"><a class="link" href="fleet.html">Fleet</a> / Request to book</p>
    <h1 class="d2">Request to book</h1>
    <p class="req__assure"><b>No payment and no card at this stage.</b> We confirm the car and the price first.</p>
    <ol class="steps" aria-label="Progress">
      <li data-label="Dates"><b>Dates</b><span> and delivery</span></li>
      <li data-label="Driver"><b>Driver</b><span> details</span></li>
      <li data-label="Licence"><b>Licence</b><span> and coverage</span></li>
      <li data-label="Review"><b>Review</b><span> and send</span></li>
    </ol>
    <p class="req__meta small"><span class="strong" data-step-count>Step 1 of 4</span><span class="muted" data-saved hidden>Saved on this device</span><button type="button" class="link" data-reset>Start over</button></p>
    <p class="alert alert--ok" data-restored hidden><span class="alert__title">We kept your place</span><span>Your earlier answers are filled in. Change anything you like.</span></p>
  </div>

  <div class="wrap req__layout">
    <form id="request" class="req__form" novalidate aria-label="Request to book">
      <!-- STEP 1 -->
      <section data-step="1" class="req__step stack-lg" aria-labelledby="rs1">
        <h2 class="d3" id="rs1">When do you need it?</h2>
        <div class="field"><label class="label" for="rq-car">Car</label>
          <select class="select" id="rq-car" name="car" data-v="required" data-msg="Choose a car.">
            <option value="">Choose a car</option>${CARS.map((c) => `<option value="${c.slug}">${c.name}, from ${money(c.rates.daily)} a day</option>`).join('')}
          </select><p class="error" role="alert"></p></div>
        <div class="field" data-dates-field>
          <span class="label">Pickup and return dates</span>
          <p class="hint">Tap the pickup date, then the return date. Hatched days are already booked. One booking covers up to 30 days.</p>
          <div class="req__cal" data-cal></div>
          <p class="error" role="alert"></p>
        </div>
        <div class="field-row">${timeSelect('tf', 'Pickup time', 'rq-tf', '10:00')}${timeSelect('tt', 'Return time', 'rq-tt', '10:00')}</div>
        <fieldset class="stack"><legend class="label">Pickup or delivery</legend>
          <label class="option"><input type="checkbox" name="deliver"><span class="option__title">Deliver the car to me <span class="muted num">+<span data-car-fee>$75 to $200</span></span></span><span class="option__body">We bring it to your home, office or hotel and hand it over in person.</span></label>
          <div data-addr-deliver hidden>${field({ id: 'rq-addr1', name: 'addrDeliver', label: 'Delivery address', auto: 'street-address', msg: 'Add the delivery address so we can confirm it.', hint: 'Street address and city. We confirm it with your booking.' })}</div>
          <label class="option"><input type="checkbox" name="collect"><span class="option__title">Pick it up from me at the end <span class="muted num">+<span data-car-fee>$75 to $200</span></span></span><span class="option__body">Leave it with our driver instead of bringing it back.</span></label>
          <div data-addr-collect hidden>${field({ id: 'rq-addr2', name: 'addrCollect', label: 'Pickup address', v: '', opt: true, hint: 'Leave empty if it is the same as the delivery address.' })}</div>
          <p class="hint">Neither ticked? You collect and return the car yourself at no charge. We confirm the place with your booking.</p>
        </fieldset>
        <div class="req__nav"><span></span><button type="button" class="btn btn--primary btn--lg" data-next>Continue to driver details</button></div>
      </section>

      <!-- STEP 2 -->
      <section data-step="2" class="req__step stack-lg" aria-labelledby="rs2" hidden>
        <h2 class="d3" id="rs2">Who is driving?</h2>
        <div class="field-row">${field({ id: 'rq-first', name: 'first', label: 'First name', auto: 'given-name', msg: 'Enter your first name as it appears on your licence.' })}${field({ id: 'rq-last', name: 'last', label: 'Last name', auto: 'family-name', msg: 'Enter your last name as it appears on your licence.' })}</div>
        <div class="field-row">${field({ id: 'rq-email', name: 'email', label: 'Email', type: 'email', v: 'required email', auto: 'email', hint: 'We send the confirmed price here.', msg: 'Enter your email so we can send the price.' })}${field({ id: 'rq-phone', name: 'phone', label: 'Mobile number', type: 'tel', v: 'required phone', auto: 'tel', hint: 'For questions about this request only.', msg: 'Enter a mobile number we can reach you on.' })}</div>
        <fieldset class="field" data-dob-field><legend class="label">Date of birth</legend>
          <p class="hint">Drivers must be 18 or older at pickup. Age sets the young driver fee.</p>
          <div class="dob">
            <div><label class="xs muted" for="rq-dobm">Month</label><select class="select" id="rq-dobm" name="dobM" autocomplete="bday-month"><option value="">Month</option>${MONTHS.map((m, i) => `<option value="${i + 1}">${m}</option>`).join('')}</select></div>
            <div><label class="xs muted" for="rq-dobd">Day</label><input class="input" id="rq-dobd" name="dobD" inputmode="numeric" maxlength="2" placeholder="DD" autocomplete="bday-day"></div>
            <div><label class="xs muted" for="rq-doby">Year</label><input class="input" id="rq-doby" name="dobY" inputmode="numeric" maxlength="4" placeholder="YYYY" autocomplete="bday-year"></div>
          </div>
          <p class="error" role="alert"></p>
        </fieldset>
        <div class="field"><span class="label" id="rq-add-l">Additional drivers</span><p class="hint">$10 a day each, up to $70 per rental. Each one needs a G2 or G licence and signs the agreement.</p>
          <div class="qty" data-min="0" data-max="3"><button type="button" aria-label="Fewer additional drivers">−</button><output aria-labelledby="rq-add-l">0</output><button type="button" aria-label="More additional drivers">+</button><input type="hidden" name="addDrivers" value="0"></div></div>
        ${field({ id: 'rq-ref', name: 'referrer', label: 'Did someone refer you?', v: '', opt: true, hint: 'Their name, if so.' })}
        <div class="req__nav"><button type="button" class="btn btn--ghost" data-back>Back</button><button type="button" class="btn btn--primary btn--lg" data-next>Continue to licence</button></div>
      </section>

      <!-- STEP 3 -->
      <section data-step="3" class="req__step stack-lg" aria-labelledby="rs3" hidden>
        <h2 class="d3" id="rs3">Licence and coverage</h2>
        <fieldset class="field" data-lic-field><legend class="label">Licence class</legend>
          <div class="seg"><label><input type="radio" name="licClass" value="G">Ontario G</label><label><input type="radio" name="licClass" value="G2">Ontario G2</label><label><input type="radio" name="licClass" value="other">Something else</label></div>
          <p class="hint">Licences from outside Ontario are reviewed by a person before we confirm.</p><p class="error" role="alert"></p>
        </fieldset>
        <fieldset class="field" data-licexp-field><legend class="label">Licence expiry</legend>
          <div class="dob dob--2"><div><label class="xs muted" for="rq-licm">Month</label><select class="select" id="rq-licm" name="licM"><option value="">Month</option>${MONTHS.map((m, i) => `<option value="${i + 1}">${m}</option>`).join('')}</select></div>
          <div><label class="xs muted" for="rq-licy">Year</label><select class="select" id="rq-licy" name="licY"><option value="">Year</option>${Array.from({ length: 8 }, (_, i) => `<option>${2026 + i}</option>`).join('')}</select></div></div>
          <p class="hint">No photos yet. We ask for your licence after you approve the price.</p><p class="error" role="alert"></p>
        </fieldset>
        <fieldset class="field" data-cov-field><legend class="label">How will the car be covered?</legend>
          <p class="hint">Liability coverage is included. This is about damage to the car. You can change your choice any time before pickup.</p>
          <div class="stack">
            <label class="option"><input type="radio" name="coverage" value="1"><span class="option__title">Option 1: OPCF 27 on my own auto policy</span><span class="option__body">You will send the policy page or an insurer letter showing OPCF 27.</span></label>
            <label class="option"><input type="radio" name="coverage" value="2"><span class="option__title">Option 2: my credit card’s rental coverage</span><span class="option__body">You will pay with that card and send its benefits certificate.</span></label>
            <label class="option"><input type="radio" name="coverage" value="3"><span class="option__title">Option 3: buy coverage through CarmaCars</span><span class="option__body">We add the price to your quote and send the provider’s terms before you buy.</span></label>
          </div><p class="error" role="alert"></p>
        </fieldset>
        <fieldset class="field"><legend class="label">Booking type</legend>
          <div class="stack">
            <label class="option"><input type="radio" name="bookingType" value="standard" checked><span class="option__title">Standard</span><span class="option__body">Cancel 48 hours or more before pickup for 75% back. <a class="link" href="cancellation.html">All tiers</a>.</span></label>
            <label class="option"><input type="radio" name="bookingType" value="nonrefundable"><span class="option__title">Non-refundable, 10% off the rental charge</span><span class="option__body">Cheaper, but no refund if you cancel, miss pickup or return early.</span></label>
          </div>
        </fieldset>
        <fieldset class="field"><legend class="label">Extras <span class="opt">optional</span></legend>
          <label class="option"><input type="checkbox" name="winter"><span class="option__title">Winter tires</span><span class="option__body">$15 a day, up to $150 per rental. On request, subject to availability for the car.</span></label>
          <div class="req__seat"><span id="rq-seat-l"><b>Baby seats</b><br><span class="small muted">$12 a day each, up to $70. You install it and check it suits your child.</span></span>
            <div class="qty" data-min="0" data-max="3"><button type="button" aria-label="Fewer baby seats">−</button><output aria-labelledby="rq-seat-l">0</output><button type="button" aria-label="More baby seats">+</button><input type="hidden" name="babySeats" value="0"></div></div>
        </fieldset>
        <div class="field"><label class="label" for="rq-notes">Anything we should know? <span class="opt">optional</span></label><textarea class="textarea" id="rq-notes" name="notes" placeholder="Flight number, a trip outside Ontario, a pet coming along"></textarea><p class="hint">Trips outside Ontario and pets need our approval first, so mention them here.</p></div>
        <div class="req__nav"><button type="button" class="btn btn--ghost" data-back>Back</button><button type="button" class="btn btn--primary btn--lg" data-next>Review request</button></div>
      </section>

      <!-- STEP 4 -->
      <section data-step="4" class="req__step stack-lg" aria-labelledby="rs4" hidden>
        <h2 class="d3" id="rs4">Check it and send</h2>
        <table class="spec req__review"><tbody data-review></tbody></table>
        <div class="alert"><span class="alert__title">What sending this does</span><span>It asks us to check the car and price. It does not book the car, and it takes no payment. The estimate may change if we need to adjust something. You see the final price before you pay.</span></div>
        <div class="field"><label class="check"><input type="checkbox" name="agree" data-v="required" data-msg="Tick this box to send your request."><span>I am 18 or older, the details above are true, and I agree to the <a class="link" href="terms.html">Terms of use</a> and <a class="link" href="privacy.html">Privacy policy</a>.</span></label><p class="error" role="alert"></p></div>
        <label class="check"><input type="checkbox" name="marketing"><span class="small">Yes, send me CarmaCars offers and news by email and text message. I can unsubscribe at any time. Sent by 18122211 Canada Inc. (CarmaCars), ${EMAIL}.</span></label>
        <div class="req__nav"><button type="button" class="btn btn--ghost" data-back>Back</button><button type="submit" class="btn btn--primary btn--lg">Send request</button></div>
        <p class="small muted">No payment now. No card needed.</p>
      </section>
    </form>

    <aside class="req__side" aria-label="Your request">
      <details class="req__sum">
        <summary><span class="d4">Your request</span><b class="num" data-summary-total></b></summary>
        <div class="req__car" data-summary-car></div>
        <div class="estimate" data-summary aria-live="polite"></div>
      </details>
    </aside>
  </div>
</div>`;
  return doc({ file: 'request.html', title: 'Request to book | CarmaCars', desc: 'Send a booking request to CarmaCars in four short steps. No payment and no card at request. We confirm the car and the price before you pay.', main, bodyClass: 'p-request', noindex: true });
}

// ---------------------------------------------------------------- confirmation
export function confirmation() {
  const main = `
<div data-page="confirmation">
<section class="page-head on-dark conf-head">
  <div class="wrap">
    <p class="row"><span class="plate plate--dark plate--lg" data-conf-ref>R-000000</span><span class="small muted">Your request number</span></p>
    <h1 class="d1">Request sent<span data-conf-name></span>.</h1>
    <p class="lead">Nothing has been charged. A person at CarmaCars is checking the car now.</p>
  </div>
</section>
<section class="section">
  <div class="wrap grid">
    <div class="c-7 stack-lg">
      <h2 class="d2">What happens next</h2>
      <ol class="seq">
        <li><div><h3>We check the car and your details</h3><p>We look at the calendar, your dates and your delivery address. Our target is to reply within 15 minutes during opening hours.</p><span class="seq__who">CarmaCars</span></div></li>
        <li><div><h3>You get the confirmed price</h3><p>By email<span data-conf hidden> to <b data-conf-email></b></span>, with every fee and HST. If we had to adjust anything, the message says what changed. We hold the car for two hours from then.</p><span class="seq__who">CarmaCars</span></div></li>
        <li><div><h3>You approve, sign and pay</h3><p>Reply yes and we send the rental agreement to sign online and a secure payment link. Use a credit card in your own name. Your booking is confirmed when the payment goes through.</p><span class="seq__who">You</span></div></li>
        <li><div><h3>You send your licence and coverage proof</h3><p>A photo of your licence, front and back, and a selfie holding it, at least 24 hours before pickup.
          <span data-conf-cov="1" hidden>For option 1, add the policy page or insurer letter that shows OPCF 27.</span><span data-conf-cov="2" hidden>For option 2, add your card’s benefits certificate, and pay with that card.</span><span data-conf-cov="3" hidden>For option 3, we send the provider’s terms and activate the coverage once it is paid.</span></p><span class="seq__who">You</span></div></li>
        <li><div><h3>Pickup day</h3><p>Bring your original licence and the card you paid with. We take the deposit, walk around the car with you and hand over the keys.</p><span class="seq__who">Both</span></div></li>
      </ol>
    </div>
    <aside class="c-4 s-8 stack-lg" aria-label="Your request">
      <div data-conf class="stack">
        <h2 class="d4">What you asked for</h2>
        <table class="spec"><tbody data-conf-rows></tbody></table>
      </div>
      <p class="alert" data-conf-none hidden><span class="alert__title">No request found on this device</span><span>This page shows the request you just sent. <a class="link" href="fleet.html">Find a car</a> to start one.</span></p>
      <div class="stack"><h2 class="d4">Need to change something?</h2><p class="small">Email <a class="link" href="mailto:${EMAIL}">${EMAIL}</a> with your request number. Nothing is locked in until you sign and pay.</p></div>
      <p class="row"><a class="btn" href="fleet.html">Back to the fleet</a><a class="btn btn--ghost" href="how-it-works.html">How it works</a></p>
      <p class="proto-note"><b>Prototype.</b> Requests are not sent anywhere. The number above is generated in your browser.</p>
    </aside>
  </div>
</section>
</div>`;
  return doc({ file: 'confirmation.html', title: 'Request sent | CarmaCars', desc: 'Your CarmaCars booking request has been sent. Nothing has been charged. Here is what happens next.', main, bodyClass: 'p-conf', noindex: true });
}

// ---------------------------------------------------------------- owners
export const OWNER_FAQ = [
  ['What does it cost me?', 'Two monthly fees for each car: an insurance fee and a tracker fee. They are due every month whether the car is rented or not. Before the car goes live you pay the first and last month’s insurance fee and a $100 tracker install fee. There is no security deposit.'],
  ['How do I get paid?', 'On the 10th of each month for the month before, with a statement for each car that lists every rental and deduction. Your payout is the rental charge plus mileage overage fees, less our revenue share.'],
  ['Can I still drive my own car?', 'Yes, whenever it is not booked. You book it like a renter and sign the same agreement, but you pay no rental charge, fee or deposit. A renter’s confirmed booking comes first.'],
  ['Who insures the car?', 'From its enrolment date the car is listed on our commercial fleet policy. We manage every claim, and repairs are done only at shops we approve. You are not paid for the time a car is off the road.'],
  ['Is there a minimum term?', 'No. You can take any car out of the program with 30 days’ written notice. If it is on a rental when the notice ends, it leaves when that rental does.'],
  ['My car is financed or leased. Can I enrol it?', 'Often, yes, with written permission from your lender or lessor. Tell us in the form and we will say which registration route is open to you and what it costs at ServiceOntario.'],
  ['Which cars do you turn down?', 'Cars branded rebuilt, salvage or irreparable. Every other car is approved one at a time with our insurance broker.'],
  ['Who pays for maintenance?', 'You do: servicing, tires, brakes and mechanical repairs. Renters pay for damage they cause, tolls and tickets.']
];
export function owners() {
  const trail = [['Home', 'index.html'], ['List your car']];
  const main = `
<section class="band band--hero on-dark">
  <div class="band__media photo fx-drift">${slotPic('owners.hero', { eager: true })}</div>
  <div class="wrap band__inner">
    <div class="band__copy stack">
      ${crumbs(trail)}
      <h1 class="d1">Your car, on our fleet, earning.</h1>
      <p class="lead">Enrol your car with CarmaCars. We find the renters, check their licences, hand over the keys and collect the money. You get a statement and a payout every month.</p>
      <p class="row"><a class="btn btn--primary btn--lg" href="#apply">Apply to list your car</a><a class="btn btn--ghost btn--lg" href="#how">How it works</a></p>
    </div>
  </div>
</section>

<section class="facts on-dark" aria-label="Owner program at a glance"><div class="wrap"><dl class="facts__list">
  <div><dt>Payout</dt><dd>10th of each month</dd></div><div><dt>Minimum term</dt><dd>None</dd></div><div><dt>Notice to leave</dt><dd>30 days</dd></div><div><dt>Security deposit</dt><dd>None</dd></div><div><dt>Your own use</dt><dd>Free when not booked</dd></div>
</dl></div></section>

<section class="section" id="how" aria-labelledby="oh-how">
  <div class="wrap grid">
    <div class="c-5"><div class="how__sticky stack"><h2 class="d1" id="oh-how">From driveway to first rental</h2><p class="lead">Five steps. We prepare the government forms and come to the registry with you.</p></div></div>
    <div class="c-7 how__steps"><span class="how__line fx-grow-y" aria-hidden="true"></span>
      <ol class="seq">
        <li><div><h3>Tell us about the car</h3><p>Year, make, model, kilometres, and whether it is owned outright, financed or leased. We reply within one business day with the fees for your car and what registration will cost you.</p></div></li>
        <li><div><h3>Sign the agreements</h3><p>An enrolment agreement and a title agreement, signed online. One agreement covers all your cars. Each car is added with its own schedule.</p></div></li>
        <li><div><h3>One registry visit</h3><p>You get the safety certificate and appraisal your route needs. We fill in the forms, book the visit and attend with you. You pay ServiceOntario directly.</p></div></li>
        <li><div><h3>Tracker and insurance</h3><p>We install a GPS tracker and add the car to our fleet policy. Once we confirm that in writing, you can cancel your own insurance on it.</p></div></li>
        <li><div><h3>Photos, listing, first booking</h3><p>We detail the car, photograph it and publish it, usually within two business days. Then it is open for requests.</p></div></li>
      </ol>
    </div>
  </div>
</section>

<section class="section on-grey" aria-labelledby="oh-modes">
  <div class="wrap stack-lg">
    <h2 class="d2" id="oh-modes">Three ways to enrol</h2>
    <div class="table-scroll" tabindex="0" role="region" aria-labelledby="oh-modes">
      <table class="data modes">
        <thead><tr><th scope="col"></th><th scope="col">Managed</th><th scope="col">Self-managed</th><th scope="col">Turo only</th></tr></thead>
        <tbody>
          <tr><th scope="row">Who runs the rentals</th><td>CarmaCars</td><td>You find renters and set the price. We collect the money.</td><td>CarmaCars, on Turo, under our account</td></tr>
          <tr><th scope="row">Revenue share to CarmaCars</th><td>A share of owner revenue</td><td>None. You keep 100% of owner revenue.</td><td>A share of the Turo payout</td></tr>
          <tr><th scope="row">Our fleet insurance</th><td>Yes</td><td>Yes</td><td>No. You keep your own comprehensive policy.</td></tr>
          <tr><th scope="row">Monthly insurance and tracker fees</th><td>Yes</td><td>Yes</td><td>No</td></tr>
          <tr><th scope="row">Registration change</th><td>Yes, one registry visit</td><td>Yes, one registry visit</td><td>No. The car stays in your name.</td></tr>
          <tr><th scope="row">GPS tracker</th><td>Yes</td><td>Yes</td><td>No</td></tr>
        </tbody>
      </table>
    </div>
  </div>
</section>

<section class="section" aria-labelledby="oh-money">
  <div class="wrap grid">
    <div class="c-6 stack-lg">
      <h2 class="d2" id="oh-money">The money, plainly</h2>
      <table class="spec"><tbody>
        <tr><th scope="row">You earn</th><td>The rental charge and mileage overage fees on your car, less our revenue share</td></tr>
        <tr><th scope="row">CarmaCars keeps</th><td>Its revenue share, plus delivery, fuel, cleaning, late return and young driver fees</td></tr>
        <tr><th scope="row">You pay monthly</th><td>An insurance fee and a tracker fee for each car, billed on the 15th, rented or not</td></tr>
        <tr><th scope="row">You pay once</th><td>First and last month’s insurance fee and a $100 tracker install fee. Registry costs go to ServiceOntario, not us.</td></tr>
        <tr><th scope="row">You are paid</th><td>On the 10th, for the month before, with a statement per car</td></tr>
        <tr><th scope="row">Referrals</th><td>Send us a new renter and earn 20% of the rental charge on their first rental. Not on your own car.</td></tr>
      </tbody></table>
    </div>
    <div class="c-5 s-8 stack-lg">
      <h2 class="d2">Standard starting grid</h2>
      <div class="table-scroll" tabindex="0" role="region" aria-label="Standard starting grid">
      <table class="data data--min"><thead><tr><th scope="col">Your cars with us</th><th scope="col" class="r">Insurance fee</th><th scope="col" class="r">Tracker fee</th><th scope="col" class="r">Revenue share</th></tr></thead>
        <tbody><tr><td>1 to 2</td><td class="r">$450 a month</td><td class="r">$25 a month</td><td class="r">35%</td></tr><tr><td>3 to 9</td><td class="r">$400 a month</td><td class="r">$20 a month</td><td class="r">30%</td></tr><tr><td>10 or more</td><td class="r">$350 a month</td><td class="r">$15 a month</td><td class="r">25%</td></tr></tbody></table>
      </div>
      <p class="small muted">A starting point only, per car, before HST. Your own fees and share are set car by car in your agreement. No revenue share on self-managed cars. Earnings depend on bookings and are not promised.</p>
    </div>
  </div>
</section>

<section class="section on-dark" id="apply" aria-labelledby="oh-apply">
  <div class="wrap grid">
    <div class="c-5 stack"><h2 class="d1" id="oh-apply">Apply to list your car</h2><p class="lead muted">Six questions. We answer within one business day with your fees and your registration options. Applying commits you to nothing.</p></div>
    <div class="c-6 s-7">
      <form class="panel stack-lg" data-simple-form="apply-done" aria-labelledby="oh-apply">
        <div class="field-row">${field({ id: 'ow-name', name: 'name', label: 'Your name', auto: 'name', msg: 'Enter your name.' })}${field({ id: 'ow-phone', name: 'phone', label: 'Mobile number', type: 'tel', v: 'required phone', auto: 'tel' })}</div>
        ${field({ id: 'ow-email', name: 'email', label: 'Email', type: 'email', v: 'required email', auto: 'email' })}
        <div class="field-row field-row--3">${field({ id: 'ow-year', name: 'year', label: 'Year', v: 'required year', attrs: 'inputmode="numeric" maxlength="4" placeholder="2021"' })}${field({ id: 'ow-make', name: 'make', label: 'Make', msg: 'Enter the make, for example Mercedes-Benz.' })}${field({ id: 'ow-model', name: 'model', label: 'Model', msg: 'Enter the model, for example C300.' })}</div>
        <div class="field-row">
          <div class="field"><label class="label" for="ow-own">How is it owned?</label><select class="select" id="ow-own" name="own" data-v="required" data-msg="Choose one."><option value="">Choose</option><option>Owned outright</option><option>Financed</option><option>Leased</option></select><p class="error" role="alert"></p></div>
          <div class="field"><label class="label" for="ow-who">Registered to</label><select class="select" id="ow-who" name="who" data-v="required" data-msg="Choose one."><option value="">Choose</option><option>Me, personally</option><option>My corporation</option></select><p class="error" role="alert"></p></div>
        </div>
        <fieldset class="field"><legend class="label">Which option interests you?</legend><div class="seg"><label><input type="radio" name="mode" value="managed" checked>Managed</label><label><input type="radio" name="mode" value="self">Self-managed</label><label><input type="radio" name="mode" value="turo">Turo only</label></div></fieldset>
        <button class="btn btn--primary btn--lg btn--block" type="submit">Send application</button>
        <p class="xs muted">We use these details to reply to you about your car. See the <a class="link" href="privacy.html">Privacy policy</a>.</p>
      </form>
      <div class="panel stack" id="apply-done" hidden><p class="d3">Application sent.</p><p>We will reply within one business day with the fees for your car and the registration routes open to you.</p><p class="proto-note"><b>Prototype.</b> Nothing was actually sent.</p><p><a class="btn" href="index.html">Back to home</a></p></div>
    </div>
  </div>
</section>

<section class="section" aria-labelledby="oh-faq">
  <div class="wrap grid"><div class="c-4"><h2 class="d2" id="oh-faq">Owner questions</h2></div><div class="c-8">${faq(OWNER_FAQ)}</div></div>
</section>`;
  return doc({ file: 'owners.html', title: 'List your car with CarmaCars | Owner program, Toronto', desc: 'Enrol your car on the CarmaCars rental fleet in Toronto. We handle renters, insurance on our fleet policy and handovers. Paid on the 10th of each month. No minimum term.', main, bodyClass: 'p-owners', ld: [crumbsLd(trail, 'owners.html'), faqLd(OWNER_FAQ)] });
}

// ---------------------------------------------------------------- sign in
export function signin() {
  const main = `
<section class="auth">
  <div class="auth__side on-dark"><div class="auth__side-in stack"><p class="d1">One sign-in for renters, owners and staff.</p><p class="muted">Renters see bookings, agreements and statements. Owners see their cars, calendar and payouts.</p></div></div>
  <div class="auth__main">
    <div class="auth__box stack-lg">
      <h1 class="d2">Sign in</h1>
      <div class="tabs" role="tablist" aria-label="Sign in or create an account"><button class="tab" role="tab" id="t-in" aria-controls="p-in" aria-selected="true">Sign in</button><button class="tab" role="tab" id="t-new" aria-controls="p-new" aria-selected="false" tabindex="-1">Create account</button></div>
      <div id="p-in" role="tabpanel" aria-labelledby="t-in">
        <form class="stack-lg" data-simple-form="" data-toast-msg="Sign-in is not connected in this prototype.">
          ${field({ id: 'si-email', name: 'email', label: 'Email', type: 'email', v: 'required email', auto: 'username' })}
          ${field({ id: 'si-pass', name: 'password', label: 'Password', type: 'password', v: 'required', auto: 'current-password', msg: 'Enter your password.' })}
          <button class="btn btn--primary btn--lg btn--block" type="submit">Sign in</button>
          <p class="small"><a class="link" href="contact.html">Forgot your password? Contact us</a></p>
        </form>
      </div>
      <div id="p-new" role="tabpanel" aria-labelledby="t-new" hidden>
        <form class="stack-lg" data-simple-form="" data-toast-msg="Accounts are not connected in this prototype.">
          ${field({ id: 'su-name', name: 'name', label: 'Full name', auto: 'name', msg: 'Enter your name.' })}
          ${field({ id: 'su-email', name: 'email', label: 'Email', type: 'email', v: 'required email', auto: 'email' })}
          ${field({ id: 'su-pass', name: 'password', label: 'Password', type: 'password', v: 'required password', auto: 'new-password', hint: 'At least 8 characters.' })}
          <div class="field"><label class="check"><input type="checkbox" name="agree" data-v="required" data-msg="Tick this box to create an account."><span class="small">I am 18 or older and agree to the <a class="link" href="terms.html">Terms of use</a> and <a class="link" href="privacy.html">Privacy policy</a>.</span></label><p class="error" role="alert"></p></div>
          <button class="btn btn--primary btn--lg btn--block" type="submit">Create account</button>
        </form>
      </div>
      <p class="small muted">You do not need an account to <a class="link" href="fleet.html">request a car</a>.</p>
    </div>
  </div>
</section>`;
  return doc({ file: 'signin.html', title: 'Sign in | CarmaCars', desc: 'Sign in to CarmaCars to see your bookings, agreements, statements and, for owners, your cars and payouts.', main, bodyClass: 'p-auth', noindex: true });
}

// ---------------------------------------------------------------- contact
export function contact() {
  const trail = [['Home', 'index.html'], ['Contact']];
  const main = `
<section class="page-head on-dark"><div class="wrap">${crumbs(trail)}<h1 class="d1">Talk to a person.</h1><p class="lead muted">Questions about a car, a booking or listing your own. We answer during opening hours, and our target is 15 minutes.</p></div></section>
<section class="section">
  <div class="wrap grid">
    <div class="c-5 stack-lg">
      <table class="spec"><tbody>
        <tr><th scope="row">Email</th><td><a class="link" href="mailto:${EMAIL}">${EMAIL}</a></td></tr>
        <tr><th scope="row">Phone and WhatsApp</th><td><span class="tbc">number to be added</span></td></tr>
        <tr><th scope="row">On a rental right now</th><td>Call the 24-hour incident and roadside line. The number is in your rental agreement and your pickup message.</td></tr>
        <tr><th scope="row">Opening hours</th><td><span class="tbc">hours to be added</span></td></tr>
        <tr><th scope="row">Location</th><td><span class="tbc">address to be added</span></td></tr>
        <tr><th scope="row">Company</th><td>18122211 Canada Inc., operating as CarmaCars</td></tr>
      </tbody></table>
      <div class="alert alert--error"><span class="alert__title">After an accident</span><span>If anyone is hurt, call 911 first. Then call our 24-hour line as soon as it is safe, and within 24 hours.</span></div>
      <p class="small">Most questions are answered in the <a class="link" href="faq.html">FAQ</a>.</p>
    </div>
    <div class="c-6 s-7">
      <form class="stack-lg" data-simple-form="contact-done" aria-label="Send us a message">
        <h2 class="d3">Send a message</h2>
        <div class="field"><label class="label" for="ct-topic">What is it about?</label><select class="select" id="ct-topic" name="topic"><option>A car or a price</option><option>A booking I have made</option><option>Listing my car</option><option>A charge or a statement</option><option>Something else</option></select></div>
        <div class="field-row">${field({ id: 'ct-name', name: 'name', label: 'Your name', auto: 'name', msg: 'Enter your name.' })}${field({ id: 'ct-email', name: 'email', label: 'Email', type: 'email', v: 'required email', auto: 'email' })}</div>
        ${field({ id: 'ct-ref', name: 'ref', label: 'Booking or request number', v: '', opt: true })}
        <div class="field"><label class="label" for="ct-msg">Message</label><textarea class="textarea" id="ct-msg" name="message" data-v="required" data-msg="Write a short message so we know how to help."></textarea><p class="error" role="alert"></p></div>
        <button class="btn btn--primary btn--lg" type="submit">Send message</button>
      </form>
      <div class="stack" id="contact-done" hidden><p class="d3">Message sent.</p><p>We reply by email during opening hours.</p><p class="proto-note"><b>Prototype.</b> Nothing was actually sent.</p><p><a class="btn" href="fleet.html">Browse the fleet</a></p></div>
    </div>
  </div>
</section>
<section class="band band--short on-dark" aria-hidden="true"><div class="band__media photo fx-drift">${slotPic('contact.city', { alt: '' })}</div></section>`;
  return doc({ file: 'contact.html', title: 'Contact CarmaCars | Car rental in Toronto', desc: 'Contact CarmaCars about a car, a booking or listing your own car. Email info@carmacars.ca or send a message.', main, bodyClass: 'p-contact', ld: [crumbsLd(trail, 'contact.html')] });
}

// ---------------------------------------------------------------- 404
export function notFound() {
  const main = `
<section class="nf on-dark">
  <div class="wrap nf__in">
    <p class="nf__code" aria-hidden="true">404</p>
    <div class="stack">
      <h1 class="d1">Wrong turn.</h1>
      <p class="lead muted">That page is not here. It may have moved, or the link was mistyped.</p>
      <p class="row"><a class="btn btn--primary btn--lg" href="fleet.html">See the fleet</a><a class="btn btn--ghost btn--lg" href="index.html">Go home</a></p>
      <ul class="nf__links"><li><a class="link" href="how-it-works.html">How it works</a></li><li><a class="link" href="requirements.html">Requirements</a></li><li><a class="link" href="faq.html">FAQ</a></li><li><a class="link" href="contact.html">Contact</a></li></ul>
    </div>
  </div>
</section>`;
  return doc({ file: '404.html', title: 'Page not found | CarmaCars', desc: 'This page could not be found. Browse the CarmaCars fleet or go back to the home page.', main, bodyClass: 'p-404', noindex: true });
}
