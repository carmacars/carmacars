import { hero, small, facts, button } from '../components.mjs';
import { FROM } from '../brand.mjs';

export default {
  code: 'admin_company_document_to_sign',
  audience: 'staff_admin',
  category: 'transactional',
  from: FROM.hello,
  digest: false,
  trigger: 'Release 50 (5060): a company document in Admin > Company documents is ready to sign (every fill-in is there and it was sent for signing, or sent again after its fill-ins changed). To each Admin named as a signer, once per request.',
  timing: 'Immediate, when the document is sent for signing',
  subject: 'Ready to sign: {{document_title}}',
  preheader: 'You sign as {{signer_role_label}}. Version {{document_version}}, in Admin > Company documents.',
  ref: 'Company documents',
  body: [
    hero('Company documents', 'Ready to sign: {{document_title}}', 'Hello {{first_name}}. A CarmaCars company document is waiting for your signature in Admin.'),
    facts(
      ['Document', '{{document_title}}'],
      ['Version', '{{document_version}}'],
      ['You sign as', '{{signer_role_label}}'],
      ['Signers', '{{signers_text}}'],
    ),
    button('Read and sign', '@admin_company_document'),
    small('Sign in to Admin to read it to the end, then sign. Only the Admins named as signers can sign it, and only Admins can see it. Take legal advice first if you want it.'),
  ],
  sample: { document_title: 'Shareholder Agreement', document_version: '1', signer_role_label: 'Principal of Side A', signers_text: 'Sam Example (Principal of Side A), Jordan Example (Principal of Side B)', company_document_id: 'a1b2c3d4-0000-4000-8000-000000000001' },
};
