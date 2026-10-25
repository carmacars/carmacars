import 'server-only';
import { rpc } from '@/lib/db/repo';
import type { Placement } from '@/features/referral/model';
import { AffiliateNote } from './AffiliateNote';

/** The affiliate's name when an Admin has turned the link on, else null (the site then shows nothing). */
export async function affiliateName(): Promise<string | null> {
  try {
    const r = (await rpc('coverage_affiliate_public', {})) as unknown as { enabled?: boolean; name?: string } | null;
    return r?.enabled ? (r.name || 'RentalCoverage') : null;
  } catch { return null; }
}

export async function Affiliate({ placement }: { placement: Placement }) {
  const name = await affiliateName();
  return name ? <AffiliateNote name={name} placement={placement} /> : null;
}
