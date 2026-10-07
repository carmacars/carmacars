import { hero, p, small, h, rule, vehicle, keyfacts, figure, facts, price, compare, table, rows, button, link, notice, list, steps, when, each } from '../components.mjs';
import { FROM } from '../brand.mjs';

export default {
  code: 'staff_field_job_changed',
  audience: 'staff_field',
  category: 'transactional',
  from: FROM.bookings,
  digest: false,
  trigger: 'An assigned field job has its time, place or vehicle changed, or is cancelled or taken away from the assignee. Sent to the staff member who held the job. Immediate.',
  timing: 'Immediate',
  subject: 'Job changed: {{job_type}}, now {{job_date}} at {{job_time}}',
  preheader: '{{job_change_summary}}',
  ref: 'Job {{job_id}}',
  body: [
    hero('Job changed', '{{job_change_headline}}', 'Hi {{first_name}}. A job on your list has changed. Please check the new details.'),
    when('job_cancelled', [
      notice('alert', 'This job is off your list', '{{job_change_summary}}'),
    ], [
      compare('job_changes', 'Was', 'Now'),
      facts(
        ['Job', '{{job_type}}'],
        ['When', '{{job_date}}, {{job_time}}'],
        ['Where', '{{job_place}}'],
        ['Vehicle', '{{vehicle_name}}, plate {{vehicle_plate}}'],
      ),
    ]),
    button('Open my jobs', '@field'),
    small('If the new time does not work, tell Fleet right away.'),
  ],
  sample: {
    job_id: 'J-5521', job_type: 'Pickup handover', job_date: 'Fri, Oct 23', job_time: '10:30 am', job_place: 'Union Station, 65 Front Street West, Toronto',
    job_change_headline: 'Pickup moved to 10:30 am', job_change_summary: 'The pickup time moved from 10:00 am to 10:30 am', job_cancelled: false,
    job_changes: [{ label: 'Time', before: '10:00 am', after: '10:30 am' }],
  },
};
