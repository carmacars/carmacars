import { hero, p, small, h, rule, vehicle, keyfacts, figure, facts, price, compare, table, rows, button, link, notice, list, steps, when, each } from '../components.mjs';
import { FROM } from '../brand.mjs';

export default {
  code: 'staff_listing_similarity',
  audience: 'staff_va_fleet',
  category: 'transactional',
  from: FROM.hello,
  digest: true,
  digestSlot: 'next',
  trigger: 'The listing similarity check finds a likely duplicate that stops publishing: a VIN one character from another car, the same plate, the same listing photo as a listed car, listing text very like a listed car (listing_similarity_copy_bps in Program settings), Queued for the next Fleet digest; a Fleet task is raised with it.',
  timing: 'Next digest',
  subject: 'Possible duplicate: {{vehicle_name}}',
  preheader: '{{flag_kind}}. Clear it or confirm it before the car is published.',
  ref: '{{vehicle_name}}',
  body: [
    hero('Possible duplicate', '{{flag_kind}}', '{{flag_detail}}'),
    facts(
      ['New car', '{{vehicle_name}}'],
      ['Looks like', '{{other_vehicle_name}}'],
    ),
    button('Review similar cars', '@va_similar_cars'),
    small('The car is not published while the flag is open. Compare the permit, the plate and the photos; clear the flag with a note if they are different cars.'),
  ],
  sample: {
    vehicle_name: '2022 Toyota Corolla LE', other_vehicle_name: '2022 Toyota Corolla LE', flag_kind: 'Same plate', flag_detail: 'Same plate CMCR482 as 2022 Toyota Corolla LE',
  },
};
