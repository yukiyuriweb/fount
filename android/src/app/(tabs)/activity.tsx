import { useTheme } from 'expo-router';
import { FlatList, StyleSheet, Text, View } from 'react-native';

import { SnapshotGate } from '@/components/SnapshotGate';
import type { Snapshot } from '@/lib/gist';
import { useSnapshot } from '@/lib/snapshot';

function Activity({ snapshot }: { snapshot: Snapshot }) {
  const { colors } = useTheme();
  const { loading, refresh } = useSnapshot();
  return (
    <FlatList
      data={snapshot.sites}
      keyExtractor={(site) => site.host}
      refreshing={loading}
      onRefresh={refresh}
      renderItem={({ item }) => (
        <View style={styles.row}>
          <Text style={[styles.host, { color: colors.text }]}>{item.host}</Text>
          <Text style={[styles.meta, { color: colors.text }]}>
            {`選択 ${item.opened} 件 · ブラウザ ${item.browser} 件 · 読み飛ばし ${item.skipped} 件`}
          </Text>
          {item.depth ? <Text style={[styles.meta, { color: colors.text }]}>{`平均到達率 ${item.depth}`}</Text> : null}
        </View>
      )}
      ItemSeparatorComponent={() => <View style={[styles.separator, { backgroundColor: colors.border }]} />}
      ListEmptyComponent={<Text style={[styles.empty, { color: colors.text }]}>Macでの閲覧履歴はまだありません。</Text>}
    />
  );
}

export default function ActivityScreen() {
  return <SnapshotGate>{(snapshot) => <Activity snapshot={snapshot} />}</SnapshotGate>;
}

const styles = StyleSheet.create({
  row: { paddingHorizontal: 16, paddingVertical: 10, gap: 4 },
  host: { fontSize: 16 },
  meta: { fontSize: 13, opacity: 0.6 },
  separator: { height: StyleSheet.hairlineWidth, marginLeft: 16 },
  empty: { padding: 16, opacity: 0.6 },
});
