import { BrandMark } from '@/components/BrandMark';

// While a page of this portal loads (r32): the brand icon, pulsing, in the page area; the menu stays.
export default function Loading() {
  return (
    <div className="brand-wait" role="status">
      <BrandMark size={44} />
      <span className="vh">Loading</span>
    </div>
  );
}
