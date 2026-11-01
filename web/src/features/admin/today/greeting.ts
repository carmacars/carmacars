// Who Admin > To do and the staff assistant greet (0324; docs/changes/2026-11-06-greeting-name.md): the greeting name set
// on Settings > My profile, whole ("Abbas and Mahad", for a login the owners share), else the first word of the account's
// name. Pure, for the unit test.
export function greetName(r: { name?: string | null; greeting?: string | null }): string | null {
  const g = r.greeting?.trim();
  if (g && g !== (r.name ?? '').trim()) return g;
  const n = r.name?.trim();
  return n ? n.split(/\s+/)[0]! : null;
}
