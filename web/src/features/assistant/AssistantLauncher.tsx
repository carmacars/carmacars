'use client';
import dynamic from 'next/dynamic';
import { useCallback, useEffect, useState } from 'react';
import { AssistantButton } from './AssistantButton';
import type { Portal } from './tools';

// r48 speed (docs/changes/2026-11-20-r48-perf.md): the Assistant button in every Admin and staff frame, without the panel's
// code. The panel (AssistantPanel.tsx) loads the first time it is opened (the button or Ctrl+/), or when the pointer
// rests on the button; it then opens at once and works as before.
const load = () => import('./AssistantPanel');
const Panel = dynamic(() => load().then((m) => m.AssistantPanel), { ssr: false });

export function AssistantLauncher({ portal, greeting }: { portal: Portal; greeting?: string | null }) {
  const [signal, setSignal] = useState(0);
  const openIt = useCallback(() => setSignal((n) => n + 1), []);
  // before the panel is loaded the shortcut is ours; once it is, the panel's own handler opens and closes it
  useEffect(() => {
    if (signal > 0) return;
    const k = (e: KeyboardEvent) => { if ((e.ctrlKey || e.metaKey) && !e.altKey && e.key === '/') { e.preventDefault(); openIt(); } };
    window.addEventListener('keydown', k);
    return () => window.removeEventListener('keydown', k);
  }, [signal, openIt]);
  return (
    <>
      <AssistantButton onOpen={openIt} onWarm={() => { void load(); }} />
      {signal > 0 && <Panel portal={portal} greeting={greeting} openSignal={signal} trigger={false} />}
    </>
  );
}
