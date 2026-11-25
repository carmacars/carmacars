import { hero, small, facts, button } from '../components.mjs';
import { FROM } from '../brand.mjs';

export default {
  code: 'staff_owner_stage_stalled',
  audience: 'staff_admin',
  category: 'transactional',
  from: FROM.owners,
  digest: false,
  trigger: 'Owner pipeline (r50, migration 4511): an owner\'s car has waited in one onboarding stage for Program settings\' owner_stage_stall_days (3 by default). Once per car and stage, from the 15-minute sweep; the owner\'s salesperson (else an Admin) also gets a To do.',
  timing: 'After the stall days in one stage',
  subject: 'Stalled {{days}} days: {{owner_name}}, {{vehicle_name}}',
  preheader: '{{stage_label}}, waiting on {{waits_on}}. {{next_step}}',
  ref: 'Owner {{owner_name}}',
  body: [
    hero('Owner pipeline', 'A car is stuck in {{stage_label}}', '{{owner_name}}\'s {{vehicle_name}} has been in this stage for {{days}} days.'),
    facts(
      ['Waiting on', '{{waits_on}}'],
      ['Next', '{{next_step}}'],
      ['Salesperson', '{{salesperson}}'],
    ),
    button('Open the owner', '@va_fleet_owner'),
    small('The Owner pipeline board has the call script of each stage and the one-tap nudge.'),
  ],
  sample: { owner_name: 'Pat Example', owner_id: 'o-1b2c3d', vehicle_name: '2021 Hyundai Sonata', stage_label: 'Ownership transfer', days: '4', waits_on: 'the owner',
    next_step: 'Help the owner book the ServiceOntario visit', salesperson: 'Darren' },
};
