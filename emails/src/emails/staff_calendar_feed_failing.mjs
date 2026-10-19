import { hero, small, facts, button } from '../components.mjs';
import { FROM } from '../brand.mjs';

export default {
  code: 'staff_calendar_feed_failing',
  audience: 'staff_va_fleet',
  also: ['staff_admin'],
  category: 'transactional',
  from: FROM.hello,
  digest: false,
  trigger: 'Calendar sync: an imported calendar link (Turo, Getaround or another platform) failed this many times in a row (calendar_feed_alert_failures in Program settings, 3 by default). Sent once per run of failures; it also raises a Fleet task. The trips already imported stay on the calendar until the link works again. Immediate.',
  timing: 'Immediate',
  subject: 'Calendar link not working: {{vehicle_name}} on {{platform}}',
  preheader: '{{failures}} failed tries in a row. {{feed_error}}',
  ref: 'Calendar sync',
  body: [
    hero('Calendar sync', 'A calendar link stopped working', 'We could not read the {{platform}} calendar of the {{vehicle_name}} {{failures}} times in a row. New trips on {{platform}} are not blocking the car on CarmaCars until it works again.'),
    facts(
      ['Car', '{{vehicle_name}}'],
      ['Platform', '{{platform}}'],
      ['Last error', '{{feed_error}}'],
      ['Last good sync', '{{last_success}}'],
    ),
    button('Open calendar sync', '{{calendar_url}}'),
    small('Copy the calendar link from {{platform}} again and paste it over the old one. A link changes when it is reset on the platform.'),
  ],
  sample: {
    vehicle_name: '2024 Mercedes-Benz C 300', platform: 'Turo', failures: '3', feed_error: 'The platform answered 404 (not found).',
    last_success: 'Mon, Oct 19 at 2:10 pm', calendar_url: 'https://carmacars.ca/admin/calendar-sync',
  },
};
