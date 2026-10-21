import { QuoError, sendText } from '@/features/phone/quo-api';
import type { PhoneLine } from './types';

// Quo's public API with the CarmaCars workspace's key (a Worker secret). Only this key is ever used here.
export function quoLine(key: string | undefined, base?: string): PhoneLine {
  return {
    name: 'quo', ready: !!key,
    async sendText(p) {
      if (!key) return { ok: false, id: null, error: 'QUO_API_KEY is not set', permanent: false };
      try {
        const r = await sendText({ key, base }, { from: p.from, to: p.to, content: p.body });
        return { ok: true, id: r.id };
      } catch (e) {
        return { ok: false, id: null, error: e instanceof Error ? e.message : String(e), permanent: e instanceof QuoError ? e.permanent : false };
      }
    }
  };
}
