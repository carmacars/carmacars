import type { SiteSettings } from '@/lib/types';

// One name, address and phone everywhere (0095): the structured data, the footer and the contact page all print the
// business address of Admin > Settings > Site (0061), which migration 0095 made the street address the site shows.
// The street is shown only when the site shows its street address at all.
export function napAddress(s: SiteSettings): { street: string | null; city: string; region: string; postal: string | null; line: string } {
  const b = s.business;
  const street = s.street_address ? b?.street || null : null;
  const city = b?.city || s.city;
  const region = b?.region || (s.region === 'Ontario' ? 'ON' : s.region);
  const postal = street ? b?.postal_code || null : null;
  return { street, city, region, postal, line: [street, city, [region, postal].filter(Boolean).join(' ')].filter(Boolean).join(', ') };
}

const DAYS = ['Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday', 'Sunday'];

// The AutoRental node (docs/blueprint/14-seo.md section 7.2) from site settings only: the business name, address and
// phone, the hours as set, the map position when set, the profiles, the places served (the location pages), the price
// range of the real cars' daily rates, and a rating only from the published reviews the page itself shows (at least
// seo_rating_min_reviews of them, public.business_rating). No legal company name.
// lite (every page, from the layout, 2026-10-23-ai-search): the node from settings alone, so every page's references to
// #business (a Service's provider, the WebSite's publisher, a car's seller) resolve; the pages that read the fleet add the
// price range, the places served and the rating to the same node.
export function businessLd(s: SiteSettings, base: string, opts: { areas?: string[]; price?: { min: number; max: number } | null; rating?: { count: number; average: number } | null; lite?: boolean } = {}) {
  const sameAs = Object.entries(s.social_links ?? {}).filter(([, v]) => /^https:\/\//.test(v)).map(([, v]) => v);
  if (s.google_place_id) sameAs.push(`https://www.google.com/maps/place/?q=place_id:${s.google_place_id}`);
  const b = s.business;
  const a = napAddress(s);
  const h = s.opening_hours;
  const hours = !h || h.always_open
    ? [{ '@type': 'OpeningHoursSpecification', dayOfWeek: DAYS, opens: '00:00', closes: '23:59' }]
    : [{ '@type': 'OpeningHoursSpecification', dayOfWeek: (h.days ?? []).map((d) => DAYS[(d - 1) % 7]).filter(Boolean), opens: h.open, closes: h.close }];
  const dollars = (c: number) => `$${Math.round(c / 100)}`;
  return {
    '@type': 'AutoRental', '@id': `${base}/#business`, name: b?.name || s.brand_name, url: `${base}/`,
    ...(s.tagline ? { slogan: s.tagline } : {}),
    ...(s.logo.light ? { logo: s.logo.light } : { logo: `${base}/favicon.svg` }),
    image: `${base}/og/default.png`,
    ...(s.phone ? { telephone: s.phone } : {}),
    ...(s.public_email ? { email: s.public_email } : {}),
    ...(s.phone ? { contactPoint: [{ '@type': 'ContactPoint', contactType: 'customer service', telephone: s.phone, ...(s.public_email ? { email: s.public_email } : {}),
      areaServed: b?.country || 'CA', availableLanguage: ['English'] }] } : {}),
    ...(s.google_place_id ? { hasMap: `https://www.google.com/maps/place/?q=place_id:${s.google_place_id}` } : {}),
    ...(opts.lite ? {} : { priceRange: opts.price ? (opts.price.min === opts.price.max ? `${dollars(opts.price.min)} a day` : `${dollars(opts.price.min)} to ${dollars(opts.price.max)} a day`) : '$$' }),
    currenciesAccepted: 'CAD', paymentAccepted: 'Credit card',
    address: { '@type': 'PostalAddress', ...(a.street ? { streetAddress: a.street } : {}), addressLocality: a.city, addressRegion: a.region, ...(a.postal ? { postalCode: a.postal } : {}), addressCountry: b?.country || 'CA' },
    ...(b?.latitude != null && b?.longitude != null ? { geo: { '@type': 'GeoCoordinates', latitude: Number(b.latitude), longitude: Number(b.longitude) } } : {}),
    openingHoursSpecification: hours,
    ...(opts.lite ? {} : { areaServed: (opts.areas?.length ? opts.areas : [s.city]).map((name) => ({ '@type': 'City', name })) }),
    ...(!opts.lite && opts.rating && opts.rating.count > 0 ? { aggregateRating: { '@type': 'AggregateRating', ratingValue: opts.rating.average, reviewCount: opts.rating.count, bestRating: 5, worstRating: 1 } } : {}),
    ...(sameAs.length ? { sameAs } : {})
  };
}

/** The site itself, on every page: its name and the fleet search (the SearchAction). */
export function websiteLd(s: SiteSettings, base: string) {
  return { '@type': 'WebSite', '@id': `${base}/#website`, url: `${base}/`, name: s.brand_name, inLanguage: 'en-CA', publisher: { '@id': `${base}/#business` },
    potentialAction: { '@type': 'SearchAction', target: { '@type': 'EntryPoint', urlTemplate: `${base}/cars?q={search_term_string}` }, 'query-input': 'required name=search_term_string' } };
}
