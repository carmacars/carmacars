// Request to book, confirmation, owner program, sign in, contact, 404.
import { CARS, RULES } from './data.mjs';
import { doc, slotPic, crumbs, crumbsLd, timeSelect, icon, money, faq, faqLd, EMAIL, SETTINGS, setting, TEL, WA, MAIL, esc } from './layout.mjs';
const E = SETTINGS.emails;
// Address field with lookup while typing (CC.addressLookup in app.js). Sample suggestions in the prototype.
const lookup = 'data-addr-lookup autocomplete="off" role="combobox" aria-autocomplete="list" aria-expanded="false"';
const placeOpts = (kind, name, addrWrap, addrField, airportName) => `
          <label class="option"><input type="radio" name="${name}" value="ours" checked><span class="option__title">At our location <span class="muted">No charge</span></span><span class="option__body">${SETTINGS.address ? esc(SETTINGS.address) : 'We send the address with your offer.'}</span></label>
          <label class="option" data-owner-opt hidden><input type="radio" name="${name}" value="owner"><span class="option__title">At the car owner’s location <span class="muted">No charge</span></span><span class="option__body">Offered for this car. We send the address with your offer.</span></label>
          <label class="option"><input type="radio" name="${name}" value="delivery"><span class="option__title">${kind === 'pickup' ? 'Deliver it to an address' : 'Pick it up from an address'} <span class="muted num">+<span data-car-fee>{{delMin}}</span> plus distance</span></span><span class="option__body">${kind === 'pickup' ? 'Home, office or hotel, anywhere. We hand it over in person.' : 'Leave it with our driver instead of bringing it back.'}</span></label>
          <div ${addrWrap} hidden>${addrField}</div>
          <label class="option"><input type="radio" name="${name}" value="airport"><span class="option__title">At the airport <span class="muted num">+<span data-car-fee>{{delMin}}</span> plus distance</span></span><span class="option__body">{{airports}}. An airport surcharge may apply.</span></label>
          <div data-airport-${kind} hidden><div class="field"><label class="label" for="rq-${airportName}">Airport</label><select class="select" id="rq-${airportName}" name="${airportName}">${RULES.airports.map((a) => `<option value="${a.code}">${a.name}</option>`).join('')}</select><p class="hint">Add your flight number in the notes on step 3.</p></div></div>`;

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
    <p class="req__assure"><b>No payment and no card at this stage.</b> We confirm the car and the price first. The car is booked only when you approve, sign and pay.</p>
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
        <h2 class="d3" id="rs1">Your dates</h2>
        <div class="field"><label class="label" for="rq-car">Car</label>
          <select class="select" id="rq-car" name="car" data-v="required" data-msg="Choose a car.">
            <option value="">Choose a car</option>${CARS.map((c) => `<option value="${c.slug}">${c.name}, from ${money(c.rates.daily)} a day</option>`).join('')}
          </select><p class="error" role="alert"></p></div>
        <div class="field" data-dates-field>
          <span class="label">Pickup and return dates</span>
          <p class="hint">Tap the pickup date, then the return date. Hatched days are already booked. One booking covers up to {{maxDays}} days.</p>
          <div class="req__cal" data-cal></div>
          <p class="error" role="alert"></p>
        </div>
        <div class="field-row">${timeSelect('tf', 'Pickup time', 'rq-tf', RULES.defaultTime)}${timeSelect('tt', 'Return time', 'rq-tt', RULES.defaultTime)}</div>
        <p class="hint">Any time, day or night, with at least {{notice}}’ notice. Each car needs {{turnaround}} between bookings, so a day next to another booking may only be free for part of it.</p>
        <fieldset class="stack"><legend class="label">Where do you want to get the car?</legend>
          ${placeOpts('pickup', 'pickupAt', 'data-addr-deliver', field({ id: 'rq-addr1', name: 'addrDeliver', label: 'Delivery address', attrs: lookup, msg: 'Add the delivery address so we can price the trip.', hint: 'Start typing and choose your address.' }), 'airportPickup')}
        </fieldset>
        <fieldset class="stack"><legend class="label">Where will you return it?</legend>
          ${placeOpts('return', 'returnAt', 'data-addr-collect', field({ id: 'rq-addr2', name: 'addrCollect', label: 'Pickup address', v: '', opt: true, attrs: lookup, hint: 'Leave empty if it is the same as the delivery address.' }), 'airportReturn')}
        </fieldset>
        <div class="req__nav"><span></span><button type="button" class="btn btn--primary btn--lg" data-next>Continue to driver details</button></div>
      </section>

      <!-- STEP 2 -->
      <section data-step="2" class="req__step stack-lg" aria-labelledby="rs2" hidden>
        <h2 class="d3" id="rs2">The driver</h2>
        <div class="field-row">${field({ id: 'rq-first', name: 'first', label: 'First name', auto: 'given-name', msg: 'Enter your first name as it appears on your licence.' })}${field({ id: 'rq-last', name: 'last', label: 'Last name', auto: 'family-name', msg: 'Enter your last name as it appears on your licence.' })}</div>
        <div class="field-row">${field({ id: 'rq-email', name: 'email', label: 'Email', type: 'email', v: 'required email', auto: 'email', hint: 'We send the confirmed price here.', msg: 'Enter your email so we can send the price.' })}${field({ id: 'rq-phone', name: 'phone', label: 'Mobile number', type: 'tel', v: 'required phone', auto: 'tel', hint: 'For questions about this request only.', msg: 'Enter a mobile number we can reach you on.' })}</div>
        <fieldset class="field" data-dob-field><legend class="label">Date of birth</legend>
          <p class="hint">Drivers must be {{minAge}} or older at pickup. Age sets the young driver fee.</p>
          <div class="dob">
            <div><label class="xs muted" for="rq-dobm">Month</label><select class="select" id="rq-dobm" name="dobM" autocomplete="bday-month"><option value="">Month</option>${MONTHS.map((m, i) => `<option value="${i + 1}">${m}</option>`).join('')}</select></div>
            <div><label class="xs muted" for="rq-dobd">Day</label><input class="input" id="rq-dobd" name="dobD" inputmode="numeric" maxlength="2" placeholder="DD" autocomplete="bday-day"></div>
            <div><label class="xs muted" for="rq-doby">Year</label><input class="input" id="rq-doby" name="dobY" inputmode="numeric" maxlength="4" placeholder="YYYY" autocomplete="bday-year"></div>
          </div>
          <p class="error" role="alert"></p>
        </fieldset>
        <div class="field"><span class="label" id="rq-add-l">Additional drivers</span><p class="hint">{{addDrvPct}} of the car’s daily rate, a day, for each one. No maximum. Each one needs a {{licence}} licence and signs the agreement.</p>
          <div class="qty" data-min="0" data-max="9"><button type="button" aria-label="Fewer additional drivers">−</button><output aria-labelledby="rq-add-l">0</output><button type="button" aria-label="More additional drivers">+</button><input type="hidden" name="addDrivers" value="0"></div></div>
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
            <label class="option"><input type="radio" name="coverage" value="3"><span class="option__title">Option 3: buy coverage through CarmaCars</span><span class="option__body">Priced in your offer, for your car and the driver’s age. We send the provider’s terms before you buy.</span></label>
          </div><p class="error" role="alert"></p>
        </fieldset>
        <fieldset class="field"><legend class="label">Booking type</legend>
          <div class="stack">
            <label class="option"><input type="radio" name="bookingType" value="standard" checked><span class="option__title">Standard</span><span class="option__body">Cancel {{cEarly}} hours or more before pickup for {{c2}} back. <a class="link" href="cancellation.html">All tiers</a>.</span></label>
            <label class="option"><input type="radio" name="bookingType" value="nonrefundable"><span class="option__title">Non-refundable, {{nonRef}} off the rental charge</span><span class="option__body">Cheaper, but no refund if you cancel, miss pickup or return early.</span></label>
          </div>
        </fieldset>
        <fieldset class="field"><legend class="label">Extras <span class="opt">optional</span></legend>
          <label class="option"><input type="checkbox" name="winter"><span class="option__title">Winter tires</span><span class="option__body">{{winter}} a day, up to {{winterCap}} per rental. On request, subject to availability for the car.</span></label>
          <div class="req__seat"><span id="rq-seat-l"><b>Baby seats</b><br><span class="small muted">{{baby}} a day each, up to {{babyCap}}. You install it and check it suits your child.</span></span>
            <div class="qty" data-min="0" data-max="3"><button type="button" aria-label="Fewer baby seats">−</button><output aria-labelledby="rq-seat-l">0</output><button type="button" aria-label="More baby seats">+</button><input type="hidden" name="babySeats" value="0"></div></div>
        </fieldset>
        <div class="field"><label class="label" for="rq-notes">Anything we should know? <span class="opt">optional</span></label><textarea class="textarea" id="rq-notes" name="notes" placeholder="Flight number, a trip outside Ontario, a pet coming along"></textarea><p class="hint">Trips outside Ontario and pets need our approval first, so mention them here.</p></div>
        <div class="req__nav"><button type="button" class="btn btn--ghost" data-back>Back</button><button type="button" class="btn btn--primary btn--lg" data-next>Review request</button></div>
      </section>

      <!-- STEP 4 -->
      <section data-step="4" class="req__step stack-lg" aria-labelledby="rs4" hidden>
        <h2 class="d3" id="rs4">Check it and send</h2>
        <table class="spec req__review"><tbody data-review></tbody></table>
        <div class="alert"><span class="alert__title">What sending this does</span><span>It asks us to check the car and price. It does not book or hold the car, and it takes no payment. We send the final price as an offer that stays open for {{offerHours}} hours. The car is booked only when you approve, sign and pay. If someone else pays for the same car and dates first, we tell you and offer another car or other dates.</span></div>
        <div class="field"><label class="check"><input type="checkbox" name="agree" data-v="required" data-msg="Tick this box to send your request."><span>I am {{minAge}} or older, the details above are true, and I agree to the <a class="link" href="terms.html">Terms of use</a> and <a class="link" href="privacy.html">Privacy policy</a>.</span></label><p class="error" role="alert"></p></div>
        <label class="check"><input type="checkbox" name="marketing"><span class="small">Yes, send me CarmaCars offers and news by email and text message. I can unsubscribe at any time. Sent by {{brand}}, ${setting(SETTINGS.mailingAddress, 'Mailing address')}, ${EMAIL}.</span></label>
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
    <p class="lead">Nothing has been charged, and the car is not booked yet. A person at CarmaCars is checking it now.</p>
  </div>
