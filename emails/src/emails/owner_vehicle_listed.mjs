import { hero, p, small, h, rule, vehicle, keyfacts, figure, facts, price, compare, table, rows, button, link, notice, list, steps, when, each } from '../components.mjs';
import { FROM } from '../brand.mjs';

export default {
  code: 'owner_vehicle_listed',
  audience: 'owner',
  category: 'transactional',
  from: FROM.owners,
  digest: false,
  trigger: 'Vehicle status changes from ready_to_list to available and its listing is published (staff approved the listing).',
  timing: 'Immediate',
  subject: 'Your {{vehicle_name}} is live and open for bookings',
  preheader: 'Approved and listed on carmacars.ca. Check the rates and block any dates you need.',
  ref: 'Vehicle listing',
  body: [
    hero('Approved and listed', 'Your car is live', 'The {{vehicle_name}} is on carmacars.ca and can be requested from today, {{first_name}}.'),
    vehicle(),
    facts(
      ['Daily rate', '{{daily_rate}}'],
      ['Weekend rate', '{{weekend_rate}}'],
      ['Weekly rate', '{{weekly_rate}}'],
      ['Monthly rate (30 days)', '{{monthly_rate}}'],
      ['Kilometres per day', '{{km_per_day}}'],
      ['Renter deposit', '{{deposit_amount}}'],
    ),
    button('View my listing and calendar', '@owner_vehicle_calendar'),
    list(
      'When you need the car yourself, ask for an Owner Booking in your account before you plan around it. A renter\'s confirmed booking has priority.',
      'We email you each time a booking on this car is confirmed.',
      'Earnings are paid on the 10th of each month for the month before, with a statement.',
    ),
  ],
  sample: {
    vehicle_name: '2023 Toyota RAV4 XLE', vehicle_id: 'v-3f81c2', daily_rate: '$100.00', weekend_rate: '$120.00', weekly_rate: '$560.00',
    monthly_rate: '$1,800.00', km_per_day: '200 km', deposit_amount: '$1,000.00',
  },
};
