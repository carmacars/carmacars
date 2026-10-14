import { hero, p, small, h, rule, vehicle, keyfacts, figure, facts, price, compare, table, rows, button, link, notice, list, steps, when, each } from '../components.mjs';
import { FROM } from '../brand.mjs';

export default {
  code: 'staff_change_proposal_answered',
  audience: 'staff_va_cs',
  category: 'transactional',
  from: FROM.bookings,
  digest: true,
  digestSlot: 'next',
  trigger: 'A change staff proposed to a confirmed booking ends: the renter accepted it online (amendment signed, difference settled, booking updated), declined it, or did not answer by the deadline. Queued for the next customer service digest. Staff notices about a test owner\'s car go only to the verification accounts.',
  timing: 'Next digest',
  subject: '{{booking_number}}: the renter {{outcome_title}} the change',
  preheader: '{{renter_name}}, {{vehicle_name}}.',
  ref: 'Booking {{booking_number}}',
  body: [
    hero('Change answered', 'The renter {{outcome_title}} the change', '{{outcome_detail}}'),
    compare('change_rows', 'Before', 'Proposed'),
    facts(
      ['Renter', '{{renter_name}}'],
      ['Vehicle', '{{vehicle_name}}'],
    ),
    button('Open the booking', '@va_cs_booking'),
  ],
  sample: {
    outcome_title: 'accepted', outcome_detail: 'The renter signed the amendment and the booking now has the new details.',
    change_rows: [{ label: 'Return', before: 'Thu, Mar 11, 10:00 am', after: 'Fri, Mar 12, 10:00 am' }],
  },
};
