import { hero, p, notice, button, small, when } from '../components.mjs';
import { FROM } from '../brand.mjs';

export default {
  code: 'applicant_referred',
  audience: 'applicant',
  category: 'transactional',
  from: FROM.hello,
  digest: false,
  trigger: 'A candidate does not qualify for the role they applied for on carmacars.ca/careers (a knock-out or a score below the pass mark for Field staff; a score below the pass mark for a remote assistant role) and another open role suits them: Field staff to Sales and Customer Relations (In person, Toronto), with Remote Sales named as the other choice; Sales in person to Remote Sales; or the best matching other open role (migration 0173). Not sent when they already applied for that role. The link opens that role\'s application with their name, email and phone filled in. One email per application.',
  timing: 'Immediate',
  subject: 'Your CarmaCars application, and a role that may suit you better',
  preheader: 'We would love you to apply for {{other_role_title}}.',
  ref: 'Careers',
  body: [
    hero('Careers', 'Thank you, {{first_name}}', 'Thank you for applying for {{role_title}}. {{reason_text}}, so we cannot offer you that role.'),
    p('We would love to have you on our team in another way. Your answers suggest you could do well as our {{other_role_title}}.'),
    notice('info', '{{other_role_title}}', '{{other_role_summary}}'),
    button('Apply in one click', '{{apply_url}}'),
    when('alt_apply_url', p('Would you rather work remotely? You can also apply for our {{alt_role_title}}: {{alt_apply_url}}')),
    small('Your name, email and phone are already filled in; it takes about five minutes. If it is not for you, there is nothing to do.'),
  ],
  sample: {
    role_title: 'Field Staff: Driver and Detailer', reason_text: 'This role needs a full Ontario G licence',
    other_role_title: 'Sales and Customer Relations Coordinator (In person, Toronto)',
    other_role_summary: 'Turn enquiries into bookings by phone, text, chat and in person in Toronto: walk-ins, handovers and visits to dealership and body shop partners. Commission only, 10% to 20% of each rental you source.',
    apply_url: 'https://carmacars.ca/careers/sales-in-person/apply?ref=3f9a1c&src=referral',
    alt_role_title: 'Remote Sales Coordinator (Commission only, worldwide)', alt_apply_url: 'https://carmacars.ca/careers/sales-remote/apply?src=referral',
  },
};
