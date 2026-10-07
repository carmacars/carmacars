// Style guide: tokens, every component, and one dense portal sample.
import { CARS, PROTO_TODAY } from './data.mjs';
import { doc, carCard, carImg, plate, icon, dateRange, faq, money, esc } from './layout.mjs';

const sw = (name, hex, note = '', dark = false) => `<li class="sw"><span class="sw__chip" style="background:${hex}"></span><b>${name}</b><code>${hex}</code>${note ? `<span class="muted xs">${note}</span>` : ''}</li>`;
const sec = (id, title, body, note = '') => `<section class="sg-sec" id="${id}" aria-labelledby="sg-${id}"><div class="sg-sec__head"><h2 class="d3" id="sg-${id}">${title}</h2>${note ? `<p class="muted small measure">${note}</p>` : ''}</div><div class="sg-sec__body">${body}</div></section>`;
const add = (iso, n) => { const d = new Date(iso + 'T00:00:00Z'); d.setUTCDate(d.getUTCDate() + n); return d.toISOString().slice(0, 10); };
const diff = (a, b) => Math.round((new Date(b + 'T00:00:00Z') - new Date(a + 'T00:00:00Z')) / 864e5);

// SAMPLE portal data. Names are placeholders.
const BOOKINGS = [
  { no: 'B-1042', renter: 'Sample Renter 01', car: 'CC 03', carName: 'Mercedes-Benz C300', from: 'Oct 15, 10:00', to: 'Oct 21, 10:00', days: 6, total: '$893.83', status: 'On rent', badge: 'badge--red', cov: 'Option 1', dep: '$1,000 hold', note: 'Handed over 10:12. Photos reviewed.' },
  { no: 'R-2217', renter: 'Sample Renter 02', car: 'CC 01', carName: 'Mercedes-Benz A220', from: 'Oct 22, 09:00', to: 'Oct 24, 09:00', days: 2, total: '$214.70', status: 'Request', badge: 'badge--hatch', cov: 'Option 2', dep: '$1,000 at pickup', note: 'New request. Age 24, young driver fee applied.' },
  { no: 'B-1043', renter: 'Sample Renter 03', car: 'CC 06', carName: 'Toyota Corolla', from: 'Oct 20, 12:00', to: 'Oct 30, 12:00', days: 10, total: '$565.00', status: 'Confirmed', badge: '', cov: 'Option 3', dep: '$500 charged', note: 'Signed and paid. Licence check due Oct 19.' },
  { no: 'R-2218', renter: 'Sample Renter 04', car: 'CC 05', carName: 'Mercedes-Benz GLE350', from: 'Oct 29, 10:00', to: 'Oct 31, 10:00', days: 2, total: '$863.32', status: 'Request', badge: 'badge--hatch', cov: 'Option 1', dep: '$2,500 at pickup', note: 'Delivery requested. Address to confirm.' },
  { no: 'B-1044', renter: 'Sample Renter 05', car: 'CC 11', carName: 'Chrysler Pacifica', from: 'Oct 17, 08:00', to: 'Oct 24, 08:00', days: 7, total: '$949.20', status: 'Confirmed', badge: '', cov: 'Option 2', dep: '$1,000 hold', note: 'Delivery and pickup. Baby seat x2.' },
  { no: 'Q-0311', renter: 'Sample Renter 06', car: 'CC 04', carName: 'Mercedes-Benz GLC300', from: 'Nov 02, 10:00', to: 'Nov 05, 10:00', days: 3, total: '$457.65', status: 'Quote sent', badge: 'badge--outline', cov: 'Not chosen', dep: '$1,000 at pickup', note: 'Quote sent 14:05. Hold expires 16:05.' },
  { no: 'B-1039', renter: 'Sample Renter 07', car: 'CC 09', carName: 'Toyota RAV4', from: 'Oct 16, 10:00', to: 'Oct 19, 10:00', days: 3, total: '$338.44', status: 'Confirmed', badge: '', cov: 'Option 1', dep: '$1,000 hold', note: 'Pickup tomorrow. Reminder sent.' },
  { no: 'B-1031', renter: 'Sample Renter 08', car: 'CC 08', carName: 'Honda Civic', from: 'Oct 09, 10:00', to: 'Oct 14, 10:00', days: 5, total: '$404.54', status: 'Returned', badge: 'badge--grey', cov: 'Option 2', dep: '$500 released', note: 'Statement sent. 18 km over allowance billed.' }
];

