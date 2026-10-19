import { hero, small, facts, button, notice } from '../components.mjs';
import { FROM } from '../brand.mjs';

export default {
  code: 'staff_site_alert',
  audience: 'staff_admin',
  category: 'transactional',
  from: FROM.hello,
  digest: false,
  trigger: 'Site check (every 5 minutes, from the database): a page or service failed its check repeatedly (the home page, a car page, sign-in or the site\'s health check answers an error or Error 1102, or does not answer), emails are failing or stuck, a scheduled job failed, the nightly backup failed or is late, or Stripe webhooks are failing. Sent to the alert address in Program settings (uptime_alert_email), once per problem; a second problem of the same kind within the cooldown is shown on Admin > To do without another email. Immediate.',
  timing: 'Immediate',
  subject: 'Site alert: {{check_label}}',
  preheader: '{{alert_detail}}',
  ref: 'Site check',
  body: [
    hero('Site alert', '{{check_label}}', 'Our site check found a problem at {{alert_opened}}. You get another email when it recovers.'),
    facts(
      ['Check', '{{check_label}}'],
      ['What we found', '{{alert_detail}}'],
      ['Since', '{{alert_opened}}'],
      ['Failed checks in a row', '{{failures}}'],
    ),
    button('Open Admin', '@admin'),
    notice('info', 'What to do', '{{alert_advice}}'),
    small('Sent by the site check. Change the address in Program settings, "Site check".'),
  ],
  sample: {
    check_label: 'Home page', alert_detail: 'Answered 503 with Error 1102 (the web host stopped the page).', alert_opened: 'Mon, Oct 19 at 2:10 pm', failures: '3',
    alert_advice: 'Open carmacars.ca on your phone. If it does not load, tell your developer.',
  },
};
