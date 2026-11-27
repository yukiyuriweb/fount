import { useTheme } from 'expo-router';
import { memo, type ReactElement, useCallback } from 'react';
import { FlatList, Linking, Pressable, RefreshControl, StyleSheet, Text, View } from 'react-native';

import type { Article } from '@/lib/gist';
import { useSnapshot } from '@/lib/snapshot';

const ArticleRow = memo(function ArticleRow({ article, showFeed }: { article: Article; showFeed: boolean }) {
  const { colors } = useTheme();
  const meta = [article.read ? '既読' : '未読', showFeed ? article.feedTitle : '', article.date].filter(Boolean).join(' · ');
  return (
    <Pressable
      onPress={() => { void Linking.openURL(article.link); }}
      android_ripple={{ color: colors.border }}
      style={styles.row}
    >
      <Text style={[styles.title, { color: colors.text }, article.read && styles.read]} numberOfLines={3}>
        {article.title}
      </Text>
      <Text style={[styles.meta, { color: colors.text }]} numberOfLines={1}>{meta}</Text>
    </Pressable>
  );
});

export function ArticleList({ articles, showFeed, header }: {
  articles: Article[];
  showFeed: boolean;
  header?: ReactElement;
}) {
  const { colors } = useTheme();
  const { loading, refresh, unreadOnly } = useSnapshot();
  const renderItem = useCallback(
    ({ item }: { item: Article }) => <ArticleRow article={item} showFeed={showFeed} />,
    [showFeed],
  );
  return (
    <FlatList
      data={articles}
      keyExtractor={(item) => item.id}
      renderItem={renderItem}
      ListHeaderComponent={header}
      ListEmptyComponent={
        <Text style={[styles.empty, { color: colors.text }]}>
          {unreadOnly ? '未読の記事はありません。' : '表示する記事はありません。'}
        </Text>
      }
      ItemSeparatorComponent={() => <View style={[styles.separator, { backgroundColor: colors.border }]} />}
      refreshControl={<RefreshControl refreshing={loading} onRefresh={refresh} />}
      initialNumToRender={20}
      windowSize={11}
    />
  );
}

const styles = StyleSheet.create({
  row: { paddingHorizontal: 16, paddingVertical: 10, gap: 4 },
  title: { fontSize: 16, lineHeight: 22 },
  read: { opacity: 0.6 },
  meta: { fontSize: 12, opacity: 0.6 },
  separator: { height: StyleSheet.hairlineWidth, marginLeft: 16 },
  empty: { padding: 16, opacity: 0.6 },
});
