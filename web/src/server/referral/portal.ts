import 'server-only';
import { rpc } from '@/lib/db/repo';
import { env } from '@/lib/env';
import { linkSecret } from '@/server/links';
import { portalKey, portalKeyOk, referralLink } from '@/features/referral/model';

// A referral partner's own page (migration 0164): the address holds the partner's id and a key made from LINK_SIGNING_KEY and the
// link's version (public.server_referral_partner_portal returns what the page shows; "New link" in Admin raises the version).
const SR = { role: 'service_role' as const };
const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/;
export interface PortalData {
  partner: { business_name: string; kind: string; status: string; referral_code: string; rate_text: string; portal_version: number };
  totals: { referrals: number; accruing_cents: number; pending_cents: number; paid_cents: number };
  rows: Array<{ first_name: string; month: string; status: string; amount_cents: number; paid_on: string | null }>;
}

export async function loadPortal(id: string, key: string): Promise<PortalData | null> {
  if (!UUID.test(id) || !/^[0-9a-f]{40}$/.test(key)) return null;
  const d = (await rpc('server_referral_partner_portal', { p_partner: id }, SR).catch(() => null)) as unknown as PortalData | null;
  if (!d || !(await portalKeyOk(linkSecret(), id, d.partner.portal_version, key))) return null;
  return d;
}

/** The address an Admin hands the partner. */
export async function portalAddress(id: string, version: number): Promise<string> {
  return `${env().NEXT_PUBLIC_APP_URL.replace(/\/$/, '')}/partners/portal/${id}/${await portalKey(linkSecret(), id, version)}`;
}
export const partnerLink = (code: string) => referralLink(env().NEXT_PUBLIC_APP_URL, code);
