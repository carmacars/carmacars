// r29 C3 (migration 0583): the staff email digest. Every staff and Admin email that is not urgent goes into it instead of
// its own email: at most one an hour (or one a day, or none: Profile, Notifications), with everything since the last one.
// The in-app notice and the phone alert of each one are still sent at once.
import { hero, small, keyfacts, rows, button, when, notice } from '../components.mjs';
import { FROM } from '../brand.mjs';

export default {
  code: 'staff_digest_hourly',
  audience: 'staff_admin',
  category: 'transactional',
  from: FROM.hello,
  digest: false,
  trigger: 'Staff and Admin alerts by email (migration 0583): each alert that is not urgent is kept for this digest instead of its own email; at most one digest an hour per person (or one a day at 07:00 Toronto time, or none, as each person chooses under Profile, Notifications), with every alert since the last one. Urgent alerts (a payment declined, documents to review for a pickup within 2 hours, the site down) still go on their own, at most 3 an hour per person. Every alert is also an in-app notice and a phone alert at once.',
  timing: 'At most hourly',
  subject: 'Your CarmaCars alerts: {{digest_count}} since {{digest_since}}',
  preheader: '{{digest_summary}}',
  ref: '{{digest_date}}',
  body: [
    hero('Your alerts', 'Since {{digest_since}}, {{first_name}}', '{{digest_summary}}'),
    keyfacts({ label: 'Alerts', value: '{{digest_count}}' }, { label: 'Next digest', value: '{{digest_next}}' }),
    when('has_items', [rows('items', '{{line}}', '{{meta}}', '{{url}}')], [notice('info', 'Nothing new', 'No alert since the last digest.')]),
    button('Open my queue', '@admin'),
    small('Urgent alerts still come on their own. Change how often this digest comes under Profile, Notifications.'),
  ],
  sample: {
    digest_date: 'Fri, Nov 6', digest_since: '5:00 pm', digest_next: '7:00 pm', digest_count: '3', has_items: true,
    digest_summary: '3 alerts: a new request, a review and a listing to review.',
    items: [
      { line: 'New request CC-10511: 2024 Honda Civic Sport, Nov 9', meta: '5:12 pm', url: 'https://carmacars.ca/admin/bookings/CC-10511' },
      { line: 'New review: 5 of 5 for the 2023 Toyota RAV4 XLE', meta: '5:40 pm', url: 'https://carmacars.ca/admin/reviews' },
      { line: 'Listing ready for review: 2022 Hyundai Elantra Preferred', meta: '5:55 pm', url: 'https://carmacars.ca/admin/listings' },
    ],
  },
};
