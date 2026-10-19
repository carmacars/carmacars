import type { SiteSettings } from '@/lib/types';

// The AutoRental node (docs/blueprint/14-seo.md section 7.2), from site settings only: the business name, address and
// phone of Admin > Settings > Site (0061), the hours, the map position when set, the profiles, and the places served
// (the location pages). No ratings: Google treats a business's own ratings as self-serving. No legal company name.
export function businessLd(s: SiteSettings, base: string, opts: { openAllDay?: boolean; areas?: string[] } = { openAllDay: true }) {
  const sameAs = Object.entries(s.social_links ?? {}).filter(([, v]) => /^https:\/\//.test(v)).map(([, v]) => v);
  if (s.google_place_id) sameAs.push(`https://www.google.com/maps/place/?q=place_id:${s.google_place_id}`);
  const b = s.business;
  const allDay = opts.openAllDay ?? true;
  return {
    '@type': 'AutoRental', '@id': `${base}/#business`, name: b?.name || s.brand_name, url: `${base}/`,
    ...(s.tagline ? { slogan: s.tagline } : {}),
    ...(s.logo.light ? { logo: s.logo.light } : { logo: `${base}/favicon.svg` }),
    image: `${base}/og/default.png`,
    ...(s.phone ? { telephone: s.phone } : {}),
    ...(s.public_email ? { email: s.public_email } : {}),
    priceRange: '$$', currenciesAccepted: 'CAD', paymentAccepted: 'Credit card',
    address: { '@type': 'PostalAddress', ...(b?.street ? { streetAddress: b.street } : {}), addressLocality: b?.city || s.city,
      addressRegion: b?.region || (s.region === 'Ontario' ? 'ON' : s.region), ...(b?.postal_code ? { postalCode: b.postal_code } : {}), addressCountry: b?.country || 'CA' },
    ...(b?.latitude != null && b?.longitude != null ? { geo: { '@type': 'GeoCoordinates', latitude: Number(b.latitude), longitude: Number(b.longitude) } } : {}),
    openingHoursSpecification: [{ '@type': 'OpeningHoursSpecification', dayOfWeek: ['Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday', 'Sunday'], opens: '00:00', closes: allDay ? '23:59' : '18:00' }],
    areaServed: (opts.areas?.length ? opts.areas : [s.city]).map((name) => ({ '@type': 'City', name })),
    ...(sameAs.length ? { sameAs } : {})
  };
}

/** The site itself, on every page: its name and the fleet search (the SearchAction). */
export function websiteLd(s: SiteSettings, base: string) {
  return { '@type': 'WebSite', '@id': `${base}/#website`, url: `${base}/`, name: s.brand_name, inLanguage: 'en-CA', publisher: { '@id': `${base}/#business` },
    potentialAction: { '@type': 'SearchAction', target: { '@type': 'EntryPoint', urlTemplate: `${base}/cars?q={search_term_string}` }, 'query-input': 'required name=search_term_string' } };
}
