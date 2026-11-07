import { Act, type Field } from '@/features/admin/Act';
import { pickupPassed } from './pickup-passed';

// Reopen offer (0569): one click on an expired offer, for an Admin and every staff role that sends offers (Customer
// service, Sales). The new offer is sent with the usual "offer ready" email and text, open 24 hours unless the hours say
// otherwise; when the pickup has passed, the dialog asks for the new pickup and return first.
export function ReopenOffer({ booking, pickupAt, returnAt, refresh, testId = 'reopen-offer' }: { booking: string; pickupAt: string; returnAt: string; refresh: string[]; testId?: string }) {
  const passed = pickupPassed(pickupAt);
  const fields: Field[] = [
    ...(passed ? [
      { name: 'pickup_at', label: 'New pickup (the old one has passed)', type: 'datetime', required: true },
      { name: 'return_at', label: 'New return', type: 'datetime', required: true, value: returnAt },
    ] as Field[] : []),
    { name: 'hours', label: 'Open for (hours)', type: 'number', placeholder: '24', hint: 'Empty: 24 hours.' },
    { name: 'note', label: 'Message to the renter', type: 'text' },
  ];
  return <Act action="reopen_expired" payload={{ booking }} label="Reopen offer" title="Reopen the offer" fields={fields} refresh={refresh}
    done="Reopened: the renter has the offer again." testId={testId} />;
}
