import { hero, p, small, h, rule, vehicle, keyfacts, figure, facts, price, compare, table, rows, button, link, notice, list, steps, when, each } from '../components.mjs';
import { FROM } from '../brand.mjs';

export default {
  code: 'owner_booking_changed',
  audience: 'owner',
  category: 'transactional',
  from: FROM.owners,
  digest: false,
  trigger: 'A change to a confirmed booking on the owner\'s car is applied (new dates, another car, or a new rental charge). One email to each owner whose car or income the change touches: the owner of the car it left and, if different, the owner of the car it moved to. Not sent for Owner Bookings, nor for a booking not shown to the owner (0156). show_amounts is false while staff hide the booking\'s revenue from the owner: the shares are left out.',
  timing: 'Immediate',
  subject: 'Booking {{booking_number}} changed',
  preheader: 'The new details of booking {{booking_number}}.',
  ref: 'Booking {{booking_number}}',
  body: [
    hero('Booking changed', 'A booking on your car changed', '{{owner_change_text}}'),
    compare('change_rows', 'Before', 'Now'),
    when('show_amounts', [
      facts(
        ['Your share before', '{{income_before}}'],
        ['Your share now', '{{income_after}}'],
      ),
    ]),
    when('income_changed', [
      notice('info', 'Your earnings changed', 'These are estimates from the rental charge and your Revenue Share. Your monthly statement shows the final figures.'),
    ]),
    button('View the booking', '@owner_booking'),
    small('The calendar of your car already shows the new dates.'),
  ],
  sample: {
    owner_change_text: 'The renter of booking CC-10482 accepted new details for your 2023 Toyota RAV4 XLE.',
    change_rows: [{ label: 'Return', before: 'Thu, Mar 11, 10:00 am', after: 'Fri, Mar 12, 10:00 am' }],
    income_before: '$195.00', income_after: '$260.00', income_changed: true, show_amounts: true,
  },
};
