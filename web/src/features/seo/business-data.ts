import 'server-only';
import { cache } from 'react';
import { rpc } from '@/lib/db/repo';
import { getFleet } from '@/lib/site';
import { getSeoLinks } from './data';

// What the AutoRental node needs beyond site settings (0095): the places served (the city landing pages), the range
// of the real cars' daily rates (sample cars never count), and the business rating when enough published reviews exist.
export const getBusinessFacts = cache(async () => {
  const [links, fleet, rating] = await Promise.all([getSeoLinks().catch(() => []), getFleet(), rpc('business_rating', {}).catch(() => null)]);
  const real = fleet.filter((c) => !c.is_sample && c.daily_rate_cents).map((c) => c.daily_rate_cents);
  return {
    areas: links.filter((l) => l.kind === 'location' && !/airport|station/i.test(l.slug)).map((l) => l.name),
    price: real.length ? { min: Math.min(...real), max: Math.max(...real) } : null,
    rating: (rating as { count: number; average: number } | null) ?? null
  };
});
