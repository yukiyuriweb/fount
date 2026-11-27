import { useTheme } from 'expo-router';
import { useMemo } from 'react';
import { Text } from 'react-native';

import { ArticleList } from '@/components/ArticleList';
import { SnapshotGate } from '@/components/SnapshotGate';
import type { Snapshot } from '@/lib/gist';
import { useSnapshot } from '@/lib/snapshot';

function Articles({ snapshot }: { snapshot: Snapshot }) {
  const { colors } = useTheme();
  const { unreadOnly } = useSnapshot();
  const articles = useMemo(
    () => (unreadOnly ? snapshot.articles.filter((a) => !a.read) : snapshot.articles),
    [snapshot, unreadOnly],
  );
  return (
    <ArticleList
      articles={articles}
      showFeed
      header={
        <Text style={{ color: colors.text, opacity: 0.6, fontSize: 12, paddingHorizontal: 16, paddingTop: 8 }}>
          {`Macの同期日 ${snapshot.exportedAt} · ${articles.length}件`}
        </Text>
      }
    />
  );
}

export default function ArticlesScreen() {
  return <SnapshotGate>{(snapshot) => <Articles snapshot={snapshot} />}</SnapshotGate>;
}
