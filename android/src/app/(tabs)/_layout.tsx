import MaterialIcons from '@expo/vector-icons/MaterialIcons';
import { Tabs } from 'expo-router/js-tabs';
import type { ComponentProps } from 'react';
import type { ColorValue } from 'react-native';

import { UnreadToggle } from '@/components/UnreadToggle';

type IconName = ComponentProps<typeof MaterialIcons>['name'];

function icon(name: IconName) {
  return ({ color, size }: { color: ColorValue; size: number }) => <MaterialIcons name={name} color={color as string} size={size} />;
}

export default function TabLayout() {
  return (
    <Tabs>
      <Tabs.Screen name="index" options={{ title: '記事', tabBarIcon: icon('article'), headerRight: () => <UnreadToggle /> }} />
      <Tabs.Screen name="feeds" options={{ title: 'フィード', headerShown: false, tabBarIcon: icon('rss-feed') }} />
      <Tabs.Screen name="activity" options={{ title: '閲覧状況', tabBarIcon: icon('insights') }} />
      <Tabs.Screen name="settings" options={{ title: '設定', tabBarIcon: icon('settings') }} />
    </Tabs>
  );
}
