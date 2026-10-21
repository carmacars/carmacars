// Brand constants. Red, black and white only, plus neutral greys. Values follow prototype/DESIGN.md.
// The sender is shown as CarmaCars only. No numbered company or "operated by" line appears in any
// email. TO CONFIRM WITH THE LAWYER: whether the anti-spam law (or any other rule) requires the
// legal name of the business on commercial (marketing) emails. If it does, add it back to the
// footer in layout.mjs for marketing emails only, and to check 10 in check.mjs.
export const BRAND = {
  name: 'CarmaCars',
  site: 'https://carmacars.ca',
  mailDomain: 'carmacars.ca',
};

// Receiving aliases, set up in Google Workspace (see docs/email-aliases.md).
// Replies go to the desk that handles the email. Sending addresses are at carmacars.ca (FROM below).
export const ALIASES = {
  contact: 'contact@carmacars.ca',     // public address; account and marketing emails to renters; staff notices
  bookings: 'bookings@carmacars.ca',   // renter booking emails
  owners: 'owners@carmacars.ca',       // owner emails
  billing: 'billing@carmacars.ca',     // money emails to renters and owners
  privacy: 'privacy@carmacars.ca',     // personal information and account security
  investors: 'investors@carmacars.ca', // investor emails
};
// The reply-to rule, in order: an email's own replyTo key; investors to investors@; staff to contact@;
// money emails (sent from billing) to billing@; owners to owners@; renter booking emails to bookings@;
// other renter emails (account, marketing) to contact@. emails/check.mjs enforces the same rule.
export function replyToFor(email) {
  if (email.replyTo) return ALIASES[email.replyTo];
  if (email.audience === 'investor') return ALIASES.investors;
  if (email.audience.startsWith('staff_')) return ALIASES.contact;
  if (email.from === FROM.billing) return ALIASES.billing;
  if (email.audience === 'owner') return ALIASES.owners;
  if (email.from === FROM.bookings) return ALIASES.bookings;
  return ALIASES.contact;
}

export const C = {
  red: '#D0111B',      // --red-600, the CarmaCars red: buttons, top rule, key figures, "Cars" in the wordmark
  redDark: '#A30C14',  // --red-700, hover and pressed (used as the button border)
  redOnBlack: '#FF4D52', // --red-400, small red text on black
  black: '#000000',
  ink: '#000000',      // body text
  mid: '#5E5E5E',      // --grey-600, secondary text on white
  soft: '#7A7A7A',     // --grey-500, labels
  rule: '#E2E2E2',     // --grey-200, hairlines
  wash: '#F0F0F0',     // --grey-100, quiet surface
  page: '#F0F0F0',
  white: '#FFFFFF',
  onBlack: '#C9C9C9',  // --grey-300, lead text on black
  labelOnBlack: '#A3A3A3', // --grey-400, secondary text on black
  slot: '#1A1A1A',     // --grey-900, vehicle photo placeholder
};

// Matches the site tokens in prototype/assets/css/tokens.css. No web fonts are loaded in email.
export const FONT = "Inter, 'Helvetica Neue', Helvetica, 'Segoe UI', Roboto, Arial, sans-serif";
// Wordmark: bold italic condensed. Falls back through the condensed faces most systems carry, then to Arial bold italic.
export const FONT_WORDMARK = "'Heros Condensed', 'HelveticaNeue-CondensedBold', 'Helvetica Neue Condensed', 'Arial Narrow', 'Roboto Condensed', 'Liberation Sans Narrow', Arial, Helvetica, sans-serif";

// Sender addresses. Display name is always CarmaCars.
export const FROM = {
  bookings: 'CarmaCars <bookings@carmacars.ca>',
  owners: 'CarmaCars <owners@carmacars.ca>',
  billing: 'CarmaCars <billing@carmacars.ca>',
  hello: 'CarmaCars <hello@carmacars.ca>',
};

// Values every email receives. The application sets these once, from program settings.
export const GLOBALS = {
  support_phone: '289-312-5991',
  contact_email: 'contact@carmacars.ca',
  opening_hours: 'Open 24 hours, every day',
  reply_time: 'within 2 hours',
  instagram_url: 'https://instagram.com/carmacars.ca',
  tiktok_url: 'https://tiktok.com/@carmacars.ca',
  company_address: 'Mailing address to be confirmed, Toronto, Ontario, Canada',
};

export const GLOBAL_NOTES = {
  support_phone: 'CarmaCars phone, WhatsApp and 24-hour line, formatted for display (site_settings.phone_display). Set once in settings.',
  contact_email: 'Public contact address shown in the footer (site_settings public email).',
  opening_hours: 'Opening hours wording (site_settings.opening_hours_text).',
  reply_time: 'Reply-time promise, used after "We reply" (site_settings reply wording).',
  instagram_url: 'Instagram profile address (social_links).',
  tiktok_url: 'TikTok profile address (social_links).',
  company_address: 'Mailing address of CarmaCars. Required by the anti-spam law on marketing email. Set once in settings.',
};
