import { hero, facts, notice, button, list, small } from '../components.mjs';
import { FROM } from '../brand.mjs';

export default {
  code: 'staff_pound_flag',
  audience: 'staff_va_fleet',
  also: ['staff_admin'],
  category: 'transactional',
  from: FROM.bookings,
  digest: false,
  trigger: 'Tracker events are on (migration 3320) and a car\'s Tracker shows it parked inside the radius of a known impound or pound lot (Admin > Cars > Fleet tracking > Pound lots) for the minutes set in Tracking settings. The booking is flagged, Fleet gets an urgent To do and alert, and this email. Once per car, lot and stay.',
  timing: 'Immediate, once per stay at a lot',
  subject: 'AT A POUND: {{car_label}} at {{lot_name}}',
  preheader: '{{booking_line}}. Parked since {{pound_since}}.',
  ref: '{{car_label}}',
  body: [
    hero('Pound flag', '{{car_label}} is parked at a pound', 'The Tracker shows it at {{lot_name}} since {{pound_since}}. {{booking_line}}.'),
    facts(
      ['Lot', '{{lot_name}}, {{lot_address}}'],
      ['Phone', '{{lot_phone}}'],
      ['Hours', '{{lot_hours}}'],
      ['Since', '{{pound_since}}'],
    ),
    notice('alert', 'Do now', 'Call the lot to confirm the car is there and what releases it, then call the renter. Keep every receipt: tow, impound, storage.'),
    button('Open Fleet tracking', '@va_fleet_tracking'),
    list(
      '**Not back after the final late notice:** the non-return charge ({{non_return_fee}} plus HST) and the recovery costs at cost (rental agreement 10.6).',
      '**Stolen, or recovered by the police or a repossession:** the theft recovery charge ({{theft_recovery_fee}} plus HST) and the costs (10.8).',
      '**Recovered with nothing owed, or not a pound:** record that on the flag, with a note.',
    ),
    small('Record the path on Fleet tracking > Pound flags. The Tracker evidence record is attached to the charge by itself.'),
  ],
  sample: {
    car_label: '2024 Honda Civic Sport (CC-7F3A)', lot_name: 'Example Towing and Storage', lot_address: '100 Example Road, Toronto, ON', lot_phone: '416-555-0100',
    lot_hours: 'Open 24 hours', pound_since: 'Sat, Nov 21, 2026 at 2:14 pm', booking_line: 'Booking CC-10482', non_return_fee: '$1,000.00', theft_recovery_fee: '$1,500.00',
  },
};