</section>
<section class="section">
  <div class="wrap grid">
    <div class="c-7 stack-lg">
      <h2 class="d2">What happens next</h2>
      <ol class="seq">
        <li><div><h3>We check the car and your details</h3><p>We look at the calendar, your dates and the place you chose. {{reply}}, day or night.</p><span class="seq__who">CarmaCars</span></div></li>
        <li><div><h3>You get the confirmed price</h3><p>By email<span data-conf hidden> to <b data-conf-email></b></span>, with every fee and HST. If we had to adjust anything, the message says what changed. That price is an offer and stays open for {{offerHours}} hours. It does not hold the car.</p><span class="seq__who">CarmaCars</span></div></li>
        <li><div><h3>You approve, sign and pay</h3><p>Reply yes and we send the rental agreement to sign online and a secure payment link. Use a credit card in your own name. The car is booked when the payment goes through. If someone else pays for the same car and dates before you do, we tell you and offer another car or other dates.</p><span class="seq__who">You</span></div></li>
        <li><div><h3>You send your licence and coverage proof</h3><p>A photo of your licence, front and back, and a selfie holding it, at least {{verifyHours}} hours before pickup.
          <span data-conf-cov="1" hidden>For option 1, add the policy page or insurer letter that shows OPCF 27.</span><span data-conf-cov="2" hidden>For option 2, add your card’s benefits certificate, and pay with that card.</span><span data-conf-cov="3" hidden>For option 3, we send the provider’s terms and activate the coverage once it is paid.</span></p><span class="seq__who">You</span></div></li>
        <li><div><h3>Pickup day</h3><p>We take the deposit about {{depLead}} before pickup. Bring your original licence and the card you paid with. We walk around the car with you and hand over the keys.</p><span class="seq__who">Both</span></div></li>
      </ol>
    </div>
    <aside class="c-4 s-8 stack-lg" aria-label="Your request">
      <div data-conf class="stack">
        <h2 class="d4">What you asked for</h2>
        <table class="spec"><tbody data-conf-rows></tbody></table>
      </div>
      <p class="alert" data-conf-none hidden><span class="alert__title">No request found on this device</span><span>This page shows the request you just sent. <a class="link" href="fleet.html">Find a car</a> to start one.</span></p>
      <div class="stack"><h2 class="d4">Need to change something?</h2><p class="small">Email ${MAIL(E.bookings)} with your request number, or call ${TEL()}. Nothing is locked in until you sign and pay.</p></div>
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
  ['What does it cost me?', 'Two monthly fees for each car: an insurance fee and a tracker fee. They are due every month whether the car is rented or not. Before the car goes live you pay the first and last month’s insurance fee and a tracker install fee. The amounts depend on how many cars you have with us and are confirmed on a call. There is no security deposit.'],
  ['How do I get paid?', 'On the {{payoutDay}} of each month for the month before, with a statement for each car that lists every rental and deduction. Your payout is the rental charge plus mileage overage fees, less our revenue share, which is agreed with you before you sign.'],
  ['Can I still drive my own car?', 'Yes, whenever it is not booked. You book it like a renter and sign the same agreement, but you pay no rental charge, fee or deposit. A renter’s confirmed booking comes first.'],
  ['Who insures the car?', 'From its enrolment date the car is listed on our commercial fleet policy. We manage every claim, and repairs are done only at shops we approve. You are not paid for the time a car is off the road.'],
  ['Is there a minimum term?', 'No. You can take any car out of the program with {{noticeDays}} days’ written notice. If it is on a rental when the notice ends, it leaves when that rental does.'],
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
      <p class="eyebrow">Owner program, {{city}}</p>
      <h1 class="d1">Your car, earning its keep.</h1>
      <p class="lead">List your car with CarmaCars. We find the renters, check their licences, hand over the keys and collect the money. Every handover is photographed, so it comes back the way it left, and you get a statement and a payout every month.</p>
      <p class="row"><a class="btn btn--primary btn--lg" href="#apply">Apply to list your car</a><a class="btn btn--ghost btn--lg" href="#how">How it works</a></p>
    </div>
  </div>
