'use client';
import { createContext, useCallback, useContext, useEffect, useRef, useState, useTransition, type ReactNode } from 'react';
import { useRouter } from 'next/navigation';
import { opsAct } from '@/server/actions/ops';
import { claimFree, claimView, type ClaimState } from './claim';

// "I'm answering this" (migration 0177). The provider holds who is answering the request on this page: opening the request
// to answer it (the Review and offer tab) takes it, the claim renews every minute while the person works (typing, clicking),
// and ends when they leave the page or send or decline. Everyone else sees "Being answered by <name> since <time>" and the
// answer buttons inside a ClaimGate are off; an Admin may take it over. The database decides every step (app.request_claim)
// and refuses a second answer whatever the screen shows.
// 2026-10-28: a request that opens while the page is up (the Sales wait ends, or the other person's claim runs out) is looked
// at again right then, and the first touch or key on the page takes it for the person who opened it to answer it; a gate that
// is off says why and when it comes on, beside the buttons (ClaimGate explain).
const POLL_MS = 30_000;
// the end-to-end tests keep one screen stale on purpose (a later poll would bring it up to date)
const pollMs = () => { try { return Number((window as unknown as { __ccClaimPollMs?: number }).__ccClaimPollMs) || POLL_MS; } catch { return POLL_MS; } };
interface Ctx { state: ClaimState | null; takeOver: () => void; pending: boolean; problem: string | null }
const C = createContext<Ctx | null>(null);

export function RequestClaim({ booking, status, answering, va, children }: {
  booking: string; status: string;
  /** this person opened the request to answer it: take the claim */
  answering: boolean;
  /** the assistant's function (their door), or null for an Admin */
  va?: string | null; children: ReactNode;
}) {
  const router = useRouter();
  const [state, setState] = useState<ClaimState | null>(null);
  const [problem, setProblem] = useState<string | null>(null);
  const [pending, start] = useTransition();
  const active = useRef(false);
  const mine = useRef(false);
  const latest = useRef<ClaimState | null>(null);
  const taking = useRef(false);
  const extra = va ? { _va: va } : {};

  const call = useCallback(async (name: 'request_claim' | 'request_state', p: Record<string, unknown> = {}) => {
    const r = await opsAct<ClaimState>(name, { booking, ...extra, ...p });
    if (!r.ok) { setProblem(r.message); return null; }
    setProblem(null);
    setState((was) => {
      // answered meanwhile (by this person in another tab, or by someone else): show the page as it is now
      if (was && was.status === 'requested' && r.data.status !== 'requested') router.refresh();
      return r.data;
    });
    mine.current = Boolean(r.data.claim?.mine);
    latest.current = r.data;
    return r.data;
  // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [booking, va, router]);

  useEffect(() => {
    if (status !== 'requested') return;
    let gone = false;
    const first = setTimeout(() => { void call(answering ? 'request_claim' : 'request_state', answering ? { mode: 'claim' } : {}); }, 0);
    // working on the page: renews one's own claim at the next look, and takes a request nobody holds at once
    const mark = () => {
      active.current = true;
      if (answering && !mine.current && !taking.current && claimFree(latest.current)) {
        taking.current = true;
        // a touch that leaves the page (a tab, a link) while the claim is on its way: let it go again
        void call('request_claim', { mode: 'claim' }).then((x) => { if (gone && x?.claim?.mine) leave(); }).finally(() => { taking.current = false; });
      }
    };
    const evs = ['input', 'keydown', 'pointerdown'] as const;
    evs.forEach((e) => document.addEventListener(e, mark, { passive: true }));
    const t = setInterval(() => {
      if (document.visibilityState !== 'visible') return;
      // renew while they keep working; otherwise only look (the claim runs out by itself)
      const renew = mine.current && active.current;
      const take = answering && !mine.current && active.current && claimFree(latest.current);
      active.current = false;
      void call(renew || take ? 'request_claim' : 'request_state', renew ? { mode: 'renew' } : take ? { mode: 'claim' } : {});
    }, pollMs());
    const leave = () => {
      if (!mine.current) return;
      mine.current = false;
      try { void fetch('/api/staff/request-claim', { method: 'POST', keepalive: true, headers: { 'content-type': 'application/json' }, body: JSON.stringify({ booking, va: va ?? null }) }); } catch { /* the claim runs out by itself */ }
    };
    window.addEventListener('pagehide', leave);
    return () => { gone = true; clearTimeout(first); clearInterval(t); evs.forEach((e) => document.removeEventListener(e, mark)); window.removeEventListener('pagehide', leave); leave(); };
  }, [booking, status, answering, va, call]);

  // the moment the buttons come on by themselves (the Sales wait ends, the other person's claim runs out): look again then,
  // not up to a poll later
  const opensAt = claimView(state).opensAt;
  useEffect(() => {
    if (status !== 'requested' || !opensAt) return;
    const ms = new Date(opensAt).getTime() - Date.now() + 1_500;
    if (!(ms > 0 && ms < 86_400_000)) return;
    const t = setTimeout(() => { void call('request_state'); }, ms);
    return () => clearTimeout(t);
  }, [opensAt, status, call]);

  const takeOver = () => start(async () => { await call('request_claim', { mode: 'takeover' }); router.refresh(); });
  return <C.Provider value={{ state, takeOver, pending, problem }}>{children}</C.Provider>;
}

/** The line above the request: who is answering it, when it opens to Sales, and Take over for an Admin. */
export function ClaimBanner() {
  const c = useContext(C);
  if (!c) return null;
  const v = claimView(c.state);
  if (!v.note && !c.problem) return null;
  return (
    <div className={`alert ${v.locked ? 'alert--warn' : 'alert--ok'}`} role="status" data-testid="request-claim">
      <span>{v.note ?? c.problem}{v.canTakeOver && <> <button type="button" className="btn btn--sm btn--ghost" disabled={c.pending} onClick={c.takeOver} data-testid="request-takeover">{c.pending ? 'Taking over' : 'Take over'}</button></>}</span>
    </div>
  );
}

/** The answer buttons: off (inert) while someone else answers the request, or while it waits for customer service first.
 *  explain: say beside them why they are off and when they come on (with Take over for an Admin), outside the inert part. */
export function ClaimGate({ children, testId, explain = false }: { children: ReactNode; testId?: string; explain?: boolean }) {
  const c = useContext(C);
  const v = claimView(c?.state ?? null);
  const locked = v.locked;
  return (
    <>
      {explain && locked && v.why && (
        <div className="alert alert--warn rc-why" role="note" data-testid={testId ? `${testId}-why` : 'claim-gate-why'}>
          <span className="alert__title">The answer buttons are off for now</span>
          <span>{v.why}{v.canTakeOver && c && <> <button type="button" className="btn btn--sm btn--ghost" disabled={c.pending} onClick={c.takeOver}>{c.pending ? 'Taking over' : 'Take over'}</button></>}</span>
        </div>)}
      <div className={locked ? 'rc-gate rc-gate--locked' : 'rc-gate'} inert={locked} data-testid={testId} data-locked={locked ? 'true' : 'false'}>{children}</div>
    </>
  );
}
