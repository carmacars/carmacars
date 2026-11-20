import 'server-only';
import { rpc } from '@/lib/db/repo';

// r48 FE (3191): "Yes, put me in Sales". The referral email's link is the applicant's own token: the page reads who they
// are and the Sales role; one press makes the Sales application from the one they sent and sends the AI interview link.
const SR = { role: 'service_role' as const, skipViewAs: true };
const TOKEN = /^[A-Za-z0-9_-]{16,80}$/;
export interface SalesOffer { first_name: string; from_role: string | null; sales_role: string; sales_summary: string | null; eligible: boolean; done: boolean; interview_state: string | null; interview_url: string | null }
export interface SalesYes { ok: boolean; application_id: string; interview_state: string | null; interview_url: string | null; expires_at: string | null }

export async function salesOffer(token: string): Promise<SalesOffer | null> {
  if (!TOKEN.test(token)) return null;
  return ((await rpc('server_hiring_sales_offer', { p_token: token }, SR).catch(() => null)) as unknown as SalesOffer | null) ?? null;
}
export async function salesYes(token: string): Promise<SalesYes> {
  if (!TOKEN.test(token)) throw new Error('This link is not valid any more');
  return (await rpc('server_hiring_sales_yes', { p_token: token }, SR)) as unknown as SalesYes;
}
