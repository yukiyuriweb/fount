import { useTheme } from 'expo-router';
import { Pressable, Text } from 'react-native';

import { useSnapshot } from '@/lib/snapshot';

export function UnreadToggle() {
  const { colors } = useTheme();
  const { unreadOnly, setUnreadOnly } = useSnapshot();
  return (
    <Pressable onPress={() => setUnreadOnly(!unreadOnly)} hitSlop={8} style={{ paddingHorizontal: 16 }}>
      <Text style={{ color: colors.primary }}>{unreadOnly ? 'すべて' : '未読のみ'}</Text>
    </Pressable>
  );
}
