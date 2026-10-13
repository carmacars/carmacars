import 'server-only';
import { redirect } from 'next/navigation';
import { auth, type SessionUser } from '@/lib/auth';
import { rpc } from '@/lib/db/repo';
import { currentUser } from '@/server/portal/data';

// The admin portal's door (docs/blueprint/03-admin.md): an Admin only, and with two-step sign-in when
// program_settings.require_staff_two_step is on (the same rule the database applies to staff
// sessions, 0019's app.staff_two_step_ok). Every admin read and action goes through requireAdmin.
const SR = { role: 'service_role' as const };

export interface AdminGate { admin: boolean; staff: boolean; two_step_required: boolean; name: string | null }

export async function adminGate(u: SessionUser): Promise<AdminGate> {
  return (await rpc('admin_gate', { p_user: u.id }, SR)) as unknown as AdminGate;
}

/** For pages: redirects to sign in, to the refusal page, or to two-step sign-in. */
export async function requireAdmin(next = '/admin'): Promise<{ user: SessionUser; gate: AdminGate }> {
  const user = await currentUser();
  if (!user) redirect(`/sign-in?next=${encodeURIComponent(next)}`);
  const gate = await adminGate(user);
  if (!gate.admin) redirect('/admin/no-access');
  if (gate.two_step_required && (await (await auth()).assurance()) !== 'aal2') redirect(`/two-step?next=${encodeURIComponent(next)}`);
  return { user, gate };
}

/** For server actions: throws instead of redirecting. */
export async function assertAdmin(): Promise<SessionUser> {
  const user = await currentUser();
  if (!user) throw new Error('Sign in first.');
  const gate = await adminGate(user);
  if (!gate.admin) throw new Error('Only an Admin may do this.');
  if (gate.two_step_required && (await (await auth()).assurance()) !== 'aal2') throw new Error('Two-step sign-in is required.');
  return user;
}

export interface AdminOwnerRow { owner_id: string; legal_name: string; owner_type: string; email: string | null; phone: string | null; has_account: boolean; applications: string[]; last_at: string; vehicles: number; statuses: Record<string, number> | null; pending_terms: number; invoices_open: number; invoices_paid: number }

export async function adminOwners(u: SessionUser): Promise<AdminOwnerRow[]> {
  return ((await rpc('admin_owner_applications', { p_admin: u.id }, SR)) ?? []) as unknown as AdminOwnerRow[];
}
export async function adminOwner(u: SessionUser, id: string): Promise<AdminOwnerDetail | null> {
  if (!/^[0-9a-f-]{36}$/.test(id)) return null;
  return (await rpc('admin_owner_detail', { p_admin: u.id, p_owner: id }, SR)) as unknown as AdminOwnerDetail | null;
}
export async function adminInvoices(u: SessionUser, status?: string): Promise<AdminInvoiceRow[]> {
  return ((await rpc('admin_owner_invoices', { p_admin: u.id, p_status: status || undefined }, SR)) ?? []) as unknown as AdminInvoiceRow[];
}

export interface AdminInvoiceRow { id: string; invoice_number: string; owner_id: string; owner_name: string; vehicle_name: string; kind: string; period_month: string | null; status: string; total_cents: number; balance_cents: number; billing_date: string; paid_at: string | null; payment_method: string; pending: boolean }
export interface Terms { insurance_fee_cents: number; tracker_fee_cents: number; revenue_share_bps: number; install_fee_cents: number; vehicle_count?: number }
export interface AdminVehicle {
  vehicle_id: string; name: string; vin: string; plate: string | null; colour: string | null; odometer_km: number | null; status: string; billing_case: string; is_shareholder_owned: boolean;
  onboarding: { status: string; held_by: string | null; title_status: string | null; finance_party_name: string | null; finance_permission: string | null; current_insurer: string | null;
    proposed_management_mode: string | null; proposed_onboarding_method: string | null; situation: string | null; estimate_cents: number | null; estimate_plus_tax: boolean | null;
    government_forms: string[] | null; owners_lien_elected: boolean | null; disclosures: Record<string, unknown> | null; new_corporation: Record<string, unknown> | null;
    decline_reason: string | null; pending_terms: (Terms & { management_mode: string; onboarding_method: string; special_terms: string | null }) | null; terms_off_grid: boolean | null; terms_approved_at: string | null; upfront_paid_at: string | null };
  standard: Terms | null;
  options: Array<{ situation: string; method: string; label: string; recommended: boolean; estimate_cents: number }>;
  schedule: (Terms & { schedule_number: string; management_mode: string; onboarding_method: string; special_terms: string | null; signed_at: string | null }) | null;
  upfront_invoice: { id: string; invoice_number: string; status: string; total_cents: number; balance_cents: number } | null;
  tracker_install_pending: boolean; tracker_installed_on: string | null;
  tracker_invoice: { id: string; invoice_number: string; status: string; total_cents: number } | null;
}
export interface AdminOwnerDetail {
  owner: Record<string, unknown> & { id: string; legal_name: string; owner_type: string; email: string | null; phone: string | null; missing: string[]; user_email: string | null; private: { licence_number: string | null; licence_province: string | null; date_of_birth: string | null } | null };
  applications: Array<{ application_number: string; source: string; vehicle_count: number; created_at: string; note: string | null }>;
  signing: { needed: boolean; enrollment: string | null; title_holding: string | null; unsigned_schedules: number };
  trackers_available: boolean;
  vehicles: AdminVehicle[];
  invoices: Array<import('@/features/owner/types').OwnerInvoice>;
}
