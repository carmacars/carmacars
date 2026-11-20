// Which parts of the app a person has. One app for every role: the tabs follow what the account holds. No imports
// besides the shared types.
import type { Roles } from '../shared.ts';

export type Tab = 'explore' | 'trips' | 'field' | 'leads' | 'owner' | 'profile';
export const TAB_LABEL: Record<Tab, string> = { explore: 'Cars', trips: 'Trips', field: 'Today', leads: 'Leads', owner: 'My cars', profile: 'Profile' };

export function holdsSales(r: Roles): boolean {
  const fns = r.va_functions ?? [];
  return r.admin || r.va === 'sales' || r.va === 'cs' || fns.includes('sales') || fns.includes('cs');
}
/** The tabs, in order. Signed out: the cars and the profile (where sign-in is). Staff who are held (onboarding, the
 *  academy, the agreement, or locked) get no work tabs: the site finishes those steps. */
export function tabsFor(r: Roles | null): Tab[] {
  if (!r) return ['explore', 'profile'];
  const held = !!(r.onboarding_locked || r.academy_locked || r.agreement_locked || r.inactive_locked);
  const t: Tab[] = [];
  if (r.field && !held) t.push('field');
  if (holdsSales(r) && !held) t.push('leads');
  if (r.owner) t.push('owner');
  t.push('explore');
  if (r.renter || (!r.staff && !r.owner && !r.admin)) t.push('trips');
  t.push('profile');
  return t;
}
/** Where the app opens for this person. */
export const homeTab = (r: Roles | null): Tab => tabsFor(r)[0]!;
/** The site's portal for the long tail (the Admin portal, the investor portal, staff pages the app does not have). */
export function portalPath(r: Roles | null): string | null {
  if (!r) return null;
  if (r.admin) return '/admin';
  if (r.staff || r.va) return '/staff';
  if (r.investor) return '/investor';
  return null;
}
export const heldMessage = (r: Roles | null): string | null =>
  !r ? null : r.inactive_locked ? 'Your staff access is locked after a while without signing in. Ask an Admin to unlock it.'
    : r.onboarding_locked || r.academy_locked || r.agreement_locked ? 'Finish your onboarding on carmacars.ca (the academy, your agreement and the team groups). Your work opens here when it is done.' : null;
