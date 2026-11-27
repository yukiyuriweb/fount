import Storage from 'expo-sqlite/kv-store';
import { createContext, type ReactNode, useCallback, useContext, useEffect, useMemo, useState } from 'react';

import { readGist, type Snapshot } from './gist';

const urlKey = 'gistURL';

type State = {
  url: string;
  snapshot: Snapshot | null;
  loading: boolean;
  error: string;
  unreadOnly: boolean;
  setUnreadOnly: (value: boolean) => void;
  saveURL: (url: string) => void;
  refresh: () => void;
};

const SnapshotContext = createContext<State | null>(null);

async function load(url: string): Promise<Snapshot> {
  try {
    return await readGist(url, (target) => fetch(target, {
      headers: target.startsWith('https://api.github.com/') ? { 'User-Agent': 'Fount-Android' } : {},
    }));
  } catch (error) {
    if (error instanceof SyntaxError) throw new Error('同期ファイルが有効なJSONではありません。');
    if (error instanceof TypeError) throw new Error('GitHubに接続できませんでした。通信状況を確認してください。');
    throw error;
  }
}

export function SnapshotProvider({ children }: { children: ReactNode }) {
  const [url, setURL] = useState(() => Storage.getItemSync(urlKey) ?? '');
  const [snapshot, setSnapshot] = useState<Snapshot | null>(null);
  const [loading, setLoading] = useState(false);
  const [error, setError] = useState('');
  const [unreadOnly, setUnreadOnly] = useState(false);
  const [generation, setGeneration] = useState(0);

  useEffect(() => {
    if (!url) return;
    let current = true;
    setLoading(true);
    setError('');
    load(url)
      .then((value) => { if (current) setSnapshot(value); })
      .catch((reason: unknown) => {
        if (current) setError(reason instanceof Error ? reason.message : 'Gistを読み込めませんでした。');
      })
      .finally(() => { if (current) setLoading(false); });
    return () => { current = false; };
  }, [url, generation]);

  const saveURL = useCallback((value: string) => {
    const trimmed = value.trim();
    Storage.setItemSync(urlKey, trimmed);
    if (trimmed !== url) setSnapshot(null);
    setURL(trimmed);
    setGeneration((n) => n + 1);
  }, [url]);

  const refresh = useCallback(() => setGeneration((n) => n + 1), []);

  const value = useMemo(
    () => ({ url, snapshot, loading, error, unreadOnly, setUnreadOnly, saveURL, refresh }),
    [url, snapshot, loading, error, unreadOnly, saveURL, refresh],
  );
  return <SnapshotContext.Provider value={value}>{children}</SnapshotContext.Provider>;
}

export function useSnapshot() {
  const value = useContext(SnapshotContext);
  if (!value) throw new Error('useSnapshot must be used inside SnapshotProvider');
  return value;
}
