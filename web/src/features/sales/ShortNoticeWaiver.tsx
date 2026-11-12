'use client';
/** "Waive short-notice upcharge" (2370), under More options of an offer, Add a rental and an extension: a switch and the
 *  reason it needs (kept on the booking and in the audit log). Admin always; staff too, the owner's minimum daily rate
 *  still applying. Shown only while there is a short-notice line to waive, or once it is waived. */
export function ShortNoticeWaiver({ idPrefix, on, reason, onChange, amount, fmt }: {
  idPrefix: string; on: boolean; reason: string; onChange: (on: boolean, reason: string) => void;
  amount?: { amount_cents: number; description?: string | null } | null; fmt: (c: number) => string;
}) {
  const id = `${idPrefix}-waive-sn`;
  return (
    <div className="stack" data-testid={id}>
      <label className="check" htmlFor={id}>
        <input id={id} type="checkbox" checked={on} onChange={(e) => onChange(e.target.checked, reason)} data-testid={`${id}-switch`} />
        <span>Waive short-notice upcharge{!on && amount && amount.amount_cents > 0 ? ` (${amount.description ?? 'short notice'}: ${fmt(amount.amount_cents)} before tax)` : ''}</span>
      </label>
      {on && <div className="field ad-field ad-field--wide"><label className="label" htmlFor={`${id}-reason`}>Why it is waived (required, kept in the history)</label>
        <input className="input" id={`${id}-reason`} value={reason} maxLength={500} onChange={(e) => onChange(true, e.target.value)} data-testid={`${id}-reason`}
          aria-invalid={reason.trim().length < 3 || undefined} placeholder="For example: regular renter, agreed on the phone" />
        {reason.trim().length < 3 && <p className="hint">Type the reason: the waiver is not applied without it.</p>}</div>}
    </div>
  );
}
