import { hero, small, facts, button, table, h } from '../components.mjs';
import { FROM } from '../brand.mjs';

export default {
  code: 'staff_seo_digest',
  audience: 'staff_admin',
  category: 'transactional',
  from: FROM.hello,
  digest: false,
  trigger: 'Scheduled (the hourly usage job, migration 1860): every Monday morning, Toronto time, to the alert address in Program settings (uptime_alert_email) while Program settings "SEO digest" is on. It goes through the email outbox like every email, at the lowest priority, so the day\'s email limit and the providers\' budgets apply and it waits for the next day when the limit is used. Search Console clicks against the monthly goal, the best queries and pages, and the pages Google shows but nobody clicks.',
  timing: 'Monday morning',
  subject: 'Search this week: {{clicks_28d}} clicks in 28 days, {{goal_share}} of the monthly goal',
  preheader: '{{indexed_line}}',
  ref: 'SEO',
  body: [
    hero('Search', 'Search this week', '{{goal_line}}'),
    facts(
      ['Clicks, last 28 days', '{{clicks_28d}}'],
      ['Impressions, last 28 days', '{{impressions_28d}}'],
      ['Monthly goal', '{{goal}} ({{goal_share}})'],
      ['Index coverage (sample)', '{{indexed_line}}'],
      ['Search engines told', '{{indexnow_line}}'],
    ),
    h('Best queries'),
    table({
      each: 'top_queries',
      cols: [
        { head: 'Query', value: '{{key}}' },
        { head: 'Clicks', value: '{{clicks}}', align: 'right', strong: true },
        { head: 'Position', value: '{{position}}', align: 'right' },
      ],
    }),
    h('Shown a lot, clicked little'),
    table({
      each: 'low_ctr',
      cols: [
        { head: 'Page', value: '{{key}}' },
        { head: 'Impressions', value: '{{impressions}}', align: 'right' },
        { head: 'Click rate', value: '{{ctr}}', align: 'right', strong: true },
      ],
    }),
    button('Open the SEO page', '@admin_seo'),
    small('Figures are Search Console\'s, which settle after about three days. The goal and the click-rate line are Program settings.'),
  ],
  sample: {
    clicks_28d: '41,200', impressions_28d: '2,300,000', goal: '5,000,000', goal_share: '1%',
    goal_line: 'At this pace the month brings about 44,000 clicks, 1% of the 5,000,000 goal.',
    indexed_line: '62% of the sampled pages Google knows are indexed; 1,200 crawled, not indexed',
    indexnow_line: '800 addresses sent in 7 days, 40 waiting',
    top_queries: [{ key: 'rent a mercedes toronto', clicks: '812', position: '4.1' }, { key: 'car rental pearson airport', clicks: '640', position: '7.9' }],
    low_ctr: [{ key: '/car-rental/mississauga', impressions: '18,400', ctr: '0.4%' }, { key: '/buy/toyota/camry', impressions: '9,900', ctr: '0.6%' }],
  },
};
