import { when as whenText } from '@/features/agreement/model';
import { STATUS_LABEL, type OwnerHistory } from './model';

const day = (iso: string) => whenText(`${iso.slice(0, 10)}T12:00:00Z`, false);

/** 2740: "42,310 km (read Nov 3)" and "Next service: Oil and filter in 800 km or by Dec 12 (due soon)". Read only. */
export function OwnerKm({ h, testId = 'owner-km' }: { h: OwnerHistory | null | undefined; testId?: string }) {
  if (!h || (!h.km && !h.next)) return null;
  const n = h.next;
  const when = n ? [n.km_left != null ? (n.km_left <= 0 ? `${Math.abs(n.km_left).toLocaleString('en-CA')} km over` : `in ${n.km_left.toLocaleString('en-CA')} km`) : null, n.due_on ? `by ${day(n.due_on)}` : null].filter(Boolean).join(n.km_left != null && n.due_on ? ' or ' : '') : '';
  return (
    <div className="small" data-testid={testId}>
      {h.km ? <p data-testid={`${testId}-km`}>Kilometres: <b>{h.km.toLocaleString('en-CA')} km</b>{h.km_on ? <span className="muted"> (read {day(h.km_on)})</span> : null}</p> : null}
      {n && <p data-testid={`${testId}-next`}>Next service: <b>{n.label}</b>{when ? ` ${when}` : ''} <span className={`badge badge--outline`} data-status={n.status}>{n.status === 'ok' ? 'OK' : STATUS_LABEL[n.status]}</span></p>}
    </div>
  );
}
