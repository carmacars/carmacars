import 'server-only';
import { rpc } from '@/lib/db/repo';
import { when } from '@/features/agreement/model';

// What every signed PDF prints for the company (the legal review, migration 0053): the signing officer's countersignature
// with its stored wording ("Signed electronically for <legal name>, by <officer>, Director,
// under a standing authorization dated <date>."), and the staff member who sent the offer, added the rental, or proposed
// or approved the amendment, as "Proposed by" or "Added by". Staff are never the signer.
const SR = { role: 'service_role' as const };
interface Row { signer_role: string; signer_name: string; signer_title: string | null; method: string; signed_at: string | null; signed_on: string | null; consent_text: string | null; staff_attribution: string | null }

export interface CompanySignature { officer: string | null; title: string | null; lines: string[][]; witness?: { name: string; when: string } | null;
  /** the countersignature's stored wording, printed in the signature block too (never the bare business name) */
  text?: string | null }

export async function companySignature(requestId: string | null | undefined): Promise<CompanySignature> {
  if (!requestId) return { officer: null, title: null, lines: [], text: null };
  const rows = ((await rpc('server_signature_lines', { p_request: requestId }, SR).catch(() => [])) ?? []) as unknown as Row[];
  const lines: string[][] = [];
  let officer: string | null = null; let title: string | null = null; let witness: CompanySignature['witness'] = null; let text: string | null = null;
  for (const r of rows) {
    if (r.signer_role === 'witness' && r.method === 'typed') {
      witness = { name: r.signer_name, when: r.signed_at ? when(r.signed_at) : '' }; // the same Toronto date and time as every signature row
      lines.push([`Witness: ${r.signer_name}`, `typed on screen in person; ${r.consent_text ?? ''}`]);
    }
    if (r.signer_role === 'carmacars') {
      officer = r.signer_name; title = r.signer_title; text = r.consent_text ?? null;
      if (r.consent_text) lines.push(['Countersignature', r.consent_text]);
    }
    if (r.staff_attribution) {
      const [k, ...v] = r.staff_attribution.split(':');
      lines.push([k!.trim(), v.join(':').trim()]);
    }
  }
  return { officer, title, lines, witness, text };
}
