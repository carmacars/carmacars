import { digest } from './_digest.mjs';

export default digest({
  code: 'staff_digest_morning_va_cs',
  audience: 'staff_va_cs',
  slot: 'morning',
  role: 'Customer service',
  queue: 'va_cs',
  contains: 'requests waiting for an offer, requests waiting on the renter, offers open and when each expires, identity and coverage documents to review, change requests, tomorrow\'s pickups with verification incomplete, reviews to moderate, bookings confirmed since the last digest',
  summary: '2 requests need an offer and 2 sets of documents are waiting for review.',
  stats: [{ label: 'Requests to answer', value: '2' }, { label: 'Documents to review', value: '2' }],
  sections: [
    { title: 'Requests waiting for an offer', items: [
      { line: 'CC-10491: 2024 Honda Civic Sport, Fri Oct 30 to Mon Nov 2', meta: 'Received yesterday 9:40 pm', url: 'https://carmacars.ca/va/cs/bookings/CC-10491' },
      { line: 'CC-10492: 2023 Toyota RAV4 XLE, Sat Oct 24 to Sun Oct 25', meta: 'Received today 6:15 am Driver is 20.', url: 'https://carmacars.ca/va/cs/bookings/CC-10492' },
    ] },
    { title: 'Offers expiring today', items: [
      { line: 'CC-10482: Maya Okafor, $468.95', meta: 'Expires 2:15 pm Reminder goes at 8:15 am', url: 'https://carmacars.ca/va/cs/bookings/CC-10482' },
    ] },
    { title: 'Documents to review', items: [
      { line: 'CC-10477: licence and selfie, 1 driver', meta: 'Pickup tomorrow 4:00 pm Due today 4:00 pm', url: 'https://carmacars.ca/va/cs/bookings/CC-10477/identity' },
      { line: 'CC-10480: coverage proof', meta: 'Pickup Sat 11:00 am', url: 'https://carmacars.ca/va/cs/bookings/CC-10480/identity' },
    ] },
    { title: 'Confirmed since yesterday', items: [
      { line: 'CC-10479: 2022 Hyundai Elantra Preferred, Mon Oct 26', meta: 'Paid $512.40. Verification not started.', url: 'https://carmacars.ca/va/cs/bookings/CC-10479' },
    ] },
  ],
});
