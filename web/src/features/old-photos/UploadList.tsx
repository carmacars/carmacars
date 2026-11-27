'use client';
import type { Upload } from './useUploads';

const WORD: Record<Upload['state'], string> = { waiting: 'Waiting', preparing: 'Getting ready', uploading: 'Uploading', done: 'Added', failed: 'Not added' };

// The progress of the background uploads: one bar for all, then each photo with its state.
export function UploadList({ items, pct, done, failed, going, retry, testId = 'op-uploads' }: {
  items: Upload[]; pct: number; done: number; failed: number; going: number; retry: (id: string) => void; testId?: string;
}) {
  if (!items.length) return null;
  return (
    <section className="op-progress" aria-label="Uploads" data-testid={testId}>
      <div className="op-meter" role="progressbar" aria-valuemin={0} aria-valuemax={100} aria-valuenow={pct} aria-label="Photos uploaded">
        <span style={{ width: `${pct}%` }} />
      </div>
      <p className="op-meter__text" aria-live="polite" data-testid={`${testId}-summary`}>
        <b>{done} of {items.length} added</b>
        <span>{going ? `${going} still going: you can keep working, they go on in the background.` : failed ? `${failed} not added` : 'All added.'}</span>
      </p>
      <ul className="op-files">
        {items.map((u) => (
          <li key={u.id} className={`op-file is-${u.state}`} data-testid="op-file" data-state={u.state}>
            <span className="op-file__name">{u.name || 'Photo'}</span>
            <span className="op-file__state">{u.dup ? 'Already added' : WORD[u.state]}{u.state === 'uploading' && u.total ? ` ${Math.round((u.loaded / u.total) * 100)}%` : ''}</span>
            {u.error && u.state !== 'done' && <span className="op-file__why">{u.error}</span>}
            {u.state === 'failed' && <button type="button" className="btn btn--ghost btn--sm" onClick={() => retry(u.id)}>Try again</button>}
          </li>))}
      </ul>
    </section>
  );
}
