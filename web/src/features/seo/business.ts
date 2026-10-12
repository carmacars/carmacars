import type { SiteSettings } from '@/lib/types';

// The AutoRental node (docs/blueprint/14-seo.md section 7.2), from site settings only. No ratings
// (Google treats a business's own ratings as self-serving), no legal company name (it never appears
// on the site), and the street address only when the settings say to show one.
export function businessLd(s: SiteSettings, base: string, opts: { openAllDay?: boolean } = { openAllDay: true }) {
  const sameAs = Object.entries(s.social_links ?? {}).filter(([, v]) => /^https:\/\//.test(v)).map(([, v]) => v);
  if (s.google_place_id) sameAs.push(`https://www.google.com/maps/place/?q=place_id:${s.google_place_id}`);
  return {
    '@type': 'AutoRental', '@id': `${base}/#business`, name: s.brand_name, url: `${base}/`,
    ...(s.tagline ? { slogan: s.tagline } : {}),
    ...(s.logo.light ? { logo: s.logo.light } : {}),
    image: `${base}/og/default.png`,
    ...(s.phone ? { telephone: s.phone } : {}),
    ...(s.public_email ? { email: s.public_email } : {}),
    priceRange: '$$',
    address: { '@type': 'PostalAddress', ...(s.street_address ? { streetAddress: s.street_address } : {}), addressLocality: s.city, addressRegion: s.region === 'Ontario' ? 'ON' : s.region, addressCountry: 'CA' },
    openingHoursSpecification: [{ '@type': 'OpeningHoursSpecification', dayOfWeek: ['Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday', 'Sunday'], opens: '00:00', closes: opts.openAllDay ? '23:59' : '18:00' }],
    areaServed: { '@type': 'City', name: s.city },
    ...(sameAs.length ? { sameAs } : {})
  };
}
