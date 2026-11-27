import { Stack, useLocalSearchParams } from 'expo-router';
import { useMemo } from 'react';

import { ArticleList } from '@/components/ArticleList';
import { SnapshotGate } from '@/components/SnapshotGate';
import type { Snapshot } from '@/lib/gist';
import { useSnapshot } from '@/lib/snapshot';

function FeedArticles({ snapshot, id }: { snapshot: Snapshot; id: string }) {
  const { unreadOnly } = useSnapshot();
  const articles = useMemo(
    () => snapshot.articles.filter((a) => a.feedId === id && (!unreadOnly || !a.read)),
    [snapshot, id, unreadOnly],
  );
  return <ArticleList articles={articles} showFeed={false} />;
}

export default function FeedScreen() {
  const { id, title } = useLocalSearchParams<{ id: string; title?: string }>();
  const { snapshot } = useSnapshot();
  const current = snapshot?.feeds.find((feed) => feed.id === id)?.title;
  return (
    <>
      <Stack.Screen options={{ title: current ?? title ?? '' }} />
      <SnapshotGate>{(snapshot) => <FeedArticles snapshot={snapshot} id={id} />}</SnapshotGate>
    </>
  );
}
