// The words of a hub page (migration 0095), written from the hub's data only: the place, its distance to us, the
// delivery price within our reach, the nearest airport, the landmarks the sources list, the live cars and the term.
// Nothing is invented: a fact the data does not have is left out. A place far from Toronto is told plainly that we
// serve the Toronto area and has no local branch. Relative imports only (the unit test runs it in Node).
import { money } from '../../lib/format.ts';
import type { Hub } from './data.ts';

export interface HubCopy { title: string; description: string; h1: string; lead: string[]; faq: Array<{ question: string; answer: string }> }
const T = (s: string) => s.replace(/\s+/g, ' ').trim();
const BRAND = 'CarmaCars';

/** "Port Credit, Mississauga", "Buffalo, NY", "Guadalajara, Jalisco", "Ontario". */
export function placeLabel(h: Pick<Hub, 'place' | 'ancestors'>): string {
  const p = h.place;
  if (p.kind === 'country' || p.kind === 'province' || p.kind === 'area') return p.name;
  const parent = [...h.ancestors].reverse().find((a) => a.kind === 'city');
  const region = p.region ? p.region.split('-')[1]! : '';
  if (p.kind === 'neighbourhood' && parent) return `${p.name}, ${parent.name}`;
  if (p.country === 'CA' && region === 'ON') return p.name;
  if (p.country === 'MX') return `${p.name}, ${p.region_name ?? region}`;
  return region ? `${p.name}, ${region}` : p.name;
}

/** 0121: a term for mechanical work CarmaCars does not do, only arranges (a request of the auto_service kind). */
export const isAutoService = (t: { lead_kind?: string | null }) => t.lead_kind === 'auto_service';
const clip = (description: string, usd: string) => { const d = T(description + usd); return d.length <= 170 ? d : T(description).slice(0, 170); };
const isWide = (h: Pick<Hub, 'place'>) => ['country', 'province', 'area', 'region'].includes(h.place.kind);
const kmText = (n: number | null | undefined) => (n === null || n === undefined ? '' : `${Math.round(n).toLocaleString('en-CA')} km`);

