import { hero, vehicle, facts, button, list } from '../components.mjs';
import { FROM } from '../brand.mjs';

export default {
  code: 'marketing_new_vehicle',
  audience: 'renter',
  category: 'marketing',
  from: FROM.hello,
  digest: false,
  trigger: 'New car campaign (2490, app.job_marketing): a car\'s listing goes live on the site (published, bookable, not a sample car). Once per car, to every address in the marketing audience (anyone who gave us their email on carmacars.ca), minus anyone unsubscribed, bounced, complained or suppressed. Queued at the marketing priority and spread over the days within the free email budgets; an address still waiting when the car stops being listed is not sent. Switch: marketing_new_vehicle_enabled.',
  timing: 'When a new car is listed',
  subject: 'New in the fleet: the {{vehicle_name}}',
  preheader: 'From {{daily_price}} a day. Ready to book now.',
  ref: 'New car',
  body: [
    hero('New in the fleet', 'The {{vehicle_name}} is here', 'Hi {{first_name}}, we just added the {{vehicle_name}} to the CarmaCars fleet. Be one of the first to drive it.'),
    vehicle('{{vehicle_name}}'),
    facts(['From', '{{daily_price}} a day'], ['Seats', '{{seats}}'], ['Transmission', '{{transmission}}']),
    button('See the car', '{{car_url}}'),
    list(
      'Sending a request is free. We reply with a firm offer; nothing is charged until you approve, sign and pay.',
      'Questions about the car or your dates? Reply to this email.',
    ),
  ],
  sample: { daily_price: '$129', seats: '5', transmission: 'Automatic', car_url: 'https://carmacars.ca/cars/mercedes-benz-c300' },
};
