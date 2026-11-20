import 'server-only';
import { DbError, rpc } from '@/lib/db/repo';
import { env } from '@/lib/env';
import { photoUrl } from '@/lib/photo';
import { getClasses, getFacts, getFleet, getSettings } from '@/lib/site';
import { torontoInstant } from '@/lib/dates';
import type { ApiResult, BodyOf, Me, ResponseOf, Roles, RouteId } from '@/features/mobile-api/contract';
import { door, rolesOf } from '@/server/door';
import { requestCountry, requestMeta } from '@/server/request';
import { deviceLabel } from '@/features/push/topics';
import { SIGN_IN_PAUSED, signInPaused } from '@/features/auth/sign-in-pause';
import { cleanCode, toE164 } from '@/features/auth/phone';
import { endSession, passwordSession, phoneSession, refreshSession, twoStepSession } from './auth';
import { passkeyAdd, passkeyList, passkeyOptions, passkeyRemove, passkeySignIn, relyingParty } from './passkeys';

// The handlers of the mobile API (release 48; the table is src/features/mobile-api/contract.ts). Each one is a thin call
// to what the website already runs for the same step: a server action, a read of src/server, or the staff door. The
// route (src/app/api/m/v1) has checked the token and runs the handler as that person (src/server/mobile/context.ts),
// so the action finds the signed-in user exactly as it does for a browser, and the database makes the same checks.
// Nothing here decides who may do what.
export interface Ctx<I extends RouteId> {
  user: { id: string; email: string; aal: 'aal1' | 'aal2' } | null;
  token: string;
  params: Record<string, string>;
  query: URLSearchParams;
  body: BodyOf<I>;
  req: Request;
}
/** A handler answers with the envelope, with a plain value (wrapped as ok), or with a Response of an existing route. */
type Out<I extends RouteId> = ApiResult<ResponseOf<I>> | Response | (ResponseOf<I> extends object | null ? ResponseOf<I> : never);
type Handler<I extends RouteId> = (c: Ctx<I>) => Promise<Out<I> | unknown>;
type Handlers = { [I in RouteId]: Handler<I> };

const SR = { role: 'service_role' as const };
const ok = <T>(data: T) => ({ ok: true as const, data });
const fail = (code: string, message: string, status?: number) => ({ ok: false as const, code, message, ...(status ? { status } : {}) });
const me = <I extends RouteId>(c: Ctx<I>) => c.user!;
const asUser = (id: string) => ({ userId: id, role: 'authenticated' as const });

