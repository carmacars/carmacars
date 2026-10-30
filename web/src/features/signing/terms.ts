// The key terms initialled and the consents given when signing documents other than a rental agreement (migration 0193,
// app.esign_doc_initials picks the codes from the documents): the owner's agreements, Forms A, B and C, the partner,
// investment and staff agreements, an updated Vehicle Schedule. The same steps as a rental agreement (EsignFlow).
// Plain module: the unit tests and the certificate read it directly.

export interface Term { code: string; title: string; text: string }

export const DOC_TERMS: Term[] = [
  // the Enrollment Agreement's three confirmations (CONFIRMATIONS in features/owner-agreement/model.ts)
  { code: 'own_insurance', title: 'Your own insurance', text: 'I keep my own insurance until CarmaCars confirms in writing (3.3).' },
  { code: 'fees_no_income', title: 'Fees every month', text: 'Fees are due every month, rented or not. No income is promised (2.3, 4.3).' },
  { code: 'tracker_downtime', title: 'The Tracker', text: 'The Tracker records location, including when I drive. No pay for downtime (5, 10, 15).' },
  // the investment agreement
  { code: 'schedule_c', title: 'Risk acknowledgment (Schedule C)', text: 'I have read the risk acknowledgment in Schedule C and I initial each statement in it.' },
  // the staff agreements (VA and field)
  { code: 'staff_confidentiality', title: 'Confidentiality', text: 'I keep the information of renters, owners and CarmaCars confidential and use it only for my work, during this agreement and after it ends.' },
  { code: 'staff_rules', title: 'Money, keys and cars', text: 'I follow the rules this agreement sets for CarmaCars\' money, cards, keys and cars, and for tickets and damage where it covers them.' },
  { code: 'staff_ending', title: 'Ending this agreement', text: 'This agreement ends as its section on ending it says, and what it says about confidentiality continues after it ends.' },
  // the partner agreement
  { code: 'partner_money', title: 'Money', text: 'CarmaCars keeps its share set out in section 4 and pays me the rest on the monthly statement, less the deductions that section allows.' },
  { code: 'partner_insurance', title: 'Insurance and condition', text: 'I keep each car insured and in good condition as section 5 says; CarmaCars may end this agreement at once if a car\'s insurance lapses.' },
  { code: 'partner_ending', title: 'Ending the agreement', text: 'Either party may end this agreement with 30 days\' written notice; bookings confirmed before the end are completed (section 10).' },
  // an updated Vehicle Schedule
  { code: 'schedule_terms', title: 'The updated terms', text: 'The fees and Revenue Share above apply from the date shown. Everything else in my Vehicle Schedule and Enrollment Agreement stays the same.' }
];

/** Form C's three acknowledgments, worded as the form prints them (its table "I acknowledge"). */
export function formCTerms(acknowledgments: string[]): Term[] {
  const codes = ['read_warning', 'no_advice', 'bears_consequences'];
  const titles = ['The warning', 'Legal advice', 'The consequences'];
  return codes.map((code, i) => ({ code, title: titles[i]!, text: acknowledgments[i] ?? '' })).filter((t) => t.text);
}

/** The consents of a document signer: to sign electronically and to get the records electronically (no card). */
export const DOC_CONSENTS = {
  esign: 'I agree to sign these documents electronically. My electronic signature and initials are as binding as my handwritten ones (Ontario Electronic Commerce Act, 2000).',
  erecords: 'I agree to receive these documents, their signed copies and the records about them electronically, by email and in my portal, and I can download and keep them.'
} as const;

/** How the certificate names each term initialled. */
export const DOC_TERM_LABELS: Record<string, string> = Object.fromEntries([
  ...DOC_TERMS.map((t) => [t.code, t.title.toLowerCase()]),
  ['schedule_c', 'the risk acknowledgment (Schedule C)'],
  ['read_warning', 'the warning'], ['no_advice', 'legal advice'], ['bears_consequences', 'the consequences']
]);
