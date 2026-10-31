// The owner pipeline (migration 0217): stages and their words. No imports: Worker and `node --test`.
export const STAGES: Array<[string, string]> = [['new', 'New'], ['contacted', 'Contacted'], ['call_booked', 'Call booked'], ['agreement_sent', 'Agreement sent'],
  ['signed', 'Signed'], ['car_onboarded', 'Car onboarded'], ['lost', 'Lost']];
export const SOURCES: Record<string, string> = { website: 'Website form', referral: 'Referral', manual: 'Added by hand', classified: 'Classified ad' };
export interface PipelineLead {
  id: string; kind: string; name: string | null; business_name: string | null; email: string | null; phone: string | null; vehicle: string | null; stage: string; stage_at: string | null;
  source: string | null; note: string | null; message: string | null; created_at: string; assignee: string | null; followup_step: number; followup_next_at: string | null;
  followup_stop_reason: string | null; replied_at: string | null; referred_by: string | null; owner_id: string | null;
}
/** The leads of each stage, in the stage order. */
export function byStage(leads: PipelineLead[]): Array<{ stage: string; label: string; leads: PipelineLead[] }> {
  return STAGES.map(([stage, label]) => ({ stage, label, leads: leads.filter((l) => l.stage === stage) }));
}
/** What the follow-ups are doing, in a few words. */
export function followupWords(l: PipelineLead, days: number[], at: (iso: string) => string): string {
  if (l.followup_next_at) return `Follow-up ${l.followup_step + 1} of ${days.length} on ${at(l.followup_next_at)}`;
  if (l.followup_stop_reason) return `Follow-ups stopped: ${l.followup_stop_reason}`;
  return 'No automatic follow-ups';
}
