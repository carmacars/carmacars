import { Act } from '@/features/admin/Act';

// Admin > Hiring (release 37, migration 2303): how video interview calls meet. Connected: every booked call gets a Google
// Calendar event with its own Google Meet link (in the emails, on the candidate's page and on the Calls tab). Not
// connected: Jitsi links, and the button to connect. Admins only (hiring is Admin-only).
export type MeetState = { status: 'not_connected' | 'connected' | 'error'; account_email: string | null; calendar_id: string; connected_at: string | null; last_error: string | null; provider: 'google' | 'jitsi'; waiting: number };
const FLASH: Record<string, [string, boolean]> = {
  connected: ['Google Calendar is connected: new video calls get a Google Meet link.', true],
  'no-keys': ['The site has no Google app keys yet (GOOGLE_CALENDAR_CLIENT_ID and SECRET, or the reviews ones).', false],
  'no-refresh': ['Google sent no lasting access: press Connect Google Calendar again and allow it.', false],
  'no-vault': ['The database has no vault to keep the connection in.', false],
  declined: ['The connection was not allowed on Google.', false],
  state: ['The connection took too long or was started in another browser. Press Connect Google Calendar again.', false],
  failed: ['Google refused the connection. Press Connect Google Calendar again.', false]
};

export function MeetCard({ s, flash }: { s: MeetState | null; flash?: string }) {
  if (!s) return null;
  const f = flash ? FLASH[flash] : undefined;
  return (
    <div className="stack-s" data-testid="meet-card">
      {f && <p className={`alert ${f[1] ? 'alert--ok' : 'alert--error'}`} role={f[1] ? 'status' : 'alert'}><span>{f[0]}</span></p>}
      <p className="small row" style={{ gap: '0.5rem', alignItems: 'center', flexWrap: 'wrap' }}>
        {s.status === 'connected'
          ? <span data-testid="meet-provider">Video calls: <b>Google Meet</b>, on {s.account_email ?? 'the company'}&apos;s Google Calendar{s.waiting ? ` (${s.waiting} waiting for their link)` : ''}.</span>
          : <span data-testid="meet-provider">Video calls: <b>Jitsi</b> links. Connect the company&apos;s Google Calendar once to give every call a Google Meet link instead.</span>}
        {/* eslint-disable-next-line @next/next/no-html-link-for-pages -- an API route (an OAuth redirect), not a page */}
        <a className={`btn btn--sm ${s.status === 'connected' ? 'btn--ghost' : 'btn--primary'}`} href="/api/google/calendar/connect" data-testid="meet-connect">{s.status === 'connected' ? 'Connect again' : 'Connect Google Calendar'}</a>
        {s.status === 'connected' && <Act action="calendar_google_disconnect" label="Disconnect" confirm="New video calls go back to Jitsi links; calls already on Google Meet keep their link." refresh={['/admin/hiring']} testId="meet-disconnect" />}
      </p>
      {s.last_error && <p className="small error" data-testid="meet-error">Last Google error: {s.last_error}. Calls kept their Jitsi link.</p>}
    </div>
  );
}
