// Delete my account (migration 0390): the state the profile card shows. No imports: shared by the server, the card and
// the unit tests.
export interface DeletionState {
  allowed: boolean;
  request: { status: 'open' | 'done' | 'withdrawn'; requested_at: string; closed_at: string | null } | null;
}

/** The card's state: ask, asked (waiting, with withdraw), or done. A withdrawn request can be asked again. */
export function deletionStep(s: DeletionState | null | undefined): 'ask' | 'asked' | 'done' | 'hidden' {
  if (!s || !s.allowed) return 'hidden';
  if (s.request?.status === 'open') return 'asked';
  if (s.request?.status === 'done') return 'done';
  return 'ask';
}
