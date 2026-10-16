import type { DebitTerms } from './types.ts';

// The agreement's values come from Program settings (app.owner_debit_terms): the payee, the debit day, the notice days
// and the one Late Fee rule of the Enrollment Agreement (4.4), the same sentence as the emails (0051).
export const mandateText = (kind: 'personal' | 'business', t: DebitTerms, withInvoice = true) => [
  `You authorize ${t.payee.name}${t.payee.name.includes(', operating as ') ? ',' : ''} to debit the bank account you give${withInvoice ? ' for this invoice now, and' : ''} for the fees on your CarmaCars invoices: the monthly fees of your vehicles enrolled with CarmaCars (the Insurance Fee, and the Tracker Fee once a tracker is installed, plus HST, as set in your Vehicle Schedule), the first and last month's Insurance Fee, the Tracker Install Fee and other amounts invoiced to you, on the ${t.debit_day_text} of each month.`,
  withInvoice ? `${t.late_fee_rule} ${t.own_debit_rule}` : t.late_fee_rule,
  `The amount can change from month to month with your vehicles and their fees. We email you a notice listing every invoice and the total ${t.notice_days} days before each debit, and each invoice is in your owner portal. We also email you a confirmation of this agreement once your bank account is set up.`,
  `This authorization is for ${kind} purposes and stays in effect until you cancel it. You may cancel it at any time by writing to ${t.payee.email}; cancelling it does not end your agreement or the fees you owe. You have certain recourse rights if a debit does not comply with this agreement: for example, the right to be reimbursed for a debit that was not authorized or is not consistent with this agreement. For more information on your recourse rights, contact your financial institution or visit payments.ca.`
];

/** The payee's contact details, shown with the agreement (Rule H1): name, address, phone and email from the settings. */
export const payeeRows = (t: DebitTerms): Array<[string, string]> => [
  ['Payee', t.payee.name], ['Address', t.payee.address || 'Not set yet'], ['Phone', t.payee.phone || 'Not set yet'], ['Email', t.payee.email]
];