</section>

<section class="facts on-dark" aria-label="Owner program at a glance"><div class="wrap"><dl class="facts__list">
  <div><dt>Payout</dt><dd>{{payoutDay}} of each month</dd></div><div><dt>Minimum term</dt><dd>None</dd></div><div><dt>Notice to leave</dt><dd>{{noticeDays}} days</dd></div><div><dt>Security deposit</dt><dd>None</dd></div><div><dt>Your own use</dt><dd>Free when not booked</dd></div>
</dl></div></section>

<section class="section" id="how" aria-labelledby="oh-how">
  <div class="wrap grid">
    <div class="c-5"><div class="how__sticky stack"><h2 class="d1" id="oh-how">From your driveway to its first rental</h2><p class="lead">Five steps. We prepare the government forms and come to the registry with you.</p></div></div>
    <div class="c-7 how__steps"><span class="how__line fx-grow-y" aria-hidden="true"></span>
      <ol class="seq">
        <li><div><h3>Tell us about the car</h3><p>Year, make, model, kilometres, and whether it is owned outright, financed or leased. We reply within {{ownerReply}} and set up a call to confirm the fees for your car and what registration will cost you.</p></div></li>
        <li><div><h3>Sign the agreements</h3><p>An enrolment agreement and a title agreement, signed online. One agreement covers all your cars. Each car is added with its own schedule.</p></div></li>
        <li><div><h3>One registry visit</h3><p>You get the safety certificate and appraisal your route needs. We fill in the forms, book the visit and attend with you. You pay ServiceOntario directly.</p></div></li>
        <li><div><h3>Tracker and insurance</h3><p>We install a GPS tracker and add the car to our fleet policy. Once we confirm that in writing, you can cancel your own insurance on it.</p></div></li>
        <li><div><h3>Photos, listing, first booking</h3><p>We detail the car, photograph it and publish it within {{listDays}}. Then it is open for requests.</p></div></li>
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
        <tr><th scope="row">You pay monthly</th><td>An insurance fee and a tracker fee for each car, billed on the {{billDay}}, rented or not</td></tr>
        <tr><th scope="row">You pay once</th><td>First and last month’s insurance fee and a tracker install fee. Registry costs go to ServiceOntario, not us.</td></tr>
        <tr><th scope="row">You are paid</th><td>On the {{payoutDay}}, for the month before, with a statement per car</td></tr>
        <tr><th scope="row">Referrals</th><td>Send us a new renter and earn {{referralPct}} of the rental charge on their first rental. Not on your own car.</td></tr>
      </tbody></table>
    </div>
    <div class="c-5 s-8 stack-lg">
      <h2 class="d2">What it costs you</h2>
      <p class="lead">Fees and our revenue share depend on how many cars you have with us. We confirm them on a call, before you sign anything.</p>
      <ul class="ticks"><li>Every owner’s terms are agreed individually and written into the agreement, car by car</li><li>Self-managed cars pay no revenue share</li><li>Earnings depend on bookings and are not promised</li></ul>
      <p><a class="btn" href="#apply">Apply and book the call</a></p>
    </div>
  </div>
