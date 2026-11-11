import { money } from '../../lib/format.ts';

// The words of an airport page (release 36, part 10): delivered to the terminal at the standard delivery price, from
// the airport's own row. Factual: what CarmaCars does, nothing about other companies. Pure.
export function airportCopy(a: { code: string; name: string; km: number | null; delivery_from_cents: number | null }, brand: string) {
  const fee = a.delivery_from_cents ? money(a.delivery_from_cents) : null;
  const short = a.name.replace(/ International Airport$| Toronto City Airport$/, '');
  return {
    title: `${short} (${a.code}) Car Rental, Delivered to the Terminal | ${brand}`.slice(0, 70),
    description: `Rent a car at ${a.name} (${a.code}): ${brand} meets you at the terminal with the car${fee ? `, delivery from ${fee}` : ''}. No rental counter, no shuttle. Request with no payment.`.slice(0, 165),
    h1: `${short} (${a.code}) car rental, delivered to the terminal`,
    lead: [
      `${brand} brings the car to ${a.name} and meets you at the terminal at the time we confirm, so there is no rental counter to queue at and no shuttle to a lot.${a.km ? ` The airport is about ${Math.round(a.km)} km from our location.` : ''}`,
      `${fee ? `Airport delivery starts at ${fee}, the standard delivery price for the distance, and each car shows its own fee. ` : ''}Return the car at the terminal too, or at our location. Send a request with no payment: we confirm the car, the time and the full price before you pay.`
    ],
    faq: [
      { question: `Where do I get the car at ${a.code}?`, answer: `At the terminal. We confirm the meeting point and time with your offer, and meet you there with the car.` },
      { question: `How much is delivery to ${a.code}?`, answer: fee ? `From ${fee}, the standard delivery price for the distance. The exact fee for your car is in your offer before you pay.` : `Each car's page shows its delivery fee; the exact fee is in your offer before you pay.` }
    ]
  };
}
