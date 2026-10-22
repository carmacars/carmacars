import { hero, p, small, button, notice, when } from '../components.mjs';
import { FROM } from '../brand.mjs';

export default {
  code: 'renter_continue_request',
  audience: 'renter',
  category: 'transactional',
  from: FROM.hello,
  digest: false,
  trigger: 'Contact capture (migration 0090): someone typed their email into a booking request, a contact form, the owner application, the discount game or the live chat. One email per account, ever. A new account opened for that address: sent by the capture job (every 15 minutes) capture_continue_minutes (30) after they stopped typing without sending the form, only within the hours set for booking recovery emails. An address that already has an account: sent at once, as the sign-in link the site says it sent. The button opens /continue, which signs the person in and confirms the email in one step and lands on their draft or request. Transactional: it is about the account opened in their name; never with offers.',
  timing: 'Some minutes after a form was left unfinished (new account), or at once (an existing account)',
  subject: 'Continue your request',
  preheader: 'One tap signs you in and confirms your email. The link works for {{link_expiry}}.',
  ref: 'Your request',
  body: [
    hero('Your request', 'Continue where you left off', 'Hi {{first_name}}, you started {{started_what}} on carmacars.ca. One tap signs you in, confirms your email and opens it again.'),
    button('Continue your request', '{{continue_url}}'),
    small('The link works for {{link_expiry}} on any device. No password needed.'),
    when('new_account', [p('We opened an account in your name with this email, so you can carry on from any device. Nothing is booked or charged until you approve an offer, sign and pay.')]),
    notice('info', 'If this was not you', 'Ignore this email. Nobody can use the account without this link, and an account that is never confirmed closes by itself after 30 days.'),
  ],
  sample: { continue_url: 'https://carmacars.ca/continue?t=9f2c41b7e0a84d6c8b3f5e1a2d7c9b04', started_what: 'a booking request for the 2023 Mercedes-Benz C300', new_account: true },
};