</section>

<section class="section on-dark" id="apply" aria-labelledby="oh-apply">
  <div class="wrap grid">
    <div class="c-5 stack"><h2 class="d1" id="oh-apply">Put your car to work</h2><p class="lead muted">Seven questions. We answer within {{ownerReply}} and arrange a call to confirm your fees and registration options. Applying commits you to nothing.</p></div>
    <div class="c-6 s-7">
      <form class="panel stack-lg" data-simple-form="apply-done" aria-labelledby="oh-apply">
        <div class="field-row">${field({ id: 'ow-name', name: 'name', label: 'Your name', auto: 'name', msg: 'Enter your name.' })}${field({ id: 'ow-phone', name: 'phone', label: 'Mobile number', type: 'tel', v: 'required phone', auto: 'tel' })}</div>
        ${field({ id: 'ow-email', name: 'email', label: 'Email', type: 'email', v: 'required email', auto: 'email' })}
        ${field({ id: 'ow-addr', name: 'carAddress', label: 'Where is the car kept?', attrs: lookup, msg: 'Start typing the address where the car is kept.', hint: 'Start typing and choose the address. It helps us plan the registry visit and handovers.' })}
        <div class="field-row field-row--3">${field({ id: 'ow-year', name: 'year', label: 'Year', v: 'required year', attrs: 'inputmode="numeric" maxlength="4" placeholder="2021"' })}${field({ id: 'ow-make', name: 'make', label: 'Make', msg: 'Enter the make, for example Mercedes-Benz.' })}${field({ id: 'ow-model', name: 'model', label: 'Model', msg: 'Enter the model, for example C300.' })}</div>
        <div class="field-row">
          <div class="field"><label class="label" for="ow-own">How is it owned?</label><select class="select" id="ow-own" name="own" data-v="required" data-msg="Choose one."><option value="">Choose</option><option>Owned outright</option><option>Financed</option><option>Leased</option></select><p class="error" role="alert"></p></div>
          <div class="field"><label class="label" for="ow-who">Registered to</label><select class="select" id="ow-who" name="who" data-v="required" data-msg="Choose one."><option value="">Choose</option><option>Me, personally</option><option>My corporation</option></select><p class="error" role="alert"></p></div>
        </div>
        <fieldset class="field"><legend class="label">Which option interests you?</legend><div class="seg"><label><input type="radio" name="mode" value="managed" checked>Managed</label><label><input type="radio" name="mode" value="self">Self-managed</label><label><input type="radio" name="mode" value="turo">Turo only</label></div></fieldset>
        <button class="btn btn--primary btn--lg btn--block" type="submit">Send application</button>
        <p class="xs muted">We use these details to reply to you about your car. See the <a class="link" href="privacy.html">Privacy policy</a>. Questions first? Email ${MAIL(E.owners)}.</p>
      </form>
      <div class="panel stack" id="apply-done" hidden><p class="d3">Application sent.</p><p>We will reply within {{ownerReply}} to arrange a call about the fees for your car and the registration routes open to you.</p><p class="proto-note"><b>Prototype.</b> Nothing was actually sent.</p><p><a class="btn" href="index.html">Back to home</a></p></div>
    </div>
  </div>
