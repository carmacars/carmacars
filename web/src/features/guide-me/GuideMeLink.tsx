'use client';
import './guide-me.css';
import { GUIDE_START_EVENT } from './engine';

// "Guide me through this" (r51, 3950): a small link on a workflow's page that starts its walkthrough right there. The
// coach (GuideMe, in the portal's header) only starts a workflow the person's functions may run.
export function GuideMeLink({ flow, label = 'Guide me through this' }: { flow: string; label?: string }) {
  return (
    <button type="button" className="gm-link link small" onClick={() => window.dispatchEvent(new CustomEvent(GUIDE_START_EVENT, { detail: { flow } }))} data-testid={`guide-me-link-${flow}`}>
      <svg viewBox="0 0 24 24" aria-hidden="true" fill="none" stroke="currentColor" strokeWidth="1.8" strokeLinecap="round" strokeLinejoin="round"><circle cx="12" cy="12" r="8.5" /><path d="M15.5 8.5l-2 5-5 2 2-5z" /></svg>
      {label}
    </button>
  );
}
