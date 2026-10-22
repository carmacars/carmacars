import { Act } from '@/features/admin/Act';

// "Shareholder's own car" on each car of an owner (migration 0079): a shareholder's car is split 90/10 and pays no
// Insurance Fee, Tracker Fee or upfront charges. An Admin turns it on or off; bookings already made keep their split.
export function ShareholderToggle({ ownerId, vehicleId, on, companyShareBps = 1000 }: { ownerId: string; vehicleId: string; on: boolean; companyShareBps?: number }) {
  const share = `${100 - companyShareBps / 100}/${companyShareBps / 100}`;
  return (
    <div className="small row" data-testid="shareholder-car">
      <span><b>Shareholder&apos;s own car:</b> {on ? `yes (${share} split, no Insurance Fee, Tracker Fee or upfront charges)` : 'no'}</span>
      <Act action="shareholder_car" payload={{ vehicle: vehicleId, on: !on }} label={on ? 'Not a shareholder’s car' : 'Shareholder’s own car'} variant="quiet"
        testId={`shareholder-${vehicleId}`} refresh={[`/admin/owners/${ownerId}`]}
        title={on ? 'No longer a shareholder’s car' : 'Make this a shareholder’s own car'}
        fields={[{ name: 'reason', label: 'Why (kept in the audit log)', type: 'text', required: true }]}
        confirm={on
          ? 'New bookings get the owner’s management fee (Revenue Share) and the car pays its Insurance Fee and Tracker Fee again.'
          : `New bookings are split ${share} (the owner keeps ${100 - companyShareBps / 100}%), and the car pays no Insurance Fee, Tracker Fee or upfront charges. Bookings already made keep their split.`}
        done={on ? 'No longer a shareholder’s car.' : 'Now a shareholder’s own car.'} />
    </div>
  );
}
