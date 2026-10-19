import { hero, p, small, button, compare, figure } from '../components.mjs';
import { FROM } from '../brand.mjs';

export default {
  code: 'owner_schedule_resign',
  audience: 'owner',
  category: 'transactional',
  from: FROM.owners,
  digest: false,
  trigger: 'An Admin changes the terms of a car whose Vehicle Schedule is signed and confirms that the owner must sign an updated one (Admin > the owner > Terms). The new terms apply from their date only once the owner signs; until then the signed terms stay in place.',
  timing: 'Immediate',
  subject: 'Please sign the updated Vehicle Schedule for the {{vehicle_name}}',
  preheader: 'New terms from {{effective_date}}, once you sign.',
  ref: 'Vehicle Schedule',
  body: [
    hero('Updated Vehicle Schedule', 'New terms for your {{vehicle_name}}', 'Hi {{first_name}}, here are the terms we agreed. They apply from {{effective_date}} once you sign.'),
    compare('terms_rows', 'Now', 'Updated'),
    figure('From', '{{effective_date}}', 'Your current terms stay in place until you sign.'),
    button('Read and sign', '@owner_schedule_sign'),
    p('Everything else in your Vehicle Schedule and your Enrollment Agreement stays the same.'),
    small('Questions before you sign? Reply to this email.'),
  ],
  sample: {
    vehicle_name: '2023 Toyota RAV4 XLE', effective_date: 'Sun, Nov 1, 2026', change_id: 'b1c2d3e4-0000-4000-8000-000000000001',
    terms_rows: [{ label: 'Insurance Fee a month', before: '$450.00', after: '$400.00' }, { label: 'Tracker Fee a month', before: '$25.00', after: '$25.00' },
      { label: 'Revenue Share', before: '35%', after: '30%' }],
  },
};
