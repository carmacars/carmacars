import { hero, p, small, h, rule, vehicle, keyfacts, figure, facts, price, compare, table, rows, button, link, notice, list, steps, when, each } from '../components.mjs';
import { FROM } from '../brand.mjs';

export default {
  code: 'staff_listing_ready_for_review',
  audience: 'staff_va_fleet',
  also: ['staff_admin'],
  category: 'transactional',
  from: FROM.owners,
  digest: true,
  digestSlot: 'next',
  trigger: 'The AI drafting step finishes for a vehicle listing (photos processed, description and details drafted) and the vehicle status becomes ready_to_list. Queued for the next Fleet digest. Nothing is published until a person approves.',
  timing: 'Next digest',
  subject: 'Listing ready for review: {{vehicle_name}}',
  preheader: 'Draft text and {{photo_count}} photos. Check, fix and publish within 2 business days.',
  ref: 'Vehicle listing',
  body: [
    hero('Listing review', 'A drafted listing needs a person', 'The draft for the {{vehicle_name}} is ready. It was written automatically, so read every line before it goes live.'),
    vehicle(),
    facts(
      ['Owner', '{{owner_name}}'],
      ['Photos', '{{photo_count}} processed'],
      ['Rates and deposit', '{{rates_status}}'],
      ['Flagged by the draft step', '{{listing_flags}}'],
      ['Live by', '{{listing_due}}'],
    ),
    button('Review the listing', '@va_fleet_listing'),
    h('Check before you publish'),
    list(
      'Year, make, model, trim, colour and fuel match the fleet register.',
      'The photos are of this car and show no plate glare, people or personal items.',
      'Features in the text are really on the car. Remove anything you cannot confirm.',
      'Rates, deposit, kilometres and the "18 to 20 allowed" flag are set by an admin.',
      'The text says "liability coverage included" and never names a coverage provider.',
    ),
  ],
  sample: {
    vehicle_name: '2023 Toyota RAV4 XLE', vehicle_id: 'v-3f81c2', photo_count: '14', rates_status: 'Set by admin', listing_flags: 'Trim could not be confirmed from the photos',
    listing_due: 'Wed, Nov 11, 2026',
  },
};
