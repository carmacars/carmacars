import 'server-only';
import { door } from '@/server/door';
import { storage } from '@/integrations/storage';
import { agreementPdf } from '@/features/agreement/pdf';
import { markdown, type Block } from '@/features/agreement/model';
import { sha256Hex } from '@/server/links';
import { blanksIn, forBlocks, investmentMarkdown, missingRequired, investmentSummary, investorFields, PERSON_AGREEMENTS_VERSION, staffFields, staffMarkdown, staffSummary, staffTitle,
  type Field, type InvestorFacts, type StaffFacts } from '@/features/person-agreements/model';

// Agreements generated from the records (migration 0049): the investor's investment agreement and the staff member's
// agreement, rendered from docs/source with the values of the record and the settings, stored privately and sent to
// sign in the person's portal with the same request as an uploaded PDF (which stays possible). The values the Admin
// confirmed and a short summary of them go with the request: the person sees the summary with the PDF.
export type GeneratedKind = 'investment_agreement' | 'staff_agreement';
export interface Prepared { kind: GeneratedKind; title: string; fields: Field[]; name: string; exemption?: { category: string; paragraph: string } }

async function facts(userId: string, aal: 'aal1' | 'aal2' | null, kind: GeneratedKind, who: string): Promise<InvestorFacts | StaffFacts> {
  return kind === 'investment_agreement'
    ? door<InvestorFacts>(userId, 'ops_do', 'investor_agreement_prepare', { investor_id: who }, aal)
    : door<StaffFacts>(userId, 'ops_read', 'staff_agreement_prepare', { staff_user_id: who }, aal);
}

export async function prepareGenerated(userId: string, aal: 'aal1' | 'aal2' | null, kind: GeneratedKind, who: string): Promise<Prepared> {
  const f = await facts(userId, aal, kind, who);
  if (kind === 'investment_agreement') {
    const x = f as InvestorFacts;
    return { kind, title: `Investment agreement ${x.agreement_number}`, name: x.investor.legal_name, fields: investorFields(x, { category: 'accredited_investor', paragraph: '' }),
      exemption: { category: 'accredited_investor', paragraph: '' } };
  }
  const x = f as StaffFacts;
  return { kind, title: `${staffTitle(x)}, ${x.staff.full_name}`, name: x.staff.full_name, fields: staffFields(x) };
}

export async function sendGenerated(userId: string, aal: 'aal1' | 'aal2' | null, kind: GeneratedKind, who: string, values: Record<string, string>,
  exemption: { category: string; paragraph: string }): Promise<{ id: string; blanks: number }> {
  const f = await facts(userId, aal, kind, who);
  const required = kind === 'investment_agreement' ? investorFields(f as InvestorFacts, exemption) : staffFields(f as StaffFacts);
  const missing = missingRequired(required, values);
  if (missing.length) throw new Error(`Fill in: ${missing.join(', ')}.`);
  let md: string; let title: string; let summary: Array<{ label: string; value: string; fix?: string | null }>; let heading: Block[];
  if (kind === 'investment_agreement') {
    const x = f as InvestorFacts;
    md = investmentMarkdown(x, values, exemption);
    title = `Investment agreement ${x.agreement_number}`;
    summary = investmentSummary(x, values);
    heading = [{ t: 'title', text: 'Investment Agreement' }, { t: 'p', text: `Agreement ${x.agreement_number}` }];
  } else {
    const x = f as StaffFacts;
    md = staffMarkdown(x, values);
    title = `${staffTitle(x)}, ${x.staff.full_name}`;
    summary = staffSummary(x, values);
    heading = [{ t: 'title', text: `CarmaCars ${staffTitle(x)}` }];
  }
  const blanks = blanksIn(md);
  const blocks = [...heading, ...markdown(forBlocks(md, f.company), {})];
  const pdf = await agreementPdf(blocks, { title, createdAt: new Date(), footer: `CarmaCars ${title}. ${PERSON_AGREEMENTS_VERSION}` });
  const sha = await sha256Hex(pdf);
  const path = `${kind === 'investment_agreement' ? 'investors' : 'staff'}/${who}/to-sign/${sha.slice(0, 16)}.pdf`;
  await (await storage()).put('agreements', path, pdf, 'application/pdf');
  const r = await door<{ id: string }>(userId, 'ops_do', 'sign_request_create', {
    doc_type: kind, investor_id: kind === 'investment_agreement' ? who : null, staff_user_id: kind === 'staff_agreement' ? who : null, title, document: { path, sha256: sha },
    exemption_category: kind === 'investment_agreement' ? exemption.category : null, exemption_paragraph: kind === 'investment_agreement' ? exemption.paragraph || null : null,
    template_version: PERSON_AGREEMENTS_VERSION, extra: { generated: true, summary, values } }, aal);
  return { id: r.id, blanks };
}
