'use client';

export function PrintButton({ label, testId }: { label: string; testId?: string }) {
  return <button type="button" className="btn btn--primary btn--sm" onClick={() => window.print()} data-testid={testId}>{label}</button>;
}
