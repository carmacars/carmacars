import { hero, rows, button, small } from '../components.mjs';
import { FROM } from '../brand.mjs';

export default {
  code: 'notify_summary',
  audience: 'renter',
  also: ['owner', 'investor', 'staff_admin', 'staff_va_finance', 'staff_va_fleet', 'staff_va_cs', 'staff_va_sales', 'staff_field'],
  category: 'transactional',
  from: FROM.hello,
  digest: false,
  trigger: 'A person chose a daily or a weekly summary on their Notifications page (release 48, migration 3260). The optional emails of the period are not sent one by one: each is held as a line and this email carries them, at the hour of Program settings (8:00 am Toronto time; the weekly one on Monday). Only when there is something to list. Security codes, legal and agreement notices, charges, receipts, booking confirmations and changes, return reminders, and for staff assigned work and onboarding or suspension notices are never held: they go at once.',
  timing: 'Daily or weekly, the person\'s choice',
  subject: 'Your {{period_word}} CarmaCars summary: {{count_words}}',
  preheader: 'What happened since your last summary.',
  ref: 'Summary',
  body: [
    hero('Summary', 'Your {{period_word}} summary', 'Hi {{first_name}}, here is what happened since your last summary: {{count_words}}.'),
    rows('items', '{{title}}', '{{when}}', '{{url}}'),
    button('Change what you get', '{{prefs_url}}'),
    small('Anything about your security, your agreement, your money or your booking is never held for a summary. It reaches you at once.'),
  ],
  sample: {
    first_name: 'Maya', period_word: 'daily', count_words: '2 updates', prefs_url: 'https://carmacars.ca/account/profile?tab=notifications',
    items: [
      { title: 'You earned 340 points on CC-10482', when: 'Thu, Nov 19 at 4:12 pm', url: 'https://carmacars.ca/account/rewards' },
      { title: 'How was your trip? Leave a review', when: 'Thu, Nov 19 at 6:30 pm', url: 'https://carmacars.ca/account/bookings/CC-10482/review' },
    ],
  },
};
