import { hero, p, facts, notice, button, small } from '../components.mjs';
import { FROM } from '../brand.mjs';

export default {
  code: 'staff_location_policy',
  audience: 'staff_field',
  category: 'transactional',
  from: FROM.hello,
  digest: false,
  trigger: 'A staff member accepts the electronic monitoring policy before their location is shown on the live map (migration 3350; Ontario Employment Standards Act, Part XI.1). Once per policy version: their copy of the policy.',
  timing: 'Immediate, once per policy version',
  subject: 'Your copy: the CarmaCars electronic monitoring policy',
  preheader: 'Your location is shown only while you are on shift or on a job.',
  ref: 'Electronic monitoring policy',
  body: [
    hero('Your copy', 'Thanks, {{first_name}}', 'You accepted the CarmaCars electronic monitoring policy. Here is your copy to keep.'),
    notice('info', 'The policy', '{{policy_text}}'),
    facts(['Accepted', '{{accepted_on}}'], ['Version', '{{policy_version}}']),
    p('Off duty, nothing is taken. On shift you can turn sharing off in your profile; during an active job it stays on, and it stops on its own when the job is done.'),
    button('Open my location settings', '{{settings_url}}'),
    small('Ontario employers with 25 or more employees must give each employee a copy of their electronic monitoring policy. Keep this email for your records.'),
  ],
  sample: { policy_text: 'Electronic monitoring policy: while you are on shift or on a job, CarmaCars records where you are from the CarmaCars app or the staff portal (with your permission), to dispatch jobs, keep you safe and prove a pickup or return. Never off duty. Only your latest position is kept, plus the points of each job for 30 days. Admins and Fleet see it on the live map.', policy_version: 'esa-em-2026-11', accepted_on: 'Fri Nov 20, 7:15 pm', settings_url: 'https://carmacars.ca/staff/profile#location' },
};