export function hubCopy(h: Hub, t: { fill: (s: string) => string }): HubCopy {
  const where = placeLabel(h);
  const term = h.term;
  const near = h.delivery.in_reach && !isWide(h);
  const from = h.origin.label === 'our location' ? 'our location in Toronto' : 'central Toronto';
  const fee = h.delivery.fee_from_cents ? money(h.delivery.fee_from_cents) : null;
  const cars = h.counts.car_count ?? h.cars.length;
  const cheapest = h.counts.min_daily_cents ? money(h.counts.min_daily_cents) : null;
  const usd = h.place.country !== 'CA' ? ' Prices are in Canadian dollars.' : '';
  const note = term.intent_note ? t.fill(term.intent_note) : '';

  // the title: the term and the place first, the brand when it fits in 70 characters
  const head = `${term.title} in ${where}`;
  const title = (`${head} | ${BRAND}`.length <= 70 ? `${head} | ${BRAND}` : head).slice(0, 70);
  const h1 = `${term.title} in ${where}`;

  let description: string;
  const lead: string[] = [];
  if (term.vertical === 'rental') {
    const stock = cars > 0 ? `${cheapest ? `from ${cheapest} a day` : 'live prices'}` : 'cars listed as they join the fleet';
    if (term.served === 'request') {
      description = `${term.title} in ${where}: ${note || 'not something we offer directly.'} Send the details and a person replies.`;
      lead.push(note, `Tell us the date, the trip and how many people, and we will reply with what we can arrange in ${where}.`);
    } else if (near || isWide(h)) {
      description = `${term.title} in ${where}, ${stock}. ${fee ? `Delivered from ${fee}` : 'Delivered to your door'} or picked up in Toronto. Request with no payment up front.`;
      lead.push(isWide(h) ? `${BRAND} rents cars from our location in Toronto and delivers across the Toronto area. Pick a place below, or see the cars.` :
        `${BRAND} brings rental cars to ${where}, about ${kmText(h.delivery.km)} from ${from}. ${fee ? `Delivery starts at ${fee} each way, priced in your offer.` : 'Each car shows its delivery fee on its page.'} You can also pick the car up from us at no charge.`);
      if (note) lead.push(note);
    } else {
      description = `${term.title} for ${where}: ${BRAND} serves the Toronto area, about ${kmText(h.delivery.km)} away. Tell us what you need in ${where} and a person replies.`;
      lead.push(`${BRAND} rents cars in the Toronto area and has no location in ${where}. ${where} is about ${kmText(h.delivery.km)} from ${from}, beyond the ${kmText(h.delivery.reach_km)} we deliver to.`,
        `If you are travelling from Toronto, rent with us before you leave. If you need a car in ${where}, send a request and we will tell you honestly whether we can help.`);
    }
  } else if (term.vertical === 'sale') {
    description = `${term.title} in ${where}? ${BRAND} does not sell, finance or lease cars. Rent the model first, or tell us what you need and we will help.`;
    lead.push(note, `${/\brent/i.test(note) ? '' : 'Renting the car you are thinking of buying, for a day or a week, is a real test drive on your own roads.'}${near ? ` We deliver rental cars to ${where}.` : ''}`);
  } else if (isAutoService(term)) {
    // 0121: mechanical work we arrange, never ours: a request, a trusted shop, and a rental while the car is in
    if (near || isWide(h)) {
      description = `${term.title} in ${where}: request it and we arrange it with a trusted shop or connect you with one, and keep you moving with a rental car while yours is in.`;
      lead.push(note, `${BRAND} does not do this work itself. Send a request and a person replies: we arrange it with a trusted shop or connect you with one, and we can deliver a rental car to you while yours is in.`);
    } else {
      description = `${term.title} for ${where}: ${BRAND} works in the Toronto area, about ${kmText(h.delivery.km)} away, and does not do this work itself. Send a request and a person replies.`;
      lead.push(`${BRAND} works in the Toronto area and has no location in ${where}, about ${kmText(h.delivery.km)} from ${from}.`,
        `${note} If you need it in ${where}, send a request and we will tell you honestly whether we know a shop there.`);
    }
  } else {
    const what = h.service ? h.service.name.toLowerCase() : term.phrase;
    const price = h.service?.from_price_cents ? `from ${money(h.service.from_price_cents)}` : 'price on request';
    const label = term.vertical === 'bodyshop' ? 'body shop' : 'detailing';
    if (near || isWide(h)) {
      description = `${term.title} in ${where} by ${BRAND}: ${what}, ${price}. Need a car while yours is with us? Rent one, delivered.`;
      lead.push(`${note} ${BRAND} does ${what} for cars in ${where}${h.delivery.km !== null && !isWide(h) ? `, about ${kmText(h.delivery.km)} from ${from}` : ''}. Send a request and a person replies with a price and a time.`);
    } else {
      description = `${term.title} for ${where}: ${BRAND}'s ${label} work is in the Toronto area, about ${kmText(h.delivery.km)} away. Send a request and a person replies.`;
      lead.push(`${BRAND}'s ${label} work is in the Toronto area, and we have no location in ${where}, about ${kmText(h.delivery.km)} from ${from}.`, `${note} If you can bring the car to Toronto, send a request.`);
    }
  }

  // questions answered from the data (none on the mechanical work we arrange: those pages carry no questions)
  const faq: Array<{ question: string; answer: string }> = [];
  if (isAutoService(term)) return { title: T(title), description: clip(description, usd), h1: T(h1), lead: lead.map(T).filter(Boolean), faq };
  if (!isWide(h)) {
    faq.push({ question: `Does ${BRAND} have a location in ${where}?`, answer: `No. ${BRAND} has one location, in Toronto${near ? `, and we deliver to ${where}` : ''}.` });
    if (h.delivery.km !== null) faq.push({ question: `How far is ${where} from ${BRAND}?`, answer: `About ${kmText(h.delivery.km)} in a straight line from ${from}.` });
  }
  if (term.vertical === 'rental' && term.served === 'yes') {
    faq.push(near
      ? { question: `Can you deliver a rental car to ${where}?`, answer: `Yes. ${fee ? `Delivery starts at ${fee} each way, and each car's page shows its own fee.` : `Each car's page shows its delivery fee.`} The full price is in your offer before you pay.` }
      : isWide(h) ? { question: `Where do you deliver?`, answer: `To addresses within about ${kmText(h.delivery.reach_km)} of ${from}, including Toronto Pearson and Billy Bishop airports.` }
      : { question: `Can you deliver a rental car to ${where}?`, answer: `Not as a rule: ${where} is beyond the ${kmText(h.delivery.reach_km)} we deliver to. Send a request and we will tell you if we can make an exception.` });
    faq.push({ question: `Do I pay when I send a request?`, answer: `No. The request is free and does not hold the car. You pay only after we confirm the car and the price and you approve the offer.` });
  }
  if (h.airport && !isWide(h)) faq.push({ question: `What is the nearest airport to ${where}?`, answer: `${h.airport.name}${h.airport.iata ? ` (${h.airport.iata})` : ''}, about ${kmText(h.airport.km)} away.` });
  if (term.vertical === 'sale') faq.push({ question: `Does ${BRAND} sell or finance cars?`, answer: `No. ${BRAND} rents cars and does detailing and body work. We are not a dealer, a lender or a leasing company.` });
  if (term.vertical === 'detailing' || term.vertical === 'bodyshop') {
    faq.push({ question: `How much does ${term.phrase} cost?`, answer: h.service?.from_price_cents ? `From ${money(h.service.from_price_cents)}. Send a request for a price for your car.` : `It depends on the car and the work. Send a request and we reply with a price.` });
    faq.push({ question: `Can I have a car while mine is in the shop?`, answer: term.vertical === 'bodyshop' ? `Yes. Rent a car delivered to you; after a collision your insurer may pay for a replacement rental when your adjuster approves it.` : `Yes. Rent one of our cars, delivered to your door, for as long as the work takes.` });
  }
  for (const q of term.faq ?? []) faq.push({ question: t.fill(q.question), answer: t.fill(q.answer) });
  return { title: T(title), description: clip(description, usd), h1: T(h1), lead: lead.map(T).filter(Boolean), faq: faq.slice(0, 6) };
}
