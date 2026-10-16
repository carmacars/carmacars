import type { DebitTerms } from './types.ts';

// The pre-authorized debit texts (the legal review of October 16, 2026; app.owner_debit_terms of 0053). The recurring
// agreement comes from the database word for word (the payee "<legal name>, operating as CarmaCars", the debit day, the
// notice days and the one Late Fee rule), so the Banking page, the invoice page and the confirmation email print the
// same text. The one-time authorization is the invoice page's first box.

/** The recurring agreement (the 1.2 text): Banking, the invoice page's second box, and the confirmation email. */
export const mandateText = (kind: 'personal' | 'business', t: DebitTerms): string[] => {
  const fromDb = t.agreement?.[kind];
  if (fromDb && fromDb.length) return fromDb;
  const payee = `${t.payee.name}${t.payee.name.includes(', operating as ') ? ',' : ''}`;
  return [
    `You authorize ${payee} to debit the bank account you give for the fees on your CarmaCars invoices: the monthly fees of your vehicles enrolled with CarmaCars (the Insurance Fee, and the Tracker Fee once a tracker is installed, plus HST, as set in your Vehicle Schedule), the first and last month's Insurance Fee, the Tracker Install Fee and other amounts invoiced to you, on the ${t.debit_day_text} of each month.`,
    t.late_fee_rule,
    `The amount can change from month to month with your vehicles and their fees. We email you a notice listing every invoice and the total ${t.notice_days} days before each debit, and each invoice is in your owner portal. We also email you a confirmation of this agreement once your bank account is set up.`,
    `This authorization is for ${kind} purposes and stays in effect until you cancel it. You may cancel it at any time by writing to ${t.payee.email}; cancelling it does not end your agreement or the fees you owe. You have certain recourse rights if a debit does not comply with this agreement: for example, the right to be reimbursed for a debit that was not authorized or is not consistent with this agreement. For more information on your recourse rights, contact your financial institution or visit payments.ca.`
  ];
};

/** The one-time debit of an invoice (the invoice page's first box, required), word for word as approved. */
export const oneTimeText = (t: DebitTerms, amount: string, invoiceNumber: string) =>
  `I authorize ${t.payee.name}${t.payee.name.includes(', operating as ') ? ',' : ''} to debit ${amount} for invoice ${invoiceNumber} from the bank account I give now. I waive pre-notification and any waiting period for this one-time debit.`;

/** The payee's contact details, shown with the agreement (Rule H1): name, address, phone and email from the settings. */
export const payeeRows = (t: DebitTerms): Array<[string, string]> => [
  ['Payee', t.payee.name], ['Address', t.payee.address || 'Not set yet'], ['Phone', t.payee.phone || 'Not set yet'], ['Email', t.payee.email]
];
