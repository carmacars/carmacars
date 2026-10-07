import { hero, p, small, h, rule, vehicle, keyfacts, figure, facts, price, compare, table, rows, button, link, notice, list, steps, when, each } from '../components.mjs';
import { FROM } from '../brand.mjs';

export default {
  code: 'owner_agreement_signed',
  audience: 'owner',
  category: 'transactional',
  from: FROM.owners,
  digest: false,
  trigger: 'Vehicle onboarding status changes to documents_signed (every owner document for the vehicle is signed by the owner and countersigned by CarmaCars, and witnessed forms are uploaded).',
  timing: 'Immediate',
  subject: 'Signed: your owner documents for the {{vehicle_name}}',
  preheader: 'Your copies are inside. Next step: {{next_step_short}}',
  ref: 'Owner documents',
  body: [
    hero('Documents signed', 'Signed by both sides', 'Your documents for the {{vehicle_name}} are complete, {{first_name}}. Keep these copies.'),
    facts(
      ['Agreement no.', '{{agreement_number}}'],
      ['Signed', '{{signed_at}}'],
      ['Documents', '{{document_count}}'],
    ),
    button('Download my signed documents', '{{signed_agreement_url}}'),
    notice('info', 'Not enrolled yet', 'Your vehicle joins the fleet policy only when we confirm it in writing. Keep your own insurance active until you get that email.'),
    p('**Next:** {{next_step}}'),
    small('The download link works for 7 days. Your documents are always in [your owner account](@owner_agreements).'),
  ],
  sample: {
    vehicle_name: '2023 Toyota RAV4 XLE', agreement_number: 'OA-0031', signed_at: 'Wed, Oct 28, 2026 at 11:20 am', document_count: '5',
    next_step_short: 'your upfront invoice.', next_step: 'We send the upfront invoice for this vehicle. Once it is paid, we start the registration steps.',
  },
};
