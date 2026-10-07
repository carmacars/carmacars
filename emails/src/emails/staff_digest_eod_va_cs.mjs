import { digest } from './_digest.mjs';

export default digest({
  code: 'staff_digest_eod_va_cs',
  audience: 'staff_va_cs',
  slot: 'eod',
  role: 'Customer service',
  queue: 'va_cs',
  contains: 'requests still unanswered, offers sent today and still open, documents still to review, change requests open, tomorrow\'s pickups and their verification status, reviews received today',
  summary: 'Every request has an answer. 4 offers are open and 1 pickup tomorrow still needs coverage proof.',
  stats: [{ label: 'Unanswered requests', value: '0' }, { label: 'Offers open', value: '4' }],
  sections: [
    { title: 'Tomorrow\'s pickups not verified', items: [
      { line: 'CC-10482: coverage proof missing', meta: 'Pickup Fri 10:00 am Reminder sent 2:00 pm', url: 'https://carmacars.ca/va/cs/bookings/CC-10482/identity' },
    ] },
    { title: 'Offers open', items: [
      { line: 'CC-10491: expires tomorrow 9:05 am', meta: '2024 Honda Civic Sport, $468.95', url: 'https://carmacars.ca/va/cs/bookings/CC-10491' },
      { line: 'CC-10492: expires tomorrow 10:20 am', meta: '2023 Toyota RAV4 XLE, $356.40', url: 'https://carmacars.ca/va/cs/bookings/CC-10492' },
    ] },
    { title: 'Reviews received', items: [
      { line: '5 of 5: 2024 Honda Civic Sport', meta: 'Booking CC-10440. Waiting to be published.', url: 'https://carmacars.ca/va/cs/reviews' },
    ] },
  ],
});
