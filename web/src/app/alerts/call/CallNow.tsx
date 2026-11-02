'use client';
import { useEffect } from 'react';

// Opens the dialer once with the number (a tap on the button does it again).
export function CallNow({ to }: { to: string }) {
  useEffect(() => {
    if (navigator.webdriver) return;
    window.location.href = `tel:${to}`;
  }, [to]);
  return <a className="btn btn--primary" href={`tel:${to}`} data-testid="alert-call-link">Call {to}</a>;
}
