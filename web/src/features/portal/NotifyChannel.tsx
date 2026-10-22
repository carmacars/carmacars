'use client';
import { useState, useTransition } from 'react';
import { useRouter } from 'next/navigation';
import { saveMyChannel } from '@/server/actions/notify-channel';
import { CHANNELS, CHANNEL_HINT, CHANNEL_LABEL, nowWords, quietWords, whyNotWords, type Channel, type Reach } from '@/features/phone/alerts';

// Text alerts (migration 0096): "How should we reach you?" Email, Text or Both. One radio group for the profiles, the
// booking request and the phone sign-up; the profile card saves as soon as a choice is made.
export function ChannelChoice({ name, value, onChange, disabled, legend = 'How should we reach you?', hint, testId = 'channel' }: {
  name: string; value: Channel; onChange: (c: Channel) => void; disabled?: boolean; legend?: string; hint?: string; testId?: string;
}) {
  return (
    <fieldset className="field stack" aria-describedby={hint ? `${name}-hint` : undefined} data-testid={testId}>
      <legend className="label">{legend}</legend>
      {CHANNELS.map((c) => (
        <label className="option" key={c}>
          <input type="radio" name={name} value={c} checked={value === c} disabled={disabled} onChange={() => onChange(c)} data-testid={`${testId}-${c}`} />
          <span className="option__title">{CHANNEL_LABEL[c]}</span>
          <span className="option__body">{CHANNEL_HINT[c]}</span>
        </label>
      ))}
      {hint && <p className="hint" id={`${name}-hint`}>{hint}</p>}
    </fieldset>
  );
}

export function NotifyChannelCard({ reach, className = 'pt-card' }: { reach: Reach; className?: string }) {
  const router = useRouter();
  const [pending, start] = useTransition();
  const [value, setValue] = useState<Channel>(reach.wanted);
  const [state, setState] = useState<Reach>(reach);
  const [msg, setMsg] = useState<{ ok: boolean; text: string } | null>(null);
  const choose = (c: Channel) => {
    const was = value;
    setValue(c); setMsg(null);
    start(async () => {
      const r = await saveMyChannel(c);
      if (!r.ok) { setValue(was); setMsg({ ok: false, text: r.message }); return; }
      setState(r.data);
      setMsg({ ok: true, text: `Saved. ${nowWords(r.data)}` });
      router.refresh();
    });
  };
  const why = whyNotWords(state.why_not, state.our_number);
  return (
    <section className={className} aria-labelledby="nc-title" data-testid="notify-channel">
      <h2 className="d4" id="nc-title">Messages</h2>
      <ChannelChoice name="nc-channel" value={value} onChange={choose} disabled={pending}
        hint={value !== 'email' && state.enabled !== false ? `${quietWords(state.quiet_from, state.quiet_until)} Reply STOP to any text to stop them.` : undefined} />
      {value !== 'email' && why && <p className="pt-note" data-testid="notify-why">{why}</p>}
      <p className="small muted" data-testid="notify-now">{msg?.ok ? '' : nowWords(state)}</p>
      {msg && <p className={msg.ok ? 'alert alert--ok' : 'alert alert--error'} role={msg.ok ? 'status' : 'alert'} data-testid="notify-msg"><span>{msg.text}</span></p>}
    </section>
  );
}
