import { redirect } from 'next/navigation';

// r35 part X: My hours is part of My pay (clock in and out is on Today, with the shift).
export default function MyHours() { redirect('/staff/field/pay'); }
