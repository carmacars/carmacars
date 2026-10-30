import { digest } from './_digest.mjs';

export default digest({
  code: 'staff_digest_eod_va_finance',
  audience: 'staff_va_finance',
  slot: 'eod',
  role: 'Finance',
  queue: 'va_finance',
  contains: 'processor payouts not matched by the 18:00 reconcile job, today\'s returns not yet billed, refunds still open, cancellations received today, payments that failed today',
  summary: 'The processor payout matched. 1 return from today is not billed and 1 refund is open.',
  stats: [{ label: 'Reconcile', value: 'Matched' }, { label: 'Open tonight', value: '2' }],
  sections: [
    { title: 'Not billed yet', items: [
      { line: 'Booking CC-10471: returned today 2:15 pm', meta: 'Findings in. Statement due within 7 business days.', url: 'https://carmacars.ca/staff/bookings/CC-10471' },
    ] },
    { title: 'Refunds open', items: [
      { line: 'Booking CC-10455: $351.71, cancellation', meta: 'Received today 9:14 am Target 2 business days.', url: 'https://carmacars.ca/staff/bookings/CC-10455' },
    ] },
  ],
});
