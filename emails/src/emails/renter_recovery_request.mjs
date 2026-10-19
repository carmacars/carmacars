import { hero, small, button, list } from '../components.mjs';
import { FROM } from '../brand.mjs';

export default {
  code: 'renter_recovery_request',
  audience: 'renter',
  category: 'marketing',
  from: FROM.hello,
  digest: false,
  trigger: 'Booking recovery job (every 15 minutes): a signed-in or known renter started a booking request on the site and stopped without sending it, recovery_request_hours ago (Program settings, 2 by default), and has sent no request since. Marketing: only with the renter\'s express marketing consent and never after they unsubscribed. At most recovery_max_emails (2), the second after recovery_second_hours (24), and one such reminder series per renter in 7 days. Not sent outside the hours set for these emails or while a staff member is already handling the renter. Stops once they send a request.',
  timing: 'Some hours after a request was started',
  subject: 'Your request for the {{vehicle_name}} is not sent yet',
  preheader: 'Pick up where you left off. It takes two minutes.',
  ref: 'Your request',
  body: [
    hero('Your request', 'You did not finish your request', 'You started a booking request for the {{vehicle_name}}, {{first_name}}, but it was not sent. Pick up where you left off: a person checks it and sends you an offer.'),
    button('Finish the request', '{{car_url}}'),
    list(
      'Sending a request is free. Nothing is charged until you approve our offer, sign and pay.',
      'Questions about the car or the dates? Reply to this email.',
    ),
  ],
  sample: { car_url: 'https://carmacars.ca/cars/mercedes-benz-c300' },
};
