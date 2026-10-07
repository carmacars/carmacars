// Brand constants. Red, black and white only, plus neutral greys. Values follow prototype/DESIGN.md.
export const BRAND = {
  name: 'CarmaCars',
  legal: '18122211 Canada Inc.',
  site: 'https://carmacars.ca',
  replyTo: 'info@carmacars.ca',
  mailDomain: 'mail.carmacars.ca',
};

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
  bookings: 'CarmaCars <bookings@mail.carmacars.ca>',
  owners: 'CarmaCars <owners@mail.carmacars.ca>',
  billing: 'CarmaCars <billing@mail.carmacars.ca>',
  hello: 'CarmaCars <hello@mail.carmacars.ca>',
};

// Values every email receives. The application sets these once, from program settings.
export const GLOBALS = {
  support_phone: '647-555-0100',
  company_address: 'Mailing address to be confirmed, Toronto, Ontario, Canada',
};

export const GLOBAL_NOTES = {
  support_phone: 'CarmaCars phone line, formatted for display. Set once in program settings.',
  company_address: 'Mailing address of 18122211 Canada Inc. Required by the anti-spam law on marketing email. Set once in program settings.',
};
