'use client';
import { useState, useTransition } from 'react';
import { useRouter } from 'next/navigation';
import { governmentFormsMakeAgain } from '@/server/actions/onboarding';

// Admin: a car's government forms made again now from what is on file (r34, 0822). A form signed or filed is kept.
export function MakeAgain({ vehicleId, name, refresh }: { vehicleId: string; name: string; refresh: string[] }) {
  const router = useRouter();
  const [pending, start] = useTransition();
  const [msg, setMsg] = useState<{ ok: boolean; text: string } | null>(null);
  return (
    <div className="row" style={{ flexWrap: 'wrap', gap: 'var(--s-2)', alignItems: 'center' }}>
      <button type="button" className="btn btn--ghost btn--sm" disabled={pending} data-testid="government-forms-make-again" aria-label={`Make the government forms of the ${name} again`}
        onClick={() => start(async () => {
          const r = await governmentFormsMakeAgain(vehicleId, refresh);
          if (r.ok) {
            const kept = r.data.forms.filter((f) => !f.made).map((f) => `${f.form_code} (${(f.why ?? '').replace(/^kept: /, '')})`);
            setMsg({ ok: true, text: `Made again: ${r.data.made}.${kept.length ? ` Kept: ${kept.join(', ')}.` : ''}` });
            router.refresh();
          } else setMsg({ ok: false, text: r.message });
        })}>{pending ? 'Making' : 'Make again'}</button>
      {msg && <span className={`small ${msg.ok ? '' : 'ad-err'}`} role={msg.ok ? 'status' : 'alert'} data-testid="government-forms-make-again-msg">{msg.text}</span>}
    </div>
  );
}
