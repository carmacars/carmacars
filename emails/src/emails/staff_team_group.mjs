import { hero, p, button, small, when } from '../components.mjs';
import { FROM } from '../brand.mjs';

export default {
  code: 'staff_team_group',
  audience: 'staff_field',
  category: 'transactional',
  from: FROM.hello,
  digest: false,
  trigger: 'A new staff member has passed the academy and signed their staff agreement, and a WhatsApp group link is set in Program settings (migration 1060). Sent once: Sales staff get the Sales group, customer service, fleet, finance and field staff the team group (both when they do both).',
  timing: 'Immediate, once',
  subject: 'You are in: join the {{group_name}} WhatsApp group',
  preheader: 'The team talks there every day.',
  ref: 'Welcome',
  body: [
    hero('Welcome to the team', 'Join {{group_name}}', 'Hi {{first_name}}. Your academy is passed and your agreement is signed: your portal is open. The team keeps in touch in a WhatsApp group.'),
    button('Join {{group_name}} on WhatsApp', '{{group_url}}'),
    when('second_group_url', p('You also work with the {{second_group_name}} group: {{second_group_url}}')),
    small('Use the name you go by in your WhatsApp profile, so the team knows who you are.'),
  ],
  sample: { group_name: 'CarmaCars Team', group_url: 'https://chat.whatsapp.com/ExampleInviteCode01', second_group_name: '', second_group_url: '' },
};
