import { hero, small, button, facts } from '../components.mjs';
import { FROM } from '../brand.mjs';

export default {
  code: 'staff_owner_signed',
  audience: 'staff_va_fleet',
  also: ['staff_admin'],
  category: 'transactional',
  from: FROM.owners,
  digest: false,
  trigger: 'Sign first (r50, migration 3800): an owner e-signed their master agreement or a Schedule A confirmation (CarmaCars countersigned at once). Tells Fleet and the Admins what comes next: approve the cars, or that an approval waiting for this signature went through by itself. Immediate.',
  timing: 'Immediate',
  subject: '{{owner_name}} signed: {{what}}',
  preheader: '{{next_step}}',
  ref: 'Owner {{owner_name}}',
  body: [
    hero('Owner signed', '{{owner_name}} signed', '{{what}}, countersigned by CarmaCars.'),
    facts(
      ['Signed', '{{what}}'],
      ['Next', '{{next_step}}'],
    ),
    button('Open the owner', '@va_fleet_owner'),
    small('The owner page lists what each car still needs.'),
  ],
  sample: { owner_name: 'Northshore Holdings Ltd.', owner_id: 'o-1b2c3d', what: 'Fleet Supplier Lease Agreement EA-1042', next_step: 'Approve the 2 cars on the application.' },
};