async function rolesAndGate(userId: string, aal: 'aal1' | 'aal2'): Promise<{ roles: Roles; twoStep: boolean }> {
  const roles = (await rolesOf(userId)) as unknown as Roles;
  return { roles, twoStep: roles.two_step_required && aal !== 'aal2' };
}
/** Staff reads and steps: the same line the staff pages hold (two-step, then the role; the database checks the rest). */
async function staff(c: Ctx<RouteId>, kind: 'field' | 'sales') {
  const u = c.user!;
  const { roles, twoStep } = await rolesAndGate(u.id, u.aal);
  if (twoStep) throw new DbError('Two-step sign-in is required.', 'two_step');
  const fns = (roles.va_functions ?? []) as string[];
  if (kind === 'field' && !roles.field && !roles.admin) throw new DbError('Only field staff may do this.', '42501');
  if (kind === 'sales' && !roles.admin && !fns.includes('sales') && !fns.includes('cs') && roles.va !== 'sales' && roles.va !== 'cs') throw new DbError('Only Sales may do this.', '42501');
  const fn = fns.includes('sales') || roles.va === 'sales' ? 'sales' : 'cs';
  return { u, roles, read: <T>(name: string, p: Record<string, unknown> = {}) => door<T>(u.id, roles.admin ? 'admin_read' : 'va_read', name, roles.admin ? p : { ...p, _va: fn }, u.aal) };
}
/** The return link of the signed-in renter's own booking (null for anyone else's number). */
async function returnToken(c: Ctx<RouteId>): Promise<string | null> {
  const u = c.user!;
  const b = await (await import('@/server/portal/data')).findBooking({ id: u.id, email: u.email }, c.params.number!);
  if (!b) return null;
  const t = (await rpc('server_return_link', { p_booking: b.id, p_user: u.id }, { ...SR, skipViewAs: true }).catch(() => null)) as unknown as string | null;
  return typeof t === 'string' && t ? t : null;
}
const instant = (day: string, time: string | undefined) => torontoInstant(day, time ?? '10:00');
/** The phone sends the date and time a person picked ("2026-11-25T10:00"): Toronto time, as on the site. An instant with its own zone passes through. */
const wallClock = (v: string) => { const m = /^(\d{4}-\d{2}-\d{2})T(\d{2}:\d{2})$/.exec(v); return m ? torontoInstant(m[1]!, m[2]!) : v; };
/** An existing route handler of the site, run for this call (the app's token is the session, as for any action here). */
async function passOn(res: Response): Promise<ApiResult<unknown> & { status?: number }> {
  const j = (await res.json().catch(() => ({}))) as Record<string, unknown>;
  if (res.ok && j.ok !== false) { const data = { ...j }; delete data.ok; return ok(data); }
  return { ...fail(res.status === 401 ? 'auth' : 'refused', String(j.message ?? j.error ?? 'Not done. Try again.')), status: res.status >= 400 ? res.status : 400 };
}
/** The same request, as a form the site's own upload route reads (the photo and its fields). */
async function formOf(req: Request, extra: Record<string, string>): Promise<Request> {
  const form = await req.formData();
  for (const [k, v] of Object.entries(extra)) form.set(k, v);
  const headers = new Headers();
  for (const h of ['user-agent', 'x-forwarded-for', 'cf-connecting-ip', 'x-real-ip', 'host']) { const v = req.headers.get(h); if (v) headers.set(h, v); }
  return new Request(req.url, { method: 'POST', body: form, headers });
}

