import { hero, p, small, h, rule, vehicle, keyfacts, figure, facts, price, compare, table, rows, button, link, notice, list, steps, when, each } from '../components.mjs';
import { FROM } from '../brand.mjs';

export default {
  code: 'staff_job_failed',
  audience: 'staff_admin',
  category: 'transactional',
  from: FROM.hello,
  digest: false,
  trigger: 'An automatic task (a scheduled job) is marked failed (which also raises one urgent admin task). Sent to both admins once per job per day. Immediate.',
  timing: 'Immediate',
  subject: 'Automatic task failed: {{job_label}}, {{job_run_date}}',
  preheader: '{{job_effect}}',
  ref: 'System',
  // r29 C4 (migration 0583): what happened, what to do, one button
  body: [
    hero('System alert', 'The {{job_label}} task failed', '{{job_effect}} It failed at {{job_run_date}} and tries again on its next run.'),
    notice('info', 'What to do', 'Nothing yet. If it still fails in a few hours, forward this email to your developer. The error was: {{job_error}}'),
    button('See the automatic tasks', '@admin_jobs'),
  ],
  sample: {
    job_label: 'owner billing', job_run_date: 'Sun, Nov 15, 2026 at 6:10 am', job_effect: 'The automatic owner billing task did not finish, so its work has not happened yet.',
    job_error: 'Payment processor timeout after 30 seconds',
  },
};
