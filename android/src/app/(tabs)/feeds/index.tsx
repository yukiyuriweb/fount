import { router, useTheme } from 'expo-router';
import { useMemo } from 'react';
import { FlatList, Pressable, StyleSheet, Text, View } from 'react-native';

import { SnapshotGate } from '@/components/SnapshotGate';
import type { Snapshot } from '@/lib/gist';
import { useSnapshot } from '@/lib/snapshot';

function Feeds({ snapshot }: { snapshot: Snapshot }) {
  const { colors } = useTheme();
  const { loading, refresh } = useSnapshot();
  const unread = useMemo(() => {
    const counts = new Map<string, number>();
    for (const a of snapshot.articles) if (!a.read) counts.set(a.feedId, (counts.get(a.feedId) ?? 0) + 1);
    return counts;
  }, [snapshot]);
  return (
    <FlatList
      data={snapshot.feeds}
      keyExtractor={(feed) => feed.id}
      refreshing={loading}
      onRefresh={refresh}
      renderItem={({ item }) => (
        <Pressable
          onPress={() => router.push({ pathname: '/feeds/[id]', params: { id: item.id, title: item.title } })}
          android_ripple={{ color: colors.border }}
          style={styles.row}
        >
          <Text style={[styles.title, { color: colors.text }]} numberOfLines={1}>{item.title}</Text>
          {unread.get(item.id) ? <Text style={[styles.count, { color: colors.text }]}>{unread.get(item.id)}</Text> : null}
        </Pressable>
      )}
      ItemSeparatorComponent={() => <View style={[styles.separator, { backgroundColor: colors.border }]} />}
      ListEmptyComponent={<Text style={[styles.empty, { color: colors.text }]}>購読フィードはありません。</Text>}
    />
  );
}

export default function FeedsScreen() {
  return <SnapshotGate>{(snapshot) => <Feeds snapshot={snapshot} />}</SnapshotGate>;
}

const styles = StyleSheet.create({
  row: { flexDirection: 'row', alignItems: 'center', paddingHorizontal: 16, paddingVertical: 14, gap: 8 },
  title: { flex: 1, fontSize: 16 },
  count: { fontSize: 14, opacity: 0.6 },
  separator: { height: StyleSheet.hairlineWidth, marginLeft: 16 },
  empty: { padding: 16, opacity: 0.6 },
});
