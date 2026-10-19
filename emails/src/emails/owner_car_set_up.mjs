import { hero, p, small, h, button, steps, when, notice } from '../components.mjs';
import { FROM } from '../brand.mjs';

export default {
  code: 'owner_car_set_up',
  audience: 'owner',
  category: 'transactional',
  from: FROM.owners,
  digest: false,
  trigger: 'Staff added a car for the owner (Admin, customer service or fleet: Add a car for this owner) and an Admin approved it with its terms and first invoices. The owner\'s one email: review the details and sign. Not sent when the owner signs on paper. For an owner with no sign-in yet it carries the link to choose a password.',
  timing: 'Immediate, after approval',
  subject: 'We set up your {{vehicle_name}}: review the details and sign',
  preheader: 'Your agreements are filled in. Check them, correct anything, and sign once.',
  ref: 'Owner set-up',
  body: [
    hero('Your car is set up', 'Review the details and sign', 'Hi {{first_name}}, {{staff_name}} set up your {{vehicle_name}} with CarmaCars. Your agreements are filled in from what you told us.'),
    when('has_password_url', [
      notice('info', 'First, choose your password', 'Your owner portal account is ready for {{owner_email}}. [Choose your password]({{password_url}}). The link works once, for 24 hours; after that, use Forgot password on the sign-in page.'),
    ]),
    h('What to do'),
    steps(
      ['Review your details', 'Check your contact details and your car. Correct anything that is wrong before you sign.'],
      ['Sign once', 'Read your agreements and the terms we agreed, and sign them all with one signature.'],
      ['Pay the first invoice', 'If we sent you an invoice, pay it from the invoice page. Anything you already paid us is marked as paid.'],
    ),
    button('Review and sign', '@owner_review'),
    small('Something not right, or a question about your terms? Reply to this email before you sign.'),
  ],
  sample: {
    vehicle_name: '2023 Toyota RAV4 XLE', staff_name: 'Sara', has_password_url: true, owner_email: 'daniel@example.com',
    password_url: 'https://carmacars.ca/auth/callback?token_hash=abc&type=invite&next=/update-password',
  },
};
