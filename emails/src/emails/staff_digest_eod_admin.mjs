import { digest } from './_digest.mjs';

export default digest({
  code: 'staff_digest_eod_admin',
  audience: 'staff_admin',
  slot: 'eod',
  role: 'Admin',
  queue: 'admin',
  contains: 'bookings confirmed today, money collected today, approvals still open, incidents updated today, anything a VA escalated that is not closed, tomorrow\'s pickups and returns',
  summary: '3 bookings confirmed and $1,412.85 collected today. 2 approvals are still open.',
  stats: [{ label: 'Confirmed today', value: '3 bookings' }, { label: 'Collected today', value: '$1,412.85' }],
  sections: [
    { title: 'Still open tonight', items: [
      { line: 'Refund outside the table: booking CC-10482, $468.95', meta: 'Waiting since Mon 11:40 am', url: 'https://carmacars.ca/admin/approvals' },
      { line: 'Deposit hold-back: booking CC-10431, $150.00', meta: 'Past the 7 business day limit.', url: 'https://carmacars.ca/admin/approvals' },
    ] },
    { title: 'Updated today', items: [
      { line: 'INC-2041: estimate received, $1,840.00', meta: 'Under $2,500. No claim. Bill the renter at cost.', url: 'https://carmacars.ca/admin/incidents/INC-2041' },
    ] },
    { title: 'Tomorrow', items: [
      { line: '5 pickups and 3 returns', meta: 'All have a field person. 1 pickup still needs coverage proof.', url: 'https://carmacars.ca/admin' },
    ] },
  ],
});