</section>

<section class="section" aria-labelledby="oh-faq">
  <div class="wrap grid"><div class="c-4"><h2 class="d2" id="oh-faq">Owner questions</h2></div><div class="c-8">${faq(OWNER_FAQ)}</div></div>
</section>`;
  return doc({ file: 'owners.html', title: 'List your car with {{brand}} | Owner program, {{city}}', desc: 'Enrol your car on the {{brand}} rental fleet in {{city}}. We handle renters, insurance on our fleet policy and handovers. Paid on the {{payoutDay}} of each month. No minimum term.', main, bodyClass: 'p-owners', ld: [crumbsLd(trail, 'owners.html'), faqLd(OWNER_FAQ)] });
}

// ---------------------------------------------------------------- sign in
export function signin() {
  const main = `
<section class="auth">
  <div class="auth__side on-dark"><div class="auth__side-in stack"><p class="d2">One sign-in for renters, owners and staff.</p><p class="muted">Renters see bookings, agreements and statements. Owners see their cars, calendar and payouts.</p></div></div>
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
          <div class="field"><label class="check"><input type="checkbox" name="agree" data-v="required" data-msg="Tick this box to create an account."><span class="small">I am {{minAge}} or older and agree to the <a class="link" href="terms.html">Terms of use</a> and <a class="link" href="privacy.html">Privacy policy</a>.</span></label><p class="error" role="alert"></p></div>
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
<section class="page-head on-dark"><div class="wrap">${crumbs(trail)}<h1 class="d1">Talk to a person.</h1><p class="lead muted">Questions about a car, a booking or listing your own. {{reply}}.</p></div></section>
<section class="section">
  <div class="wrap grid">
    <div class="c-5 stack-lg">
      <table class="spec"><tbody>
        <tr><th scope="row">Phone</th><td>${TEL()}</td></tr>
        <tr><th scope="row">WhatsApp</th><td>${WA()}</td></tr>
        <tr><th scope="row">Email</th><td>${MAIL(E.contact)}</td></tr>
        <tr><th scope="row">On a rental right now</th><td>Call the 24-hour incident and roadside line, ${TEL(SETTINGS.roadsideLine)}</td></tr>
        <tr><th scope="row">Hours</th><td>${esc(SETTINGS.hours)}. {{reply}}.</td></tr>
        <tr><th scope="row">Location</th><td>${setting(SETTINGS.address, 'Street address')}</td></tr>
        <tr><th scope="row">Where we rent</th><td>{{serviceArea}}. Delivery anywhere, including {{airports}}</td></tr>
      </tbody></table>
      <table class="spec"><caption class="small strong">Write to the right desk</caption><tbody>
        <tr><th scope="row">A booking or a request</th><td>${MAIL(E.bookings)}</td></tr>
        <tr><th scope="row">Listing your car</th><td>${MAIL(E.owners)}</td></tr>
        <tr><th scope="row">A charge or a statement</th><td>${MAIL(E.billing)}</td></tr>
        <tr><th scope="row">Your personal information</th><td>${MAIL(E.privacy)}</td></tr>
      </tbody></table>
      <div class="alert alert--error"><span class="alert__title">After an accident</span><span>If anyone is hurt, call 911 first. Then call our 24-hour line, ${TEL(SETTINGS.roadsideLine)}, as soon as it is safe, and within {{callHours}} hours.</span></div>
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
      <div class="stack" id="contact-done" hidden><p class="d3">Message sent.</p><p>{{reply}}, by email.</p><p class="proto-note"><b>Prototype.</b> Nothing was actually sent.</p><p><a class="btn" href="fleet.html">Browse the fleet</a></p></div>
    </div>
  </div>
