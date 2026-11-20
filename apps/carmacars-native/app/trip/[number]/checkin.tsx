import { useLocalSearchParams } from 'expo-router';
import { SelfHandover } from '@/ui/self-handover';

export default function SelfCheckin() {
  const { number } = useLocalSearchParams<{ number: string }>();
  return <SelfHandover number={number} kind="pickup" />;
}
