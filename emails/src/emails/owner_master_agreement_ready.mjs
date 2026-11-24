import { hero, p, small, steps, button, facts } from '../components.mjs';
import { FROM } from '../brand.mjs';

export default {
  code: 'owner_master_agreement_ready',
  audience: 'owner',
  category: 'transactional',
  from: FROM.owners,
  digest: false,
  trigger: 'Sign first (r50, migration 3800, app.owner_master_ensure): the owner\'s profile is complete (the legal or corporation name, the address and, for a corporation, the signing officer) and their master agreement is made from it: the Fleet Supplier Lease Agreement with the Title-Holding and Lease Agreement for a fleet supplier, the Vehicle Enrollment Agreement (or the Flat-Rate one) for a program owner. No car is needed. Once per agreement; the backfill of 3800 sends it to every owner it made one for.',
  timing: 'Immediate',
  subject: 'Sign your {{agreement_title}}: your first step with CarmaCars',
  preheader: 'It is filled in from your profile. Sign it now; then add your cars.',
  ref: 'Owner agreement {{agreement_number}}',
  body: [
    hero('Step 2 of 6', 'Your {{agreement_title}} is ready', 'Hi {{first_name}}, it is filled in from your profile and our standard terms. Sign it once now, before any car comes over.'),
    facts(
      ['Agreement', '{{agreement_title}} {{agreement_number}}'],
      ['Signing as', '{{signer}}'],
    ),
    button('Read and sign', '{{sign_url}}'),
    steps(
      ['Sign the agreement', 'On screen, about two minutes. CarmaCars countersigns at the same moment.'],
      ['Add your cars', 'One at a time or as a list of VINs. Each car is added to Schedule A of your agreement, and you confirm each batch with one signature.'],
      ['Photos and inspection, then approval and delivery', 'We check each car, approve it and you hand it over. Your portal shows the next step every time.'],
    ),
    small('Something wrong in it? Fix it in your profile and the agreement updates before you sign, or reply to this email.'),
  ],
  sample: { agreement_title: 'Fleet Supplier Lease Agreement', agreement_number: 'EA-1042', signer: 'Nora Example, Director, for Northshore Holdings Ltd.', sign_url: 'https://carmacars.ca/owner/sign' },
};
