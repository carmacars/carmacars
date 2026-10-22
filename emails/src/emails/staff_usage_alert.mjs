import { hero, small, facts, button, notice } from '../components.mjs';
import { FROM } from '../brand.mjs';

export default {
  code: 'staff_usage_alert',
  audience: 'staff_admin',
  category: 'transactional',
  from: FROM.hello,
  digest: false,
  trigger: 'Usage guard (every hour, from the database): a metered service (Workers AI, Worker requests and CPU, image transformations, Resend emails, the Supabase database, file storage and egress, R2 storage, the Claude assistant) reached 80% of its included allowance for the period, or used all of it. Sent to the alert address in Program settings (uptime_alert_email), once per service, level and period, never from uptime_quiet_from_hour to uptime_quiet_until_hour (it waits for the morning). The same alert shows on Admin > To do.',
  timing: 'Immediate',
  subject: '{{usage_title}}',
  preheader: '{{usage_used}} of {{usage_included}} used. {{usage_effect}}',
  ref: 'Usage guard',
  body: [
    hero('Usage', '{{usage_title}}', '{{usage_effect}}'),
    facts(
      ['Service', '{{service_label}}'],
      ['Used', '{{usage_used}} of {{usage_included}} ({{usage_share}})'],
      ['Period', '{{usage_period}}'],
      ['Resets', '{{usage_resets}}'],
      ['If you allow paid usage', '{{usage_cost}}'],
    ),
    button('Open Usage', '@admin_usage'),
    notice('info', 'What to do', '{{usage_advice}}'),
    small('Sent by the usage guard, once per service and period. Change the address in Program settings, "Site check".'),
  ],
  sample: {
    usage_title: 'Included Workers AI used up for today', service_label: 'Workers AI (assistant, live chat, copy)', usage_used: '10,000 neurons', usage_included: '10,000 neurons', usage_share: '100%',
    usage_period: 'Today, Toronto time', usage_resets: 'Thu, Oct 22 at 12:00 am',
    usage_effect: 'AI features are paused until the allowance resets. Nothing is broken: each feature shows a short message and waits.',
    usage_cost: 'About US$0.011 per 1,000 neurons. A busy day above the allowance costs cents.',
    usage_advice: 'Open Usage to allow paid usage until the end of today or this month, up to an amount you choose, or keep it paused.',
  },
};
