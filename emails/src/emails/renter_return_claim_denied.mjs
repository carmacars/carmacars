import { hero, p, facts, button, link, notice } from '../components.mjs';
import { FROM } from '../brand.mjs';

export default {
  code: 'renter_return_claim_denied',
  audience: 'renter',
  category: 'transactional',
  from: FROM.bookings,
  digest: false,
  trigger: 'Staff press Deny on the renter\'s "I\'ve returned the car" report (migration 0532): the car is not back. The booking is overdue again, so the late return notices resume.',
  timing: 'Immediate',
  subject: 'We could not confirm the return of the {{vehicle_name}}',
  preheader: 'The car is not checked out yet. Please return it now or call {{support_phone}}.',
  ref: 'Booking {{booking_number}}',
  body: [
    hero('Return not confirmed', 'We could not confirm your return', 'You told us the {{vehicle_name}} is back, {{first_name}}, but we could not confirm it. The booking is still overdue.'),
    facts(
      ['Was due', '{{return_date}}, {{return_time}}'],
      ['Return place', '{{return_place}}'],
      ['Why', '{{deny_reason}}'],
    ),
    notice('alert', 'What happens now', 'The late fees and the overdue notices go on until the car is checked out. Please return it now, or call us if it is already back.'),
    button('Pay for an extension', '@booking_extend'),
    link('Returned it since? Tell us in one tap', '{{returned_url}}'),
    p('To talk it through, call **{{support_phone}}** now.'),
  ],
  sample: { returned_url: 'https://carmacars.ca/returned/9d3b6a1e-4c2f-4b7a-8e1d-2f6c5a4b3e21', deny_reason: 'The car is not at the return place and the tracker shows it on the road.' },
};
