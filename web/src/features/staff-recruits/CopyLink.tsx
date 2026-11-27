'use client';
import { useState } from 'react';

// 5135: the invite link with Copy (the person pastes it into a text or a post).
export function CopyLink({ link }: { link: string }) {
  const [copied, setCopied] = useState(false);
  return (
    <div className="stack">
      <p className="small" data-testid="recruit-link-text"><code className="rc-link">{link}</code></p>
      <div><button type="button" className="btn btn--primary btn--sm" data-testid="recruit-link-copy"
        onClick={() => { void navigator.clipboard?.writeText(link).then(() => setCopied(true)).catch(() => setCopied(false)); }}>{copied ? 'Copied' : 'Copy the link'}</button>
        <span className="small muted" role="status">{copied ? ' Paste it into a text, an email or a post.' : ''}</span></div>
    </div>
  );
}
