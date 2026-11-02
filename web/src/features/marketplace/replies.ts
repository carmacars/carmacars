// The Marketplace inbox replies (migration 0410, docs/runbooks/marketplace.md): one short answer per question buyers ask,
// filled from the car's own record. Never "rent", "rental" or "for rent" (the owner, November 1, 2026): the car is booked by the day. Every reply ends on the next step: request on carmacars.ca (the car's tracked link,
// utm_content=reply so the report can tell a reply from the listing), or send a phone number for a call.
// Pure (no I/O). Relative imports only.
import { carName, money, type CarFacts, type Rules } from '../ads/listing.ts';

export type ReplyKey = 'available' | 'price' | 'availability' | 'requirements' | 'deposit' | 'delivery' | 'number' | 'after_number';
export interface Reply { key: ReplyKey; label: string; when: string; text: string }

export const replyLink = (link: string) => { const u = new URL(link); u.searchParams.set('utm_content', 'reply'); return u.toString(); };

/** The replies for one car. link: the kit's tracked link (utm_source=fb_marketplace). */
export function replies(c: CarFacts, r: Rules, link: string, phone: string | null): Reply[] {
  const name = carName(c);
  const l = replyLink(link);
  const ask = 'Send your phone number and we will call you in a few minutes.';
  const minAge = c.allows_18_to_20 && r.min_age ? r.min_age : r.standard_min_age;
  const rates = [c.daily ? `${money(c.daily)} a day` : null, c.weekend && c.weekend !== c.daily ? `${money(c.weekend)} a day on weekends` : null,
    c.weekly ? `${money(c.weekly)} a week` : null, c.monthly ? `${money(c.monthly)} for 30 days` : null].filter(Boolean).join(', ');
  return [
    { key: 'available', label: 'Is this still available?', when: 'The first message (Meta\'s auto-reply sends the same words while it is on)',
      text: `Hi! Yes, the ${name} is available to book by the day or week (not for sale). Pick your dates and see the full price here: ${l}\n\n${ask}` },
    { key: 'price', label: 'Price', when: 'How much? Best price? Weekly or monthly?',
      text: `The ${name} is ${rates || 'priced by the day'}, plus HST${c.km ? `, with ${c.km} km a day included` : ''}. Longer bookings cost less a day. Your exact total for your dates shows here before you send anything: ${l}\n\n${ask}` },
    { key: 'availability', label: 'Availability', when: 'Is it free on my dates? Today? This weekend?',
      text: `The live calendar for the ${name} is here, and you can request your dates in 2 minutes (nothing is charged until we confirm): ${l}\n\nOr send your number and your dates, and we will call you to book it.` },
    { key: 'requirements', label: 'Requirements', when: 'What do I need? Age? G2? Insurance? Credit card?',
      text: `To book: ${minAge ? `age ${minAge} or older, ` : ''}a G2 or G licence, and one coverage option: OPCF 27 on your own auto policy, a credit card with collision damage cover, or our Protection Plan.${c.no_credit_card ? '' : ' A credit card in your name for the deposit.'} Request here and upload your licence: ${l}\n\n${ask}` },
    { key: 'deposit', label: 'Deposit', when: 'Is there a deposit? How much? Cash?',
      text: `${c.deposit ? `The refundable deposit for the ${name} is ${money(c.deposit)}, held on pickup day` : `The refundable deposit is held on pickup day`} and returned after the trip once tolls and tickets are clear. Full details for your dates: ${l}\n\n${ask}` },
    { key: 'delivery', label: 'Delivery', when: 'Can you deliver? Where is it? Pickup location?',
      text: `${c.delivery ? `Yes, we deliver across Ontario from ${money(c.delivery)} each way` : 'Yes, we can deliver'}, or you can pick it up from us. Put your address in the request and the delivery price is in your total: ${l}\n\n${ask}` },
    { key: 'number', label: 'Send your number', when: 'Any other question, a long chat, a haggler, or someone ready to book',
      text: `Easiest by phone. Send your number and one of our team will call you in a few minutes${phone ? `, or call or text us at ${phone}` : ''}. You can also book it here: ${l}` },
    { key: 'after_number', label: 'After they send a number', when: 'Right after a number arrives (then log it in Admin)',
      text: `Thank you! Someone from CarmaCars will call you shortly. To save time, you can start the request here: ${l}` }
  ];
}
