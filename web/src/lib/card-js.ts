// r50: the card box of every card form, for the processor in use. Stripe: Stripe.js and its Payment Element (stripe-js.ts).
// Helcim: HelcimPay.js (secure.helcim.app), whose card form opens in Helcim's own modal when the person presses Pay; the
// card number never touches our pages either way. Both are given the same shape (elements, create, mount, confirmPayment,
// confirmSetup), so the forms change only the line that loads it. The Helcim modal's answer is checked on our server
// (/api/payments/helcim/confirm) before the form goes on; a declined card gets a new checkout session for the next try.
import { loadStripe } from '@/lib/stripe-js';

type Confirmed = { error?: { message?: string }; paymentIntent?: { id: string; status: string }; setupIntent?: { id: string; status: string } };
interface HelcimElements { __helcim: true; token: string }
export interface CardJs {
  elements(o: { clientSecret: string; appearance?: unknown }): { create(type: 'payment', o?: unknown): { mount(el: HTMLElement): void; destroy(): void } };
  confirmPayment(o: { elements: unknown; redirect: 'if_required'; confirmParams: Record<string, unknown> }): Promise<Confirmed>;
  confirmSetup(o: { elements: unknown; redirect: 'if_required'; confirmParams: Record<string, unknown> }): Promise<Confirmed>;
  /** Stripe.js only: the brand before charging (Helcim: the server checks it after) */
  createPaymentMethod?(o: { elements: unknown; params?: Record<string, unknown> }): Promise<{ error?: { message?: string }; paymentMethod?: { card?: { brand?: string } } }>;
}

declare global {
  interface Window { appendHelcimPayIframe?: (checkoutToken: string, allowExit?: boolean) => void; removeHelcimPayIframe?: () => void }
}

const HELCIM_JS = 'https://secure.helcim.app/helcim-pay/services/start.js';
let helcimLoading: Promise<void> | null = null;
function loadHelcimScript(): Promise<void> {
  if (window.appendHelcimPayIframe) return Promise.resolve();
  helcimLoading ??= new Promise<void>((resolve, reject) => {
    const s = document.createElement('script');
    s.src = HELCIM_JS;
    s.onload = () => (window.appendHelcimPayIframe ? resolve() : reject(new Error('Helcim did not load')));
    s.onerror = () => { helcimLoading = null; reject(new Error('Helcim did not load')); };
    document.head.appendChild(s);
  });
  return helcimLoading;
}

async function post(body: Record<string, unknown>): Promise<{ ok: boolean; id?: string; status?: string; checkoutToken?: string | null; error?: string }> {
  const r = await fetch('/api/payments/helcim/confirm', { method: 'POST', headers: { 'content-type': 'application/json' }, body: JSON.stringify(body), credentials: 'same-origin' });
  return (await r.json().catch(() => ({ ok: false }))) as { ok: boolean; id?: string; status?: string; checkoutToken?: string | null; error?: string };
}

/** Opens the Helcim modal for this checkout session and waits for its answer. */
function openModal(token: string): Promise<{ status: 'SUCCESS' | 'ABORTED' | 'HIDE'; message: unknown }> {
  return new Promise((resolve) => {
    const name = `helcim-pay-js-${token}`;
    const on = (e: MessageEvent) => {
      if (e.origin !== 'https://secure.helcim.app') return;
      const d = e.data as { eventName?: string; eventStatus?: string; eventMessage?: unknown } | null;
      if (!d || d.eventName !== name) return;
      if (d.eventStatus === 'SUCCESS' || d.eventStatus === 'ABORTED' || d.eventStatus === 'HIDE') {
        window.removeEventListener('message', on);
        resolve({ status: d.eventStatus, message: d.eventMessage });
      }
    };
    window.addEventListener('message', on);
    window.appendHelcimPayIframe!(token, true);
  });
}

function helcimJs(): CardJs {
  const confirm = async (o: { elements: unknown }, setup: boolean): Promise<Confirmed> => {
    const el = o.elements as HelcimElements;
    await loadHelcimScript();
    const answer = await openModal(el.token);
    window.removeHelcimPayIframe?.();
    if (answer.status === 'SUCCESS') {
      const r = await post({ checkoutToken: el.token, message: answer.message });
      if (!r.ok || !r.id) return { error: { message: r.error ?? 'We could not confirm the card yet. Wait a moment and reload the page: you are never charged twice.' } };
      return setup ? { setupIntent: { id: r.id, status: r.status ?? 'succeeded' } } : { paymentIntent: { id: r.id, status: r.status ?? 'succeeded' } };
    }
    if (answer.status === 'ABORTED') {
      // Helcim's session is used up by a declined card: the next try gets a new one
      const r = await post({ checkoutToken: el.token, renew: true }).catch(() => null);
      if (r?.checkoutToken) el.token = r.checkoutToken;
      return { error: { message: typeof answer.message === 'string' && answer.message.length < 160 ? `Your card was declined: ${answer.message}` : 'Your card was declined. Try again, or use another card.' } };
    }
    return { error: { message: 'The card window was closed. Nothing was charged.' } };
  };
  return {
    elements: ({ clientSecret }) => {
      const el: HelcimElements = { __helcim: true, token: clientSecret };
      return Object.assign(el, {
        create: () => ({
          mount(node: HTMLElement) {
            node.replaceChildren();
            const p = document.createElement('p');
            p.className = 'small muted';
            p.dataset.testid = 'helcim-card';
            p.textContent = 'Your card details open in Helcim\'s secure window when you press the button. CarmaCars never sees your card number.';
            node.appendChild(p);
            void loadHelcimScript().catch(() => undefined);
          },
          destroy() { /* nothing mounted in a frame */ }
        })
      });
    },
    confirmPayment: (o) => confirm(o, false),
    confirmSetup: (o) => confirm(o, true)
  };
}

/** The card box for the processor the server says is in use (StartedPayment.provider). */
export async function loadCardJs(provider: string, stripeKey: string | null | undefined): Promise<CardJs> {
  if (provider === 'helcim') return helcimJs();
  if (provider === 'stripe' && stripeKey) return (await loadStripe(stripeKey)) as unknown as CardJs;
  throw new Error('Card payments are not available right now');
}

/** Whether a started payment has a real card box to show (not the fake test form, not cards off). */
export const hasCardBox = (provider: string, stripeKey: string | null | undefined): boolean => provider === 'helcim' || (provider === 'stripe' && !!stripeKey);