export const HANDLERS: Handlers = {
  // ---------------------------------------------------------------- anyone
  config: async () => {
    const [s, f, phone, { payments }, { nativePushConfig }] = await Promise.all([getSettings(), getFacts(),
      rpc('signin_phone_rules', {} as never, { role: 'anon' }).catch(() => null) as Promise<unknown>, import('@/integrations/payments'), import('@/server/push')]);
    const e = env();
    const p = (phone ?? {}) as { enabled?: boolean; us_allowed?: boolean; code_length?: number };
    const set = s as unknown as { brand_name?: string; phone?: string | null; email?: string | null };
    return ok({
      site_url: e.NEXT_PUBLIC_APP_URL.replace(/\/$/, ''), brand: set.brand_name ?? 'CarmaCars', phone: set.phone ?? null, email: set.email ?? null,
      stripe_publishable_key: e.NEXT_PUBLIC_STRIPE_PUBLISHABLE_KEY ?? null, payments: (await payments()).name,
      phone_sign_in: { enabled: !!p.enabled, us_allowed: !!p.us_allowed, code_length: p.code_length ?? 6 },
      passkeys: { rp_id: relyingParty().id }, push: nativePushConfig() !== null,
      turnstile: e.TURNSTILE_PROVIDER === 'off' ? 'off' as const : e.TURNSTILE_PROVIDER === 'fake' ? 'fake' as const : 'cloudflare' as const,
      min_app_version: '1.0.0',
      rules: { min_age: f.min_renter_age, max_days: f.max_rental_days, notice_minutes: f.booking_min_notice_minutes, licence_classes: [...f.accepted_licence_classes].sort() },
      airports: f.airports.map((a) => ({ code: a.code, name: a.name }))
    });
  },
  cars: async () => {
    const [fleet, classes] = await Promise.all([getFleet(), getClasses()]);
    return ok({ classes, cars: fleet.map((c) => ({ vehicle_id: c.vehicle_id, slug: c.slug, year: c.year, make: c.make, model: c.model, trim: c.trim, classes: c.classes, seats: c.seats, transmission: c.transmission,
      fuel: c.fuel, colour: c.colour, daily_rate_cents: c.daily_rate_cents, insurance_included: !!c.insurance_included,
      cover: c.cover ? { url: photoUrl(c.cover.path), alt: c.cover.alt, width: c.cover.width ?? null, height: c.cover.height ?? null } : null })) });
  },
  'cars.available': async ({ body }) => ok(((await rpc('search_available', { p_pickup: instant(body.from, body.tf), p_return: instant(body.to, body.tt), p_filters: {} })) ?? [])
    .map((a) => ({ vehicle_id: a.vehicle_id, slug: a.slug, daily_rate_cents: a.daily_rate_cents, billable_days: a.billable_days, rental_charge_cents: a.rental_charge_cents, subtotal_cents: a.subtotal_cents,
      hst_cents: a.hst_cents, total_cents: a.total_cents, deposit_cents: a.deposit_cents }))),
  car: async ({ params }) => {
    if (!/^[a-z0-9-]{1,120}$/.test(params.slug ?? '')) return fail('not_found', 'Car not found.', 404);
    const car = (await rpc('car_page', { p_slug: params.slug! })) as unknown as (Record<string, unknown> & { vehicle_id?: string; redirect?: string }) | null;
    if (!car?.vehicle_id) return fail('not_found', 'This car is no longer listed.', 404);
    const from = new Date().toISOString().slice(0, 10);
    const to = new Date(Date.now() + 120 * 86400_000).toISOString().slice(0, 10);
    const [photos, places, calendar, addons] = await Promise.all([
      rpc('vehicle_photos_public', { p_slug: params.slug! }).catch(() => null) as Promise<unknown>,
      rpc('handover_places', { p_vehicle: car.vehicle_id }).catch(() => null) as Promise<unknown>,
      rpc('public_vehicle_calendar', { p_vehicle: car.vehicle_id, p_from: from, p_to: to }).catch(() => []),
      rpc('addons_for_car', { p_vehicle: car.vehicle_id }).catch(() => null) as Promise<unknown>]);
    let list = (Array.isArray(photos) ? photos : ((photos as { photos?: unknown[] } | null)?.photos ?? [])) as Array<{ path?: string; alt?: string; width?: number; height?: number }>;
    if (!list.length && Array.isArray(car.photos)) list = car.photos as typeof list;
    return ok({ car: car as never, photos: list.filter((p) => typeof p?.path === 'string').map((p) => ({ url: photoUrl(p.path!), alt: p.alt ?? null, width: p.width ?? null, height: p.height ?? null })),
      places: places as never, unavailable: (calendar ?? []).map((d) => ({ unavailable_from: d.unavailable_from, unavailable_to: d.unavailable_to })), addons });
  },
  'car.quote': async ({ params, body }) => {
    const car = (await getFleet()).find((c) => c.slug === params.slug);
    if (!car) return fail('not_found', 'This car is no longer listed.', 404);
    return ok(await rpc('quote_booking', { p_vehicle: car.vehicle_id, p_pickup: instant(body.from, body.tf), p_return: instant(body.to, body.tt), p_options: (body.options ?? {}) as never }));
  },

  // ---------------------------------------------------------------- sign-in (the website's own rules, src/server/actions/auth.ts)
  'auth.signIn': async ({ body }) => {
    const allowed = await rpc('server_sign_in_allowed' as never, { p_email: body.email } as never, SR).catch(() => null);
    if (signInPaused(allowed)) return fail('rate_limited', SIGN_IN_PAUSED, 429);
    // two accounts of one person merged (0955): either email signs in, to the kept account
    const alias = (await rpc('server_sign_in_alias', { p_email: body.email }, SR).catch(() => null)) as unknown as { user_id: string; email: string | null } | null;
    let r = alias?.email ? await passwordSession(alias.email, body.password) : null;
    if (!r?.ok) r = await passwordSession(body.email, body.password);
    try {
      const m = await requestMeta();
      await rpc('server_sign_in_event', { p: { email: body.email, user_id: r.ok ? r.session.user.id : null, ok: r.ok, device: deviceLabel(m.userAgent), country: await requestCountry() } }, SR);
    } catch { /* the sign-in goes on */ }
    if (!r.ok) return fail(r.code, r.message, r.code === 'rate_limited' ? 429 : 401);
    const kept = (await rpc('server_sign_in_alias', { p_user: r.session.user.id }, SR).catch(() => null)) as unknown as { user_id: string } | null;
    if (kept && kept.user_id !== r.session.user.id) {
      await endSession(r.session.access_token);
      return fail('merged', 'Your CarmaCars accounts are now one. Sign in with your phone number and a code, or with your other email.', 401);
    }
    await rpc('server_account_email_verified', { p_user: r.session.user.id, p_email: r.session.user.email }, SR).catch(() => undefined);
    return ok(r.session);
  },
  'auth.refresh': async ({ body }) => {
    const r = await refreshSession(body.refresh_token);
    return r.ok ? ok(r.session) : fail(r.code, r.message, r.code === 'busy' ? 503 : 401);
  },
  'auth.phoneStart': async ({ body }) => (await import('@/server/actions/phone-auth')).requestPhoneCode({ phone: body.phone, purpose: 'sign_in', turnstile: body.turnstile ?? null }),
  'auth.phoneVerify': async ({ body }) => {
    const phone = toE164(body.phone);
    const code = cleanCode(body.code);
    if (!phone) return fail('invalid', 'Ask for a code again.');
    if (!code) return { ...fail('invalid', 'Enter the 6-digit code from the text.'), fieldErrors: { code: 'Enter the 6 digits.' } };
    const meta = await requestMeta();
    const lim = (await rpc('server_signin_phone_request', { p: { phone, ip: meta.ip, kind: 'verify' } }, SR)) as unknown as { ok: boolean; reason?: string };
    if (!lim.ok && lim.reason === 'rate_limited') return fail('rate_limited', 'Too many tries. Wait a while, then ask for a new code.', 429);
    const r = await phoneSession(phone, code);
    if (!r.ok) return { ...fail(r.code, r.message, 401), fieldErrors: { code: r.message } };
    const kept = (await rpc('server_sign_in_alias', { p_user: r.session.user.id }, SR).catch(() => null)) as unknown as { user_id: string } | null;
    if (kept && kept.user_id !== r.session.user.id) { await endSession(r.session.access_token); return fail('merged', 'Your CarmaCars accounts are now one. Sign in with your email instead.', 401); }
    try {
      // the number the sign-in service verified (never what was typed): the account's row, then what the number links to
      const done = (await rpc('server_phone_signed_in', { p_user: r.session.user.id, p_phone: r.session.user.phone ?? phone, p_name: (body.name ?? '').trim() || undefined }, { ...SR, requestId: meta.requestId })) as unknown as { needs_name?: boolean };
      return ok({ ...r.session, needs_name: !!done.needs_name });
    } catch (e) {
      if (!(e instanceof DbError)) throw e;
      return fail('refused', e.message);
    }
  },
  'auth.passkeyOptions': async () => ok(await passkeyOptions(null, (await requestMeta()).ip)),
  'auth.passkeyVerify': async ({ body }) => {
    const r = await passkeySignIn(body.challenge_id, body.credential);
    if (!r.ok) return fail(r.code, r.message, 401);
    try {
      const m = await requestMeta();
      await rpc('server_sign_in_event', { p: { email: r.session.user.email, user_id: r.session.user.id, ok: true, device: deviceLabel(m.userAgent), country: await requestCountry() } }, SR);
    } catch { /* the sign-in goes on */ }
    return ok(r.session);
  },
  'auth.twoStep': async ({ token, body }) => {
    const r = await twoStepSession(token, body.code);
    return r.ok ? ok(r.session) : fail(r.code, r.message, r.code === 'rate_limited' ? 429 : 400);
  },
  'auth.signOut': async ({ token }) => { await endSession(token); return ok(null); },

  // ---------------------------------------------------------------- the account
  me: async (c) => {
    const u = me(c);
    const [{ roles, twoStep }, deletion, { pushCard }] = await Promise.all([rolesAndGate(u.id, u.aal),
      rpc('server_account_deletion_state', { p_user: u.id }, SR).catch(() => null) as Promise<unknown>, import('@/server/push')]);
    const card = await pushCard(u.id, true);
    const phone = ((await rpc('my_profile', {}, asUser(u.id)).catch(() => null)) as unknown as { mobile?: string | null } | null)?.mobile ?? null;
    const out: Me = { user: { id: u.id, email: u.email, phone }, aal: u.aal, roles, needs_two_step: twoStep, deletion: deletion as Me['deletion'], push: (card?.state ?? null) as Me['push'], push_available: !!card?.native };
    return ok(out);
  },
  'me.name': async ({ body }) => (await import('@/server/actions/phone-auth')).savePhoneName(body.name, null),
  'me.passkeys': async (c) => ok(await passkeyList(me(c).id)),
  'me.passkeyOptions': async (c) => {
    const u = me(c);
    const name = ((await rolesOf(u.id)) as { name?: string | null }).name ?? null;
    return ok(await passkeyOptions({ id: u.id, email: u.email, name }, (await requestMeta()).ip));
  },
  'me.passkeyAdd': async (c) => ok(await passkeyAdd(me(c).id, c.body.challenge_id, c.body.credential, c.body.device)),
  'me.passkeyRemove': async (c) => ok(await passkeyRemove(me(c).id, c.params.id!)),
  'me.deletionAsk': async ({ body }) => (await import('@/server/actions/account-deletion')).requestAccountDeletion(body.reason ?? ''),
  'me.deletionWithdraw': async () => (await import('@/server/actions/account-deletion')).withdrawAccountDeletion(),
  'me.pushOn': async ({ body }) => (await import('@/server/actions/push')).subscribePush({ kind: 'fcm', token: body.token, platform: body.platform, portal: body.portal, device: body.device }),
  'me.pushOff': async ({ body }) => (await import('@/server/actions/push')).unsubscribePush({ endpoint: `fcm:${body.token}` }),
  'me.pushTest': async () => (await import('@/server/actions/push')).sendTestPush(),
  'me.pushTopics': async ({ body }) => (await import('@/server/actions/push')).savePushTopics(body.topics),
  notices: async (c) => ok((await rpc('my_notifications', { p_limit: 50, p_unread_only: false }, asUser(me(c).id))) ?? []),
  'notices.read': async ({ body }) => (await import('@/server/actions/portal')).markRead(body.ids ?? null),

  // ---------------------------------------------------------------- renter (src/server/actions/portal.ts)
  trips: async (c) => {
    const u = me(c);
    const [list, photos] = await Promise.all([rpc('my_bookings', {}, asUser(u.id)), rpc('my_trip_photos', {}, asUser(u.id)).catch(() => null) as Promise<unknown>]);
    const covers = (photos ?? {}) as Record<string, { path?: string; alt?: string }>;
    return ok(((list ?? []) as unknown as Array<{ vehicle_id: string }>).map((b) => ({ ...b, cover: covers[b.vehicle_id]?.path ? { url: photoUrl(covers[b.vehicle_id]!.path!), alt: covers[b.vehicle_id]!.alt ?? null } : null })));
  },
  trip: async (c) => {
    const u = me(c);
    const { findBooking } = await import('@/server/portal/data');
    const b = await findBooking({ id: u.id, email: u.email }, c.params.number!);
    if (!b) return fail('not_found', 'Booking not found.', 404);
    const [messages, selfPickup] = await Promise.all([
      rpc('my_booking_messages', { p_number: b.booking_number }, asUser(u.id)).then((x) => x ?? []).catch(() => []),
      rpc('server_return_link', { p_booking: b.id, p_user: u.id }, SR).then((x) => Boolean(x)).catch(() => false)]);
    return ok({ booking: b, messages, self_checkin: selfPickup });
  },
  'trip.message': async ({ params, body }) => (await import('@/server/actions/portal')).sendBookingMessage(params.number!, body.body),
  'request.account': async () => (await import('@/server/actions/booking')).requestAccount(),
  'request.submit': async ({ body }) => (await import('@/server/actions/booking')).submitBookingRequest({ data: body.data as never, requestKey: body.requestKey, token: body.turnstile ?? null, bookNow: body.bookNow ?? false }),
  'trip.offer': async ({ params, body }) => {
    const a = await import('@/server/actions/portal');
    if (body.action === 'approve') return a.approveOffer(params.number!, body.version ?? 0);
    if (body.action === 'decline') return a.declineOffer(params.number!, body.note ?? '');
    return a.requestOfferChange(params.number!, body.note ?? '');
  },
  'trip.agreement': async (c) => {
    const u = me(c);
    const [{ findBooking }, { openAgreement, screenBlocks }, { companionOf }, model, { CONSENTS }] = await Promise.all([import('@/server/portal/data'), import('@/server/portal/agreement'),
      import('@/server/portal/blindspot'), import('@/features/agreement/model'), import('@/features/agreement/extra')]);
    let b = await findBooking({ id: u.id, email: u.email }, c.params.number!);
    if (!b) return fail('not_found', 'Booking not found.', 404);
    // the Sign and pay page opens the agreement when the offer is approved and none is open yet; so does this
    if (!b.agreement && b.offer_approved_version) { await openAgreement(b.id, u.id).catch((e) => console.error('mobile: open agreement', e instanceof Error ? e.message : e)); b = (await findBooking({ id: u.id, email: u.email }, c.params.number!)) ?? b; }
    if (!b.agreement) return fail('no_agreement', 'There is no agreement to sign yet.', 409);
    const [blocks, companion, profile, terms] = await Promise.all([screenBlocks(b.id, u.id), b.agreement.status === 'open' ? companionOf(b.id).catch(() => null) : null,
      rpc('my_profile', {}, asUser(u.id)).catch(() => null) as Promise<unknown>,
      import('@/server/agreements/bundle').then(async (m) => m.keyTerms(await m.loadBundle(b!.id, u.id))).catch(() => [])]);
    const comp = companion as { status?: string; document_sha256?: string } | null;
    return ok({ sha: b.agreement.document_sha256, companionSha: comp?.status === 'open' ? comp.document_sha256 ?? null : null, status: b.agreement.status, blocks: blocks as never,
      consents: model.consents().map((x) => ({ code: x.code, title: x.title, text: x.text })), esignConsents: { ...CONSENTS }, statement: model.SIGN_STATEMENT,
      legalName: (profile as { legal_name?: string; full_name?: string } | null)?.legal_name ?? (profile as { full_name?: string } | null)?.full_name ?? '', documentId: b.agreement.document_id,
      terms: (terms as Array<{ code: string; title: string; text: string }>).map((t) => ({ code: t.code, title: t.title, text: t.text })) });
  },
  'trip.esign': async ({ params, body }) => {
    const e = await import('@/server/actions/esign');
    const ctx = { kind: 'renter' as const, number: params.number! };
    if (body.op === 'start') return e.esignStart(ctx);
    if (!body.session) return fail('invalid', 'The signing has ended. Start again.');
    if (body.op === 'send_code') return e.esignSendCode(ctx, body.session, body.channel ?? 'sms');
    if (body.op === 'check_code') return e.esignCheckCode(ctx, body.session, body.code ?? '');
    if (body.op === 'use_saved') return e.esignUseSaved(ctx, body.session, body.part ?? 'signature');
    if (!body.step) return fail('invalid', 'Nothing to record.');
    return e.esignStep(ctx, body.session, body.step as never);
  },
  'trip.sign': async ({ params, body }) => (await import('@/server/actions/portal')).signAgreement(params.number!, body),
  'trip.payStart': async ({ params }) => (await import('@/server/actions/portal')).startPayment(params.number!),
  'trip.payFinish': async ({ params, body }) => (await import('@/server/actions/portal')).finalizePayment(params.number!, body.intentId),
  'trip.upload': async ({ params, body }) => (await import('@/server/actions/portal')).createUpload(params.number!, body.kind, body.driverId ?? null, body.contentType, body.size),
  'upload.confirm': async ({ body }) => (await import('@/server/actions/portal')).confirmUpload(body.ticket, (body.details ?? null) as Record<string, string> | null),
  'trip.licence': async ({ params, body }) => (await import('@/server/actions/portal')).saveLicence(params.number!, body),
  'trip.checkinPhoto': async (c) => {
    const u = me(c);
    const b = await (await import('@/server/portal/data')).findBooking({ id: u.id, email: u.email }, c.params.number!);
    if (!b) return fail('not_found', 'Booking not found.', 404);
    const { POST } = await import('@/app/api/handover-photo/route');
    return passOn(await POST(await formOf(c.req, { scope: 'self-pickup', id: b.id })));
  },
  'trip.checkin': async ({ params, body }) => (await import('@/server/actions/self-handover')).selfPickup({ number: params.number!, at: body.at, odometer_km: body.odometer_km, fuel_pct: body.fuel_pct, note: body.note,
    photos: body.photos.map((p) => ({ bucket: p.bucket, path: p.path, angle: p.angle ?? null })), reading: body.reading }),
  // the renter's own check-out, "I've returned the car" (0532, 0545): the booking's own return link, found for its renter only
  'trip.returnPhoto': async (c) => {
    const token = await returnToken(c);
    if (!token) return fail('not_found', 'Booking not found.', 404);
    const { POST } = await import('@/app/api/returned/[token]/photo/route');
    return passOn(await POST(await formOf(c.req, {}), { params: Promise.resolve({ token }) }));
  },
  'trip.return': async (c) => {
    const token = await returnToken(c);
    if (!token) return fail('not_found', 'Booking not found.', 404);
    const { POST } = await import('@/app/api/returned/[token]/route');
    const headers = new Headers({ 'content-type': 'application/json' });
    for (const h of ['user-agent', 'x-forwarded-for', 'cf-connecting-ip', 'host']) { const v = c.req.headers.get(h); if (v) headers.set(h, v); }
    return passOn(await POST(new Request(c.req.url, { method: 'POST', headers, body: JSON.stringify(c.body) }), { params: Promise.resolve({ token }) }));
  },
  'trip.extendPreview': async ({ params, body }) => (await import('@/server/actions/portal')).previewExtension(params.number!, wallClock(body.newReturn)),
  'trip.extend': async ({ params, body }) => (await import('@/server/actions/portal')).requestExtension(params.number!, wallClock(body.newReturn), body.note ?? ''),
  'trip.extendPay': async ({ params }) => (await import('@/server/actions/portal')).payExtension(params.number!, params.id!),
  'trip.cancelPreview': async (c) => {
    const u = me(c);
    const d = await import('@/server/portal/data');
    const b = await d.findBooking({ id: u.id, email: u.email }, c.params.number!);
    if (!b) return fail('not_found', 'Booking not found.', 404);
    return ok(await d.cancellationPreview({ id: u.id, email: u.email }, b.id));
  },
  'trip.cancel': async ({ params, body }) => (await import('@/server/actions/portal')).cancelBooking(params.number!, body.typed),

  // ---------------------------------------------------------------- field staff (src/server/actions/field.ts)
  'field.today': async (c) => { const s = await staff(c, 'field'); const day = c.query.get('day'); return ok(await door(s.u.id, 'field_read', 'today', day && /^\d{4}-\d{2}-\d{2}$/.test(day) ? { day } : {}, s.u.aal)); },
  'field.jobs': async (c) => { const s = await staff(c, 'field'); return ok(await door(s.u.id, 'field_read', 'jobs', {}, s.u.aal)); },
  'field.job': async (c) => {
    const s = await staff(c, 'field');
    const j = await door(s.u.id, 'field_read', 'job', { id: c.params.id }, s.u.aal).catch(() => null);
    return j ? ok(j) : fail('not_found', 'That job is not one of yours.', 404);
  },
  'field.shifts': async (c) => { const s = await staff(c, 'field'); return ok(await door(s.u.id, 'field_read', 'my_shifts', {}, s.u.aal)); },
  'field.act': async ({ body }) => (await import('@/server/actions/field')).fieldAct(body.action, body.p),
  'field.clock': async ({ body }) => (await import('@/server/actions/field')).fieldClock(body.what, body.note ?? null, body.loc ?? null, body.reason ?? null, (body.openReasons ?? null) as Record<string, string> | null),
  'field.photo': async (c) => {
    const { POST } = await import('@/app/api/field/upload/route');
    return passOn(await POST(await formOf(c.req, { job: c.params.id! })));
  },

  // ---------------------------------------------------------------- sales (src/server/actions/sales-leads.ts, /api/staff/phone)
  'sales.leads': async (c) => {
    const s = await staff(c, 'sales');
    const { listQuery } = await import('@/features/sales-leads/model');
    const q = listQuery(Object.fromEntries(c.query) as Record<string, string | undefined>);
    const [leads, dashboard] = await Promise.all([s.read('sales_leads', q), s.roles.admin ? null : s.read('sales_dashboard').catch(() => null)]);
    return ok({ leads, dashboard });
  },
  'sales.lead': async (c) => {
    const s = await staff(c, 'sales');
    const d = await s.read('sales_lead', { id: c.params.id }).catch(() => null);
    return d ? ok(d) : fail('not_found', 'Lead not found.', 404);
  },
  'sales.leadAct': async ({ body }) => (await import('@/server/actions/sales-leads')).leadAct(body.action, body.p),
  'sales.phoneButtons': async (c) => {
    const { GET } = await import('@/app/api/staff/phone/route');
    const u = new URL(c.req.url); u.search = '?what=phone_buttons';
    return passOn(await GET(new Request(u, { headers: c.req.headers })));
  },
  // the number stays masked: the app sends what it was shown ("(647) •••-••00") and the server finds the real one
  'sales.phone': async (c) => {
    const { POST } = await import('@/app/api/staff/phone/route');
    const headers = new Headers({ 'content-type': 'application/json' });
    for (const h of ['user-agent', 'x-forwarded-for', 'cf-connecting-ip', 'host']) { const v = c.req.headers.get(h); if (v) headers.set(h, v); }
    const r = await POST(new Request(c.req.url, { method: 'POST', headers, body: JSON.stringify(c.body) }));
    return passOn(r);
  },
  'sales.offerRead': async ({ body }) => (await import('@/server/actions/offers')).offersRead(body.what, body.p),
  'sales.offer': async ({ body }) => (await import('@/server/actions/offers')).offersDo(body.action, body.p),

  // ---------------------------------------------------------------- owner (src/server/owner/data.ts)
  'owner.home': async (c) => {
    const u = me(c);
    const d = await import('@/server/owner/data');
    const home = await d.ownerHome({ id: u.id, email: u.email });
    if (!home) return fail('not_owner', 'This account is not an owner account.', 403);
    const [view, mtd] = await Promise.all([d.ownerView({ id: u.id, email: u.email }, home), d.ownerMonthToDate({ id: u.id, email: u.email })]);
    const photo = Object.fromEntries(Object.entries(view.photo).map(([k, p]) => [k, p ? { url: photoUrl(p.path), alt: p.alt } : null]));
    return ok({ home, live: view.live, months: view.months, photo, month_to_date: mtd });
  },
  'owner.bookings': async (c) => {
    const u = me(c);
    const d = await import('@/server/owner/data');
    if (!(await d.ownerHome({ id: u.id, email: u.email }))) return fail('not_owner', 'This account is not an owner account.', 403);
    return ok(await d.ownerBookings({ id: u.id, email: u.email }, c.query.get('from') ?? undefined, c.query.get('to') ?? undefined));
  },
  'owner.statement': async (c) => { const u = me(c); return ok(await (await import('@/server/owner/data')).ownerStatement({ id: u.id, email: u.email }, c.params.id!)); }
};
