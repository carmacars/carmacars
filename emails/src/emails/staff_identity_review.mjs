import { hero, p, small, h, rule, vehicle, keyfacts, figure, facts, price, compare, table, rows, button, link, notice, list, steps, when, each } from '../components.mjs';
import { FROM } from '../brand.mjs';

export default {
  code: 'staff_identity_review',
  audience: 'staff_va_cs',
  category: 'transactional',
  from: FROM.bookings,
  digest: true,
  digestSlot: 'next',
  trigger: 'A renter or additional driver uploads identity documents (licence front, back and selfie) or coverage proof, creating a verification in status pending review. Queued for the next customer service digest. Sent immediately instead when the booking\'s pickup is less than 48 hours away.',
  timing: 'Next digest. Immediate if pickup is within 48 hours',
  subject: 'Documents to review: {{driver_name}}, booking {{booking_number}}',
  preheader: '{{documents_summary}}. Pickup {{pickup_date}}. Due {{verify_by}}.',
  ref: 'Booking {{booking_number}}',
  body: [
    hero('Identity review', 'Documents are waiting for your review', '{{driver_name}} uploaded documents for booking {{booking_number}}. Review them before {{verify_by}}.'),
    facts(
      ['Driver', '{{driver_name}} ({{driver_role}})'],
      ['Uploaded', '{{documents_summary}}'],
      ['Pickup', '{{pickup_date}}, {{pickup_time}}'],
      ['Review due', '{{verify_by}}'],
    ),
    button('Review the documents', '@va_cs_identity'),
    h('Check'),
    list(
      'Name and date of birth match the booking.',
      'Licence class is G2 or G, and it expires after the return date.',
      'The face in the selfie matches the licence photo.',
      'Coverage proof is active to the return date and covers this car and every driver.',
    ),
    small('Escalate to an admin for a non-Ontario licence, a doubtful document, proof that does not clearly cover the car, or any refusal. Never copy document images out of the portal.'),
  ],
  sample: { driver_name: 'Maya Okafor', driver_role: 'renter', documents_summary: 'Licence front, licence back, selfie', verify_by: 'Thu, Oct 22 at 10:00 am' },
};
