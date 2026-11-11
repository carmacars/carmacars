// The words of an event page (release 36, part 5): from the event's own row only (name, venue, months or dates,
// summary, source). Pure.
export interface EventLike { name: string; venue: string; venue_address: string | null; city: string; usual_months: string; starts_on: string | null; ends_on: string | null; summary: string; source_name: string; category: string }

const fmt = (d: string) => new Intl.DateTimeFormat('en-CA', { month: 'long', day: 'numeric', year: 'numeric', timeZone: 'UTC' }).format(new Date(`${d}T12:00:00Z`));
/** "June 5 to 14, 2027" from the announced dates, else "usually in June". */
export function eventWhen(e: Pick<EventLike, 'starts_on' | 'ends_on' | 'usual_months'>, today = new Date().toISOString().slice(0, 10)): { text: string; announced: boolean } {
  if (e.starts_on && (e.ends_on ?? e.starts_on) >= today) return { text: e.ends_on && e.ends_on !== e.starts_on ? `${fmt(e.starts_on)} to ${fmt(e.ends_on)}` : fmt(e.starts_on), announced: true };
  return { text: `usually ${/^(through|late|early|mid)/i.test(e.usual_months) ? e.usual_months.charAt(0).toLowerCase() + e.usual_months.slice(1) : `in ${e.usual_months}`}`, announced: false };
}
const SEASON = new Set(['sports_season', 'concerts', 'theme_park']);
export function eventCopy(e: EventLike, brand: string, today?: string) {
  const w = eventWhen(e, today);
  const title = `Rent a Car for ${e.name}`.length <= 60 ? `Rent a Car for ${e.name}` : `Car Rental for ${e.name}`;
  const lead = [
    `${e.summary} ${SEASON.has(e.category) ? 'Games and shows run' : 'It runs'} ${w.text}${w.announced ? '' : ' (check the organiser for this year’s dates)'}, at ${e.venue}${e.venue_address ? `, ${e.venue_address}` : ''}.`,
    `Rent a car from ${brand} for the trip: delivered to your address, a hotel or the airport, or picked up in Toronto. Send a request with no payment and we confirm the car and the full price before you pay.`
  ];
  const faq = [
    { question: `When is ${e.name}?`, answer: w.announced ? `${w.text}, at ${e.venue}. Source: ${e.source_name}.` : `It is ${w.text}, at ${e.venue}. ${e.source_name} announces each year’s dates.` },
    { question: `Can I get a rental car delivered for ${e.name}?`, answer: `Yes. ${brand} delivers to your address, a hotel or the airport at the time we confirm, or you pick the car up in Toronto.` },
    { question: `Where can I park near ${e.venue}?`, answer: 'The parking section of this page lists lots, garages and streets with parking near the venue, from OpenStreetMap.' }
  ];
  return { title, h1: `Rent a car for ${e.name}`, description: `Rent a car for ${e.name} at ${e.venue}, ${w.text}: delivered or picked up in Toronto, nearby parking and transit. Request with no payment.`.slice(0, 165), lead, faq, when: w };
}