function masterCalendar() {
  const start = PROTO_TODAY; const N = 28; const days = Array.from({ length: N }, (_, i) => add(start, i));
  const dow = ['S', 'M', 'T', 'W', 'T', 'F', 'S'];
  const bar = (r, cls, label, row) => {
    const a = Math.max(0, diff(start, r[0])); const b = Math.min(N - 1, diff(start, r[1])); if (b < 0 || a > N - 1) return '';
    return `<div class="mc__bar ${cls}" style="grid-row:${row};grid-column:${a + 2} / ${b + 3}" title="${label}"><span>${label}</span></div>`;
  };
  let bars = '';
  CARS.forEach((c, i) => {
    const row = i + 2;
    c.booked.forEach((r, j) => { const on = r[0] <= start && r[1] >= start; bars += bar(r, on ? 'is-rent' : 'is-conf', on ? 'On rent' : 'Confirmed', row); });
    c.pending.forEach((r) => { bars += bar(r, 'is-pend', 'Request', row); });
  });
  // quotes that do not block the calendar (outlined)
  bars += bar(['2026-11-02', '2026-11-05'], 'is-open', 'Quote', 5) + bar(['2026-10-26', '2026-10-28'], 'is-open', 'Quote', 9) + bar(['2026-11-04', '2026-11-08'], 'is-open', 'Owner asks', 13) + bar(['2026-10-27', '2026-10-29'], 'is-svc', 'Service', 11);
  return `<div class="mc-wrap" tabindex="0" role="region" aria-label="Fleet master calendar, scrolls sideways">
    <div class="mc" style="--n:${N}" role="img" aria-label="Calendar grid: 12 vehicles down the side, 28 days across, bookings drawn as bars">
      <div class="mc__corner">Vehicle</div>
      ${days.map((d, i) => { const dt = new Date(d + 'T00:00:00Z'); const w = dt.getUTCDay(); return `<div class="mc__day${w === 5 || w === 6 ? ' is-we' : ''}${i === 0 ? ' is-today' : ''}" style="grid-column:${i + 2}"><span>${dow[w]}</span><b>${dt.getUTCDate()}</b></div>`; }).join('')}
      ${CARS.map((c, i) => `<div class="mc__car" style="grid-row:${i + 2}">${plate(c.code)}<span>${c.model}</span></div>${days.map((d, k) => { const w = new Date(d + 'T00:00:00Z').getUTCDay(); return `<div class="mc__cell${w === 5 || w === 6 ? ' is-we' : ''}" style="grid-row:${i + 2};grid-column:${k + 2}"></div>`; }).join('')}`).join('')}
      ${bars}
    </div>
  </div>
  <ul class="mc-legend"><li><i class="mc__bar is-rent"></i>On rent</li><li><i class="mc__bar is-conf"></i>Confirmed</li><li><i class="mc__bar is-pend"></i>Pending request (holds the dates)</li><li><i class="mc__bar is-open"></i>Does not block: quote or owner ask</li><li><i class="mc__bar is-svc"></i>Service or cleaning</li></ul>`;
}

