// r48 part 2: Approve all names what it approves (the owner's report: "Approve all (1)" counted a proof of coverage or a
// Protection Plan waiting, without saying so). Pure: DocumentReview and doc-approve.test.ts share it.
const ITEM: Record<string, string> = { licence_front: 'licence front', licence_back: 'licence back', selfie: 'selfie' };

/** What Approve all approves, in words: each image waiting, the proof of coverage, the Protection Plan. */
export function approvableItems(d: { uploads: Array<{ kind: string; status: string }> } | null, covWaiting: boolean, planWaiting: boolean): string[] {
  if (!d) return [];
  const ups = d.uploads.filter((u) => u.status === 'submitted').map((u) => ITEM[u.kind] ?? u.kind.replace(/_/g, ' '));
  return [...ups, ...(covWaiting ? ['proof of coverage'] : []), ...(planWaiting ? ['Protection Plan'] : [])];
}
export function approveLabel(items: string[]): string {
  if (items.length === 0) return 'Approve all';
  if (items.length === 1) return `Approve the ${items[0]}`;
  return `Approve all ${items.length}: ${items.slice(0, -1).join(', ')} and ${items[items.length - 1]}`;
}
