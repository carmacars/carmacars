import { hero, small, h, table, button, when, each } from '../components.mjs';
import { FROM } from '../brand.mjs';

export default {
  code: 'owner_weekly_summary',
  audience: 'owner',
  category: 'transactional',
  from: FROM.owners,
  digest: false,
  trigger: 'Every Monday at about 9:00 Toronto time (2620, app.job_owner_weekly, every 15 minutes), once per owner per week (the dedupe key is the owner and the Monday), only for an owner with any activity: a trip returned last week (Monday to Sunday), a confirmed booking in the next 14 days, or earnings this month so far. Switch: Program settings owner_weekly_summary_enabled (on by default). Per car: the trips completed last week with dates and the owner\'s share, the confirmed bookings of the next 14 days (dates only, no renter details), and the month to date, provisional (app.owner_month_to_date). Only bookings that count toward the owner\'s revenue (app.booking_counts_for_owner, 2480) are listed; a trip whose revenue is not shown to the owner yet lists its dates and "On your statement" in place of the share (0156).',
  timing: 'Weekly',
  subject: 'Your week with CarmaCars: {{week_label}}',
  preheader: 'Last week\'s trips, what is coming up and your month so far.',
  ref: '{{week_label}}',
  body: [
    hero('Your week', 'Your cars, week by week', 'Hi {{first_name}}, here is what happened with your cars last week ({{week_label}}) and what is coming up.'),
    each('cars', [
      h('{{car_name}}'),
      when('has_trips', [
        table({ each: 'trips', cols: [{ head: 'Trip completed', value: '{{dates}}', strong: true }, { head: 'Your share', value: '{{share}}', align: 'right' }] }),
      ]),
      when('has_upcoming', [
        table({ each: 'upcoming', cols: [{ head: 'Coming up in the next 14 days', value: '{{dates}}' }] }),
      ]),
      when('has_mtd', [small('Your share in {{month_label}} so far, provisional: {{month_share}}')]),
    ]),
    button('Open your owner portal', '@owner'),
    small('Shares are estimates from the rental charge and your Revenue Share. Your monthly statement shows the final figures.'),
  ],
  sample: {
    first_name: 'Daniel', week_label: 'Mon, Nov 2 to Sun, Nov 8, 2026',
    cars: [{
      car_name: '2023 Toyota RAV4 XLE',
      has_trips: true, trips: [{ dates: 'Tue, Nov 3 to Fri, Nov 6', share: '$340.00' }, { dates: 'Sat, Nov 7 to Sun, Nov 8', share: 'On your statement' }],
      has_upcoming: true, upcoming: [{ dates: 'Wed, Nov 11 to Fri, Nov 13' }],
      has_mtd: true, month_label: 'November', month_share: '$1,120.00',
    }],
  },
};
