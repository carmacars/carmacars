'use client';
import { useState } from 'react';
import { money } from '@/lib/format';
import { Icon } from '@/components/Icon';
import { IconSwap } from '@/portable/motion/react';
import { CARD_PAUSED_TITLE, cardPausedWhy, etransferMessage, type CardPayments } from './card-pay';
import './etransfer-pay.css';

// Hotfix 3650: what every staff role sees where a card tool was (Money tab, the field tools) while card payments are
// paused: why, and "Ask the renter to e-Transfer" with the message ready to copy (the email, the booking number as the
// message, the exact amounts). Collect a card, Send card link and Take a deposit hold are hidden meanwhile.
const fmt = (c: number) => money(Number(c ?? 0), { cents: true });

export function CardPausedNote({ card, bookingNumber, rentalCents = 0, depositCents = 0, firstName, compact = false }: {
  card: Pick<CardPayments, 'reason' | 'e_transfer_email'> | null | undefined; bookingNumber: string; rentalCents?: number; depositCents?: number; firstName?: string | null;
  /** the field tools: one line and the copy button */ compact?: boolean }) {
  const [copied, setCopied] = useState(false);
  const text = etransferMessage({ firstName, bookingNumber, email: card?.e_transfer_email ?? null, rentalCents, depositCents, fmt });
  const copy = () => navigator.clipboard?.writeText(text).then(() => { setCopied(true); setTimeout(() => setCopied(false), 1800); }).catch(() => undefined);
  return (
    <div className="alert alert--warn cpn" role="status" data-testid="card-paused-note">
      <span className="alert__title">{CARD_PAUSED_TITLE}</span>
      <span>{cardPausedWhy(card)} Collect a card, card links and deposit holds are off. Ask the renter to e-Transfer{compact ? '.' : ': copy the message below and send it by text, email or WhatsApp. When they upload the screenshot (or you report it), Finance confirms it in one tap.'}</span>
      {!compact && <pre className="cpn__msg" data-testid="card-paused-message">{text}</pre>}
      <span className="cpn__actions"><button type="button" className="btn btn--primary btn--sm" onClick={copy} data-testid="card-paused-copy"><IconSwap on={copied} first={<Icon name="copy" />} second={<Icon name="check" />} />{copied ? 'Copied' : 'Copy the e-Transfer message'}</button></span>
    </div>
  );
}
