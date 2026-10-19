import { hero, small, facts, button } from '../components.mjs';
import { FROM } from '../brand.mjs';

export default {
  code: 'staff_site_recovered',
  audience: 'staff_admin',
  category: 'transactional',
  from: FROM.hello,
  digest: false,
  trigger: 'Site check: a problem that sent a site alert passed its check again. One email per alert that was emailed, to the same address. Immediate.',
  timing: 'Immediate',
  subject: 'Recovered: {{check_label}}',
  preheader: 'Working again since {{alert_resolved}}, after {{alert_duration}}.',
  ref: 'Site check',
  body: [
    hero('Site check', '{{check_label}} works again', 'The problem we emailed you about at {{alert_opened}} has passed.'),
    facts(
      ['Check', '{{check_label}}'],
      ['Problem', '{{alert_detail}}'],
      ['Working again', '{{alert_resolved}}'],
      ['How long', '{{alert_duration}}'],
    ),
    button('Open Admin', '@admin'),
    small('Sent by the site check. Nothing else to do.'),
  ],
  sample: {
    check_label: 'Home page', alert_detail: 'Answered 503 with Error 1102 (the web host stopped the page).', alert_opened: 'Mon, Oct 19 at 2:10 pm',
    alert_resolved: 'Mon, Oct 19 at 2:35 pm', alert_duration: '25 minutes',
  },
};
