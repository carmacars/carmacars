'use client';
import { useRouter } from 'next/navigation';
import { useState } from 'react';
import { hireApplicant } from '@/server/actions/hiring';
import { SendGenerated } from '@/features/manual/SignRequests';

// Hire (migration 0173): the existing staff invitation (field staff, or an assistant with the role's function) for the
// candidate's email, recorded on the application; then the staff agreement is generated and sent to sign in their portal
// with the existing flow (the values are shown to check first).
export function Hire({ id, name, portal, hiredUserId }: { id: string; name: string; portal: string; hiredUserId: string | null }) {
  const router = useRouter();
  const [busy, setBusy] = useState(false);
  const [err, setErr] = useState<string | null>(null);
  const [user, setUser] = useState<string | null>(hiredUserId);
  const [note, setNote] = useState<string | null>(null);
  async function hire() {
    if (!window.confirm(`Hire ${name}? They get an invitation to the ${portal} portal by email.`)) return;
    setBusy(true); setErr(null);
    const r = await hireApplicant(id);
    setBusy(false);
    if (!r.ok) { setErr(r.message); return; }
    setUser(r.data.user_id);
    setNote(r.data.existed ? 'Hired. They already sign in: the role was added, no email sent.' : `Hired. The invitation to choose a password is on its way to ${r.data.email}.`);
    router.refresh();
  }
  if (user) {
    return (
      <div className="stack" data-testid="hire-done">
        {note && <p className="small" role="status">{note}</p>}
        <p className="small">Next: send the staff agreement to sign in their portal.</p>
        <SendGenerated docType="staff_agreement" who={user} refresh={[`/admin/hiring/${id}`]} />
      </div>
    );
  }
  return (
    <span className="stack">
      <button type="button" className="btn btn--primary" onClick={hire} disabled={busy} data-testid="hire">{busy ? 'Inviting' : `Hire: invite to the ${portal} portal`}</button>
      {err && <span className="error" role="alert">{err}</span>}
    </span>
  );
}
