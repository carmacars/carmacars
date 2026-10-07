import { hero, p, small, h, rule, vehicle, keyfacts, figure, facts, price, compare, table, rows, button, link, notice, list, steps, when, each } from '../components.mjs';
import { FROM } from '../brand.mjs';
import { trip, places, bookingPrice } from '../snippets.mjs';

export default {
  code: 'renter_breakdown_help',
  audience: 'renter',
  category: 'transactional',
  from: FROM.bookings,
  digest: false,
  trigger: 'An incident of type breakdown on an on_rent booking has roadside dispatched (dispatched_at is set by Fleet). (Message template T18.)',
  timing: 'Immediate',
  source: 'T18',
  subject: 'Help is on the way, about {{eta_minutes}} minutes',
  preheader: 'Stay somewhere safe. Call {{roadside_phone}} if anything changes.',
  ref: 'Booking {{booking_number}}',
  body: [
    hero('Roadside help', 'Help is on the way', 'Roadside assistance has been sent to you, {{first_name}}.'),
    keyfacts(
      { label: 'Arriving in about', value: '{{eta_minutes}} minutes' },
      { label: 'Going to', value: '{{breakdown_location}}' },
    ),
    notice('alert', 'Stay somewhere safe', 'If you are on a highway, stay well away from traffic. Call **{{roadside_phone}}** if anything changes or you need to move.'),
    list(
      'Keep your phone on and the keys with you.',
      'Do not arrange your own tow or repair. Call us first.',
      'If the fault is mechanical and not your doing, roadside is free and we arrange a replacement car or refund the unused time.',
    ),
    link('View my booking', '@booking'),
  ],
  help: '**24-hour line:** {{roadside_phone}}',
  sample: { eta_minutes: '35', breakdown_location: 'Highway 401 eastbound at Keele Street, right shoulder' },
};
