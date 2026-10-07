import { digest } from './_digest.mjs';

export default digest({
  code: 'staff_digest_morning_va_finance',
  audience: 'staff_va_finance',
  slot: 'morning',
  role: 'Finance',
  queue: 'va_finance',
  contains: 'returns waiting for a statement, deposits near 7 business days since check-in, hold-backs near 30 days, card retries due today, declined payments, tolls and tickets to match and charge, refunds to process, owner invoices failed',
  summary: '3 statements to issue and 1 deposit reaches its 7 business day limit today.',
  stats: [{ label: 'Statements to issue', value: '3' }, { label: 'Deposits due today', value: '1' }],
  sections: [
    { title: 'Deposits near the limit', items: [
      { line: 'Booking CC-10431: $500.00 held', meta: 'Day 7 of 7 today. Release or hold back with a reason.', url: 'https://carmacars.ca/va/finance/bookings/CC-10431' },
    ] },
    { title: 'Returns to bill', items: [
      { line: 'Booking CC-10466: fuel short, no damage', meta: 'Checked in yesterday 9:52 am', url: 'https://carmacars.ca/va/finance/bookings/CC-10466' },
      { line: 'Booking CC-10459: 84 km over the allowance', meta: 'Checked in yesterday 4:10 pm', url: 'https://carmacars.ca/va/finance/bookings/CC-10459' },
    ] },
    { title: 'Tolls and tickets', items: [
      { line: 'Toll invoice, plate CMCR 482, $18.42', meta: 'Matched to booking CC-10482. Charge by Thu.', url: 'https://carmacars.ca/va/finance/tolls-tickets/tt-9012' },
    ] },
    { title: 'Declined payments', items: [
      { line: 'Booking CC-10418: $80.57 due', meta: 'Retry 2 runs today.', url: 'https://carmacars.ca/va/finance/bookings/CC-10418' },
    ] },
  ],
});
