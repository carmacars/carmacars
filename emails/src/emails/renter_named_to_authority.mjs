import { hero, p, small, h, rule, vehicle, keyfacts, figure, facts, price, compare, table, rows, button, link, notice, list, steps, when, each } from '../components.mjs';
import { FROM } from '../brand.mjs';

export default {
  code: 'renter_named_to_authority',
  audience: 'renter',
  category: 'transactional',
  from: FROM.billing,
  digest: false,
  trigger: 'An admin names the renter to the issuing authority for a ticket or offence notice matched to the renter\'s booking (toll ticket status becomes named_to_authority). The authority will send its notice to the renter directly; CarmaCars does not pay it and adds no charge for it.',
  timing: 'Immediate, when the admin names the renter',
  subject: 'We gave your details to the issuing authority for {{notice_type_lower}} {{notice_number}}',
  preheader: 'The authority will contact you directly about booking {{booking_number}}.',
  ref: 'Booking {{booking_number}}',
  body: [
    hero('Notice transferred', 'The authority will contact you about this {{notice_type_lower}}', 'It was issued while you had the {{vehicle_name}}, {{first_name}}, so we named you as the driver as your rental agreement allows.'),
    facts(
      ['Notice', '{{notice_description}}'],
      ['Notice no.', '{{notice_number}}'],
      ['Date and time', '{{notice_event_date}}'],
      ['Amount on the notice', '{{notice_amount}}'],
      ['Issued by', '{{authority_name}}'],
      ['Booking', '{{booking_number}}'],
    ),
    notice('info', 'What happens next', 'The authority sends the notice, and any further steps, to you at the address on your licence. Pay it or respond to them directly by the date they give. CarmaCars has not paid it and will not charge you for it.'),
    button('View the notice', '{{supporting_document_url}}'),
    small('If you think this notice is not yours, reply to this email with the booking number. We check every notice against the trip record for the car.'),
  ],
  sample: {
    notice_type_lower: 'red light camera notice', notice_number: 'RLC 2026 448 190', notice_description: 'Red light camera, Dundas Street West at Bathurst Street',
    notice_event_date: 'Sat, Oct 24, 2026 at 6:12 pm', notice_amount: '$325.00', authority_name: 'City of Toronto',
  },
};
