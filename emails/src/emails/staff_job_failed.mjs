import { hero, p, small, h, rule, vehicle, keyfacts, figure, facts, price, compare, table, rows, button, link, notice, list, steps, when, each } from '../components.mjs';
import { FROM } from '../brand.mjs';

export default {
  code: 'staff_job_failed',
  audience: 'staff_admin',
  category: 'transactional',
  from: FROM.hello,
  digest: false,
  trigger: 'A scheduled job run is marked failed in job_runs (which also raises one urgent admin task). Sent to both admins once per job per day. Immediate.',
  timing: 'Immediate',
  subject: 'JOB FAILED: {{job_name}}, {{job_run_date}}',
  preheader: '{{job_effect}}',
  ref: 'System',
  body: [
    hero('System alert', 'The {{job_name}} job failed', 'It will try again on the next hourly run today. Until it succeeds, the work below has not happened.'),
    facts(
      ['Job', '{{job_name}}'],
      ['Run', '{{job_run_date}}'],
      ['What did not happen', '{{job_effect}}'],
      ['Error', '{{job_error}}'],
    ),
    button('Open the job log', '@admin_jobs'),
    small('If it has not recovered within a few hours, send this email to the developer. Do not run money jobs by hand without checking the run key.'),
  ],
  sample: {
    job_name: 'owner-billing', job_run_date: 'Sun, Nov 15, 2026 at 6:10 am', job_effect: 'Owner fee debits for November were not submitted and invoice emails were not sent.',
    job_error: 'Payment processor timeout after 30 seconds',
  },
};
