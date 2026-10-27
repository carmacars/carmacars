'use client';
import { useCallback, useEffect, useState } from 'react';
import { readTaxMode, saveTaxMode, TAX_MODE_OPTIONS, type TaxMode } from './taxIncluded';

/** The staff member's choice of how they type amounts, remembered on this device (2026-10-27). */
export function useTaxMode(): [TaxMode, (m: TaxMode) => void] {
  const [mode, setMode] = useState<TaxMode>('before');
  // read after the first paint, so the server's page and the browser's agree
  // eslint-disable-next-line react-hooks/set-state-in-effect -- the device's choice must follow hydration
  useEffect(() => { setMode(readTaxMode()); }, []);
  const set = useCallback((m: TaxMode) => { setMode(m); saveTaxMode(m); }, []);
  return [mode, set];
}

/** "Amounts I type: Before tax | After tax (HST included)", at the top of a price. The rate is the settings' (bps). */
export function TaxModeToggle({ value, onChange, idPrefix, bps, children }: { value: TaxMode; onChange: (m: TaxMode) => void; idPrefix: string; bps: number | null | undefined; children?: React.ReactNode }) {
  const rate = bps == null ? null : `${(bps / 100).toLocaleString('en-CA', { maximumFractionDigits: 2 })}%`;
  return (
    <div className="ad-taxmode" data-testid={`${idPrefix}-tax-mode`} data-mode={value}>
      <div className="ad-taxmode__row">
        <span className="label" id={`${idPrefix}-tax-mode-l`}>Amounts I type</span>
        <div className="ad-taxmode__opts" role="radiogroup" aria-labelledby={`${idPrefix}-tax-mode-l`}>
          {TAX_MODE_OPTIONS.map(([v, l]) => (
            <label key={v} className="ad-taxmode__opt" htmlFor={`${idPrefix}-tax-mode-${v}`} data-testid={`${idPrefix}-tax-mode-${v}`}>
              <input type="radio" id={`${idPrefix}-tax-mode-${v}`} name={`${idPrefix}-tax-mode`} value={v} checked={value === v} onChange={() => onChange(v)} />
              <span>{l}</span></label>))}
        </div>
      </div>
      <p className="hint">{value === 'after'
        ? `Type what the renter pays for each line, HST${rate ? ` (${rate})` : ''} included: it is worked back to the amount before tax for you. Lines without HST are typed as they are.`
        : 'Type each amount before HST: HST is added for you.'}</p>
      {children}
    </div>
  );
}
