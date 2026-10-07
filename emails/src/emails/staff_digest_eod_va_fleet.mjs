import { digest } from './_digest.mjs';

export default digest({
  code: 'staff_digest_eod_va_fleet',
  audience: 'staff_va_fleet',
  slot: 'eod',
  role: 'Fleet',
  queue: 'va_fleet',
  contains: 'the closing checks of procedure 19: handovers and returns without a signed condition report or full photo set, returns with no findings sent to Finance, calendar statuses that do not match, tomorrow\'s cars not cleaned, incidents updated, the handover note for the on-call person',
  summary: '10 of 10 jobs done. 1 return has no findings yet and 1 car for tomorrow is not cleaned.',
  stats: [{ label: 'Jobs done', value: '10 of 10' }, { label: 'To close', value: '2' }],
  sections: [
    { title: 'Returns without findings', items: [
      { line: 'Booking CC-10471: returned 2:15 pm', meta: 'Photo set filed. Send the findings to Finance today.', url: 'https://carmacars.ca/va/fleet/bookings/CC-10471' },
    ] },
    { title: 'Not ready for tomorrow', items: [
      { line: '2022 Hyundai Elantra Preferred: status Cleaning', meta: 'Pickup tomorrow 9:00 am', url: 'https://carmacars.ca/va/fleet/vehicles/v-88ad10' },
    ] },
  ],
});
