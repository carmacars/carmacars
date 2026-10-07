import { hero, p, small, h, rule, vehicle, keyfacts, figure, facts, price, compare, table, rows, button, link, notice, list, steps, when, each } from '../components.mjs';
import { FROM } from '../brand.mjs';

export default {
  code: 'investor_notice_received',
  audience: 'investor',
  category: 'transactional',
  from: FROM.hello,
  digest: false,
  trigger: 'An admin logs a written notice received from an existing investor (change of bank account, change of the pay or reinvest election, change of contact details, or another notice under the Investment Agreement).',
  timing: 'Immediate, when the notice is logged',
  subject: 'We received your notice of {{notice_date}}',
  preheader: 'This confirms receipt. Details inside.',
  ref: 'Notice received',
  body: [
    hero('Notice received', 'We have your notice', 'Hello {{first_name}}. This confirms that we received your written notice.'),
    facts(
      ['Received', '{{notice_date}}'],
      ['About', '{{notice_subject}}'],
      { label: 'Takes effect', value: '{{notice_effective}}', when: 'notice_effective' },
    ),
    p('There is nothing more you need to do. If the details above do not match what you sent, reply to this email so we can correct our record.'),
    small('This is a confirmation of receipt only. Your signed Investment Agreement continues to govern.'),
  ],
  sample: {
    notice_date: 'Mon, Jul 5, 2027', notice_subject: 'Change of bank account for payments',
    notice_effective: 'From the Payment Date of August 15, 2027',
  },
};