</section>
<section class="band band--short on-dark" aria-hidden="true"><div class="band__media photo fx-drift">${slotPic('contact.city', { alt: '' })}</div></section>`;
  return doc({ file: 'contact.html', title: 'Contact {{brand}} | Car rental in {{city}}', desc: 'Contact {{brand}} about renting a car in {{city}}, a booking you have made, or listing your own car. Open 24 hours. Call, WhatsApp or send a message and a person replies.', main, bodyClass: 'p-contact', ld: [crumbsLd(trail, 'contact.html')] });
}

// ---------------------------------------------------------------- investor sign in (no public pitch)
export function investors() {
  const main = `
<section class="auth">
  <div class="auth__side on-dark"><div class="auth__side-in stack"><p class="d2">Investor sign in</p><p class="muted">For people who already invest with {{brand}}.</p></div></div>
  <div class="auth__main">
    <div class="auth__box stack-lg">
      <h1 class="d2">Sign in to the investor portal</h1>
      <p>Investor information is available to signed-in investors only. Nothing about investing with {{brand}} is published on this site.</p>
      <form class="stack-lg" data-simple-form="" data-toast-msg="Investor sign-in is not connected in this prototype.">
        ${field({ id: 'iv-email', name: 'email', label: 'Email', type: 'email', v: 'required email', auto: 'username' })}
        ${field({ id: 'iv-pass', name: 'password', label: 'Password', type: 'password', v: 'required', auto: 'current-password', msg: 'Enter your password.' })}
        <button class="btn btn--primary btn--lg btn--block" type="submit">Sign in</button>
      </form>
      <p class="small muted">Existing investors with a question can email ${MAIL(E.investors)}.</p>
    </div>
  </div>
