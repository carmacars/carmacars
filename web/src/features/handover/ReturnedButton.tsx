import { Act, type Field } from '@/features/admin/Act';
import { RETURNED_REASON } from './returned';

// r32 one-tap return: "Returned" on every overdue and due-today booking on rent (Today, Bookings > Now, the booking page,
// the late return panel, the staff and field boards). A small form: the return time (now, or earlier: the late charges
// follow it), km and fuel if known. It records through the 0195 record-now path (app.handover_record_now): the trip is
// returned, Fleet gets the task for the photos and readings, every overdue notice stops. The database decides who may.
const fields = (): Field[] => [
  { name: 'at', label: 'Returned at', type: 'datetime', value: new Date().toISOString(), required: true, hint: 'Now, or earlier. Late return charges follow this time.' },
  { name: 'odometer_km', label: 'Odometer (km), if known', type: 'number', min: 0 },
  { name: 'fuel_pct', label: 'Fuel or charge (%), if known', type: 'number', min: 0, max: 100 }];

export function ReturnedButton({ booking, number, refresh = [], variant = 'primary', testId }: {
  booking: string; number: string; refresh?: string[]; variant?: 'primary' | 'ghost'; testId?: string;
}) {
  return <Act ops action="handover_record_now" payload={{ booking, kind: 'return', reason: RETURNED_REASON }} label="Returned" variant={variant}
    title={`Mark ${number} returned`} fields={fields()} refresh={refresh} submitLabel="Mark returned"
    done="Returned. Fleet has a task to add the photos and readings; the deposit can be settled." testId={testId ?? `returned-${number}`} />;
}
