import { NextResponse } from 'next/server';
import { API_PREFIX, APP_HEADER, ROUTES, bearerOf, compareVersions, matchRoute, type RouteDef, type RouteId } from '@/features/mobile-api/contract';
import { parse } from '@/features/mobile-api/shape';
import { answerOf, answerOfError, type Answer } from '@/features/mobile-api/respond';
import { asMobileCall } from '@/server/mobile/context';
import { tokenUser } from '@/server/mobile/auth';
import { HANDLERS, type Ctx } from '@/server/mobile/routes';
import { maskPersonal } from '@/lib/db/friendly';

// The mobile API, version 1 (release 48): what the native app (apps/carmacars-native) calls. The table of routes is
// src/features/mobile-api/contract.ts; the handlers are src/server/mobile/routes.ts. This file is the door:
//   1. finds the route (404 otherwise) and reads the JSON body against the route's shape;
//   2. checks the access token ("Authorization: Bearer", the same token the website keeps in its session cookie) with
//      the sign-in service's public keys. No cookie is ever read here, so a browser on another site has nothing to send:
//      the cross-site check of every request (src/lib/security/request-guard.ts) still runs first;
//   3. runs the handler as that person. Handlers are the website's own server actions and reads, so the same database
//      checks decide what is allowed.
// Answers are JSON: { ok: true, data } or { ok: false, code, message, fieldErrors? }, never cached.
export const dynamic = 'force-dynamic';
const HEAD = { 'cache-control': 'no-store', 'x-content-type-options': 'nosniff' };
/** The oldest app this server still answers (raise it only when an old build would do harm; the app then says "Update"). */
const MIN_APP = '1.0.0';
const MAX_JSON = 1_500_000;
const json = (a: Answer) => NextResponse.json(a.body, { status: a.status, headers: HEAD });
type Params = { params: Promise<{ path: string[] }> };

async function handle(req: Request, { params }: Params): Promise<Response> {
  let segments: string[];
  try { segments = ((await params).path ?? []).map((s) => decodeURIComponent(s)); } catch { segments = []; }
  const m = matchRoute(req.method, segments);
  if (!m) return json({ status: 404, body: { ok: false, code: 'not_found', message: 'Unknown call.' } });
  const def = ROUTES[m.id] as RouteDef<unknown>;
  const app = (req.headers.get(APP_HEADER) ?? '').split(' ')[0] ?? '';
  if (app && /^\d+\.\d+\.\d+$/.test(app) && compareVersions(app, MIN_APP) < 0) return json({ status: 426, body: { ok: false, code: 'update', message: 'Update the CarmaCars app to continue.' } });

  const token = bearerOf(req.headers.get('authorization'));
  const user = token ? await tokenUser(token).catch(() => null) : null;
  if (def.auth === 'user' && !user) return json({ status: 401, body: { ok: false, code: token ? 'expired' : 'auth', message: 'Sign in first.' } });

  let body: unknown;
  if (def.body) {
    if (Number(req.headers.get('content-length') ?? 0) > MAX_JSON) return json({ status: 413, body: { ok: false, code: 'too_large', message: 'That is too large to send.' } });
    const text = await req.text().catch(() => '');
    if (text.length > MAX_JSON) return json({ status: 413, body: { ok: false, code: 'too_large', message: 'That is too large to send.' } });
    let raw: unknown;
    try { raw = text ? JSON.parse(text) : {}; } catch { return json({ status: 400, body: { ok: false, code: 'invalid', message: 'Send the fields as JSON.' } }); }
    const p = parse(def.body, raw);
    if (!p.ok) return json({ status: 400, body: { ok: false, code: 'invalid', message: p.message, fieldErrors: { [p.field || 'body']: p.message } } });
    body = p.data;
  }

  const ctx = { user, token: user ? token! : '', params: m.params, query: new URL(req.url).searchParams, body, req } as Ctx<RouteId>;
  try {
    const out = await asMobileCall(ctx.token, () => (HANDLERS[m.id] as (c: Ctx<RouteId>) => Promise<unknown>)(ctx));
    return out instanceof Response ? out : json(answerOf(out));
  } catch (e) {
    const a = answerOfError(e);
    // ids and the route only: never a body, an address or a name (docs/engineering-rules.md)
    if (a.unexpected) console.error(`mobile api ${API_PREFIX}${def.path}`, e instanceof Error ? `${e.name}: ${maskPersonal(e.message).slice(0, 200)}` : 'error');
    return json(a);
  }
}

export const GET = handle;
export const POST = handle;
export const PUT = handle;
export const DELETE = handle;
