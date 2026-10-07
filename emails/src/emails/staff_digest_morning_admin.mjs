import { digest } from './_digest.mjs';

export default digest({
  code: 'staff_digest_morning_admin',
  audience: 'staff_admin',
  slot: 'morning',
  role: 'Admin',
  queue: 'admin',
  contains: 'approvals waiting, open incidents and claims, open disputes, late returns, charges unpaid over 24 hours, owners in arrears, requests waiting over 2 hours, failed jobs',
  summary: '4 approvals are waiting and 1 incident is open. 6 pickups and 4 returns today.',
  stats: [{ label: 'Approvals waiting', value: '4' }, { label: 'Today', value: '6 out, 4 back' }],
  sections: [
    { title: 'Approvals waiting', items: [
      { line: 'Refund outside the table: booking CC-10482, $468.95', meta: 'Asked by Grace, Mon 11:40 am Decide by Thu.', url: 'https://carmacars.ca/admin/approvals' },
      { line: 'Deposit hold-back: booking CC-10431, $150.00', meta: 'Toll expected. 8 business days since check-in.', url: 'https://carmacars.ca/admin/approvals' },
    ] },
    { title: 'Incidents and disputes', items: [
      { line: 'INC-2041: accident, 2023 Toyota RAV4 XLE', meta: 'Estimate due today from the shop.', url: 'https://carmacars.ca/admin/incidents/INC-2041' },
    ] },
    { title: 'Money overdue', items: [
      { line: 'Charge unpaid over 24 hours: booking CC-10418, $80.57', meta: 'Declined twice. Next retry Thu.', url: 'https://carmacars.ca/admin/bookings/CC-10418' },
      { line: 'Owner in arrears: 2022 Hyundai Elantra Preferred, $586.75', meta: 'Deduct at the Dec 10 payout.', url: 'https://carmacars.ca/admin/approvals' },
    ] },
  ],
});
