import { Act } from '@/features/admin/Act';
import type { SignCar } from './path';

// r50 (3810): an Admin changes a car's Onboarding Method after its terms are set and before its Vehicle Schedule is
// signed. The schedule entry, the plan and the government forms follow; the agreements and Forms A and B are made
// again from the records when the owner opens them.
const METHODS: Array<[string, string]> = [['transfer', 'Transfer'], ['co_registrant', 'Co-Registrant'], ['lease_existing_corporation', 'Lease, existing corporation'], ['lease_new_owner_corporation', 'Lease, new Owner Corporation']];

export function OnboardingMethod({ cars, refresh }: { cars: SignCar[]; refresh: string[] }) {
  const open = cars.filter((c) => c.scheduled && !c.schedule_signed);
  if (!open.length) return null;
  return (
    <section className="pt-card stack" aria-labelledby="om-h" data-testid="onboarding-method">
      <h2 className="d4" id="om-h">Onboarding Method</h2>
      <p className="small muted">Wrong method on a Vehicle Schedule not signed yet? Change it here: the schedule, the plan and the government forms follow, and the owner signs the corrected documents.</p>
      <ul className="ad-list small">{open.map((c) => (
        <li key={c.vehicle_id}><span><b>{c.name}</b>{c.schedule_number ? ` · ${c.schedule_number}` : ''}</span>
          <Act action="set_onboarding_method" payload={{ vehicle_id: c.vehicle_id }} label="Change the method" title={`Onboarding Method: ${c.name}`} submitLabel="Change it" refresh={refresh}
            done="Changed. The owner signs the corrected documents." testId={`onboarding-method-${c.vehicle_id}`}
            fields={[{ name: 'method', label: 'Onboarding Method', type: 'select', required: true, options: METHODS },
              { name: 'reason', label: 'Why', type: 'text', required: true, hint: 'Kept in the history with the change.' }]} /></li>))}</ul>
    </section>
  );
}
