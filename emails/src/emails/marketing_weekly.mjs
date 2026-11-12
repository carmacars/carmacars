import { hero, h, rows, button, when, small } from '../components.mjs';
import { FROM } from '../brand.mjs';

export default {
  code: 'marketing_weekly',
  audience: 'renter',
  category: 'marketing',
  from: FROM.hello,
  digest: false,
  trigger: 'Weekly marketing campaign (2490, app.job_marketing): once a week, on Program settings marketing_weekly_dow at marketing_weekly_hour (Toronto time), to every address in the marketing audience (anyone who gave us their email on carmacars.ca: renters, accounts, leads, forms left unfinished), minus anyone unsubscribed, bounced, complained or suppressed. The cars and deals come from the live listings and the active public promo codes when the campaign is made. Queued at the marketing priority: booking, payment and sign-in emails always go first, and the sends are spread over the days within the free email budgets. Switch: marketing_weekly_enabled.',
  timing: 'Weekly',
  subject: '{{headline}}',
  preheader: '{{preheader_text}}',
  ref: 'This week',
  body: [
    hero('This week', '{{headline}}', 'Hi {{first_name}}, here are cars ready to rent this week, with their prices. Send a request in two minutes: we reply with a firm offer, and nothing is charged until you approve, sign and pay.'),
    rows('cars', '{{name}}', '{{meta}}', '{{url}}'),
    when('has_deals', [h('Deals'), rows('deals', '{{label}}', '{{detail}}', '{{url}}')]),
    button('See every car', '@cars'),
    small('Questions about a car or your dates? Reply to this email.'),
  ],
  sample: {
    headline: '12 cars ready to rent this week',
    preheader_text: 'From $59 a day. Delivery across the GTA.',
    cars: [
      { name: '2024 Mercedes-Benz C 300', meta: 'From $129 a day. 5 seats, automatic.', url: 'https://carmacars.ca/cars/mercedes-benz-c300' },
      { name: '2023 Toyota Corolla', meta: 'From $59 a day. 5 seats, automatic.', url: 'https://carmacars.ca/cars/toyota-corolla' },
    ],
    has_deals: true,
    deals: [{ label: 'Code WINTER15', detail: '15% off the rental charge, until Mon, Nov 30, 2026.', url: 'https://carmacars.ca/cars' }],
  },
};
