'use server';
import { currentUser } from '@/server/portal/data';
import { cardPayments } from '@/server/card-provider';
import type { CardPayments } from '@/features/money/card-pay';

// Hotfix 3650: card payments on or off, for the client card tools (field, balance): they hide while cards are paused.
export async function cardPaymentsNow(): Promise<CardPayments | null> {
  if (!(await currentUser())) return null;
  return cardPayments();
}
