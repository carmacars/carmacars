import { hero, p, small, h, rule, vehicle, keyfacts, figure, facts, price, compare, table, rows, button, link, notice, list, steps, when, each } from '../components.mjs';
import { FROM } from '../brand.mjs';

export default {
  code: 'owner_toll_ticket',
  audience: 'owner',
  category: 'transactional',
  from: FROM.billing,
  digest: false,
  trigger: 'A toll or ticket is matched to the owner rather than a renter. is_forwarded true: the owner had the car outside the program, or the car is Turo-Only, and the notice is forwarded for the owner to pay. is_forwarded false: the owner had the car on an Owner Booking, CarmaCars paid it and an owner deduction is created at cost with no fee.',
  timing: 'Immediate, when Finance matches the notice',
  subject: '{{notice_type}} for your {{vehicle_name}}, {{notice_amount}}',
  preheader: '{{notice_action_short}}',
  ref: 'Notice {{notice_number}}',
  body: [
    hero('{{notice_type}}', 'A {{notice_type_lower}} came in for your {{vehicle_name}}', 'Our records show you had the car at the time, {{first_name}}.'),
    facts(
      ['Notice', '{{notice_description}}'],
      ['Date and time', '{{notice_event_date}}'],
      ['Notice no.', '{{notice_number}}'],
      ['Amount', '{{notice_amount}}'],
      { label: 'Due to the authority by', value: '{{notice_due_date}}', when: 'is_forwarded' },
    ),
    when('is_forwarded', [
      notice('alert', 'Please pay this directly by {{notice_due_date}}', 'We are forwarding the notice to you. CarmaCars has not paid it. Pay the authority named on the notice so no penalty is added.'),
    ], [
      notice('info', 'We paid it. It comes off your next payout.', '{{notice_amount}} is deducted on your next statement, at cost, with no administration fee, because you had the car on an Owner Booking.'),
    ]),
    button('View the notice', '{{supporting_document_url}}'),
    small('If you think this was not you, reply to this email. We check every notice against the trip record for the car.'),
  ],
  sample: {
    notice_type: 'Parking ticket', notice_type_lower: 'parking ticket', notice_description: 'City of Toronto parking infraction',
    notice_event_date: 'Sun, Nov 1, 2026 at 2:40 pm', notice_number: 'PA 4471 0092', notice_amount: '$50.00', is_forwarded: false,
    notice_due_date: '', notice_action_short: 'We paid it. $50.00 comes off your next payout, at cost.',
  },
};
