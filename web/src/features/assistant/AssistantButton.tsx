'use client';
/** The header's Assistant button (the panel's own, and AssistantLauncher's before the panel is loaded). */
export function AssistantButton({ onOpen, onWarm }: { onOpen: () => void; onWarm?: () => void }) {
  return (
    <button type="button" className="btn btn--quiet btn--sm as-open hd-act" onClick={onOpen} onPointerEnter={onWarm} onFocus={onWarm} aria-haspopup="dialog" aria-keyshortcuts="Control+/ Meta+/" data-testid="assistant-open"
      title="Assistant (Ctrl+/)">
      <svg viewBox="0 0 24 24" aria-hidden="true" fill="none" stroke="currentColor" strokeWidth="1.8" strokeLinecap="round" strokeLinejoin="round"><path d="M4 5.5A2.5 2.5 0 0 1 6.5 3h11A2.5 2.5 0 0 1 20 5.5v8a2.5 2.5 0 0 1-2.5 2.5H11l-4.5 4v-4h0A2.5 2.5 0 0 1 4 13.5z" /></svg>
      <span className="hd-lbl">Assistant</span></button>
  );
}
