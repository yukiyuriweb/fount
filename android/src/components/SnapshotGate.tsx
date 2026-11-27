import { router, useTheme } from 'expo-router';
import type { ReactNode } from 'react';
import { ActivityIndicator, Pressable, StyleSheet, Text, View } from 'react-native';

import type { Snapshot } from '@/lib/gist';
import { useSnapshot } from '@/lib/snapshot';

/** Shows what stands in for a screen's content until a snapshot has loaded. */
export function SnapshotGate({ children }: { children: (snapshot: Snapshot) => ReactNode }) {
  const { colors } = useTheme();
  const { url, snapshot, loading, error, refresh } = useSnapshot();
  if (snapshot) return children(snapshot);
  if (url && loading) {
    return <View style={styles.center}><ActivityIndicator /></View>;
  }
  const title = url ? '同期データを読み込めません' : 'MacのFountに接続';
  const message = url
    ? error || '接続を確認して更新してください。'
    : 'MacのFountでコピーしたGistのURLを設定すると、同期した記事をここで読めます。';
  return (
    <View style={styles.center}>
      <Text style={[styles.title, { color: colors.text }]}>{title}</Text>
      <Text style={[styles.message, { color: colors.text }]}>{message}</Text>
      <View style={styles.buttons}>
        <Pressable onPress={() => router.navigate('/settings')} style={styles.button}>
          <Text style={{ color: colors.primary }}>{url ? 'GistのURLを確認' : 'GistのURLを設定'}</Text>
        </Pressable>
        {url ? (
          <Pressable onPress={refresh} style={styles.button}>
            <Text style={{ color: colors.primary }}>再読み込み</Text>
          </Pressable>
        ) : null}
      </View>
    </View>
  );
}

const styles = StyleSheet.create({
  center: { flex: 1, alignItems: 'center', justifyContent: 'center', padding: 24, gap: 8 },
  title: { fontSize: 18, fontWeight: '600', textAlign: 'center' },
  message: { textAlign: 'center', opacity: 0.7 },
  buttons: { flexDirection: 'row', gap: 16, marginTop: 8 },
  button: { padding: 8 },
});
