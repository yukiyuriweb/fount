import { useTheme } from 'expo-router';
import { useEffect, useState } from 'react';
import { Pressable, StyleSheet, Text, TextInput, View } from 'react-native';

import { useSnapshot } from '@/lib/snapshot';

export default function SettingsScreen() {
  const { colors } = useTheme();
  const { url, saveURL, loading, error, snapshot } = useSnapshot();
  const [draft, setDraft] = useState(url);
  useEffect(() => setDraft(url), [url]);
  const canSave = draft.trim() !== '' && draft.trim() !== url;
  const status = loading ? '読み込み中…' : error ? error : snapshot ? `Macの同期日 ${snapshot.exportedAt}` : '';
  return (
    <View style={styles.container}>
      <Text style={[styles.label, { color: colors.text }]}>GistのURL</Text>
      <TextInput
        value={draft}
        onChangeText={setDraft}
        placeholder="https://gist.github.com/…"
        placeholderTextColor={colors.border}
        autoCapitalize="none"
        autoCorrect={false}
        keyboardType="url"
        returnKeyType="done"
        onSubmitEditing={() => { if (canSave) saveURL(draft); }}
        style={[styles.input, { color: colors.text, borderColor: colors.border, backgroundColor: colors.card }]}
      />
      <Text style={[styles.hint, { color: colors.text }]}>MacのFountで「GitHub 同期…」からコピーしたURLを貼り付けます。</Text>
      <Pressable
        onPress={() => saveURL(draft)}
        disabled={!canSave}
        style={[styles.save, { backgroundColor: colors.primary, opacity: canSave ? 1 : 0.4 }]}
      >
        <Text style={styles.saveText}>保存</Text>
      </Pressable>
      {url && status ? <Text style={[styles.hint, { color: colors.text }]}>{status}</Text> : null}
    </View>
  );
}

const styles = StyleSheet.create({
  container: { padding: 16, gap: 8 },
  label: { fontSize: 13, opacity: 0.7 },
  input: { borderWidth: StyleSheet.hairlineWidth, borderRadius: 8, paddingHorizontal: 12, paddingVertical: 10, fontSize: 16 },
  hint: { fontSize: 13, opacity: 0.6 },
  save: { alignSelf: 'flex-start', borderRadius: 20, paddingHorizontal: 20, paddingVertical: 10, marginTop: 8 },
  saveText: { color: 'white', fontSize: 16 },
});
