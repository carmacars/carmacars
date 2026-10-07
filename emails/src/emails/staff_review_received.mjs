import { hero, p, small, h, rule, vehicle, keyfacts, figure, facts, price, compare, table, rows, button, link, notice, list, steps, when, each } from '../components.mjs';
import { FROM } from '../brand.mjs';

export default {
  code: 'staff_review_received',
  audience: 'staff_va_cs',
  also: ['staff_admin'],
  category: 'transactional',
  from: FROM.hello,
  digest: true,
  digestSlot: 'next',
  trigger: 'A renter submits a review for a closed booking (review row created, status pending moderation). Queued for the next customer service digest. A rating of 2 stars or lower is sent immediately to customer service and both admins instead.',
  timing: 'Next digest. Immediate for 2 stars or lower',
  subject: 'New review: {{review_rating}} of 5 for the {{vehicle_name}}',
  preheader: '{{renter_name}}, booking {{booking_number}}. Read it and publish or reply.',
  ref: 'Booking {{booking_number}}',
  body: [
    hero('New review', '{{review_rating}} of 5 from {{renter_name}}', 'For the {{vehicle_name}}, booking {{booking_number}}. It is not public until you publish it.'),
    notice('info', '{{review_title}}', '{{review_text}}'),
    facts(
      ['Rental', '{{pickup_date}} to {{return_date}}'],
      ['Handover by', '{{field_staff_name}}'],
    ),
    button('Open reviews', '@va_cs_reviews'),
    small('Publish it as written, or hold it and tell an admin if it names a person or contains private details. Reply personally to a low rating.'),
  ],
  sample: { review_rating: '5', review_title: 'Clean car, easy handover', review_text: 'Sam was on time and walked me through everything. The car was spotless and the return took five minutes.' },
};
