import { hero, p, small, button } from '../components.mjs';
import { FROM } from '../brand.mjs';

export default {
  code: 'owner_document_reissued',
  audience: 'owner',
  category: 'transactional',
  from: FROM.owners,
  digest: false,
  trigger: 'Release 50 (migration 3810), once: a signed copy of the owner\'s Form D (or another countersigned document) was filed with the owner\'s drawn signature in the part CarmaCars signs. The copy is filed again with the correct CarmaCars countersignature; the owner\'s signature and the text are unchanged.',
  timing: 'Once, when the corrected copy is filed',
  subject: 'We corrected your signed {{document_title}}',
  preheader: 'The CarmaCars countersignature is fixed. Nothing changes for you.',
  ref: 'Owner documents',
  body: [
    hero('Corrected copy', 'Your {{document_title}}, corrected', 'Hi {{first_name}}, we found a mistake in the signed copy we filed for you, and fixed it.'),
    p('{{what}}'),
    button('Open my documents', '{{documents_url}}'),
    small('The corrected copy replaces the old one in Documents within a few minutes. You do not need to sign again.'),
  ],
  sample: { document_title: 'Form D: Limited Power of Attorney', what: 'Part 2, which CarmaCars signs, showed your signature instead of the CarmaCars countersignature. Your own signature and everything you signed are unchanged.', documents_url: 'https://carmacars.ca/owner/documents' },
};
