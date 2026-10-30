// Shared builder for the per-role digests. Each role has its own small file that calls this with its
// sections, so the catalogue has one entry per role and slot while the structure stays in one place.
import { hero, small, h, keyfacts, rows, button, notice, when, each } from '../components.mjs';
import { FROM } from '../brand.mjs';

const SLOT = {
  morning: {
    eyebrow: 'Morning digest', title: 'Good morning, {{first_name}}', time: '07:30',
    rule: 'Sent every day at 07:30 Toronto time to each active staff member with this role, even when nothing is waiting, so a missing digest is itself a warning sign.',
  },
  eod: {
    eyebrow: 'End-of-day digest', title: 'End of day, {{first_name}}', time: '18:15',
    rule: 'Sent every day at 18:15 Toronto time (after the 18:00 reconcile job) to each active staff member with this role. Skipped when there is nothing to report.',
  },
};

export function digest({ code, audience, slot, role, queue, contains, stats, sections, summary }) {
  const s = SLOT[slot];
  return {
    code,
    audience,
    category: 'transactional',
    from: FROM.hello,
    digest: false,
    trigger: `Scheduled digest for ${role}. ${s.rule} It carries every notice queued for this role with digest true since the last digest, plus these lists computed at send time: ${contains}. Each line links to the item. One email replaces the separate notices.`,
    timing: `Daily ${s.time}`,
    subject: slot === 'morning' ? `${role} morning digest: {{digest_count}} items for {{digest_date}}` : `${role} end of day: {{digest_count}} items open, {{digest_date}}`,
    preheader: '{{digest_summary}}',
    ref: '{{digest_date}}',
    body: [
      hero(s.eyebrow, s.title, '{{digest_summary}}'),
      keyfacts({ label: stats[0].label, value: '{{stat_1}}', sub: stats[0].sub }, { label: stats[1].label, value: '{{stat_2}}', sub: stats[1].sub }),
      when('has_items', [
        each('sections', [h('{{title}} ({{count}})'), rows('items', '{{line}}', '{{meta}}', '{{url}}')]),
      ], [
        notice('info', 'Nothing waiting', 'Your queue is clear.'),
      ]),
      button('Open my queue', '@' + queue),
      small(slot === 'morning'
        ? 'Urgent items are still sent on their own, at once: late returns, incidents, disputes, new booking requests and anything due within hours.'
        : 'Anything still open tonight is in tomorrow morning\'s digest. Urgent items are sent on their own, at once.'),
    ],
    sample: {
      digest_date: slot === 'morning' ? 'Tue, Oct 20' : 'Tue, Oct 20',
      digest_count: String(sections.reduce((n, x) => n + x.items.length, 0)),
      digest_summary: summary,
      stat_1: stats[0].value,
      stat_2: stats[1].value,
      has_items: true,
      sections: sections.map((x) => ({ ...x, count: String(x.items.length) })),
    },
  };
}

// Field staff: the list of jobs for today (morning) or tomorrow (evening).
export function fieldJobs({ code, slot }) {
  const tomorrow = slot === 'eod';
  return {
    code,
    audience: 'staff_field',
    category: 'transactional',
    from: FROM.bookings,
    digest: false,
    trigger: tomorrow
      ? 'Scheduled digest for field staff: every day at 18:00 Toronto time, one email to each field staff member who has at least one job assigned for the next day (pickup handovers, returns, tracker installs, details, photo shoots). Skipped for a person with no jobs. Jobs assigned or changed after it is sent go out at once with staff_field_job_assigned or staff_field_job_changed.'
      : 'Scheduled digest for field staff: every day at 07:00 Toronto time, one email to each field staff member who has at least one job that day. Skipped for a person with no jobs. Lists the same jobs as the evening digest, with any changes made overnight.',
    timing: tomorrow ? 'Daily 18:00' : 'Daily 07:00',
    subject: tomorrow ? 'Tomorrow: {{job_count}} jobs, first at {{first_job_time}}' : 'Today: {{job_count}} jobs, first at {{first_job_time}}',
    preheader: '{{jobs_summary}}',
    ref: '{{digest_date}}',
    body: [
      hero(tomorrow ? 'Jobs for tomorrow' : 'Jobs for today', tomorrow ? 'Your jobs for {{digest_date}}' : 'Today, {{digest_date}}', 'Hi {{first_name}}. {{jobs_summary}}'),
      keyfacts({ label: 'Jobs', value: '{{job_count}}' }, { label: 'First job', value: '{{first_job_time}}' }),
      rows('jobs', '{{time}}  {{type}}: {{vehicle}}', '{{place}}. {{note}}', '{{url}}'),
      button(tomorrow ? 'Open my jobs and acknowledge' : 'Open my jobs', '@field'),
      small('Have each car ready 30 minutes before a pickup. Photos are reviewed within 1 hour, so upload the full set, in order, before you leave. If you cannot do a job, tell Fleet right away.'),
    ],
    sample: {
      digest_date: tomorrow ? 'Fri, Oct 23' : 'Fri, Oct 23', job_count: '3', first_job_time: '10:00 am',
      jobs_summary: '2 pickups and 1 return. Please acknowledge each one.',
      jobs: [
        { time: '10:00 am', type: 'Pickup', vehicle: '2024 Honda Civic Sport (CMCR 482)', place: 'Union Station, 65 Front Street West', note: 'Renter Maya. Deposit $500.00 before handover.', url: 'https://carmacars.ca/staff/field/jobs/J-5521' },
        { time: '1:30 pm', type: 'Return', vehicle: '2022 Hyundai Elantra Preferred (CHYE 554)', place: 'CarmaCars lot', note: 'Renter Omar. Check fuel and both keys.', url: 'https://carmacars.ca/staff/field/jobs/J-5524' },
        { time: '4:00 pm', type: 'Pickup', vehicle: '2023 Toyota RAV4 XLE (CXRV 310)', place: 'Delivery to 14 Sample Road, Scarborough', note: 'Renter Chen. Winter tires fitted.', url: 'https://carmacars.ca/staff/field/jobs/J-5527' },
      ],
    },
  };
}
