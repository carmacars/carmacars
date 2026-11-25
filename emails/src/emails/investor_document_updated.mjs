import { hero, small, facts, button } from '../components.mjs';
import { FROM } from '../brand.mjs';

export default {
  code: 'investor_document_updated',
  audience: 'investor',
  category: 'transactional',
  from: FROM.hello,
  digest: false,
  trigger: 'Release 50 (4300): an Admin adds a document to the investor Documents library (business plan, financial forecast, pitch deck, feature decks or another kind), or replaces one with a new version. Once per version, to every active investor.',
  timing: 'Immediate, when the document is added or replaced',
  subject: '{{document_change}}: {{document_title}}',
  preheader: '{{document_kind}}, version {{document_version}}, updated {{document_date}}. Open it in your investor portal.',
  ref: 'Investor documents',
  body: [
    hero('Investor documents', '{{document_change}}: {{document_title}}', 'Hello {{first_name}}. A document in your CarmaCars investor portal is new or has a new version.'),
    facts(
      ['Document', '{{document_title}}'],
      ['Kind', '{{document_kind}}'],
      ['Version', '{{document_version}}'],
      ['Updated', '{{document_date}}'],
    ),
    button('Open your documents', '@investor_library'),
    small('Sign in to open it: the files are private to CarmaCars investors and each link works for a few minutes. It is not an offer or a solicitation; your signed Investment Agreement continues to govern.'),
  ],
  sample: { document_change: 'New version', document_title: 'CarmaCars business plan', document_kind: 'Business plan', document_version: '2', document_date: 'November 24, 2026' },
};
