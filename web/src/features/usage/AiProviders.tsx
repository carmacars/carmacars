import { Card, t } from '@/features/admin/ui';
import { Act } from '@/features/admin/Act';

// Settings > Usage (r48 part AI, migration 3095): every AI feature at no cost. Each call goes to Workers AI (the free
// allowance), then the server's own models, then Gemini's free tier when the feature is not private. Per feature: its
// order (an Admin may change it), the provider of its last call, and its calls of the last 7 days by provider. The server's
// models are "warming up" until they are downloaded and checked.
export type AiRoute = 'auto' | 'no_gemini' | 'local_first' | 'workers_ai_only' | 'local_only';
export interface AiProvidersData {
  local: { text: boolean; vision: boolean; speech: boolean; gemini: boolean; text_model: string | null; vision_model: string | null; speech_model: string | null; detail: string | null; at: string; fresh: boolean } | null;
  features: Array<{ purpose: string; label: string; kind: 'text' | 'vision' | 'speech'; private: boolean; route: AiRoute; last_provider: string | null; last_ok: boolean | null; last_at: string | null;
    week: { workers_ai: number; local: number; gemini: number; claude: number }; failed_week: number }>;
}

export const PROVIDER: Record<string, string> = { workers_ai: 'Workers AI', local: 'Server model', gemini: 'Gemini', claude: 'Claude', none: 'None connected' };
export const ROUTE: Record<AiRoute, string> = {
  auto: 'Workers AI, then the server, then Gemini',
  no_gemini: 'Workers AI, then the server (never Gemini)',
  local_first: 'The server first, then Workers AI, then Gemini',
  workers_ai_only: 'Workers AI only',
  local_only: 'The server only'
};
/** The order as it applies to a feature: Gemini is never used for a private one, whatever the route says. */
export function routeText(route: AiRoute, priv: boolean): string {
  const s = ROUTE[route] ?? ROUTE.auto;
  return priv ? s.replace(/, then Gemini$/, '').replace(' (never Gemini)', '') : s;
}
const label = (f: { label: string; purpose: string }) => (f.label && f.label !== f.purpose ? f.label : f.purpose.replace(/_/g, ' ').replace(/^./, (c) => c.toUpperCase()));
const n = (v: number) => Math.round(v).toLocaleString('en-US');
const state = (on: boolean | undefined, fresh: boolean | undefined) => (!fresh ? 'not seen in the last 15 minutes' : on ? 'ready' : 'warming up');

export function AiProviders({ ai }: { ai: AiProvidersData }) {
  const l = ai.local;
  return (
    <Card title="AI providers by feature" id="usage-ai-providers" testId="usage-ai-providers"
      aside={<span className="small" data-testid="usage-ai-local-state">{l ? `Server models: ${l.fresh && (l.text || l.vision || l.speech) ? 'on' : 'warming up'}` : 'Server models: not set up here'}</span>}>
      <p className="small" style={{ maxWidth: '52rem' }}>Every AI feature works at no cost. A call goes to Workers AI while its free allowance has room, then to the models on CarmaCars&apos; own server (free and private, slower), then to Gemini&apos;s free tier.
        Identity documents, call and interview recordings and the text made from them never go to Gemini. Change a feature&apos;s order below.</p>
      {l && (
        <dl className="pt-dl ad-kv" data-testid="usage-ai-local">
          <div><dt>Text model</dt><dd data-testid="usage-ai-local-text">{l.text_model ?? 'not set'}: {state(l.text, l.fresh)}</dd></div>
          <div><dt>Vision model</dt><dd data-testid="usage-ai-local-vision">{l.vision_model ?? 'not set'}: {state(l.vision, l.fresh)}</dd></div>
          <div><dt>Speech to text</dt><dd data-testid="usage-ai-local-speech">{l.speech_model ?? 'whisper.cpp'}: {state(l.speech, l.fresh)}</dd></div>
          <div><dt>Gemini</dt><dd>{l.gemini ? 'Set (free tier, for what is not private)' : 'Not set'}</dd></div>
          <div><dt>Checked</dt><dd>{t(l.at)}{l.detail && l.detail !== 'ready' ? ` (${l.detail})` : ''}</dd></div>
        </dl>)}
      <div className="table-scroll ad-scroll" tabIndex={0} role="region" aria-label="AI providers by feature">
        <table className="ad-table ad-table--dense" data-testid="usage-ai-providers-table">
          <thead><tr><th scope="col">Feature</th><th scope="col">Order</th><th scope="col">Last call</th><th scope="col" className="num">Workers AI, 7 days</th><th scope="col" className="num">Server, 7 days</th>
            <th scope="col" className="num">Gemini, 7 days</th><th scope="col" className="num">Failed, 7 days</th><th scope="col"><span className="vh">Change</span></th></tr></thead>
          <tbody>
            {ai.features.map((f) => (
              <tr key={f.purpose} data-testid={`usage-ai-provider-${f.purpose}`}>
                <td>{label(f)}{f.private ? <span className="small muted"> (private)</span> : null}</td>
                <td className="small">{routeText(f.route, f.private)}</td>
                <td className="small" data-testid={`usage-ai-provider-${f.purpose}-last`}>{f.last_provider ? `${PROVIDER[f.last_provider] ?? f.last_provider}${f.last_ok ? '' : ' (failed)'}${f.last_at ? `, ${t(f.last_at)}` : ''}` : 'No call yet'}</td>
                <td className="num">{n(f.week.workers_ai)}{f.week.claude ? ` (+${n(f.week.claude)} Claude)` : ''}</td><td className="num">{n(f.week.local)}</td><td className="num">{n(f.week.gemini)}</td><td className="num">{n(f.failed_week)}</td>
                <td>
                  <Act action="ai_route_save" label="Order" title={`${label(f)}: the order of AI providers`} testId={`usage-ai-route-${f.purpose}`} payload={{ purpose: f.purpose }}
                    refresh={['/admin/settings/usage']} done="Saved."
                    fields={[{ name: 'route', label: 'Ask in this order', type: 'select', value: f.route, required: true,
                      options: (Object.keys(ROUTE) as AiRoute[]).filter((r) => !(f.private && r === 'no_gemini')).map((r) => [r, routeText(r, f.private)] as [string, string]),
                      hint: f.private ? 'Private: never sent to Gemini.' : 'Gemini is used only when the others cannot answer.' }]} />
                </td>
              </tr>))}
          </tbody>
        </table>
      </div>
    </Card>
  );
}
