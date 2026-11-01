'use client';
import { useState, useTransition } from 'react';
import { useRouter } from 'next/navigation';
import { opsAct } from '@/server/actions/ops';

// The tracker ingest key (migration 0400): made here, shown once, copied into the relay or the tracker service. A new
// key replaces the old one at once (a sender still using the old one is refused).
export function IngestKey({ hasKey, hint }: { hasKey: boolean; hint: string | null }) {
  const [key, setKey] = useState<string | null>(null);
  const [err, setErr] = useState('');
  const [copied, setCopied] = useState(false);
  const [pending, start] = useTransition();
  const router = useRouter();
  const make = () => {
    if (hasKey && !window.confirm('Make a new key? The old key stops working at once: put the new one in the relay or tracker service straight away.')) return;
    start(async () => {
      const r = await opsAct<{ key: string }>('tracker_key_new');
      if (r.ok) { setKey(r.data.key); setErr(''); router.refresh(); } else setErr(r.message);
    });
  };
  return (
    <div data-testid="ingest-key">
      <p className="small">{hasKey ? <>A key is set (ending <b>{hint}</b>).</> : 'No key yet: the ingest refuses every batch until one is made.'} The relay or tracker service signs each batch with it.</p>
      {key && <p className="alert alert--ok" role="status"><span>Copy it now, it is shown only once: <code data-testid="ingest-key-value">{key}</code>{' '}
        <button type="button" className="btn btn--ghost btn--sm" onClick={() => { void navigator.clipboard?.writeText(key).then(() => setCopied(true)); }}>{copied ? 'Copied' : 'Copy'}</button></span></p>}
      {err && <p className="alert alert--error" role="alert"><span>{err}</span></p>}
      <button type="button" className="btn btn--ghost btn--sm" onClick={make} disabled={pending} data-testid="ingest-key-make">{pending ? 'Working' : hasKey ? 'Make a new key' : 'Make the ingest key'}</button>
    </div>
  );
}
