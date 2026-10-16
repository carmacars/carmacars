import { hero, p, small, button } from '../components.mjs';
import { FROM } from '../brand.mjs';

export default {
  code: 'owner_cosigner_sign',
  audience: 'owner',
  category: 'transactional',
  from: FROM.owners,
  digest: false,
  trigger: 'Every Owner named in the Title Schedule signs the program agreements. The documents of an owner are opened for signature (or an Admin adds an Owner, or sends the link again): each Owner besides the one with the portal account gets their own signing link. The agreements take effect when the last Owner signs.',
  timing: 'Immediate',
  subject: 'Your CarmaCars owner documents are ready to sign',
  preheader: 'You are named as an Owner. Read the documents and sign them with your own link.',
  ref: 'Owner documents',
  body: [
    hero('Owner documents', 'Read and sign your documents', 'Hi {{first_name}}, you are named as an Owner in the CarmaCars agreements of {{owner_name}}. Each Owner signs with their own link.'),
    button('Read and sign', '@owner_cosign'),
    p('No account is needed. The agreements take effect when every Owner has signed.'),
    small('If you did not expect this email, reply to it and we will look into it.'),
  ],
  sample: {
    token: '3f9c1b2a7d4e4c8a9b0e6f1d2c3b4a5e3f9c1b2a7d4e4c8a9b0e6f1d2c3b4a5e', owner_name: 'Jordan Rossi',
  },
};
