import { hero, p, small, h, rule, vehicle, keyfacts, figure, facts, price, compare, table, rows, button, link, notice, list, steps, when, each } from '../components.mjs';
import { FROM } from '../brand.mjs';

export default {
  code: 'staff_approval_needed',
  audience: 'staff_admin',
  category: 'transactional',
  from: FROM.billing,
  digest: true,
  digestSlot: 'next',
  trigger: 'A task that only an admin can approve is raised, other than a tracker disable: a refund outside the tier table or over the VA limit, a deposit release with a hold-back, a price override, a fee off the grid, or a write-off. Queued for the next admin digest. Sent immediately instead when its due time is within 4 hours.',
  timing: 'Next digest. Immediate if due within 4 hours',
  subject: 'Approval needed: {{approval_type}}, {{amount}}',
  preheader: 'Asked by {{requested_by}}. {{approval_summary}}',
  ref: 'Approval',
  body: [
    hero('Approval needed', '{{approval_type}}', '{{requested_by}} needs an admin decision before this can go ahead.'),
    figure('Amount', '{{amount}}', '{{approval_summary}}'),
    facts(
      ['Asked by', '{{requested_by}} at {{requested_at}}'],
      ['About', '{{approval_subject}}'],
      ['Reason given', '{{approval_reason}}'],
      ['Decide by', '{{approval_due}}'],
    ),
    button('Review and decide', '@admin_approvals'),
  ],
  sample: {
    approval_type: 'Refund outside the table', amount: '$468.95', approval_summary: 'Full refund on a booking cancelled 20 hours before pickup.',
    requested_by: 'Grace (Finance)', requested_at: 'Tue, Oct 20 at 11:40 am', approval_subject: 'Booking CC-10482, Maya Okafor',
    approval_reason: 'Renter was hospitalised and sent a doctor\'s note.', approval_due: 'Thu, Oct 22',
  },
};
