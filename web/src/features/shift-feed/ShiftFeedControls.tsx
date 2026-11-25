'use client';
import { useId, useState, useTransition } from 'react';
import { useRouter } from 'next/navigation';
import { setShiftFeed } from '@/server/actions/shift-feed';
import { googleAddUrl, type FeedScope } from './links';

// r50 (5050): one feed's controls: make the link, copy it, add it to Google Calendar in one click, regenerate it (the
// old address stops working) or turn it off. A press that changes the link asks once more before it goes.
export function ShiftFeedControls({ scope, url }: { scope: FeedScope; url: string | null }) {
  const router = useRouter();
  const id = useId().replace(/:/g, '');
  const [pending, start] = useTransition();
  const [copied, setCopied] = useState(false);
  const [ask, setAsk] = useState<'regenerate' | 'revoke' | null>(null);
  const [err, setErr] = useState<string | null>(null);
  const run = (action: 'create' | 'regenerate' | 'revoke') => start(async () => {
    setErr(null);
    const r = await setShiftFeed(scope, action);
    if (!r.ok) { setErr(r.message); return; }
    setAsk(null);
    router.refresh();
  });
  if (!url) {
    return (
      <div className="stack">
        <div className="row">
          <button type="button" className="btn btn--ghost btn--sm" disabled={pending} aria-busy={pending || undefined} onClick={() => run('create')} data-testid={`shift-feed-create-${scope}`}>{pending ? 'Working' : 'Make my calendar link'}</button>
        </div>
        {err && <p className="alert alert--error" role="alert"><span>{err}</span></p>}
      </div>
    );
  }
  return (
    <div className="stack">
      <label className="small" htmlFor={`sf-${id}`}>Your private calendar link (keep it to yourself: anyone with it sees the shifts)</label>
      <input className="input" id={`sf-${id}`} readOnly value={url} onFocus={(e) => e.currentTarget.select()} data-testid={`shift-feed-url-${scope}`} />
      <div className="row">
        <a className="btn btn--ghost btn--sm" href={googleAddUrl(url)} target="_blank" rel="noopener noreferrer" data-testid={`shift-feed-google-${scope}`}>Add to Google Calendar</a>
        <button type="button" className="btn btn--ghost btn--sm" onClick={() => { void navigator.clipboard?.writeText(url).then(() => { setCopied(true); setTimeout(() => setCopied(false), 1500); }).catch(() => setCopied(false)); }} data-testid={`shift-feed-copy-${scope}`}>{copied ? 'Copied' : 'Copy link'}</button>
        <button type="button" className="btn btn--quiet btn--sm" disabled={pending} aria-busy={pending && ask === 'regenerate' ? true : undefined} onClick={() => (ask === 'regenerate' ? run('regenerate') : setAsk('regenerate'))} data-testid={`shift-feed-regenerate-${scope}`}>{ask === 'regenerate' ? 'Yes, make a new link' : 'Regenerate link'}</button>
        <button type="button" className="btn btn--quiet btn--sm" disabled={pending} aria-busy={pending && ask === 'revoke' ? true : undefined} onClick={() => (ask === 'revoke' ? run('revoke') : setAsk('revoke'))} data-testid={`shift-feed-revoke-${scope}`}>{ask === 'revoke' ? 'Yes, turn it off' : 'Turn off'}</button>
      </div>
      {ask && <p className="small" role="status">{ask === 'regenerate' ? 'The old link stops working: calendars that use it stop updating. Add the new one.' : 'The link stops working and the calendar stops updating.'} <button type="button" className="btn btn--quiet btn--sm" onClick={() => setAsk(null)}>Cancel</button></p>}
      {err && <p className="alert alert--error" role="alert"><span>{err}</span></p>}
    </div>
  );
}
