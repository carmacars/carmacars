# Calls in the site: the weekly townhall and interview calls on the company's own media server (Release 50: 5010, 5011)

Migrations `5010_r50_in_site_calls.sql` and `5011_r50_calls_guides.sql` (generator `supabase/seed/5011_gen_guides.mjs`),
`web/src/features/calls/` (`CallRoom.tsx`, `adapter.ts`, `livekit-adapter.ts`, `fake-adapter.ts`, `token.ts`,
`TownhallLive.tsx`, `calls.css`), `web/src/server/calls/`, `web/src/app/api/calls/` (`token`, `presence`, `webhook`,
`guest`, `live`, `fake`), the pages `/staff/townhall/live`, `/admin/townhall/live`, `/admin/hiring/<id>/call`,
`/call/i/<token>`, `infra/vps/livekit/`, `infra/vps/systemd/carmacars-livekit-tls.*`, `scripts/deploy/web-vps.sh`
(`calls_env`), `web-vps-remote.sh` (`livekit_up`), `cf-site.sh media`. Tests: `supabase/tests/99_r50_in_site_calls.sql`,
`web/src/features/calls/token.test.ts`, `adapter.test.ts`, `web/src/lib/security/csp.test.ts`, e2e
`web/tests/e2e/calls-in-site.spec.ts` (fake media).

## Platform

- **LiveKit** (Apache 2.0, self-hosted) on the VPS, `livekit/livekit-server:v1.13.10`, host networking, 1 GB and 2 CPUs,
  OOM-killed before the database. No vendor account, no meet.jit.si (its embed stops after 5 minutes).
- Ports opened by the deploy (ufw, as root on the server): **7881/tcp** (WebRTC over TCP), **50000-50199/udp** (media),
  **3478/udp** (TURN), **5349/tcp** (TURN over TLS; 443 is Caddy's). The signal port 7880 is never public: Caddy serves
  `wss://meet.carmacars.ca` (Let's Encrypt, a **DNS-only** record that `cf-site.sh media` creates through the API) and
  proxies to 7880 over the Docker gateway, which ufw allows from the Docker networks only.
- TURN over TLS uses Caddy's certificate for the media host, copied by `up.sh` on each deploy and daily
  (`carmacars-livekit-tls.timer`); until the first certificate exists, TURN runs over UDP only.
- **No new secret**: the API key and secret are derived from `LINK_SIGNING_KEY` at deploy (`calls_env`), written to the
  site's settings (`CALLS_PROVIDER=livekit`, `LIVEKIT_URL`, `LIVEKIT_API_KEY`, `LIVEKIT_API_SECRET`) and to the server's
  `livekit.yaml` (mode 600). LiveKit's webhook goes to `https://carmacars.ca/api/calls/webhook`, signed with them.
- **Tokens**: minted on the server per person and room (`token.ts`, HS256, 10 minutes to connect), only after the
  database said who may join (`door call_join`: staff and Admins for the townhall, from 15 minutes before for staff;
  Admins only for interviews) or, for a candidate, their link's signed session. The presenter and the interviewer get
  `roomAdmin`; everyone may talk, show a camera, share a screen and send data.
- **Provider seam**: `CALLS_PROVIDER` livekit, fake (no media; the site's relay `/api/calls/fake` carries who is in and
  the data messages, local and CI only) or off. `mediaConfig()` never answers fake in production.
- **CSP**: the media host's wss and https origins are added to `connect-src` on the staff, Admin and `/call/` pages only.

## The call page

- Video tiles (a shared screen first, then the presenter or interviewer), **Mute**, **Camera off**, **Share screen**
  (hidden on phones), **Raise hand**, **Chat** (to everyone, not kept), **Leave**. Phone widths 320 and 375: tiles two
  across, controls wrap, every control 44 px tall, no sideways scroll.
- **Townhall**: the week's deck beside the video. The presenter (an Admin) moves the slide for everyone over the data
  channel (and repeats it every 8 seconds and on each newcomer's ask); anyone may browse with Previous and Next and come
  back with **Back to the presenter**.
- **Attendance by itself**: `app.call_event` (from the webhook and the page's own join, 30-second heartbeat and leave)
  records `call_participants` (first join, last join and leave, seconds, visits) and the townhall's
  `townhall_attendance` (method `call`, confirmed, `joined_at`, `left_at`, `seconds`). The missed counts and the
  two-in-a-row lock keep working unchanged; a meeting already closed with the person absent is corrected.
- **Admin live list** (People): in the call now, who left (minutes) and who of the team has not joined (`call_live`,
  every 10 seconds).
- **Interviews**: one private room per slot (`iv-<slot>`). Booking a video call writes the in-site link
  (`/call/i/<64 hex>`) in place of the Jitsi one (before the Google Meet trigger, which then leaves it alone); only its
  SHA-256 is kept (`call_guest_links`). Opening the page uses nothing (an email scanner may open it); **Join the call**
  (a POST) binds the link to that browser's signed session cookie (`cc-call-guest`, until 30 minutes after the call);
  another browser is refused, a moved or cancelled call's link stops working. It opens 15 minutes before the slot.
  The interviewer opens `/admin/hiring/<id>/call` (**Join the interview call** on the candidate's page, the calls list
  and Today; an Admin never opens the candidate's own link): the candidate's details, answers, the role's questions
  and the rubric beside the video, with **No show** and **Not hired**; Hire stays on the candidate's page.
- **Fallback**: Program settings `calls_mode` (`in_site` default, `link`). **Switch to the outside link** on the
  Townhall page (Admin) sends every Join to the old outside link until **Back to the call in the site**.
- **Recording**: not in this release (see Follow-up). The Recordings card keeps taking a link.
- **Guide me**: `join-townhall` (everyone) and `interview-call` (Admin).
- **Security**: three tables with RLS, `admin_all` and the audit trigger; functions security definer with
  `search_path = public, app, pg_temp`, the server role only; webhooks checked (issuer, HS256, the body's SHA-256).

## Follow-up: recording

LiveKit Egress records a room by running a headless Chrome (2 to 4 GB per recording) and needs Redis. The VPS-4's
memory is already budgeted (database about 13.5 GB, site 3 GB, local AI 7.5 GB), so it is not switched on. To add it:
`livekit/egress` and `redis` in `infra/vps/livekit/docker-compose.yml` (egress capped at 3 GB, started only for the
townhall), `redis:` in `livekit.yaml`, a `roomRecord` grant for the presenter, an Admin **Record** button calling
`StartRoomCompositeEgress` (Twirp, signed like the tokens) with S3 output to Storage, and the file's link saved by
`townhall_recording` (the existing Recordings card). Or a second, smaller server for egress only.

## Guides

`va/your-workday`, `field/start-here`, `admin/hiring` (migration 5011).
