// SITE SETTINGS. A stand-in for what the admin portal will edit (Admin > Settings).
// Nothing in the page templates may type one of these values directly.
// null means "not confirmed yet": the page shows a hatched "to be added" marker, or leaves the line out.
// Values confirmed by the owner on October 8, 2026 unless marked otherwise. They match
// site_settings in supabase/migrations/0025_owner_answers.sql.
export const SITE = {
  brand: 'CarmaCars',
  url: 'https://carmacars.ca/',
  tagline: 'What goes around, drives around.',       // confirmed for now
  carmaLine: 'Drive your carma.',                     // the owner's line: fleet band and closing call to action
  // Logo slot. The logo is coming; until then the text wordmark shows. Set image to a file path
  // (for example 'assets/brand/logo.svg') to replace the wordmark everywhere. width and height are the file's pixel size.
  logo: { image: null, imageOnDark: null, width: null, height: null, alt: 'CarmaCars' },
  favicon: null,                                      // null = the drawn stand-in; will be made from the logo
  city: 'Toronto',
  region: 'Ontario',
  serviceArea: 'Toronto, Ontario',                    // used in copy and JSON-LD areaServed
  // Contact (Settings > Contact)
  email: 'contact@carmacars.ca',                      // public address on the site
  emails: {                                           // receiving aliases; see docs/email-aliases.md
    contact: 'contact@carmacars.ca', bookings: 'bookings@carmacars.ca', owners: 'owners@carmacars.ca',
    billing: 'billing@carmacars.ca', privacy: 'privacy@carmacars.ca', investors: 'investors@carmacars.ca'
  },
  phone: { display: '647-575-3377', e164: '+16475753377' },     // phone, WhatsApp and the 24-hour line share one number
  whatsapp: { display: '647-575-3377', link: 'https://wa.me/16475753377' },
  roadsideLine: { display: '647-575-3377', e164: '+16475753377' },
  address: null,                                      // street address: supplied later; shown when set
  mailingAddress: null,                               // for the marketing opt-in line and email footers
  hours: 'Open 24 hours, every day',
  replyWording: 'We reply within 2 hours',
  replyShort: 'within 2 hours',
  social: { instagram: 'https://instagram.com/carmacars.ca', tiktok: 'https://tiktok.com/@carmacars.ca', facebook: null },
  socialLabels: { instagram: 'Instagram', tiktok: 'TikTok', facebook: 'Facebook' },
  // Reviews (Settings > Reviews): our own post-rental reviews plus Google reviews.
  googlePlaceId: null,                                // Google Business Profile place id; null = Google block shows its empty state
  // Legal pages (Settings > Legal pages). The text in docs/source/website_terms_policies.md is final.
  legal: { lastUpdated: 'October 8, 2026', privacyOfficer: null },
  // Investors: no public pitch. A footer link leads to a sign-in page only.
  investorSignIn: true,
  // The legal entity name is deliberately not displayed anywhere on the site.
  legalNameDisplayed: false
};

// COOKIE CONSENT wording. Versioned: a new version asks every visitor again.
// Stored answers go to cookie_consents through public.record_cookie_choice (migration 0025).
export const COOKIES = {
  version: '2026-10-08',
  title: 'Cookies on CarmaCars',
  text: 'We use necessary cookies to keep the site working and your bookings secure. With your consent we also use analytics cookies to see how the site is used, so we can improve it.',
  accept: 'Accept all',
  necessary: 'Necessary only',
  prefs: 'Preferences',
  save: 'Save my choice',
  groups: [
    { code: 'necessary_cookies', name: 'Necessary', always: true, text: 'Sign-in, security and your booking request. Always on.' },
    { code: 'analytics_cookies', name: 'Analytics', always: false, text: 'Counts visits and pages viewed, so we can see what to improve. Off unless you turn it on.' }
  ]
};
