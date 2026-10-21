import { hero, p, small, h, list, button, notice, when } from '../components.mjs';
import { FROM } from '../brand.mjs';

export default {
  code: 'renter_coverage_needed',
  audience: 'renter',
  category: 'transactional',
  from: FROM.bookings,
  digest: false,
  trigger: 'A confirmed booking whose Coverage Option is 1 (OPCF 27 on the renter\'s own policy) or 2 (credit card rental coverage) has no proof waiting for review and none confirmed: sent 48 hours before pickup and again 24 hours before pickup (app.job_coverage_reminders, every 15 minutes). Not sent while a proof is in review, nor for the Protection Plan. The 48-hour one is skipped while a driver\'s licence is also missing (renter_identity_needed then lists the proof too).',
  timing: '48 hours and 24 hours before pickup, while the proof is missing or was declined',
  subject: 'Pickup in {{hours_left}}: we still need your proof of coverage',
  preheader: 'Without it we cannot hand over the car. It takes a few minutes on your phone.',
  ref: 'Booking {{booking_number}}',
  body: [
    hero('Proof of coverage', 'We still need your proof of coverage', 'Your pickup is in {{hours_left}}, {{first_name}}. You chose {{coverage_choice}}.'),
    notice('alert', 'Due by {{verify_by}}', 'We release the {{vehicle_name}} only once a person on our team has confirmed your coverage.'),
    when('has_reject_reason', [notice('info', 'What to fix', 'We could not accept what you sent last time: {{reject_reason}}')]),
    h('What to send'),
    p('{{coverage_what_to_send}}'),
    button('Send my proof', '@booking_verify'),
    h('Other choices'),
    list(
      '**OPCF 27 on your own auto policy.** Your policy document or the OPCF 27 endorsement, the insurer, the policy number and the expiry date.',
      '**Rental coverage on your credit card.** Only with the credit card you paid with, in your name. Debit and prepaid cards do not qualify.',
      '**The CarmaCars Protection Plan.** Ask us from the upload page and we add it to your booking.',
    ),
    small('A person on our team checks what you send. Your documents are kept privately with your rental records.'),
  ],
  sample: {
    hours_left: '24 hours',
    coverage_choice: 'OPCF 27 on your own auto policy',
    coverage_what_to_send: 'A PDF or photos of your policy document or the OPCF 27 endorsement, with the insurer, the policy number and the expiry date. The policy must still be active after your return date.',
    has_reject_reason: false,
    reject_reason: 'The policy shown ends before your return date.',
    verify_by: 'Thu, Oct 22 at 10:00 am',
  },
};
