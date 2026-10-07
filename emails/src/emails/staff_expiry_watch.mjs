import { hero, p, small, h, rule, vehicle, keyfacts, figure, facts, price, compare, table, rows, button, link, notice, list, steps, when, each } from '../components.mjs';
import { FROM } from '../brand.mjs';

export default {
  code: 'staff_expiry_watch',
  audience: 'staff_va_fleet',
  also: ['staff_admin'],
  category: 'transactional',
  from: FROM.owners,
  digest: true,
  digestSlot: 'morning',
  trigger: 'Expiry-watch job (daily 06:00) finds at least one item inside its window: plate renewal within 30 days, an insurance document within 14 days, a safety certificate inside its 36-day window with no registry visit booked, or arrears older than 30 days. The list is included in the Fleet morning digest; sent as its own email to Fleet and admins only when an item expires within 3 days.',
  timing: 'Morning digest. Own email when an item is within 3 days',
  subject: 'Expiry watch: {{expiry_count}} items, {{expiry_urgent_count}} within 3 days',
  preheader: 'Plates, insurance documents and safety certificates coming due.',
  ref: 'Expiry watch',
  body: [
    hero('Expiry watch', '{{expiry_count}} dates coming up', 'Sorted by date. The first {{expiry_urgent_count}} expire within 3 days.'),
    table({
      each: 'expiry_items',
      cols: [
        { head: 'Vehicle', value: '{{vehicle}}', strong: true },
        { head: 'Item', value: '{{item}}' },
        { head: 'Expires', value: '{{expires}}', align: 'right', strong: true },
      ],
    }),
    button('Open the expiry list', '@va_fleet_expiries'),
    list(
      'Turo-Only insurance: the owner gets a notice 14 days before. Unlist the car if proof lapses.',
      'Plates: renew before the month ends. The cost is an owner cost on the next statement.',
      'Safety certificate: the registry visit must fall inside its 36 days.',
    ),
  ],
  sample: {
    expiry_count: '4', expiry_urgent_count: '1',
    expiry_items: [
      { vehicle: '2021 Kia Forte EX (CKFT 207)', item: 'Safety certificate, no registry visit booked', expires: 'Nov 6' },
      { vehicle: '2022 Tesla Model 3 (CTSL 118)', item: 'Owner insurance proof (Turo-Only)', expires: 'Nov 14' },
      { vehicle: '2023 Toyota RAV4 XLE (CXRV 310)', item: 'Plate renewal', expires: 'Nov 30' },
      { vehicle: '2024 Honda Civic Sport (CMCR 482)', item: 'Plate renewal', expires: 'Nov 30' },
    ],
  },
};
