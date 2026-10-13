// Each task opens the screen where its work is done (05-va.md section 1.3), or the task sheet itself.
export interface Task { id: string; task_type: string; title: string; detail?: string | null; queue: string; priority: string; status: string; due_at: string | null; created_at: string;
  booking_number?: string | null; booking_id?: string | null; vehicle_id?: string | null; vehicle_name?: string | null; plate?: string | null; assigned_to?: string | null; assignee_name?: string | null;
  procedure_no?: number | null; escalated?: boolean; bucket?: string; overdue?: boolean; renter_first_name?: string | null; related_table?: string | null; related_id?: string | null; waiting_reason?: string | null }

const BOOKING_REVIEW = ['booking_request', 'offer_change_requested', 'offer_change', 'offer_expired', 'reoffer_booking', 'chase_offer', 'offer_approved_paid'];
const VERIFY = ['verify_renter', 'chase_verification'];
const CHANGES = ['review_extension', 'booking_change_approval'];
const MONEY = ['refund_cancellation', 'take_deposit', 'release_deposit', 'settle_holdback', 'price_findings', 'charge_question'];
const FLEET = ['schedule_handover', 'schedule_detail', 'late_return', 'job_unacknowledged', 'review_photos', 'vehicle_swap', 'incident', 'breakdown'];

export function taskHref(t: Task): string {
  const n = t.booking_number ? encodeURIComponent(t.booking_number) : null;
  if (n && BOOKING_REVIEW.includes(t.task_type)) return `/va/bookings/${n}?task=${t.id}`;
  if (n && VERIFY.includes(t.task_type)) return `/va/verify/${n}?task=${t.id}`;
  if (n && CHANGES.includes(t.task_type)) return `/va/bookings/${n}?tab=changes&task=${t.id}`;
  if (n && MONEY.includes(t.task_type)) return `/va/bookings/${n}?tab=money&task=${t.id}`;
  if (FLEET.includes(t.task_type)) return n ? `/va/bookings/${n}?task=${t.id}` : `/va/fleet?task=${t.id}`;
  if (t.task_type === 'match_toll') return '/va/tolls';
  if (['debit_failed', 'arrears', 'collect_upfront', 'review_statements', 'reconcile', 'unmatched_payment', 'fleet_report'].includes(t.task_type)) return '/va/money';
  if (['review_listing', 'list_vehicle'].includes(t.task_type)) return '/va/listings';
  if (['owner_intake', 'check_owner_document', 'enquiry', 'lost_property'].includes(t.task_type)) return '/va/leads';
  if (['turo_expiry', 'safety_certificate_window', 'plate_renewal', 'book_registry'].includes(t.task_type)) return '/va/fleet#expiry';
  return `/va/tasks/${t.id}`;
}
