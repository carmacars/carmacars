'use client';

/** Print the gift card (or save it as a PDF from the browser's print dialog). */
export function PrintButton() {
  return <button type="button" className="btn btn--primary" onClick={() => window.print()} data-testid="gift-print-button">Print or save as PDF</button>;
}
