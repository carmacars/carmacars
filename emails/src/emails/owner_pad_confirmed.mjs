import { hero, p, small, h, rule, vehicle, keyfacts, figure, facts, price, compare, table, rows, button, link, notice, list, steps, when, each } from '../components.mjs';
import { FROM } from '../brand.mjs';

export default {
  code: 'owner_pad_confirmed',
  audience: 'owner',
  category: 'transactional',
  from: FROM.billing,
  digest: false,
  trigger: 'An owner\'s pre-authorized debit mandate becomes active (set up under Banking, confirmed by micro-deposits, or saved with a debit paid from an invoice page). CarmaCars\' own confirmation of the pre-authorized debit agreement (Payments Canada Rule H1): the agreement, the payee and how to reach it, the account, the timing, how to cancel and the recourse rights. Sent once per debit mandate. An automatic debit is scheduled only with its notice, the notice days ahead, so this confirmation comes before the first automatic debit.',
  timing: 'Immediate, when the debit mandate becomes active',
  subject: 'Your pre-authorized debit agreement with {{payee_name}}',
  preheader: 'Your confirmation for the account ending {{bank_last4}}. Keep it for your records.',
  ref: 'Pre-authorized debit',
  body: [
    hero('Debit set up', 'Your pre-authorized debit is set up', 'This confirms the pre-authorized debit agreement you accepted on {{accepted_on}}, {{first_name}}. Keep this email for your records.'),
    facts(
      ['Payee', '{{payee_name}}'],
      ['Address', '{{payee_address}}'],
      ['Phone', '{{payee_phone}}'],
      ['Email', '{{payee_email}}'],
      ['Your account', '{{bank_name}} account ending {{bank_last4}}'],
      ['Type', '{{agreement_type}}'],
      ['Accepted on', '{{accepted_on}}'],
    ),
    h('When we debit'),
    p('We debit the fees on your CarmaCars invoices on the {{debit_day}} of each month. The amount can change from month to month with your vehicles and their fees. We email you a notice listing every invoice and the total {{notice_days}} days before each debit. The first automatic debit is not before {{first_debit_date}}.'),
    p('{{late_fee_rule}}'),
    h('How to cancel'),
    p('You may cancel this authorization at any time by writing to {{payee_email}}. Cancelling it does not end your agreement or the fees you owe.'),
    h('Your recourse rights'),
    p('You have certain recourse rights if a debit does not comply with this agreement. For example, you have the right to be reimbursed for a debit that was not authorized or is not consistent with this agreement. For more information on your recourse rights, contact your financial institution or visit payments.ca.'),
    button('Read the agreement', '@owner_banking'),
    small('The full agreement is on the Banking page of your owner portal. Questions: reply to this email or call {{payee_phone}}.'),
  ],
  sample: {
    payee_name: 'CarmaCars', payee_address: '100 Sample Street, Toronto, Ontario', payee_phone: '647-575-3377', payee_email: 'billing@carmacars.ca',
    bank_name: 'TD Canada Trust', bank_last4: '6621', agreement_type: 'Personal', accepted_on: 'Fri, Oct 16, 2026', first_debit_date: 'Sun, Nov 15, 2026', notice_days: '10',
  },
};
