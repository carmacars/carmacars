import { hero, p, small, h, rule, vehicle, keyfacts, figure, facts, price, compare, table, rows, button, link, notice, list, steps, when, each } from '../components.mjs';
import { FROM } from '../brand.mjs';

export default {
  code: 'staff_owner_application_received',
  audience: 'staff_va_sales',
  category: 'transactional',
  from: FROM.owners,
  digest: false,
  trigger: 'An owner vehicle application is submitted (vehicle onboarding row created with status intake), from a new owner or an enrolled owner adding a vehicle. Sent to every active sales VA. Immediate.',
  timing: 'Immediate',
  subject: 'New owner application: {{owner_name}}, {{vehicle_name}}',
  preheader: '{{ownership_summary}}. Reply within 1 business day.',
  ref: 'Owner application',
  body: [
    hero('Owner application', 'A new vehicle application is in', '{{owner_name}} applied to enrol a vehicle. Reply within 1 business day.'),
    facts(
      ['Owner', '{{owner_name}} ({{owner_type}})'],
      ['Contact', '{{owner_contact}}'],
      ['Vehicle', '{{vehicle_name}}, {{vehicle_km}}'],
      ['VIN and plate', '{{vehicle_vin}}, {{vehicle_plate}}'],
      ['Held as', '{{ownership_summary}}'],
      ['Lender', '{{lender}}'],
      ['Current insurer', '{{current_insurer}}'],
      ['Management mode wanted', '{{management_mode}}'],
      ['Referred by', '{{referred_by}}'],
    ),
    button('Open the application', '@va_sales_application'),
    list(
      'Rebuilt, salvage or irreparable brand: decline that vehicle.',
      'Offer only the registration methods open to this car and give the owner the estimate for their situation.',
      'An admin sets the fees, the revenue share and the management mode before documents go out.',
    ),
  ],
  sample: {
    application_id: 'app-0318', owner_type: 'individual', owner_contact: 'daniel.rossi@example.com, 416-555-0177', vehicle_name: '2023 Toyota RAV4 XLE',
    vehicle_km: '41,200 km', vehicle_vin: '2T3P1RFV0PC000000', vehicle_plate: 'CXRV 310', ownership_summary: 'Financed', lender: 'Named on the application',
    current_insurer: 'Named on the application', management_mode: 'Managed by CarmaCars', referred_by: 'None',
  },
};
