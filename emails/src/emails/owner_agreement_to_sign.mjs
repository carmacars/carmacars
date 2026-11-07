import { hero, p, small, button } from '../components.mjs';
import { FROM } from '../brand.mjs';

export default {
  code: 'owner_agreement_to_sign',
  audience: 'owner',
  category: 'transactional',
  from: FROM.owners,
  digest: false,
  trigger: 'An Admin presses Send on an owner\'s line of the Agreements checklist (Admin > Owners > Agreements, migration 0640): the agreement that owner\'s deal needs (the Vehicle Enrollment Agreement, the Flat-Rate or Fleet Supplier Lease Agreement with the Title-Holding and Lease Agreement, an Additional Vehicle Schedule, the Partner agreement or a Referral Override Agreement) is ready to read and sign in the owner portal. Sent again each time Send is pressed.',
  timing: 'When an Admin presses Send',
  subject: 'Please sign your {{agreement_title}}',
  preheader: 'It is ready in your owner portal. One signature, on screen.',
  ref: 'Owner agreement',
  body: [
    hero('Signature needed', 'Your {{agreement_title}} is ready', 'Hi {{first_name}}, it is filled in from the terms we agreed with you. Read it in full before you sign.'),
    p('{{note}}'),
    button('Read and sign', '{{sign_url}}'),
    small('Something wrong in it? Reply to this email before you sign and we fix it. Prefer paper? Ask us for a copy.'),
  ],
  sample: {
    agreement_title: 'Fleet Supplier Lease Agreement', note: 'It covers every car in your Vehicle Schedule. You sign once for all of them.',
    sign_url: 'https://carmacars.ca/owner/sign',
  },
};
