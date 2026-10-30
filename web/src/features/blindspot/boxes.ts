// Every box of Blind Spot's rental agreement form (Release 21b, item 8: the form-completeness audit), by the name layout.ts
// gives it, with what fills it. The form has no fillable field (layout.ts draws each value in its box), so this list is the
// form's field list: boxes.test.ts fails when layout.ts draws a box that is not here, or when a box here is neither drawn
// (a value, or N/A when it does not apply) in some booking nor listed in BLANK with the reason it stays empty.
// Relative imports with their extension: the unit tests run this file in Node directly.

export const BOXES: Record<string, string> = {
  ra: 'RA #: the booking number',
  address: 'Top left: the mailing address (covers the old one)',
  '1': 'HST REG. NO.: CarmaCars\' HST number (blank until entered in Program settings)',
  '2': 'P.O. number: N/A (not collected)',
  '3': 'The renter\'s legal name',
  '3-cell': 'Cell phone: the renter\'s mobile',
  '3-home': 'Home phone: N/A (not collected)',
  '4': 'The renter\'s home street address',
  '5-city': 'City', '5-prov': 'Province', '5-postal': 'Postal code',
  '7': 'Employer: N/A (not collected)',
  '7-office': 'Office phone: N/A (not collected)',
  '8': 'New or temporary address: N/A (not collected)',
  '8-dob': 'Date of birth (YYYY-MM-DD)',
  '9': 'Licence number', '9-prov': 'Licence province', '9-d': 'Licence expiry day', '9-m': 'Licence expiry month', '9-y': 'Licence expiry year', '9-age': 'Age at pickup',
  '10': 'Additional drivers\' names (N/A with none)',
  '11': 'First additional driver\'s licence (N/A with none)', '11-prov': 'Its province', '11-d': 'Its expiry day', '11-m': 'Its expiry month', '11-y': 'Its expiry year',
  insured: 'Insured vehicle (insurance replacement; N/A otherwise)',
  claim: 'Claim number (insurance replacement; N/A otherwise)',
  adjuster: 'Adjuster name and phone (insurance replacement; N/A otherwise)',
  '12': 'Insurance company: the insurer, the card issuer, the Protection Plan or included insurance',
  '13': 'Policy: the policy number, OPCF 27, card coverage or the plan reference',
  '13-prov': 'Policy province (a policy only; N/A otherwise)', '13-expiry': 'Policy expiry (a policy only; N/A otherwise)',
  '14': 'Remarks: the insurer\'s authorized days and rate, other drivers\' licences, charges with no box of their own',
  '15-from': 'Rented from: the mailing address', '15-to': 'To be returned to: the mailing address', '15-dest': 'Destination: N/A (not collected)',
  '18-card': 'Card on file: last four digits and brand', '18-expiry': 'Card expiry',
  '22': 'Original vehicle: fleet number', '23': 'Plate', '24-make': 'Make', '24-model': 'Year, model and trim',
  '25': 'Time and date in (closing copy)', '26': 'Time and date out', '27': 'K/M in (closing copy)', '28': 'K/M out', '29': 'K/M driven (closing copy)',
  '30': 'K/M allowed', '31': 'K/M charged (closing copy)', '32': 'Free K/M per day',
  'r-22': 'Replacement vehicle column (a car swapped; N/A otherwise)',
  '33': 'Per K/M: the overage rate, and the kilometres and amount at return',
  '34': 'Per hour late: the hours and the late fee (closing copy)',
  '35': 'Days @ the rate = the rental charge', '36': 'Weeks row (the weekly rate makes the charge)', '37': 'Months row (the monthly rate makes the charge)',
  '38': 'Extra days row (closing copy)',
  '39': 'Sub total of time and distance',
  '40-d': 'Due back: day', '40-m': 'Due back: month', '40-y': 'Due back: year', '40-time': 'Due back: time, AM or PM',
  '42': 'Underage fee (young driver; N/A without)', cdw: 'CDW: the Protection Plan sold', '43': 'VLF (insurer-billed; N/A without)', '44': 'Winter tires (N/A without)',
  '45': 'LDW (insurer-billed; N/A without)', '46': 'T&LDW (insurer-billed; N/A without)', '47': 'PAP/PEC (insurer-billed; N/A without)', waiver: 'Waiver Saver (N/A without)',
  '48': 'Other charges with no box of their own (delivery and the like)', '49': 'Subtotal before tax', '50': 'HST (13%)',
  '52': 'Damages (closing copy)', '53': 'Fuel (closing copy)', '54': 'Other return charges (closing copy)', '55': 'Total charges', '56': 'Total deposit', '57': 'Balance (closing copy)',
  '59-d': 'Deposit received: day', '59-m': 'Deposit received: month',
  'deposit-due': 'Deposit due (before it is taken)', 'deposit-received': 'Deposit received', paid: 'Amount paid', 'paid-how': 'How it was paid', refund: 'Refund (closing copy)',
  'fuel-out': 'Fuel out, in words (check-out report)', 'fuel-in': 'Fuel in, in words (check-in report)'
};

/** Boxes that stay empty on purpose, with the reason (never invented). */
export const BLANK: Record<string, string> = {
  '36': 'Only when the weekly rate makes the charge exactly; otherwise the days row carries it.',
  '37': 'Only when the monthly rate makes the charge exactly; otherwise the days row carries it.',
  '52': 'Damages are billed after the return, on the booking and through a claim, not on the closing copy until charged.'
};

/** The box a layout name belongs to: "33-rate" and "33-amount" are box 33, "14-2" is box 14, "7-na" is box 7. */
export const boxOf = (name: string): string => name.replace(/-na$/, '').replace(/-(amount|rate|count)$/, '').replace(/^14-\d+$/, '14');

/** The signature and initial boxes (layout.ts SIG), drawn by fill.ts on the signed copy. */
export const SIGNED: Record<string, string> = {
  '16': 'The renter\'s signature: Loss Damage Waiver declined ("Full Value")', '17': 'The renter\'s signature: tickets, violations and toll charges',
  '20': 'The renter\'s signature: the terms', '21': 'The authorized company representative',
  '10': 'Additional drivers sign CarmaCars\' agreement through their own link; their line here stays blank',
  cleanup: 'The renter\'s initials under the kilometre rates', '40-x': 'The renter\'s initials beside the due-back date'
};
