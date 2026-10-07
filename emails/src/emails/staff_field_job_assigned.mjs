import { hero, p, small, h, rule, vehicle, keyfacts, figure, facts, price, compare, table, rows, button, link, notice, list, steps, when, each } from '../components.mjs';
import { FROM } from '../brand.mjs';

export default {
  code: 'staff_field_job_assigned',
  audience: 'staff_field',
  category: 'transactional',
  from: FROM.bookings,
  digest: false,
  trigger: 'A field job (pickup handover, return, tracker install, detail or photo shoot) is assigned to a field staff member, or reassigned to a new one. Sent to the new assignee. Immediate.',
  timing: 'Immediate',
  subject: 'New job: {{job_type}}, {{job_date}} at {{job_time}}',
  preheader: '{{vehicle_name}}, {{job_place}}. Open it and tap Acknowledge.',
  ref: 'Job {{job_id}}',
  body: [
    hero('Job assigned', '{{job_type}}: {{job_date}} at {{job_time}}', 'Hi {{first_name}}. This job is yours. Please acknowledge it in the field app.'),
    facts(
      ['Job', '{{job_type}}'],
      ['When', '{{job_date}}, {{job_time}}'],
      ['Where', '{{job_place}}'],
      ['Vehicle', '{{vehicle_name}}, plate {{vehicle_plate}}'],
      { label: 'Customer', value: '{{customer_first_name}}', when: 'customer_first_name' },
      { label: 'Note from Fleet', value: '{{job_note}}', when: 'job_note' },
    ),
    button('Open the job and acknowledge', '@field_job'),
    list(
      'Have the car ready 30 minutes before a pickup.',
      'Hand over only to the renter, in person. Check the original licence and the physical card.',
      'Complete every line of the condition report and the full photo set, in order.',
    ),
    small('If you cannot do it, tell Fleet right away so the job can be reassigned.'),
  ],
  sample: {
    job_id: 'J-5521', job_type: 'Pickup handover', job_date: 'Fri, Oct 23', job_time: '10:00 am',
    job_place: 'Union Station, 65 Front Street West, Toronto', customer_first_name: 'Maya', job_note: 'Meet at the taxi stand on the Front Street side.',
  },
};
