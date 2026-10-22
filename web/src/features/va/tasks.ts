// Each task opens the screen where its work is done (05-va.md section 1.3), or the task sheet itself.
export interface Task { id: string; task_type: string; title: string; detail?: string | null; queue: string; priority: string; status: string; due_at: string | null; created_at: string;
  booking_number?: string | null; booking_id?: string | null; vehicle_id?: string | null; vehicle_name?: string | null; plate?: string | null; assigned_to?: string | null; assignee_name?: string | null;
  procedure_no?: number | null; escalated?: boolean; bucket?: string; overdue?: boolean; renter_first_name?: string | null; related_table?: string | null; related_id?: string | null; waiting_reason?: string | null }

const BOOKING_REVIEW = ['booking_request', 'offer_change_requested', 'offer_change', 'offer_expired', 'reoffer_booking', 'chase_offer', 'offer_approved_paid'];
const VERIFY = ['verify_renter', 'chase_verification', 'protection_plan_request', 'coverage_review'];
const CHANGES = ['review_extension', 'booking_change_approval'];
const MONEY = ['refund_cancellation', 'take_deposit', 'release_deposit', 'settle_holdback', 'price_findings', 'charge_question'];
const FLEET = ['schedule_handover', 'schedule_detail', 'late_return', 'job_unacknowledged', 'vehicle_swap', 'incident', 'breakdown'];

export function taskHref(t: Task): string {
  const n = t.booking_number ? encodeURIComponent(t.booking_number) : null;
  // a visitor who asked for a person: straight to that chat (0078)
  if (['live_chat_waiting', 'chat_request', 'chat_contact', 'visitor_follow_up'].includes(t.task_type)) return t.related_table === 'chat_conversations' && t.related_id ? `/va/chat?id=${t.related_id}` : '/va/chat';
  if (n && BOOKING_REVIEW.includes(t.task_type)) return `/va/bookings/${n}?task=${t.id}`;
  if (n && VERIFY.includes(t.task_type)) return `/va/verify/${n}?task=${t.id}`;
  if (n && CHANGES.includes(t.task_type)) return `/va/bookings/${n}?tab=changes&task=${t.id}`;
  if (n && MONEY.includes(t.task_type)) return `/va/bookings/${n}?tab=money&task=${t.id}`;
  if (n && t.task_type === 'review_photos') return `/va/review/${n}?task=${t.id}`;
  if (t.task_type === 'renter_message' && n) return `/va/bookings/${n}?tab=messages&task=${t.id}`;
  if (['opening_checks', 'closing_checks'].includes(t.task_type)) return `/va/checks?kind=${t.task_type === 'closing_checks' ? 'closing' : 'opening'}`;
  if (FLEET.includes(t.task_type)) return n ? `/va/bookings/${n}?task=${t.id}` : `/va/fleet?task=${t.id}`;
  if (t.task_type === 'match_toll') return '/va/tolls';
  if (['reconcile', 'unmatched_payment'].includes(t.task_type)) return '/va/reconciliation';
  if (['debit_failed', 'arrears', 'collect_upfront', 'review_statements', 'fleet_report'].includes(t.task_type)) return '/va/money';
  if (['review_listing', 'list_vehicle'].includes(t.task_type)) return '/va/listings';
  if (t.task_type === 'listing_similarity') return '/va/similar-cars';
  if (t.task_type === 'owner_form_review') return '/va/owner-forms';
  if (t.task_type === 'account_link_review') return '/va/renters';
  if (['owner_intake', 'check_owner_document', 'enquiry', 'lost_property'].includes(t.task_type)) return '/va/leads';
  if (['turo_expiry', 'safety_certificate_window', 'plate_renewal', 'book_registry'].includes(t.task_type)) return '/va/fleet#expiry';
  // maintenance (0089): the car's Maintenance with the record pop-up open
  if (['maintenance_due', 'maintenance_backfill'].includes(t.task_type) && t.vehicle_id) return `/va/vehicles/${t.vehicle_id}?record=1#maintenance`;
  if (t.task_type === 'maintenance_bill' && t.vehicle_id) return `/va/vehicles/${t.vehicle_id}#maintenance`;
  return `/va/tasks/${t.id}`;
}

// The same task on the Admin's side (migration 0078): Admin > Tasks and Admin > Today open the screen where the work is
// done, never the task sheet.
export function adminTaskHref(t: Pick<Task, 'task_type' | 'booking_number' | 'vehicle_id' | 'related_table' | 'related_id'> & { owner_id?: string | null; invoice_number?: string | null }): string {
  const n = t.booking_number ? encodeURIComponent(t.booking_number) : null;
  const rel = (table: string) => (t.related_table === table && t.related_id ? t.related_id : null);
  if (['live_chat_waiting', 'chat_request', 'chat_contact', 'visitor_follow_up'].includes(t.task_type)) return rel('chat_conversations') ? `/admin/chat?id=${rel('chat_conversations')}` : '/admin/chat';
  if (n && BOOKING_REVIEW.includes(t.task_type)) return `/admin/bookings/${n}?tab=review`;
  if (n && (VERIFY.includes(t.task_type) || t.task_type === 'live_rental_agreement')) return `/admin/bookings/${n}?tab=documents`;
  if (n && CHANGES.includes(t.task_type)) return `/admin/bookings/${n}?tab=changes`;
  if (n && MONEY.includes(t.task_type)) return `/admin/bookings/${n}?tab=money`;
  if (['debit_failed', 'arrears', 'collect_upfront', 'owner_overpayment'].includes(t.task_type)) return t.invoice_number ? `/admin/invoices/${encodeURIComponent(t.invoice_number)}` : t.owner_id ? `/admin/owners/${t.owner_id}?tab=invoices` : '/admin/invoices';
  if (['owner_intake', 'onboarding_disclosure'].includes(t.task_type)) return t.owner_id ? `/admin/owners/${t.owner_id}` : '/admin/applications';
  if (['first_last_decide', 'check_owner_document'].includes(t.task_type)) return t.owner_id ? `/admin/owners/${t.owner_id}${t.task_type === 'first_last_decide' ? '?tab=terms' : ''}` : '/admin/owner-forms';
  if (['live_rental_insurance', 'insurer_confirmation', 'list_vehicle', 'review_listing', 'book_registry', 'turo_expiry', 'safety_certificate_window', 'plate_renewal'].includes(t.task_type) && t.vehicle_id)
    return `/admin/vehicles/${t.vehicle_id}${['list_vehicle', 'review_listing', 'live_rental_insurance', 'insurer_confirmation'].includes(t.task_type) ? '?tab=listing' : ''}`;
  if (t.task_type === 'listing_similarity') return '/admin/similar-cars';
  if (t.task_type === 'match_toll') return '/admin/tolls';
  if (['reconcile', 'unmatched_payment'].includes(t.task_type)) return '/admin/reconciliation';
  if (['review_statements', 'fleet_report'].includes(t.task_type)) return '/admin/statements';
  if (t.task_type === 'fleet_minimum') return '/admin/overview';
  if (n) return `/admin/bookings/${n}`;
  if (t.vehicle_id) return `/admin/vehicles/${t.vehicle_id}`;
  if (t.owner_id) return `/admin/owners/${t.owner_id}`;
  return '/admin/tasks';
}
