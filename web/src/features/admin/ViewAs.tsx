import type { ReactNode } from 'react';

// "View as" buttons and pickers: plain forms to /api/view-as/start (they work before the page's script loads). The
// route checks the Admin and the database checks the person and the portal (app.view_as_start, 0036).
export type Portal = 'account' | 'owner' | 'va' | 'field' | 'investor';
export const PORTAL_NAME: Record<Portal, string> = { account: 'renter portal', owner: 'owner portal', va: 'staff portal', field: 'staff portal (field work)', investor: 'investor portal' };

export function ViewAsButton({ user, portal, fn, label, testId }: { user: string; portal: Portal; fn?: string | null; label?: ReactNode; testId?: string }) {
  return (
    <form method="post" action="/api/view-as/start" style={{ display: 'inline' }}>
      <input type="hidden" name="user" value={user} />
      <input type="hidden" name="portal" value={portal} />
      {fn && <input type="hidden" name="fn" value={fn} />}
      <button className="btn btn--ghost btn--sm" type="submit" data-testid={testId}>{label ?? `View as (${PORTAL_NAME[portal]})`}</button>
    </form>
  );
}

/** A picker of the people who have a portal, and one button: "Open as ...". */
export function ViewAsPicker({ id, portal, fn, people, testId }: { id: string; portal: Portal; fn?: string; people: Array<{ id: string; name: string; email: string }>; testId?: string }) {
  if (!people.length) return <p className="small muted">No one has this portal yet.</p>;
  return (
    <form method="post" action="/api/view-as/start" className="row" style={{ flexWrap: 'wrap', gap: 'var(--s-2)', alignItems: 'end' }} data-testid={testId}>
      <input type="hidden" name="portal" value={portal} />
      {fn && <input type="hidden" name="fn" value={fn} />}
      <div className="field ad-field" style={{ minWidth: '14rem', flex: '1 1 14rem' }}>
        <label className="label" htmlFor={id}>Person</label>
        <select className="select" id={id} name="user" required defaultValue="">
          <option value="" disabled>Choose a person</option>
          {people.map((p) => <option key={p.id} value={p.id}>{p.name} ({p.email})</option>)}
        </select>
      </div>
      <button className="btn btn--primary btn--sm" type="submit">Open as this person</button>
    </form>
  );
}
