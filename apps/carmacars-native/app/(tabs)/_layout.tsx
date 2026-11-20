import { Text } from 'react-native';
import { Tabs } from 'expo-router';
import { useApp } from '@/app-state';
import { TAB_LABEL, tabsFor, type Tab } from '@/logic/roles';
import { color } from '@/theme';

// One app for every role: the tabs are the parts this account holds (src/logic/roles.ts). A tab the account does not
// hold is not there at all (href: null), and the database refuses its data anyway.
const GLYPH: Record<Tab, string> = { explore: '⌕', trips: '◷', field: '✓', leads: '☎', owner: '▣', profile: '☺' };
const FILE: Record<Tab, string> = { explore: 'index', trips: 'trips', field: 'field', leads: 'leads', owner: 'owner', profile: 'profile' };
const ALL: Tab[] = ['field', 'leads', 'owner', 'explore', 'trips', 'profile'];

export default function TabsLayout() {
  const { me } = useApp();
  const mine = tabsFor(me?.roles ?? null);
  return (
    <Tabs screenOptions={{ headerStyle: { backgroundColor: color.black }, headerTintColor: color.white, headerTitleStyle: { fontWeight: '700' },
      tabBarActiveTintColor: color.red, tabBarInactiveTintColor: color.muted, tabBarStyle: { backgroundColor: color.white, borderTopColor: color.line }, tabBarLabelStyle: { fontSize: 12, fontWeight: '600' } }}>
      {ALL.map((t) => (
        <Tabs.Screen key={t} name={FILE[t]} options={{ title: t === 'explore' ? 'CarmaCars' : TAB_LABEL[t], tabBarLabel: TAB_LABEL[t], href: mine.includes(t) ? undefined : null,
          tabBarAccessibilityLabel: TAB_LABEL[t], tabBarIcon: ({ color: c }) => <Text style={{ color: c, fontSize: 20, lineHeight: 24 }} accessibilityElementsHidden importantForAccessibility="no">{GLYPH[t]}</Text> }} />
      ))}
    </Tabs>
  );
}
