import Link from 'next/link';
import { money } from '@/lib/format';
import { DeckFrame } from './DeckFrame';
import { BarChart } from './Charts';
import { ReturnsCalculator } from './ReturnsCalculator';
import { FEATURE_GROUPS, SAFETY, type Feature } from './features';
import { computeReturns, firstOfNextMonth, longDate } from './returns';
import type { DeckFigures } from './types';

// The investor deck (migration 0078; docs/changes/2026-10-21-investor-deck.md). Every amount comes from
// app.deck_figures(); the words are the owner's story, told truthfully: structure and public prices, the company's own
// multiplier figure with its footnote, and the Investment Agreement's terms and risks exactly as signed.

export const SHORT_NOTICE = 'Illustrations only, not a forecast or a promise, and not part of any offering memorandum. The investment is offered under prospectus exemptions in Ontario. Past or projected results do not guarantee future results or returns.';
const FULL_NOTICE = [
  'Forward-looking statements. This deck describes plans, growth and how returns are calculated. Those statements and every example, chart and calculation in it are illustrations, not forecasts or promises. Actual results may differ materially.',
  'The investment is a security offered in Ontario under exemptions from the prospectus requirement. No prospectus has been filed and no securities regulator has reviewed this deck or the investment. This deck is not an offering memorandum and is not part of one. Only your signed Investment Agreement sets your terms.',
  'Past results and projected results do not guarantee future results or any return. You could lose all of the money you invest.'
];

const $ = (c: number | null | undefined) => (c === null || c === undefined ? '' : money(c));
const $c = (c: number) => money(c, { cents: true });
const pctOf = (bps: number | null | undefined) => (bps === null || bps === undefined ? '' : `${+(bps / 100).toFixed(2)}%`);
const tierLabel = (min: number, max: number | null) => (max === null ? `${min} or more cars` : min === max ? `${min} car` : `${min} to ${max} cars`);

interface SlideDef { title: string; tone?: 'dark' | 'red' | 'grey'; id?: string; node: React.ReactNode }

function Slide({ s, n }: { s: SlideDef; n: number }) {
  return (
    <section className={`dk-slide${s.tone ? ` dk-slide--${s.tone}` : ''}`} id={s.id ?? `slide-${n}`} aria-label={`Slide ${n}: ${s.title}`} tabIndex={-1} data-testid="deck-slide">
      <div className="dk-slide__in">
        {s.node}
        <footer className="dk-foot">
          <span className="dk-foot__brand">Carma<b>Cars</b></span>
          <span className="dk-foot__note">{SHORT_NOTICE}</span>
          <span className="dk-foot__n" aria-hidden="true" />
        </footer>
      </div>
    </section>
  );
}

function Head({ kicker, title, lead, hero }: { kicker?: string; title: string; lead?: React.ReactNode; hero?: boolean }) {
  return <header style={{ display: 'grid', gap: '0.5em' }}>
    {kicker && <p className="dk-kicker">{kicker}</p>}
    <h2 className={`dk-title${hero ? ' dk-title--hero' : ''}`}>{title}</h2>
    {lead && <p className="dk-lead">{lead}</p>}
  </header>;
}

function FeatureSlide({ f, group }: { f: Feature; group: string }) {
  return (
    <div className="dk-feature">
      <div className="dk-feature__words">
        <p className="dk-kicker">{group}</p>
        <h2 className="dk-title">{f.title}</h2>
        <div><p className="dk-feature__label">What it is</p><p>{f.what}</p></div>
        <div><p className="dk-feature__label">Why it matters</p><p>{f.why}</p></div>
      </div>
      {f.shots?.length ? (
        <div className="dk-shots">
          {f.shots.map((s) => <figure key={s.src} className={`dk-shot dk-shot--${s.kind}`}>
            {/* eslint-disable-next-line @next/next/no-img-element */}
            <img src={s.src} alt={s.alt} loading="lazy" decoding="async" />
          </figure>)}
        </div>
      ) : <div className="dk-noshot">Runs in the background: nothing to click.</div>}
    </div>
  );
}

