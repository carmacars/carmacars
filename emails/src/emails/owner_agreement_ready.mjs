import { hero, p, small, h, rule, vehicle, keyfacts, figure, facts, price, compare, table, rows, button, link, notice, list, steps, when, each } from '../components.mjs';
import { FROM } from '../brand.mjs';

export default {
  code: 'owner_agreement_ready',
  audience: 'owner',
  category: 'transactional',
  from: FROM.owners,
  digest: false,
  trigger: 'Vehicle onboarding status changes to documents_sent (a signature request for the owner documents is opened): the Enrollment Agreement and Title Agreement for a first vehicle, or an Additional Vehicle Schedule for a later one, with the forms that vehicle needs.',
  timing: 'Immediate',
  subject: 'Your CarmaCars owner documents are ready to sign',
  preheader: 'For the {{vehicle_name}}. Please sign by {{sign_by}}.',
  ref: 'Owner documents',
  body: [
    hero('Signature needed', 'Your documents are ready, {{first_name}}', 'These set the terms for your {{vehicle_name}}. Read them in full before you sign.'),
    h('Your terms for this vehicle'),
    facts(
      ['Management mode', '{{management_mode}}'],
      ['Insurance fee', '{{insurance_fee}} a month plus HST'],
      ['Tracker fee', '{{tracker_fee}} a month plus HST'],
      ['Revenue share kept by CarmaCars', '{{revenue_share}}'],
      ['Registration method', '{{onboarding_method}}'],
    ),
    h('To sign on the website'),
    table({ each: 'documents_to_sign', cols: [{ head: 'Document', value: '{{name}}', strong: true }, { head: 'Note', value: '{{note}}' }] }),
    button('Read and sign', '@owner_agreements'),
    when('has_paper_forms', [
      notice('info', 'Some forms need a witness', '{{paper_forms}} must be signed on paper in front of a witness. Print, sign, scan and upload them on the same page.'),
    ]),
    p('Please sign by **{{sign_by}}**. The vehicle is enrolled only once the documents are signed and we confirm it in writing. Until then, keep your own insurance on it.'),
  ],
  sample: {
    vehicle_name: '2023 Toyota RAV4 XLE', sign_by: 'Fri, Oct 30, 2026', management_mode: 'Managed by CarmaCars',
    insurance_fee: '$450.00', tracker_fee: '$25.00', revenue_share: '35% of Owner Revenue', onboarding_method: 'Co-Registrant',
    documents_to_sign: [
      { name: 'Vehicle Enrollment Agreement', note: 'With the Vehicle Schedule for this vehicle. Three places to initial.' },
      { name: 'Title-Holding and Lease Agreement', note: 'With Schedule 1 for this vehicle.' },
      { name: 'Form A', note: 'Co-registrant authorization.' },
    ],
    has_paper_forms: true, paper_forms: 'Form C and Form D',
  },
};
