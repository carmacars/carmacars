// Brand constants. Red, black and white only, plus neutral greys.
export const BRAND = {
  name: 'CarmaCars',
  legal: '18122211 Canada Inc.',
  site: 'https://carmacars.ca',
  replyTo: 'info@carmacars.ca',
  mailDomain: 'mail.carmacars.ca',
};

export const C = {
  red: '#D90429',     // the one red: buttons, top rule, key figures
  black: '#0A0A0A',
  ink: '#111111',     // body text
  mid: '#5C5C5C',     // secondary text
  soft: '#8A8A8A',    // labels
  rule: '#E4E4E4',
  wash: '#F5F5F5',    // notice and table wash
  page: '#EDEDED',
  white: '#FFFFFF',
  onBlack: '#C8C8C8', // secondary text on the black bands
  slot: '#1C1C1E',    // vehicle photo placeholder
};

export const FONT = "'Helvetica Neue', Helvetica, Arial, sans-serif";

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
