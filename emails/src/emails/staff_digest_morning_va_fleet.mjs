import { digest } from './_digest.mjs';

export default digest({
  code: 'staff_digest_morning_va_fleet',
  audience: 'staff_va_fleet',
  slot: 'morning',
  role: 'Fleet',
  queue: 'va_fleet',
  contains: 'the opening checks of procedure 19: trackers not reporting, overnight movement or tamper alerts, today\'s handovers and returns with their field person and acknowledgement, tomorrow\'s pickups not ready, late returns, the expiry watch, listings to review, cars due for cleaning',
  summary: 'All trackers are reporting. 6 pickups and 4 returns today. 1 job is not acknowledged.',
  stats: [{ label: 'Today', value: '6 out, 4 back' }, { label: 'Trackers', value: 'All reporting' }],
  sections: [
    { title: 'Jobs not acknowledged', items: [
      { line: '4:00 pm pickup: 2023 Toyota RAV4 XLE', meta: 'Assigned to Sam yesterday 6:02 pm No acknowledgement.', url: 'https://carmacars.ca/staff/bookings/CC-10477' },
    ] },
    { title: 'Tomorrow\'s pickups not ready', items: [
      { line: 'Booking CC-10482: coverage proof missing', meta: 'Pickup Fri 10:00 am Customer service is chasing.', url: 'https://carmacars.ca/staff/bookings/CC-10482' },
    ] },
    { title: 'Expiry watch', items: [
      { line: '2021 Kia Forte EX: safety certificate ends Nov 6', meta: 'No registry visit booked.', url: 'https://carmacars.ca/staff/fleet#expiry' },
    ] },
    { title: 'Listings to review', items: [
      { line: '2023 Toyota RAV4 XLE: draft ready', meta: '14 photos. Live by Wed, Nov 11.', url: 'https://carmacars.ca/staff/listings/v-3f81c2' },
    ] },
  ],
});
