// SITE SETTINGS. A stand-in for what the admin portal will edit (Admin > Settings).
// Nothing in the page templates may type one of these values directly.
// null means "not confirmed yet": the page shows a hatched "to be added" marker.
export const SITE = {
  brand: 'CarmaCars',
  url: 'https://carmacars.ca/',
  tagline: 'What goes around, drives around.',
  // Logo slot. Set image to a file path (for example 'assets/brand/logo.svg') to
  // replace the text wordmark everywhere. width and height are the file's pixel size.
  logo: { image: null, imageOnDark: null, width: null, height: null, alt: 'CarmaCars' },
  city: 'Toronto',
  region: 'Ontario',
  serviceArea: 'Toronto, Ontario',   // used in copy and JSON-LD areaServed
  deliveryArea: null,                // e.g. 'Toronto, Mississauga, Vaughan'. null = "confirmed with your booking"
  airportDelivery: null,             // true, false or null (not decided)
  email: 'info@carmacars.ca',        // UNCONFIRMED: from planning notes
  phone: null,
  whatsapp: null,
  roadsideLine: null,
  address: null,
  hours: null,                       // e.g. 'Every day, 9 a.m. to 6 p.m.'
  social: { instagram: null, tiktok: null, facebook: null },
  reviewSource: null,                // e.g. 'Google' or 'CarmaCars renters'
  replyWording: 'We reply as fast as we can during opening hours',
  // The legal entity name is deliberately not displayed anywhere on the site.
  legalNameDisplayed: false
};
