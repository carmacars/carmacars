import { hero, p, small, h, rule, vehicle, keyfacts, figure, facts, price, compare, table, rows, button, link, notice, list, steps, when, each } from '../components.mjs';
import { FROM } from '../brand.mjs';

export default {
  code: 'renter_driver_link',
  audience: 'renter',
  category: 'transactional',
  from: FROM.bookings,
  digest: false,
  trigger: 'The signing link of an additional driver is sent: when the renter\'s agreement is opened, or when the renter or customer service sends a new link from the booking. Sent to the additional driver\'s own email address. The link is valid for booking_driver_link_hours (Program settings, 72 by default); a newer link replaces it.',
  timing: 'Immediate',
  subject: '{{renter_name}} added you as a driver on booking {{booking_number}}',
  preheader: 'Read and accept the rental agreement before pickup. The link works until {{link_expires}}.',
  ref: 'Booking {{booking_number}}',
  body: [
    hero('Additional driver', 'Accept the rental agreement', 'Hi {{first_name}}, {{renter_name}} added you as a driver on a CarmaCars booking. You need to accept the agreement before you drive.'),
    facts(
      ['Car', '{{vehicle_name}}'],
      ['Pickup', '{{pickup_date}}, {{pickup_time}}'],
      ['Return', '{{return_date}}, {{return_time}}'],
    ),
    button('Read and accept', '{{sign_url}}'),
    p('No account is needed. The link works until **{{link_expires}}**. If it has expired, ask {{renter_name}} to send a new one from their booking.'),
    small('Bring your driver\'s licence at pickup. We check it against the details on the booking.'),
  ],
  sample: {
    sign_url: 'https://carmacars.ca/sign/driver/eyJzIjoiZXhhbXBsZSJ9.c2lnbmF0dXJl', link_expires: 'Mon, Mar 1 at 3:00 pm',
  },
};
