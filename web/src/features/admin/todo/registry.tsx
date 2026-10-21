import type { ReactNode } from 'react';
import Link from 'next/link';
import type { Prompt } from './types';

// The pop-up of a task on Admin > Today, by task type (migration 0077). A task the database raises for the Admin (or for
// an assistant function nobody real holds yet) shows on Today by itself, as one line with its title and why. Without an
// entry here it gets the general pop-up: what it is, a link to where the work is done, Done and Later.
//
// To give a task type its own one-step pop-up, add an entry: the function receives the prompt (task_id, task_type,
// vehicle_id, owner_id, booking_number, related_table, related_id, title, why) and returns the control that does the
// work, usually an Act (features/admin/Act.tsx) with its fields pre-filled. When the work is done the database closes
// the task (or the prompt's own rule hides it) and the line disappears. Example, the first and last month invoice
// choice (raised as first_last_decide in the admin queue). A car waiting for the insurer (including a rental already
// under way, live_rental_insurance) has its own prompt with Insurer confirmed, not a task line.
//   first_last_decide: (p) => <FirstLastChoice vehicleId={p.vehicle_id!} ownerId={p.owner_id!} />,
export const TASK_PROMPTS: Record<string, (p: Prompt) => ReactNode> = {
  // until its own pop-up plugs in here: the owner's Terms tab, where the choice is made
  first_last_decide: (p) => (p.owner_id ? <Link prefetch={false} className="btn btn--primary btn--sm" href={`/admin/owners/${p.owner_id}?tab=terms`} data-testid={`todo-act-${p.key}`}>Decide</Link> : null)
};
