import { hero, small, button, notice, facts, when } from '../components.mjs';
import { FROM } from '../brand.mjs';

export default {
  code: 'owner_insurance_late_fee',
  audience: 'owner',
  category: 'transactional',
  from: FROM.billing,
  digest: false,
  trigger: 'Owner Late Fee on unpaid insurance (release 48, migration 3271), to an owner in the Vehicle Owner Program: a reminder a few days before an unpaid insurance invoice is due (3 days by default), and the notice when the Late Fee is added (5% of the unpaid insurance, a Program setting, plus HST) because the debit failed or the invoice is past its due date. The unpaid insurance and the Late Fee are then deducted from the next statement as two lines.',
  timing: 'Once before the due date (reminder) and once when the Late Fee is added',
  subject: '{{late_title}}',
  preheader: '{{late_how}}',
  ref: 'Invoice {{invoice_number}}',
  body: [
    hero('Insurance', '{{late_title}}', 'Hi {{first_name}}. {{late_text}}'),
    when('applied', [facts(['Unpaid insurance', '{{insurance_amount}}'], ['Late Fee', '{{late_fee_amount}}'], ['Owing on the invoice', '{{balance}}'])],
      [facts(['Insurance due', '{{insurance_amount}}'], ['Late Fee if not paid on time', '{{late_fee_amount}}'])]),
    notice('info', 'What happens next', '{{late_how}}'),
    button('Open invoice {{invoice_number}}', '@owner_invoice'),
    small('The Late Fee is set out in section 4.4 and Schedule B of your Enrollment Agreement. Questions? Reply to this email.'),
  ],
  sample: {
    first_name: 'Karan', invoice_number: 'INV-1090', applied: true,
    late_title: 'A Late Fee of $25.43 was added to invoice INV-1090',
    late_text: 'The insurance for your 2021 Hyundai Sonata was not paid on time. The Late Fee is 5% of the unpaid insurance of $450.00: $22.50 plus $2.93 HST.',
    late_how: 'The unpaid insurance and the Late Fee are deducted from your next statement, as two separate lines. There is nothing to do. You can also pay the invoice now from its page.',
    insurance_amount: '$450.00', late_fee_amount: '$25.43', balance: '$500.43',
  },
};