export function Deck({ f, today }: { f: DeckFigures; today: string }) {
  const b = f.brand;
  const brand = 'CarmaCars';
  const mult = Number(f.settings.deck_multiplier);
  const multText = `${+mult.toFixed(2)}x`;
  const bps = f.settings.deck_return_bps;
  const yearly = pctOf(bps);
  const inv = f.investment;
  const tiers = f.owner_tiers;
  const shares = tiers.map((t) => t.revenue_share_bps);
  const fees = tiers.map((t) => t.monthly_fees_cents);
  const shareRange = shares.length ? `${pctOf(Math.min(...shares))} to ${pctOf(Math.max(...shares))}` : '';
  const feeRange = fees.length ? `${$(Math.min(...fees))} to ${$(Math.max(...fees))}` : '';
  const fee = (k: string) => f.fees?.[k]?.amount_cents ?? null;
  const s = f.sample;
  const start = firstOfNextMonth(today);
  const minC = inv.min_cents;
  const examples = [minC, Math.max(minC, 5_000_000)].filter((v, i, a) => a.indexOf(v) === i);
  const horizons = [1, 2, 3, 5];
  const ex = (amt: number, y: number, reinvest: boolean) => computeReturns({ amountCents: amt, yearlyBps: bps, investmentDate: start, years: y, reinvestMonths: reinvest ? Infinity : 0,
    lockupMonths: inv.lockup_months, paymentDay: inv.payment_day });
  const first = ex(minC, 1, false);
  const perDay = (c: number | null) => (c ? `${$(c)} a day` : '');
  const groupTitles = FEATURE_GROUPS.flatMap((g) => g.features.map((x) => x.title));

  const slides: SlideDef[] = [];
  const add = (x: SlideDef) => slides.push(x);

  // ---------------------------------------------------------------- the story
  add({ title: brand, tone: 'dark', id: 'title', node: <div className="dk-body" style={{ alignContent: 'center', gap: '1.5em' }}>
    <p className="dk-kicker">Investor deck{f.investor_name ? `, prepared for ${f.investor_name}` : ''}</p>
    <p className="dk-wordmark" aria-label={brand}>Carma<b>Cars</b></p>
    <p className="dk-title" style={{ maxWidth: '22em' }}>{b.tagline ?? 'Car rental, run on our own platform.'}</p>
    <p className="dk-lead">Car rental in {b.service_area ?? b.city ?? 'Ontario'}, built on cars owners bring to us and a platform we built ourselves. {longDate(today)}.</p>
  </div> });

  add({ title: 'CarmaCars at a glance', node: <>
    <Head kicker="In one page" title="A rental company that grows without buying every car" lead="Owners bring their cars, CarmaCars rents them out on its own platform, and every rental carries several lines of revenue. Investors back the growth and earn a fixed yearly percentage under a written agreement." />
    <div className="dk-body"><div className="dk-grid">
      <div className="dk-card"><h3>Asset-light supply</h3><p>Owner cars pay us fixed monthly fees and a {shareRange} management fee on their rental revenue. Partner cars earn us a {pctOf(f.partner_commission_bps)} commission with no capital.</p></div>
      <div className="dk-card"><h3>Our own platform</h3><p>Renter, owner, investor, staff, field and Admin portals, with {f.emails} automated emails, AI listings and live chat. Built, owned and run by CarmaCars.</p></div>
      <div className="dk-card"><h3>Many revenue lines</h3><p>Rental, delivery, add-ons, young driver and other renter fees, coverage, and charges after the trip, on every rental.</p></div>
      <div className="dk-card dk-card--accent"><h3>{multText}</h3><p>CarmaCars&apos; figure: a {multText} multiplier on the money we invest in the fleet. Internal, not audited.</p></div>
      <div className="dk-card dk-card--accent"><h3>{yearly} a year</h3><p>On our current offer, set in your agreement. From {$(minC)}. No Return for the {inv.lockup_months}-month lockup, then monthly.</p></div>
    </div></div>
  </> });

  add({ title: 'The problem for renters', tone: 'grey', node: <>
    <Head kicker="The problem" title="Renting a car is still harder than it should be" lead="Counters, paperwork and surprise charges on one side; peer-to-peer apps with uneven hosts on the other." />
    <div className="dk-body"><div className="dk-grid">
      <div className="dk-card"><h3>The price is not the price</h3><p>Fees appear at the counter or at checkout, and the final cost is hard to know in advance.</p></div>
      <div className="dk-card"><h3>Lines and paperwork</h3><p>Pickup means a counter, a queue and paper forms, often far from where the renter is.</p></div>
      <div className="dk-card"><h3>Young drivers left out</h3><p>Drivers under 25 face refusals or high surcharges at many rental companies.</p></div>
      <div className="dk-card"><h3>Uneven peer-to-peer hosts</h3><p>On marketplace apps, every host runs things differently: cancellations, late replies and cars that do not match the photos.</p></div>
    </div></div>
  </> });

  add({ title: 'The problem for car owners', tone: 'grey', node: <>
    <Head kicker="The problem" title="Cars sit idle, and renting one out alone is a job" lead="A car parked most of the day loses value. Renting it out yourself means insurance, screening renters, cleaning, messages, tolls and damage claims." />
    <div className="dk-body"><div className="dk-grid">
      <div className="dk-card"><h3>Idle assets</h3><p>Most private cars are parked most of the time while their payments and depreciation continue.</p></div>
      <div className="dk-card"><h3>Insurance is the hard part</h3><p>A personal policy does not cover renting the car out. Commercial cover for one car is hard to find.</p></div>
      <div className="dk-card"><h3>The work never stops</h3><p>Listings, questions at night, handovers, cleaning, tolls and tickets weeks later.</p></div>
      <div className="dk-card"><h3>The risk of strangers</h3><p>Without checks, deposits and evidence at handover, one bad renter can cost more than a year of income.</p></div>
    </div></div>
  </> });

  add({ title: 'The solution', node: <>
    <Head kicker="The solution" title="CarmaCars runs the rental. Owners earn. Renters get a better trip." />
    <div className="dk-body"><div className="dk-cols" style={{ ['--dk-cols' as string]: 3 }}>
      <div className="dk-card"><h3>For renters</h3><ul className="dk-list"><li>The whole price before booking</li><li>Delivery to the door</li><li>Sign, pay and upload ID on the phone</li><li>A real person reviews every request</li><li>Young drivers welcome on cars that allow them</li></ul></div>
      <div className="dk-card"><h3>For owners</h3><ul className="dk-list"><li>The car on our fleet insurance policy</li><li>We list, screen, hand over, clean and recover charges</li><li>A monthly statement with every line</li><li>Payouts to their bank</li><li>Their own portal to see it all</li></ul></div>
      <div className="dk-card dk-card--accent"><h3>For CarmaCars</h3><ul className="dk-list"><li>Cars without buying them</li><li>Fixed monthly fees per owner car</li><li>A management fee on every owner rental</li><li>All delivery, add-on and renter fee revenue</li><li>A platform that keeps the team small</li></ul></div>
    </div></div>
  </> });

  add({ title: 'How a rental works', node: <>
    <Head kicker="How it works" title="Every rental follows the same checked path" lead="From the first request to the owner's statement, each step is in the platform, with its record." />
    <div className="dk-body"><ol className="dk-flow">
      <li><b>Request</b><span>The renter picks a car and dates and sees the whole price</span></li>
      <li><b>Review</b><span>A person checks the renter, the car and the dates</span></li>
      <li><b>Offer</b><span>The renter approves it, asks for a change or declines</span></li>
      <li><b>Sign</b><span>The rental agreement, online, with each driver</span></li>
      <li><b>Pay</b><span>Card authorized, captured on confirmation</span></li>
      <li><b>Verify</b><span>Licence, selfie and proof of coverage</span></li>
      <li><b>Handover</b><span>Odometer, fuel, photos and signatures on the field app</span></li>
      <li><b>Return</b><span>Tolls, tickets, fuel and cleaning charged by the rules</span></li>
      <li><b>Statement</b><span>The owner sees every line and is paid</span></li>
    </ol></div>
  </> });

  // ---------------------------------------------------------------- the business
  add({ title: 'How CarmaCars adds cars', node: <>
    <Head kicker="Business model" title="Three ways to add cars, two of them without capital" lead="The fleet grows with owners and partners, and CarmaCars earns on every car it rents, whoever owns it." />
    <div className="dk-body"><div className="dk-cols" style={{ ['--dk-cols' as string]: 2 }}>
      <div className="dk-card dk-card--accent"><h3>Owner program</h3><p>Owners bring their cars. Each owner car pays CarmaCars a monthly insurance fee and a monthly tracker fee ({feeRange} a month together, by tier), plus a management fee of {shareRange} of its rental revenue.</p></div>
      <div className="dk-card dk-card--accent"><h3>Brokered partner cars</h3><p>Partner rental companies list their cars with us. CarmaCars earns a {pctOf(f.partner_commission_bps)} commission on the rental charge, with no purchase and no loan.</p></div>
      <div className="dk-card"><h3>Company cars</h3><p>Cars CarmaCars owns keep 100% of their rental revenue.</p></div>
      <div className="dk-card"><h3>A marketplace partner</h3><p>A marketplace partner lists our cars under our policy, bringing renters we do not pay to find.</p></div>
    </div>
    <p className="dk-note">On every car, whatever its supply: delivery, add-ons, young driver and other renter fees, and coverage sold are CarmaCars&apos; own revenue.</p></div>
  </> });

  add({ title: 'The owner program fees', node: <>
    <Head kicker="Owner program" title="Each owner car pays fixed monthly fees on top of its management fee" lead="Our published starting terms, by how many cars an owner brings. Each car's signed schedule sets its own amounts." />
    <div className="dk-body"><div className="dk-scroll"><table className="dk-tbl" data-testid="deck-tiers">
      <thead><tr><th>Cars per owner</th><th className="n">Insurance fee a month</th><th className="n">Tracker fee a month</th><th className="n">Fixed fees a month</th><th className="n">Management fee</th></tr></thead>
      <tbody>{tiers.map((t) => <tr key={t.min_vehicles}><td>{tierLabel(t.min_vehicles, t.max_vehicles)}</td><td className="n">{$(t.insurance_fee_cents)}</td><td className="n">{$(t.tracker_fee_cents)}</td>
        <td className="n"><b>{$(t.monthly_fees_cents)}</b></td><td className="n">{pctOf(t.revenue_share_bps)} of rental revenue</td></tr>)}</tbody>
    </table></div>
    <div className="dk-grid">
      <div className="dk-card"><h3>Paid whether or not the car is booked</h3><p>The monthly fees are invoiced and collected by automatic debit on a set day.</p></div>
      <div className="dk-card"><h3>The management fee follows revenue</h3><p>CarmaCars keeps its share of each rental charge before the owner&apos;s payout.</p></div>
      {f.install_fee_cents ? <div className="dk-card"><h3>{$(f.install_fee_cents)} to start</h3><p>A one-time tracker installation fee per car.</p></div> : null}
    </div></div>
  </> });

  add({ title: 'Many revenue lines per rental', node: <>
    <Head kicker="Revenue" title="One rental, many lines of revenue" lead="Public prices from our site today." />
    <div className="dk-body"><div className="dk-cols" style={{ ['--dk-cols' as string]: 2 }}>
      <div className="dk-card"><h3>The rental</h3><ul className="dk-list">
        {f.rates.min_daily_cents && f.rates.max_daily_cents ? <li>Our listed cars from {$(f.rates.min_daily_cents)} to {$(f.rates.max_daily_cents)} a day, with weekly and monthly rates</li> : <li>Daily, weekly and monthly rates per car</li>}
        {f.rates.delivery_cents ? <li>Delivery to the renter: {$(f.rates.delivery_cents)} on our listed cars</li> : <li>Delivery and return pickup, priced per car</li>}
        {fee('young_driver_21_25') ? <li>Young driver fee: {perDay(fee('young_driver_21_25'))} for 21 to 25, {perDay(fee('young_driver_18_20'))} for 18 to 20</li> : null}
        <li>Additional drivers and coverage sold to renters who need it</li>
      </ul></div>
      <div className="dk-card"><h3>Add-ons</h3><ul className="dk-list">
        {f.addons.slice(0, 8).map((a) => <li key={a.name}>{a.name}: {$(a.price_cents)}{a.unit === 'per_day' ? ' a day' : a.unit === 'per_hour' ? ' an hour' : ''}{a.cap_cents ? ` (at most ${$(a.cap_cents)})` : ''}</li>)}
      </ul></div>
      <div className="dk-card" style={{ gridColumn: '1 / -1' }}><h3>After the trip, charged by the rules</h3><p>
        {[fee('cleaning') && `cleaning ${$(fee('cleaning'))}`, fee('smoking') && `smoking ${$(fee('smoking'))}`, fee('pet_cleaning') && `pet cleaning ${$(fee('pet_cleaning'))}`,
          fee('fuel_service_fee') && `fuel service fee ${$(fee('fuel_service_fee'))} plus fuel`, fee('late_return_fee') && 'late returns by the hour', fee('lost_key_fee') && `lost key fee ${$(fee('lost_key_fee'))}`,
          fee('toll_admin_fee') && `${$(fee('toll_admin_fee'))} administration per toll invoice`, fee('ticket_admin_fee') && `${$(fee('ticket_admin_fee'))} administration per ticket`].filter(Boolean).join(', ')}.
        These are CarmaCars&apos; own revenue, never shared with the car&apos;s owner.</p></div>
    </div></div>
  </> });

  add({ title: 'A sample 3-day rental', node: <>
    <Head kicker="Illustration" title={`How a ${s.days}-day rental stacks up, and who keeps what`} lead={`Built only from public prices: ${f.rates.source === 'real' ? 'the median daily rate of our listed cars' : 'our default daily rate for a standard car'}, ${s.delivery_cents ? 'delivery, ' : ''}one add-on and the young driver fee. Before HST.`} />
    <div className="dk-body"><div className="dk-cols" style={{ ['--dk-cols' as string]: 2 }}>
      <table className="dk-tbl" data-testid="deck-sample">
        <thead><tr><th>Line</th><th className="n">Amount</th></tr></thead>
        <tbody>
          <tr><td>Rental: {s.days} days at {$(s.daily_rate_cents)}</td><td className="n">{$c(s.rental_cents)}</td></tr>
          {s.delivery_cents ? <tr><td>Delivery</td><td className="n">{$c(s.delivery_cents)}</td></tr> : null}
          {s.addon_cents ? <tr><td>{s.addon_name}, {s.days} days</td><td className="n">{$c(s.addon_cents)}</td></tr> : null}
          {s.young_driver_cents ? <tr><td>Young driver fee (21 to 25), {s.days} days</td><td className="n">{$c(s.young_driver_cents)}</td></tr> : null}
          <tr className="dk-tot"><td>The renter pays (before HST)</td><td className="n">{$c(s.total_cents)}</td></tr>
        </tbody>
      </table>
      <table className="dk-tbl" data-testid="deck-splits">
        <thead><tr><th>The car is</th><th className="n">CarmaCars keeps</th><th className="n">Owner or partner</th></tr></thead>
        <tbody>{s.splits.map((x) => <tr key={x.label}>
          <td>{x.label}{x.kind !== 'company' ? ` (${pctOf(x.share_bps)} ${x.kind === 'partner' ? 'commission' : 'management fee'})` : ''}</td>
          <td className="n"><b>{$c(x.company_cents)}</b></td><td className="n">{x.owner_cents ? $c(x.owner_cents) : ''}</td></tr>)}</tbody>
      </table>
    </div>
    <p className="dk-note">CarmaCars keeps its share of the rental charge plus every delivery, add-on and renter fee line. An owner car also pays its fixed monthly fees ({feeRange} a month) whether or not it is booked. Illustration only: real rentals vary in length, price, extras and discounts.</p></div>
  </> });

  add({ title: 'Why the model scales', node: <>
    <Head kicker="Founder's view" title="Why each new car makes the business stronger" />
    <div className="dk-body"><div className="dk-grid">
      <div className="dk-card dk-card--accent"><h3>Fixed fees from owner cars</h3><p>Every owner car adds {feeRange} a month in insurance and tracker fees before it earns a dollar of rent, plus its management fee on every booking.</p></div>
      <div className="dk-card dk-card--accent"><h3>One fleet policy, spread wider</h3><p>The fleet insurance policy is a fixed cost for the business. Every car added spreads that cost further.</p></div>
      <div className="dk-card"><h3>Growth without capital</h3><p>Owner and partner cars join the fleet without CarmaCars buying them.</p></div>
      <div className="dk-card"><h3>Revenue we keep in full</h3><p>Delivery, add-ons and renter fees are ours on every car, owner, partner or company.</p></div>
      <div className="dk-card"><h3>Automation, not headcount</h3><p>Listings, emails, calendars, toll reading, statements and owner debits run by themselves, so the team stays small as the fleet grows.</p></div>
      <div className="dk-card"><h3>Risk controls built in</h3><p>Request to book, verified renters, deposits, a deductible and charges after the trip protect each car&apos;s earnings.</p></div>
    </div></div>
  </> });

  add({ title: `Profitability: ${multText}`, tone: 'red', id: 'multiplier', node: <div className="dk-body" style={{ alignContent: 'center', gap: '1.2em' }}>
    <p className="dk-kicker">Profitability</p>
    <p className="dk-big" data-testid="deck-multiplier">{multText}</p>
    <p className="dk-title" style={{ maxWidth: '24em' }}>CarmaCars&apos; figure: a {multText} multiplier on the money we invest in the fleet.</p>
    <p className="dk-note" style={{ maxWidth: '60em' }}>The company&apos;s own internal figure. It has not been audited or reviewed by an accountant or anyone independent. Past results do not guarantee future results, and this figure is not a forecast and not a promise of any return. Your return is the fixed Yearly Percentage in your agreement, which does not depend on this figure.</p>
  </div> });

  // ---------------------------------------------------------------- the platform
  add({ title: 'The platform at a glance', tone: 'dark', node: <>
    <Head kicker="What we built" title="One platform for everyone in the business" lead={`Seven portals on one website that works on any phone, and the automation behind them. ${groupTitles.length} features follow, each with what it is, why it matters, and the real screen.`} />
    <div className="dk-body"><div className="dk-grid">
      {FEATURE_GROUPS.map((g) => <div key={g.id} className="dk-card"><h3>{g.kicker}</h3><p>{g.features.map((x) => x.title).join('. ')}.</p></div>)}
    </div><p className="dk-note">Screens are shown with fictional people and sample cars.</p></div>
  </> });

  for (const g of FEATURE_GROUPS) {
    add({ title: g.kicker, tone: 'dark', node: <>
      <Head kicker={g.kicker} title={g.title} lead={g.intro} />
      <div className="dk-body"><ol className="dk-flow">{g.features.map((x) => <li key={x.id}><b>{x.title}</b></li>)}</ol></div>
    </> });
    for (const x of g.features) {
      const xx = x.id === 'emails' ? { ...x, title: `${f.emails} automated emails, sent by rules` } : x;
      add({ title: xx.title, node: <FeatureSlide f={xx} group={g.kicker} /> });
    }
  }

  add({ title: 'Safety and risk controls', node: <>
    <Head kicker="Safety and risk" title="Built to protect every car and every dollar" />
    <div className="dk-body"><div className="dk-grid">
      {SAFETY.map((x) => <div key={x.title} className="dk-card"><h3>{x.title}</h3><p>{x.title === 'Deposits and a deductible' && f.deposits?.min_cents
        ? `A refundable deposit of ${$(f.deposits.min_cents)} to ${$(f.deposits.max_cents)} at pickup, by car class, and a deductible of ${$(f.deductible_cents)} the renter owes after damage.` : x.text}</p></div>)}
    </div></div>
  </> });

  add({ title: 'Team and operations', node: <>
    <Head kicker="Team and operations" title="A lean team, supported by the platform" />
    <div className="dk-body"><div className="dk-grid">
      <div className="dk-card"><h3>Founder-led</h3><p>The owner runs CarmaCars as Admin: pricing, owners, partners, investors and every rule of the business.</p></div>
      <div className="dk-card"><h3>Remote assistant team</h3><p>Customer service, fleet, finance and sales assistants, each with their own workspace, queues and targets.</p></div>
      <div className="dk-card"><h3>Field staff</h3><p>Deliveries, handovers, returns, cleaning and photo shoots, guided step by step on a phone.</p></div>
      <div className="dk-card dk-card--accent"><h3>24/7 incident line</h3><p>Renters reach us at any hour for accidents, breakdowns and emergencies{b.incident_phone ? `: ${b.incident_phone}` : ''}.</p></div>
      <div className="dk-card"><h3>Guides for everyone</h3><p>Each portal has its own guide, kept up to date by the platform, so new people start fast.</p></div>
    </div></div>
  </> });

  add({ title: 'Roadmap', node: <>
    <Head kicker="Roadmap" title="What comes next" />
    <div className="dk-body"><ol className="dk-flow">
      <li><b>Native apps</b><span>iOS and Android apps for renters, owners and staff, after the web build</span></li>
      <li><b>GPS trackers</b><span>Location and remote immobilizer on every car; the platform&apos;s tracker interface is ready</span></li>
      <li><b>More partner fleets</b><span>More rental companies listing their cars with us on commission</span></li>
      <li><b>More marketplaces</b><span>More channels listing our cars under our policy</span></li>
    </ol><p className="dk-note">Plans, not promises: timing and scope may change.</p></div>
  </> });

  // ---------------------------------------------------------------- the investment
  add({ title: 'The investment offer', tone: 'dark', id: 'offer', node: <>
    <Head kicker="The offer" title={`${yearly} a year on our current offer, set in your agreement`} lead="An investment contract with CarmaCars: a fixed yearly percentage on your Invested Amount, under a written Investment Agreement." />
    <div className="dk-body"><div className="dk-grid">
      <div className="dk-card"><h3>From {$(minC)}</h3><p>The minimum initial investment. You may add more later, each with its own Investment Date and lockup.</p></div>
      <div className="dk-card"><h3>{inv.lockup_months}-month lockup</h3><p>No Return is earned for the first {inv.lockup_months} months, and that is never made up.</p></div>
      <div className="dk-card dk-card--accent"><h3>Then every month</h3><p>One twelfth of the Yearly Percentage on your Invested Amount, paid on the {inv.payment_day}th of the next month.</p></div>
      <div className="dk-card"><h3>Or reinvest</h3><p>Choose to add each Return to your Invested Amount, so the next month earns on more. Change your choice by notice.</p></div>
      <div className="dk-card"><h3>Fixed, not shares</h3><p>The Return does not change with our results. You get no shares, no vote and no share of profits or of a sale.</p></div>
      <div className="dk-card"><h3>How you exit</h3><p>By a transfer the company approves, or when the company redeems on at least {inv.redemption_notice_months} months&apos; notice. You cannot demand repayment.</p></div>
    </div></div>
  </> });

  const b12 = computeReturns({ amountCents: minC, yearlyBps: bps, investmentDate: start, years: 3, reinvestMonths: 12, lockupMonths: inv.lockup_months, paymentDay: inv.payment_day });
  const after12 = b12.months[12];
  add({ title: 'How your return builds', node: <>
    <Head kicker="Your return" title="How the Return builds, month by month" lead={`${$(minC)} invested on ${longDate(start)} at ${yearly} a year, exactly as the agreement calculates it.`} />
    <div className="dk-body"><ol className="dk-flow">
      <li><b>{longDate(start)}</b><span>Investment Date: the day we receive cleared funds</span></li>
      <li><b>{inv.lockup_months} months</b><span>Lockup: no Return earned</span></li>
      <li><b>{longDate(first.lockupEndDate)}</b><span>Lockup End Date: the first Return Month starts</span></li>
      <li><b>{first.monthlyPaymentCents !== null ? `${$c(first.monthlyPaymentCents)} a month` : ''}</b><span>{$(minC)} x {yearly} / 12, for a full month</span></li>
      <li><b>{first.firstPaymentDate ? longDate(first.firstPaymentDate) : ''}</b><span>First payment, about {first.monthsToFirstPayment} months after you invest</span></li>
    </ol>
    <div className="dk-cols" style={{ ['--dk-cols' as string]: 2 }}>
      <div className="dk-card"><h3>Paid monthly</h3><p>{first.monthlyPaymentCents !== null ? $c(first.monthlyPaymentCents) : ''} every month, paid on the {inv.payment_day}th of the next month, while your {$(minC)} stays invested.</p></div>
      <div className="dk-card dk-card--accent"><h3>Reinvested for 12 months</h3><p>Each Return is added at month end, so your Invested Amount grows to {$c(b12.months[11]?.closingCents ?? minC)}. Switch to paid then and a full month pays {after12 ? $c(after12.returnCents) : ''}.</p></div>
    </div></div>
  </> });

  const series = (amt: number, reinvest: boolean) => horizons.map((y) => { const r = ex(amt, y, reinvest); return reinvest ? r.finalInvestedCents - amt : r.totalPaidCents; });
  add({ title: 'Worked examples', node: <>
    <Head kicker="Worked examples" title={`What ${$(examples[0])}${examples[1] ? ` and ${$(examples[1])}` : ''} can earn at ${yearly}`} lead={`Invested on ${longDate(start)}. Returns earned to the day before each anniversary. The lockup is included, so year 1 has ${12 - inv.lockup_months} Return Months.`} />
    <div className="dk-body"><div className="dk-cols" style={{ ['--dk-cols' as string]: 2 }}>
      <div>
        <BarChart title={`${$(examples[0])}: Returns paid to you or reinvested, after 1, 2, 3 and 5 years`} groups={horizons.map((y) => `${y} ${y === 1 ? 'year' : 'years'}`)}
          series={[{ name: 'Paid monthly: total received', color: '#000000', values: series(examples[0], false) }, { name: 'Reinvested: added to your investment', color: '#D0111B', values: series(examples[0], true) }]} />
        <p className="dk-legend"><span><i style={{ background: '#000' }} />Paid monthly: Returns received</span><span><i style={{ background: '#D0111B' }} />Reinvested: growth of the Invested Amount</span></p>
      </div>
      <div className="dk-scroll"><table className="dk-tbl" data-testid="deck-examples">
        <thead><tr><th>Invested</th><th>Returns</th>{horizons.map((y) => <th key={y} className="n">{y} {y === 1 ? 'yr' : 'yrs'}</th>)}</tr></thead>
        <tbody>{examples.flatMap((amt) => [
          <tr key={`${amt}p`}><td>{$(amt)}</td><td>Paid: received</td>{horizons.map((y) => <td key={y} className="n">{$c(ex(amt, y, false).totalPaidCents)}</td>)}</tr>,
          <tr key={`${amt}r`} className="dk-hl"><td>{$(amt)}</td><td>Reinvested: Invested Amount</td>{horizons.map((y) => <td key={y} className="n">{$c(ex(amt, y, true).finalInvestedCents)}</td>)}</tr>
        ])}</tbody>
      </table>
      <p className="dk-note">Paid monthly: your Invested Amount stays the same and the Returns are paid to you; the last month of each period is paid on the {inv.payment_day}th of the next month. Reinvested: no cash is paid and the whole amount stays invested and at risk. Before any tax.</p></div>
    </div></div>
  </> });

  add({ title: 'Return calculator', id: 'calculator', node: <>
    <Head kicker="Calculator" title="Try your own numbers" />
    <div className="dk-body"><ReturnsCalculator yearlyBps={bps} minCents={minC} lockupMonths={inv.lockup_months} paymentDay={inv.payment_day} defaultDate={start} /></div>
  </> });

  add({ title: 'Key risks', tone: 'grey', id: 'risks', node: <>
    <Head kicker="Key risks" title="Read these before you invest" lead="From the risk acknowledgment you sign with the agreement." />
    <div className="dk-body"><div className="dk-cols" style={{ ['--dk-cols' as string]: 2 }}>
      <ul className="dk-list">
        <li>You could lose all of the money you invest. Nobody guarantees the Return or your Invested Amount. The Return is high because the risk is high.</li>
        <li>The investment is unsecured. It ranks behind the company&apos;s senior obligations: lenders, lessors, governments, staff, vehicle owners, renters, insurers and trade creditors.</li>
        <li>You cannot demand your money back. You exit only by a transfer the company approves, or if the company redeems (on at least {inv.redemption_notice_months} months&apos; notice) or agrees to buy your investment. You may have to hold it indefinitely.</li>
        <li>No Return is earned for the {inv.lockup_months}-month lockup, and it is never made up.</li>
      </ul>
      <ul className="dk-list">
        <li>You get no shares, no vote and no share of profits or of a sale. No shareholder, director or officer is personally liable to you.</li>
        <li>CarmaCars is a new business with little operating history, exposed to accidents, theft, insurance costs, depreciation, regulation, competition and seasonal demand. It may not earn enough to pay the Return.</li>
        <li>The company may raise more from other investors on different terms and take on debt that ranks ahead of you.</li>
        <li>If you reinvest, you receive no cash, your amount at risk grows, and you may owe tax on Returns you did not receive. Not a deposit; not insured; no regulator has reviewed it.</li>
      </ul>
    </div></div>
  </> });

  add({ title: 'How to invest', node: <>
    <Head kicker="How to invest" title={`Invest from ${$(minC)}, all online`} />
    <div className="dk-body"><ol className="dk-flow">
      <li><b>Talk to us</b><span>Call {b.phone ?? ''} or email {b.email ?? ''}. We answer your questions and confirm the terms of the current offer.</span></li>
      <li><b>Receive your agreement</b><span>It appears in this portal under Documents to sign, with the risk acknowledgment and your exemption category.</span></li>
      <li><b>Sign online</b><span>Read it, get advice if you wish, and sign. Your amount, percentage and dates are in Schedule A.</span></li>
      <li><b>Send the funds</b><span>Your Investment Date is the day we receive cleared funds. The {inv.lockup_months}-month lockup starts then.</span></li>
      <li><b>Follow it here</b><span>Your investment, monthly statements and notices, any time in the investor portal.</span></li>
    </ol>
    <p className="dk-screen-only"><Link className="btn btn--primary" href="/investor/sign" prefetch={false}>Documents to sign</Link></p></div>
  </> });

  add({ title: 'Contact', tone: 'dark', id: 'contact', node: <>
    <Head kicker="Contact" title="Let's talk" />
    <div className="dk-body"><div className="dk-cols" style={{ ['--dk-cols' as string]: 2 }}>
      <div className="dk-stat" style={{ gap: '0.6em' }}>
        <span>Phone</span><b>{b.phone_href ? <a className="link" href={`tel:${b.phone_href}`}>{b.phone}</a> : b.phone}</b>
        <span>Email</span><b>{b.email ? <a className="link" href={`mailto:${b.email}`}>{b.email}</a> : null}</b>
        <span>{b.site_url?.replace(/^https?:\/\//, '') ?? 'carmacars.ca'}</span>
      </div>
      <div className="dk-note" style={{ display: 'grid', gap: '0.7em' }}>{FULL_NOTICE.map((t, i) => <p key={i}>{t}</p>)}</div>
    </div></div>
  </> });

  return (
    <DeckFrame titles={slides.map((x) => x.title)}>
      {slides.map((x, i) => <Slide key={i} s={x} n={i + 1} />)}
    </DeckFrame>
  );
}
