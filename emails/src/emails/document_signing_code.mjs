import { hero, p, small, figure } from '../components.mjs';
import { FROM } from '../brand.mjs';

export default {
  code: 'document_signing_code',
  audience: 'owner',
  category: 'transactional',
  from: FROM.owners,
  digest: false,
  trigger: 'Someone about to sign documents other than a rental agreement asks for the identity code by email (migration 0193): an owner signing the program agreements, a schedule or a form, another Owner signing with their link, a partner, an investor or a staff member signing their agreement. The code proves the signer controls the email on file; it is never stored in clear.',
  timing: 'Immediate',
  subject: 'Your CarmaCars signing code: {{code}}',
  preheader: 'Enter it on the signing page within {{minutes}} minutes.',
  ref: 'Signing',
  body: [
    hero('Signing code', 'Confirm it is you', 'Enter this code on the signing page to sign {{document_label}}.'),
    figure('Your code', '{{code}}', 'It expires in {{minutes}} minutes.'),
    p('If you did not ask for it, someone may be trying to sign in your name: do not share the code, and call us.'),
    small('CarmaCars never asks for this code by phone.'),
  ],
  sample: { code: '482913', minutes: '10', document_label: 'your 3 documents' },
};
