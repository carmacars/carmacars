// The CarmaCars brand icon (public/favicon.svg, the brand kit's square mark), for the menu header, loading screens and
// the lock screen. Decorative: the words beside it say what it is.
export function BrandMark({ size = 24, className = '' }: { size?: number; className?: string }) {
  // eslint-disable-next-line @next/next/no-img-element
  return <img src="/favicon.svg" width={size} height={size} alt="" aria-hidden="true" decoding="async" className={`brand-mark ${className}`.trim()} />;
}
