import { Stack } from 'expo-router';

import { UnreadToggle } from '@/components/UnreadToggle';

export default function FeedsLayout() {
  return (
    <Stack>
      <Stack.Screen name="index" options={{ title: 'フィード' }} />
      <Stack.Screen name="[id]" options={{ title: '', headerRight: () => <UnreadToggle /> }} />
    </Stack>
  );
}