export function styleguide() {
  const c = CARS[2];
  const main = `
<section class="page-head on-dark"><div class="wrap">
  <p class="small muted">For the build team</p>
  <h1 class="d1">Style guide</h1>
  <p class="lead muted">One system for the public site and the admin, owner and staff portals. Tokens first, then every component, then a dense portal screen to prove it holds up.</p>
</div></section>
<div class="wrap sg">
  <nav class="sg-toc" aria-label="Style guide sections"><ul class="toc">${[['colour', 'Colour'], ['type', 'Type'], ['space', 'Space and shape'], ['motion', 'Motion'], ['buttons', 'Buttons'], ['labels', 'Plates and badges'], ['forms', 'Form controls'], ['dates', 'Date picker and calendar'], ['cards', 'Cards'], ['tables', 'Tables'], ['alerts', 'Alerts'], ['tabs', 'Tabs and accordion'], ['overlays', 'Modal and toast'], ['steps', 'Step indicator'], ['skeletons', 'Skeletons'], ['portal', 'Portal sample']].map(([h, l]) => `<li><a href="#${h}">${l}</a></li>`).join('')}</ul></nav>
  <div class="sg-main">
  ${sec('colour', 'Colour', `
    <h3 class="small strong">Red</h3><ul class="sws">${sw('red-600', '#D0111B', 'Brand. Buttons, selection. White text 5.6:1')}${sw('red-700', '#A30C14', 'Hover, pressed')}${sw('red-400', '#FF4D52', 'Red text on black 6.4:1')}${sw('red-100', '#FAD4D6', 'Tint')}${sw('red-50', '#FDEEEE', 'Error surface, range fill')}</ul>
    <h3 class="small strong">Black, white and neutral greys</h3><ul class="sws">${sw('black', '#000000', 'Dark surfaces, text')}${sw('grey-950', '#111111')}${sw('grey-900', '#1A1A1A')}${sw('grey-800', '#2B2B2B', 'Lines on black')}${sw('grey-700', '#474747')}${sw('grey-600', '#5E5E5E', 'Secondary text 6.5:1')}${sw('grey-500', '#7A7A7A', 'Input border')}${sw('grey-400', '#A3A3A3', 'Secondary on black')}${sw('grey-300', '#C9C9C9')}${sw('grey-200', '#E2E2E2', 'Hairlines')}${sw('grey-100', '#F0F0F0', 'Quiet surface')}${sw('grey-50', '#F7F7F7')}${sw('white', '#FFFFFF')}</ul>
    <div class="sg-surfaces"><div class="sg-surface"><b>On white</b><p class="muted small">Secondary text</p><a class="link" href="#colour">Link</a></div><div class="sg-surface on-grey"><b>On grey</b><p class="muted small">Secondary text</p><a class="link" href="#colour">Link</a></div><div class="sg-surface on-dark"><b>On black</b><p class="muted small">Secondary text</p><a class="link" href="#colour">Link</a></div><div class="sg-surface on-red"><b>On red</b><p class="small">Secondary text</p><a class="link" href="#colour">Link</a></div></div>`,
    'No other hues. Status is carried by fill, outline and hatch, never by green or amber.')}
  ${sec('type', 'Type', `
    <div class="sg-type"><p class="d-hero">Hero 152</p><code>.d-hero  Heros Condensed Bold, uppercase, 0.86</code></div>
    <div class="sg-type"><p class="d1">Display one</p><code>.d1  44 to 96 px, 0.92</code></div>
    <div class="sg-type"><p class="d2">Display two</p><code>.d2  34 to 64 px</code></div>
    <div class="sg-type"><p class="d3">Display three</p><code>.d3  26 to 36 px</code></div>
    <div class="sg-type"><p class="d4">Display four</p><code>.d4  22 px</code></div>
    <div class="sg-type"><p class="lead">Lead paragraph. Inter Regular, 17 to 20 px, line height 1.45, set to a measure of 38 em.</p><code>.lead</code></div>
    <div class="sg-type"><p>Body. Inter Regular 16 px on 1.55. Sentence case everywhere outside display type. Numbers in tables and prices use tabular figures: <span class="num">$1,234.56</span>.</p><code>body, .num</code></div>
    <div class="sg-type"><p class="small muted">Small 14 px, secondary colour. Labels are 14 px semibold, sentence case, never tracked caps.</p><code>.small .muted</code></div>`)}
  ${sec('space', 'Space and shape', `
    <ul class="sg-space">${[['s-1', 4], ['s-2', 8], ['s-3', 12], ['s-4', 16], ['s-5', 24], ['s-6', 32], ['s-7', 48], ['s-8', 64], ['s-9', 96], ['s-10', 128]].map(([n, p]) => `<li><i style="width:${p}px"></i><code>${n}</code><span class="muted xs num">${p}px</span></li>`).join('')}</ul>
    <ul class="sg-radii"><li><i style="border-radius:0"></i><code>r-0</code><span class="muted xs">Photos, sections, tables</span></li><li><i style="border-radius:4px"></i><code>r-1  4px</code><span class="muted xs">Plates, badges, days</span></li><li><i style="border-radius:6px"></i><code>r-2  6px</code><span class="muted xs">Buttons, inputs</span></li><li><i style="border-radius:14px"></i><code>r-3  14px</code><span class="muted xs">Things that float</span></li></ul>`,
    'A 4 px base. Radius follows role: the more an element floats above the page, the rounder it is. Photos are always square-cornered.')}
  ${sec('motion', 'Motion', `<table class="spec"><tbody>
    <tr><th scope="row">t-1  120 ms</th><td>Hover and press on controls</td></tr><tr><th scope="row">t-2  220 ms</th><td>Menus, tabs, toggles</td></tr><tr><th scope="row">t-3  420 ms</th><td>Sheets, modals, step bar</td></tr><tr><th scope="row">t-4  800 ms</th><td>Image reveals</td></tr>
    <tr><th scope="row">Easing</th><td><code>cubic-bezier(0.2, 0.7, 0.1, 1)</code> for anything a person triggers. Linear for scroll-driven.</td></tr>
    <tr><th scope="row">Scroll</th><td>Photo wipe and settle, band drift, the line beside numbered steps, the rail progress bar. CSS scroll timelines, IntersectionObserver fallback.</td></tr>
    <tr><th scope="row">Rules</th><td>Only transform, opacity and clip-path animate. Nothing moves under reduced motion. No scroll hijacking.</td></tr></tbody></table>
    <div class="photo photo--32 fx-wipe sg-fx">${carImg(c.slug, 'side')}</div>`)}
  ${sec('buttons', 'Buttons', `
    <div class="row"><button class="btn btn--primary" type="button">Request to book</button><button class="btn" type="button">Find a car</button><button class="btn btn--ghost" type="button">How it works</button><button class="btn btn--quiet" type="button">Clear dates</button><button class="btn" type="button" disabled>Unavailable</button></div>
    <div class="row"><button class="btn btn--primary btn--lg" type="button">Large</button><button class="btn btn--primary" type="button">Default</button><button class="btn btn--primary btn--sm" type="button">Small</button><button class="icon-btn" type="button" aria-label="Previous">${icon('left')}</button><button class="icon-btn" type="button" aria-label="Next">${icon('right')}</button><a class="link link--go" href="#buttons">Text link ${icon('arrow')}</a></div>
    <div class="sg-dark on-dark row"><button class="btn btn--primary" type="button">Primary</button><button class="btn btn--light" type="button">Light</button><button class="btn btn--ghost" type="button">Ghost</button><button class="icon-btn" type="button" aria-label="Next">${icon('right')}</button></div>`,
    'One red button per view: the thing we most want pressed. Labels say what happens and keep that name through the flow.')}
  ${sec('labels', 'Plates and badges', `
    <div class="row">${plate('CC 03')}${plate('CC 03', 'plate--dark')}${plate('R-221704', 'plate--lg')}</div>
    <div class="row"><span class="badge badge--red">On rent</span><span class="badge">Confirmed</span><span class="badge badge--hatch">Request</span><span class="badge badge--outline">Quote sent</span><span class="badge badge--grey">Returned</span></div>`,
    'The plate is the one decorative device, and it always carries a real identifier: a fleet number or a request number. Badges are rectangular and state status only.')}
  ${sec('forms', 'Form controls', `
    <div class="field-row"><div class="field"><label class="label" for="sg-a">Text input</label><input class="input" id="sg-a" placeholder="Placeholder"><p class="hint">Hint text sits under the field.</p></div>
      <div class="field has-error"><label class="label" for="sg-b">With an error</label><input class="input" id="sg-b" value="name@" aria-invalid="true" aria-describedby="sg-b-e"><p class="error" id="sg-b-e">Enter an email address like name@example.com.</p></div></div>
    <div class="field-row"><div class="field is-ok"><label class="label" for="sg-c">Valid</label><input class="input" id="sg-c" value="Sample Renter"></div>
      <div class="field"><label class="label" for="sg-d">Select</label><select class="select" id="sg-d"><option>26 or older</option><option>21 to 25</option><option>18 to 20</option></select></div></div>
    <div class="field"><label class="label" for="sg-e">Textarea <span class="opt">optional</span></label><textarea class="textarea" id="sg-e" placeholder="Anything we should know"></textarea></div>
    <div class="field-row"><fieldset class="stack"><legend class="label">Checkbox and radio</legend><label class="check"><input type="checkbox" checked><span>Deliver it to me</span></label><label class="check"><input type="checkbox"><span>Pick it up at the end</span></label><label class="radio"><input type="radio" name="sg-r" checked><span>Standard</span></label><label class="radio"><input type="radio" name="sg-r"><span>Non-refundable</span></label></fieldset>
      <div class="stack"><fieldset class="field"><legend class="label">Segmented</legend><div class="seg"><label><input type="radio" name="sg-s" checked>Any</label><label><input type="radio" name="sg-s">Automatic</label><label><input type="radio" name="sg-s">Manual</label></div></fieldset>
        <label class="switch"><input type="checkbox" checked> Switch</label>
        <div class="field"><label class="label" for="sg-rg">Range</label><input class="range" id="sg-rg" type="range" min="60" max="190" value="130"></div>
        <div class="field"><span class="label" id="sg-q">Quantity</span><div class="qty" data-min="0" data-max="3"><button type="button" aria-label="Fewer">−</button><output aria-labelledby="sg-q">1</output><button type="button" aria-label="More">+</button><input type="hidden" value="1"></div></div></div></div>
    <fieldset class="stack"><legend class="label">Option cards</legend><label class="option"><input type="radio" name="sg-o" checked><span class="option__title">Option 1: OPCF 27 on my own auto policy</span><span class="option__body">Body text explains the consequence of the choice.</span></label><label class="option"><input type="radio" name="sg-o"><span class="option__title">Option 2: my credit card’s rental coverage</span><span class="option__body">The whole card is the hit area.</span></label></fieldset>`,
    'Fields are 50 px tall with a visible border. Errors are red, bold and say how to fix the problem. Validation runs when a field loses focus, then live while it is being corrected.')}
  ${sec('dates', 'Date picker and calendar', `
    <div class="field" style="max-width:26rem">${dateRange({ id: 'sg' })}</div>
    <p class="small muted">Two buttons open one range calendar: a popover on desktop, a bottom sheet on phones. Arrow keys move by day and week, Page Up and Page Down by month, Escape closes.</p>
    <div class="sg-cal" data-sg-cal></div>`,
    'The same calendar renders inline on the car page with that car’s unavailable days hatched.')}
  ${sec('cards', 'Cards', `<ul class="fleet-grid fleet-grid--3"><li>${carCard(CARS[2])}</li><li>${carCard(CARS[5])}</li><li>${carCard(CARS[3])}</li></ul>`, 'The car card has no box, shadow or radius. The photo is the card. The whole card is one link.')}
  ${sec('tables', 'Tables', `
    <table class="spec"><tbody><tr><th scope="row">Spec table</th><td>Label left, value right, hairline between rows</td></tr><tr><th scope="row">Deposit</th><td>$1,000 at pickup</td></tr></tbody></table>
    <div class="table-scroll" tabindex="0" role="region" aria-label="Data table example"><table class="data"><thead><tr><th scope="col">Data table</th><th scope="col">When</th><th scope="col" class="r">Amount</th></tr></thead><tbody><tr><td>Delivery</td><td>Each way</td><td class="r">$100.00</td></tr><tr><td>Young driver fee</td><td>Ages 21 to 25</td><td class="r">$60.00</td></tr><tr><td>HST</td><td>13%</td><td class="r">$20.80</td></tr></tbody></table></div>`)}
  ${sec('alerts', 'Alerts', `<div class="stack"><p class="alert"><span class="alert__title">Information</span><span>Neutral notes use a black bar on grey.</span></p><p class="alert alert--ok"><span class="alert__title">Confirmed</span><span>Success is a check on black. There is no green in this system.</span></p><p class="alert alert--warn"><span class="alert__title">Heads up</span><span>Warnings are outlined.</span></p><p class="alert alert--error"><span class="alert__title">Something is wrong</span><span>Errors are the only red alert, and they say what to do next.</span></p><p class="proto-note"><b>Prototype note.</b> Dashed boxes mark sample data or controls that only exist in the prototype.</p></div>`)}
  ${sec('tabs', 'Tabs and accordion', `
    <div class="tabs" role="tablist" aria-label="Example tabs"><button class="tab" role="tab" id="sgt1" aria-controls="sgp1" aria-selected="true">Upcoming</button><button class="tab" role="tab" id="sgt2" aria-controls="sgp2" aria-selected="false" tabindex="-1">On rent</button><button class="tab" role="tab" id="sgt3" aria-controls="sgp3" aria-selected="false" tabindex="-1">Past</button></div>
    <div class="tabpanel" id="sgp1" role="tabpanel" aria-labelledby="sgt1"><p class="muted">Upcoming bookings panel.</p></div><div class="tabpanel" id="sgp2" role="tabpanel" aria-labelledby="sgt2" hidden><p class="muted">On rent panel.</p></div><div class="tabpanel" id="sgp3" role="tabpanel" aria-labelledby="sgt3" hidden><p class="muted">Past bookings panel.</p></div>
    ${faq([['Accordion row', 'Native details and summary, so it works without JavaScript and is searchable in the page.'], ['A second row', 'The plus turns into a cross when the row is open.']])}`)}
  ${sec('overlays', 'Modal and toast', `<div class="row"><button class="btn" type="button" data-modal-open="sg-modal">Open modal</button><button class="btn btn--ghost" type="button" data-toast="Request R-221704 confirmed.">Show toast</button></div>
    <dialog class="modal modal--sheet" id="sg-modal" aria-labelledby="sg-modal-t"><div class="modal__head"><h3 class="d4" id="sg-modal-t">Decline this request?</h3><button class="modal__close" type="button" data-modal-close aria-label="Close">×</button></div><div class="modal__body stack"><p>The renter is told the car is not available for those dates. Nothing was charged, so there is nothing to refund.</p><div class="field"><label class="label" for="sg-why">Reason, shown to the renter</label><select class="select" id="sg-why"><option>Car not available</option><option>Outside our delivery range</option><option>Licence not accepted</option></select></div></div><div class="modal__foot"><button class="btn btn--ghost" type="button" data-modal-close>Keep request</button><button class="btn btn--primary" type="button" data-modal-close>Decline request</button></div></dialog>`,
    'Modals use the native dialog element: focus is trapped, Escape closes. On phones they rise as a sheet.')}
  ${sec('steps', 'Step indicator', `<ol class="steps" aria-label="Progress example"><li class="is-done"><b>Dates</b><span> and delivery</span></li><li class="is-current" aria-current="step"><b>Driver</b><span> details</span></li><li><b>Licence</b><span> and coverage</span></li><li><b>Review</b><span> and send</span></li></ol>`, 'Done steps turn black and become links back. The current step is red.')}
  ${sec('skeletons', 'Skeletons and empty states', `<ul class="fleet-grid fleet-grid--3"><li><div class="skeleton sk-img"></div><div class="skeleton sk-title"></div><div class="skeleton sk-line" style="width:40%"></div></li><li><div class="skeleton sk-img"></div><div class="skeleton sk-title"></div><div class="skeleton sk-line" style="width:55%"></div></li><li class="empty empty--box"><p class="d3">No cars match.</p><p class="muted small">An empty state says what happened and offers the way out.</p><button class="btn btn--sm" type="button">Clear filters</button></li></ul>`)}
  </div>
</div>

<section class="portal" id="portal" aria-labelledby="sg-portal">
  <div class="portal__top on-dark"><div class="wrap portal__top-in"><div><p class="small muted">Portal sample, admin</p><h2 class="d2" id="sg-portal">Bookings</h2></div><p class="proto-note">Sample data. Names are placeholders.</p></div></div>
  <div class="wrap portal__body">
    <div class="portal__tools">
      <div class="tabs" role="tablist" aria-label="Filter bookings" data-bookings-filter><button class="tab" role="tab" aria-selected="true" data-status="all">All <span class="num muted">${BOOKINGS.length}</span></button><button class="tab" role="tab" aria-selected="false" tabindex="-1" data-status="Request">Requests <span class="num muted">2</span></button><button class="tab" role="tab" aria-selected="false" tabindex="-1" data-status="Confirmed">Confirmed <span class="num muted">3</span></button><button class="tab" role="tab" aria-selected="false" tabindex="-1" data-status="On rent">On rent <span class="num muted">1</span></button></div>
      <div class="row"><label class="vh" for="pt-q">Search bookings</label><input class="input portal__search" id="pt-q" type="search" placeholder="Search name, car or number"><button class="btn btn--sm" type="button" data-toast="New booking form is not part of this sample.">New booking</button></div>
    </div>
    <div class="portal__split">
      <div class="table-scroll" tabindex="0" role="region" aria-label="Bookings table">
        <table class="data data--dense" data-bookings>
          <thead><tr><th scope="col">No.</th><th scope="col">Renter</th><th scope="col">Car</th><th scope="col">Pickup</th><th scope="col">Return</th><th scope="col" class="r">Days</th><th scope="col" class="r">Total</th><th scope="col">Coverage</th><th scope="col">Status</th></tr></thead>
          <tbody>${BOOKINGS.map((b, i) => `<tr tabindex="0" data-b="${esc(JSON.stringify(b))}"${i === 1 ? ' class="is-selected" aria-selected="true"' : ''}><td class="num strong">${b.no}</td><td>${b.renter}</td><td>${plate(b.car)}</td><td class="num">${b.from}</td><td class="num">${b.to}</td><td class="r">${b.days}</td><td class="r">${b.total}</td><td>${b.cov}</td><td><span class="badge ${b.badge}">${b.status}</span></td></tr>`).join('')}</tbody>
        </table>
      </div>
      <aside class="portal__panel is-open" data-booking-panel aria-label="Booking details">
        <div class="portal__panel-head"><div><span class="plate" data-f="no">${BOOKINGS[1].no}</span> <span class="badge ${BOOKINGS[1].badge}" data-f-status>${BOOKINGS[1].status}</span></div><button class="modal__close" type="button" data-panel-close aria-label="Close details">×</button></div>
        <h3 class="d3" data-f="renter">${BOOKINGS[1].renter}</h3>
        <table class="spec"><tbody><tr><th scope="row">Car</th><td data-f="carName">${BOOKINGS[1].carName}</td></tr><tr><th scope="row">Pickup</th><td class="num" data-f="from">${BOOKINGS[1].from}</td></tr><tr><th scope="row">Return</th><td class="num" data-f="to">${BOOKINGS[1].to}</td></tr><tr><th scope="row">Total</th><td class="num" data-f="total">${BOOKINGS[1].total}</td></tr><tr><th scope="row">Deposit</th><td data-f="dep">${BOOKINGS[1].dep}</td></tr><tr><th scope="row">Coverage</th><td data-f="cov">${BOOKINGS[1].cov}</td></tr></tbody></table>
        <p class="alert"><span class="alert__title">Latest</span><span data-f="note">${BOOKINGS[1].note}</span></p>
        <div class="row"><button class="btn btn--primary btn--sm" type="button" data-toast="Quote sent to the renter.">Confirm and send price</button><button class="btn btn--ghost btn--sm" type="button" data-toast="Adjust form is not part of this sample.">Adjust</button><button class="btn btn--quiet btn--sm" type="button" data-modal-open="sg-modal">Decline</button></div>
      </aside>
    </div>

    <div class="portal__cal-head"><h3 class="d3">Fleet calendar</h3><div class="row"><button class="icon-btn" type="button" aria-label="Earlier" disabled>${icon('left')}</button><span class="strong num">Oct 15 to Nov 11, 2026</span><button class="icon-btn" type="button" aria-label="Later" data-toast="Paging is not part of this sample.">${icon('right')}</button></div></div>
    ${masterCalendar()}
  </div>
</section>`;
  return doc({ file: 'styleguide.html', title: 'Style guide | CarmaCars', desc: 'CarmaCars design tokens and components for the public site and the admin, owner and staff portals.', main, bodyClass: 'p-sg', noindex: true });
}
