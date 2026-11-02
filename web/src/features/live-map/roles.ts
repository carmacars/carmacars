// What a person is to us (migration 0470): the roles the database works out from every record (owner, partner, investor,
// staff, renter), in the order to show them. No imports, so the unit tests run it as it is.

export type Role = 'owner' | 'partner' | 'investor' | 'staff' | 'renter';
const WORD: Record<Role, string> = { owner: 'Owner', partner: 'Partner', investor: 'Investor', staff: 'Staff', renter: 'Renter' };
const ORDER: Role[] = ['owner', 'partner', 'investor', 'staff', 'renter'];

/** The roles as the database sent them, known ones only, in the display order. */
export function cleanRoles(roles: readonly string[] | null | undefined): Role[] {
  const have = new Set(roles ?? []);
  return ORDER.filter((r) => have.has(r));
}
/** "Owner", "Owner · renter", "Investor · renter"; null when nothing is known (use the page's own words then). */
export function roleLabel(roles: readonly string[] | null | undefined): string | null {
  const r = cleanRoles(roles);
  if (!r.length) return null;
  return r.map((x, i) => (i === 0 ? WORD[x] : WORD[x].toLowerCase())).join(' · ');
}
/** True when the person is something other than a renter and not also one: an owner browsing is not a renter lead. */
export function notRenterOnly(roles: readonly string[] | null | undefined): boolean {
  const r = cleanRoles(roles);
  return r.length > 0 && !r.includes('renter');
}
/** Where Admin keeps the person: the owner page for an owner (when no renter record counts), else the renter page. */
export function personPages(p: { roles?: readonly string[] | null; owner_id?: string | null; renter_id?: string | null }): Array<{ href: string; label: string }> {
  const r = cleanRoles(p.roles), out: Array<{ href: string; label: string }> = [];
  if (p.owner_id && r.includes('owner')) out.push({ href: `/admin/owners/${encodeURIComponent(p.owner_id)}`, label: 'Owner page' });
  if (p.renter_id && (r.includes('renter') || !r.length)) out.push({ href: `/admin/renters/${encodeURIComponent(p.renter_id)}`, label: 'Renter page' });
  return out;
}
