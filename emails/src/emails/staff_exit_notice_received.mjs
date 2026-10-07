import { hero, p, small, h, rule, vehicle, keyfacts, figure, facts, price, compare, table, rows, button, link, notice, list, steps, when, each } from '../components.mjs';
import { FROM } from '../brand.mjs';

export default {
  code: 'staff_exit_notice_received',
  audience: 'staff_va_fleet',
  also: ['staff_admin', 'staff_va_finance'],
  category: 'transactional',
  from: FROM.owners,
  digest: true,
  digestSlot: 'next',
  trigger: 'Vehicle status changes to exit_notice. Queued for the next Fleet, finance and admin digests. Sent immediately to the admins instead when the fleet count after the exit would be below 10.',
  timing: 'Next digest. Immediate to admins if the fleet would fall below 10',
  subject: 'Exit notice: {{owner_name}}, {{vehicle_name}}, Exit Date {{exit_date}}',
  preheader: 'Block the calendar after the Exit Date and plan the re-transfer.',
  ref: 'Vehicle exit',
  body: [
    hero('Exit notice', '{{vehicle_name}} is leaving on {{exit_date}}', '{{owner_name}} gave written notice on {{notice_date}}. The owner\'s other vehicles carry on.'),
    facts(
      ['Exit Date', '{{exit_date}}'],
      ['Bookings before the Exit Date', '{{bookings_before_exit}}'],
      ['On the fleet policy since', '{{enrollment_date}}'],
      ['Transfer-back fees', '{{retransfer_fee_note}}'],
      ['Fleet count after exit', '{{fleet_count_after}}'],
    ),
    button('Open the vehicle', '@va_fleet_vehicle'),
    list(
      'Block the calendar after the Exit Date.',
      'Get the owner\'s proof of own insurance from the Exit Date.',
      'On the Exit Date: remove the tracker, record odometer and photos, have the broker remove the car.',
      'Complete our part of the re-transfer within 10 business days after the Exit Date. Both sides sign Form E.',
      'Finance: bill the final month pro-rated and pay the final balance on the first payout date after the month of the Exit Date.',
    ),
    small('Never delay a re-transfer because money is owed.'),
  ],
  sample: {
    exit_date: 'Wed, Dec 2, 2026', notice_date: 'Mon, Nov 2, 2026', bookings_before_exit: '2 confirmed, last return Nov 28', enrollment_date: 'Aug 14, 2026',
    retransfer_fee_note: 'Owner pays (under 6 months on the policy)', fleet_count_after: '12',
  },
};
