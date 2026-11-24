import { hero, p, small, button, list } from '../components.mjs';
import { FROM } from '../brand.mjs';

export default {
  code: 'owner_sign_reminder',
  audience: 'owner',
  category: 'transactional',
  from: FROM.owners,
  digest: false,
  trigger: 'Sign first (r50, migration 3800): an Admin or Fleet presses Send reminder where the owner\'s page lists what is missing (or the Admin connector\'s send_owner_agreement_reminder is confirmed). Lists what still waits for the owner: the master agreement, a Schedule A confirmation, or the profile values the agreement needs. At most once in 10 minutes per owner.',
  timing: 'When staff press Send reminder',
  subject: 'Reminder: {{what}} waits for your signature',
  preheader: 'Your cars move once it is signed. About two minutes, on screen.',
  ref: 'Owner agreement',
  body: [
    hero('Reminder', 'One step left before your cars move', 'Hi {{first_name}}, nothing can be approved, delivered or rented until these are done:'),
    list('{{missing_text}}'),
    button('{{cta}}', '{{sign_url}}'),
    p('Everything is filled in from what you already gave us. Check it and sign once.'),
    small('Questions? Reply to this email.'),
  ],
  sample: { what: 'Your Fleet Supplier Lease Agreement', missing_text: 'Sign the Fleet Supplier Lease Agreement (EA-1042)', cta: 'Read and sign', sign_url: 'https://carmacars.ca/owner/sign' },
};