</section>`;
  return doc({ file: 'investors.html', title: 'Investor sign in | CarmaCars', desc: 'Sign in for existing CarmaCars investors. Investor information is available to signed-in investors only.', main, bodyClass: 'p-auth', noindex: true });
}

// ---------------------------------------------------------------- 404
export function notFound() {
  const main = `
<section class="nf on-dark">
  <div class="wrap nf__in">
    <p class="nf__code" aria-hidden="true">404</p>
    <div class="stack">
      <h1 class="d1">Wrong turn.</h1>
      <p class="lead muted">Not every road comes back around. This page is not here: it may have moved, or the link was mistyped.</p>
      <p class="row"><a class="btn btn--primary btn--lg" href="fleet.html">See the fleet</a><a class="btn btn--ghost btn--lg" href="index.html">Go home</a></p>
      <ul class="nf__links"><li><a class="link" href="how-it-works.html">How it works</a></li><li><a class="link" href="requirements.html">Requirements</a></li><li><a class="link" href="faq.html">FAQ</a></li><li><a class="link" href="contact.html">Contact</a></li></ul>
    </div>
  </div>
</section>`;
  return doc({ file: '404.html', title: 'Page not found | CarmaCars', desc: 'This page could not be found. Browse the CarmaCars fleet or go back to the home page.', main, bodyClass: 'p-404', noindex: true });
}
