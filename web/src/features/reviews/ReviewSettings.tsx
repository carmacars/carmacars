import type { ReactNode } from 'react';
import Link from 'next/link';
import { Act } from '@/features/admin/Act';
import { Card, Kv, t } from '@/features/admin/ui';

// Admin > Settings > Reviews (migration 0146): when the review requests go, the hold, the Google review link, and the
// Google Business Profile connection for the reviews sync (rent@carmacars.ca; the refresh token is kept in the vault).
export interface ReviewSettingsData {
  google: { status: string; account_email: string | null; account_name: string | null; location_name: string | null; location_title: string | null; connected_at: string | null;
    last_sync_at: string | null; last_ok_at: string | null; last_error: string | null; reviews_seen: number; vault: boolean };
  place_id: string | null; review_link: string | null; google_url: string | null;
  counts: { held: number; google_reviews: number; suggested: number };
}

const MESSAGES: Record<string, [string, boolean]> = {
  connected: ['Google is connected. The first reviews are read within 5 minutes.', true],
  'no-keys': ['The Google app keys are not set yet (deploy_google_reviews_client_id and deploy_google_reviews_client_secret in the vault, then deploy).', false],
  'no-refresh': ['Google did not give offline access. Press Connect Google again and allow access for rent@carmacars.ca.', false],
  'no-vault': ['The database has no vault to keep the connection in.', false],
  declined: ['The connection was not allowed on Google.', false],
  state: ['The connection took too long or was started in another browser. Press Connect Google again.', false],
  failed: ['Google refused the connection. Press Connect Google again.', false]
};
const STATUS: Record<string, string> = {
  not_connected: 'Not connected',
  connected: 'Connected',
  api_not_approved: 'Connected, waiting for Google to approve the Business Profile API for this project. Everything else works: renters still get the review link, and "I already left a review", staff marks and on-site reviews still stop the requests.',
  error: 'The last sync failed'
};

export function ReviewSettings({ data, message, keysSet, timings, link }: { data: ReviewSettingsData; message: string | null; keysSet: boolean; timings: ReactNode; link: ReactNode }) {
  const g = data.google;
  const m = message ? MESSAGES[message] : undefined;
  return (
    <div className="stack" data-testid="review-settings">
      {m && <p className={`alert ${m[1] ? 'alert--ok' : 'alert--warn'}`} role="status" data-testid="review-google-message"><span>{m[0]}</span></p>}
      <Card title="When review requests go" testId="review-timings">
        <p className="small muted">A mid-trip check-in for longer rentals (no review ask in it), the review request after the check-in, a reminder and a final follow-up, by email and text as each renter chose, only between the hours below. Nothing goes while charges are open (the hold list in Reviews), after the renter reviewed, or after an unsubscribe.</p>
        {timings}
      </Card>
      <Card title="The Google review link" testId="review-link">
        <p className="small">Renters open it from the review page with their draft copied. {data.google_url ? <>Now: <a className="link" href={data.google_url} target="_blank" rel="noopener">{data.google_url}</a></> : <b>Not set: add the Google place id or the review link.</b>}</p>
        {link}
      </Card>
      <Card title="Google Business Profile" testId="review-google" tone={g.status === 'error' ? 'warn' : undefined}
        aside={<span className="ad-actions">
          {keysSet ? <a className="btn btn--primary btn--sm" href="/api/google/reviews/connect" data-testid="review-google-connect">{g.status === 'not_connected' ? 'Connect Google' : 'Connect again'}</a>
            : <span className="small muted" data-testid="review-google-nokeys">Google app keys not set</span>}
          {g.status !== 'not_connected' && <Act action="review_google_disconnect" label="Disconnect" variant="quiet" confirm="Stop reading Google reviews. The reviews already read and their matches stay." refresh={['/admin/settings/reviews']} done="Disconnected." />}
        </span>}>
        <p className="small">Reads the CarmaCars reviews on Google every 6 hours and matches each one to a renter by name within the days after their return, so their reminders stop. Sign in with <b>rent@carmacars.ca</b> (the Business Profile&apos;s owner or manager) and allow access.</p>
        <Kv rows={[
          ['Status', <span key="s" data-testid="review-google-status">{STATUS[g.status] ?? g.status}</span>],
          ['Account', g.account_email ?? ''], ['Location', g.location_title ?? g.location_name ?? ''],
          ['Connected', t(g.connected_at)], ['Last read', t(g.last_ok_at)], ['Last error', g.status !== 'connected' ? g.last_error ?? '' : ''],
          ['Reviews read', g.status === 'not_connected' && !data.counts.google_reviews ? '' : `${data.counts.google_reviews}${data.counts.suggested ? `, ${data.counts.suggested} to confirm in Reviews` : ''}`]
        ]} />
        {!keysSet && <p className="small muted">To connect: a Google Cloud project with the Business Profile APIs (approved by Google), an OAuth Web client with the redirect address https://carmacars.ca/api/google/reviews/callback, its id and secret in the vault as deploy_google_reviews_client_id and deploy_google_reviews_client_secret, then a deploy.</p>}
        {!g.vault && <p className="small muted">This database has no vault: the connection cannot be kept here (local and test databases).</p>}
        <p className="small"><Link prefetch={false} className="link" href="/admin/reviews">Reviews</Link>: requests sent, the hold list, Google reviews and their matches.</p>
      </Card>
    </div>
  );
}
