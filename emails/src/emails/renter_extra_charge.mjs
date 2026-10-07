import { hero, p, small, h, rule, vehicle, keyfacts, figure, facts, price, compare, table, rows, button, link, notice, list, steps, when, each } from '../components.mjs';
import { FROM } from '../brand.mjs';
import { trip, places, bookingPrice } from '../snippets.mjs';

export default {
  code: 'renter_extra_charge',
  audience: 'renter',
  category: 'transactional',
  from: FROM.billing,
  digest: false,
  trigger: 'A charge is billed to a renter after the final statement: a toll or ticket matched to the booking and charged, or a damage, fuel, cleaning, mileage, lost key or other line added by Finance with its supporting record. One email per charge event. The supporting document is required; the charge cannot be sent without it. (Message template T19 for tolls and tickets.)',
  timing: 'Immediate, when the charge is taken',
  source: 'T19',
  subject: '{{charge_type}} charge of {{charge_total}} on booking {{booking_number}}',
  preheader: '{{charge_summary}}. The record is linked inside.',
  ref: 'Booking {{booking_number}}',
  body: [
    hero('Extra charge', '{{charge_type}} charge on your rental', 'A charge has come in for the time you had the {{vehicle_name}}, {{first_name}}. The record is below so you can check it.'),
    facts(
      ['What', '{{charge_summary}}'],
      ['When', '{{charge_event_date}}'],
      { label: 'Reference', value: '{{charge_reference}}', when: 'charge_reference' },
      ['Your rental', '{{pickup_date}} to {{return_date}}'],
    ),
    price({ each: 'charge_lines', total: ['Total charged', '{{charge_total}}'] }),
    notice('info', 'How it was paid', '{{charge_total}} was taken from {{charged_to}} on {{payment_date}}.'),
    button('View the supporting record', '{{supporting_document_url}}'),
    small('The record link works for 7 days. The charge and its record also stay in [your statement](@booking_statement). If you think this is not yours, reply to this email and tell us why. We check it against the trip record for the car.'),
  ],
  sample: {
    charge_type: 'Toll',
    charge_summary: 'Highway 407 ETR toll invoice',
    charge_event_date: 'Sat, Oct 24, 2026 at 3:18 pm',
    charge_reference: 'Invoice 4471-0092',
    charge_lines: [
      { label: 'Toll amount', amount: '$18.42' },
      { label: 'Administration fee, per toll invoice', amount: '$15.00' },
      { label: 'HST on the fee (13%)', amount: '$1.95' },
    ],
    charge_total: '$35.37',
    charged_to: 'your deposit',
    payment_date: 'Wed, Nov 11, 2026',
  },
};
