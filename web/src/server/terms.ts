import 'server-only';
import { rpc } from '@/lib/db/repo';
import { viewAs } from '@/server/view-as';
import { legalValues, renderLegal } from '@/features/legal/render';

// Updated terms to accept (0721): the versions of the terms of use, the privacy policy or an agreement template the
// person is bound by, published after their account was opened and not accepted yet. An Admin viewing as someone sees
// the portal as it is (read only): the step is not shown then.
const SR = { role: 'service_role' as const };
export interface PendingTerms { id: string; doc_key: string; version: string; title: string; summary: string; body: string; body_sha256: string; published_at: string; html: string }

const esc = (s: string) => s.replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;');

export async function pendingTerms(userId: string): Promise<PendingTerms[]> {
  if (await viewAs()) return [];
  const rows = ((await rpc('server_terms_pending', { p_by: userId }, SR).catch(() => [])) ?? []) as unknown as Array<Omit<PendingTerms, 'html'>>;
  if (!rows.length) return [];
  const values = await legalValues().catch(() => ({} as Record<string, string>));
  return rows.map((r) => {
    let html: string;
    // the site's legal text (headings, lists, tables, its {{values}}); a template pasted as plain text, paragraph by paragraph
    try { html = renderLegal(r.body, values); } catch { html = r.body.split(/\n{2,}/).map((p) => `<p>${esc(p).replace(/\n/g, '<br>')}</p>`).join(''); }
    return { ...r, html };
  });
}
