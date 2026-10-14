import { hero, p, small, h, rule, vehicle, keyfacts, figure, facts, price, compare, table, rows, button, link, notice, list, steps, when, each } from '../components.mjs';
import { FROM } from '../brand.mjs';

export default {
  code: 'staff_monthly_statements_pdfs',
  audience: 'staff_admin',
  category: 'transactional',
  from: FROM.billing,
  digest: false,
  trigger: 'Statement emails job, on the company statement email day in Program settings (the 10th by default): the company statement for last month exists (draft or final). One email to each Admin with three PDFs attached: the company total with every section, the statement by owner and the statement by vehicle. An Admin can also send it to themselves from Company statements.',
  timing: 'The company statement email day (the 10th by default)',
  subject: '{{statement_month}} company statements: net {{company_net}}',
  preheader: '{{statement_status}}. {{ties_text}}. Three PDFs attached.',
  ref: 'Month end',
  body: [
    hero('Company statements', 'Your {{statement_month}} statements', 'The company total, the statement by owner and the statement by vehicle are attached as PDFs, {{first_name}}.'),
    figure('Contribution before costs not in the platform', '{{company_net}}', '{{statement_status}}. {{ties_text}}.'),
    facts(
      ['Rental revenue', '{{rental_revenue}}'],
      ['Revenue Share kept', '{{revenue_share}}'],
      ['Renter fees kept', '{{company_fees}}'],
      ['Owner fees billed', '{{owner_fees}}'],
      ['Owners', '{{owner_count}}'],
      ['Vehicles', '{{vehicle_count}}'],
    ),
    button('Open company statements', '@admin_reports'),
    p('[Download the company statement (PDF)]({{statement_url}}). The link works for {{link_expiry}}; the statements are always in Admin.'),
    small('A draft can still change until it is finalized; a final month never changes, and later corrections show under Adjustments to earlier months.'),
  ],
  sample: {
    statement_month: 'November 2026', company_net: '$14,802.10', statement_status: 'Final', ties_text: 'All checks tie out',
    rental_revenue: '$34,910.00', revenue_share: '$11,204.50', company_fees: '$2,140.00', owner_fees: '$6,300.00', owner_count: '14', vehicle_count: '22',
    statement_url: 'https://carmacars.ca/d/sample-company-statement', link_expiry: '7 days',
  },
};
