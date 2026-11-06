import { hero, p, small, h, rule, vehicle, keyfacts, figure, facts, price, compare, table, rows, button, link, notice, list, steps, when, each } from '../components.mjs';
import { FROM } from '../brand.mjs';
import { trip, places, bookingPrice } from '../snippets.mjs';

export default {
  code: 'renter_return_soon',
  audience: 'renter',
  category: 'transactional',
  from: FROM.bookings,
  digest: false,
  trigger: 'Reminders job (every 5 minutes, migration 0430): a booking that is out (on rent, or confirmed with its pickup time passed and no handover recorded) has its return about 3 hours away (notify_return_soon_hours). Sent once per return time, so again after an extension moves it. Only between 7 am and 10 pm Toronto time. Off with notify_return_soon.',
  timing: 'About 3 hours before return',
  subject: 'Your rental ends at {{return_time}}',
  preheader: 'Return to {{return_place}} with the same fuel and all keys, or extend in one tap.',
  ref: 'Booking {{booking_number}}',
  body: [
    hero('Return soon', 'Your rental ends at {{return_time}}', 'A quick reminder so the return is easy, {{first_name}}.'),
    keyfacts(
      { label: 'When', value: '{{return_time}}', sub: '{{return_date}}' },
      { label: 'Where', value: '{{return_place}}' },
    ),
    list(
      'Bring the fuel or charge back to where it was at pickup (**{{fuel_out}}**).',
      'Leave the car reasonably clean and take your belongings.',
      'Bring **all keys** and anything that came with the car.',
    ),
    p('**{{extend_offer}}.** Pick 1 hour, 3 hours, a day, a week or a month in your booking and pay with your card on file.'),
    button('Extend my rental', '@booking_extend'),
    p('When you return the car, Return the car yourself on your booking: the photos (all at once from your camera roll), the odometer and the fuel complete your trip in one step.'),
    notice('info', 'Please be on time', 'More than 30 minutes late, a late fee of {{late_fee_hourly}} per started hour applies, plus the rental charge for each extra day.'),
  ],
  sample: { fuel_out: 'Full', late_fee_hourly: '$25', return_time: '5:00 pm', extend_offer: 'Extend at 5% off: from $107.35 for 1 more day' },
};
