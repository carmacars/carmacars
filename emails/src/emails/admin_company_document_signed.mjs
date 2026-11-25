import { hero, small, facts, button } from '../components.mjs';
import { FROM } from '../brand.mjs';

export default {
  code: 'admin_company_document_signed',
  audience: 'staff_admin',
  category: 'transactional',
  from: FROM.hello,
  digest: false,
  trigger: 'Release 50 (5060): every signer has signed a company document in Admin > Company documents and its signed copy is filed. To each Admin who signed, once per version, with the signed copy.',
  timing: 'Immediate, when the last signer signs',
  subject: 'Signed by everyone: {{document_title}}',
  preheader: 'Version {{document_version}} is signed. Your signed copy is inside.',
  ref: 'Company documents',
  body: [
    hero('Company documents', 'Signed by everyone', 'Hello {{first_name}}. Every signer has signed {{document_title}}. Keep this copy.'),
    facts(
      ['Document', '{{document_title}}'],
      ['Version', '{{document_version}}'],
      ['Signed', '{{signed_at}}'],
      ['Signers', '{{signers_text}}'],
    ),
    button('Download the signed copy', '{{signed_agreement_url}}'),
    small('The download link works for 7 days. The signed copy, with each signature, its date, IP address and the document\'s hash, stays in [Admin > Company documents](@admin_company_document).'),
  ],
  sample: { document_title: 'Shareholder Agreement', document_version: '1', signed_at: 'Wed, Nov 25, 2026 at 4:10 pm', signers_text: 'Sam Example (Principal of Side A), Jordan Example (Principal of Side B)', company_document_id: 'a1b2c3d4-0000-4000-8000-000000000001' },
};
