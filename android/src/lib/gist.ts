export type Article = {
  id: string; feedId: string; feedTitle: string; title: string; link: string; date: string; read: boolean;
};
export type Feed = { id: string; title: string };
export type Site = { host: string; opened: number; browser: number; skipped: number; depth: string };
export type Snapshot = { exportedAt: string; feeds: Feed[]; articles: Article[]; sites: Site[] };

const fileName = 'fount-sync.json';
const gistID = /^[a-f\d]{5,32}$/i;
const gistURL = /^(?:https?:\/\/)?gist\.github\.com\/(?:([\w-]+)\/)?([a-f\d]{5,32})\/?(?:[?#].*)?$/i;
const pastedRawURL = /^(?:https?:\/\/)?gist\.githubusercontent\.com\/([\w-]+)\/([a-f\d]{5,32})\/raw(?:\/[^?#\s]*)?(?:[?#].*)?$/i;
const apiURL = /^(?:https?:\/\/)?api\.github\.com\/gists\/([a-f\d]{5,32})\/?(?:[?#].*)?$/i;
const rawURL = /^https:\/\/gist\.githubusercontent\.com\/[\w-]+\/[a-f\d]{5,32}\/raw(?:\/[a-f\d]{40})?\/fount-sync\.json$/i;

function gistAddress(pasted: string): { id: string; owner?: string } | undefined {
  const input = pasted.replace(/[！-～]/g, (c) => String.fromCharCode(c.charCodeAt(0) - 0xfee0))
    .replace(/[\u200B-\u200F\u202A-\u202E\u2060\u2066-\u2069\uFEFF]/g, '').trim();
  if (gistID.test(input)) return { id: input.toLowerCase() };

  // Android share sheets may include a title or enclose the link in angle brackets.
  const candidates = [input, ...input.split(/[\s<>"'()\[\]{}「」『』]+/u)];
  for (const candidate of candidates) {
    const match = gistURL.exec(candidate) ?? pastedRawURL.exec(candidate);
    if (match) return { id: match[2].toLowerCase(), owner: match[1] };
    const apiMatch = apiURL.exec(candidate);
    if (apiMatch) return { id: apiMatch[1].toLowerCase() };
  }
}

type RecordValue = Record<string, unknown>;

function record(value: unknown): RecordValue | undefined {
  return value !== null && typeof value === 'object' && !Array.isArray(value)
    ? value as RecordValue
    : undefined;
}

function isText(value: unknown): value is string {
  return typeof value === 'string';
}

function count(value: unknown): value is number {
  return typeof value === 'number' && Number.isSafeInteger(value) && value >= 0;
}

export function parseSnapshot(value: unknown): Snapshot {
  const data = record(value);
  const activity = record(data?.activity);
  if (!data || data.schemaVersion !== 1 || !isText(data.exportedAt) ||
      !Array.isArray(data.feeds) || !Array.isArray(data.articles) || !Array.isArray(activity?.sites)) {
    throw new Error('Fountの同期データを読み込めません。');
  }

  // A feed is identified by its URL, so a newer export that drops or reorders feeds
  // never points an open feed screen at a different feed.
  const feedTitles = new Map<string, string>();
  const feeds: Feed[] = [];
  for (const value of data.feeds) {
    const feed = record(value);
    if (!feed || !isText(feed.url) || !isText(feed.title) || feedTitles.has(feed.url)) continue;
    feedTitles.set(feed.url, feed.title);
    feeds.push({ id: feed.url, title: feed.title || feed.url });
  }

  const seen = new Set<string>();
  const articles: Article[] = [];
  for (const value of data.articles) {
    const item = record(value);
    if (!item || !isText(item.id) || !isText(item.feed) || !isText(item.title) ||
        !isText(item.link) || !/^https?:\/\/[^\s/]+/i.test(item.link) ||
        !isText(item.date) || typeof item.read !== 'boolean') continue;
    const id = JSON.stringify([item.feed, item.id]);
    if (seen.has(id)) continue;
    seen.add(id);
    articles.push({
      id, feedId: feedTitles.has(item.feed) ? item.feed : '', feedTitle: feedTitles.get(item.feed) || item.feed,
      title: item.title || item.link, link: item.link, date: item.date.slice(0, 10), read: item.read,
    });
  }

  const sites: Site[] = [];
  for (const value of activity.sites) {
    const site = record(value);
    if (!site || !isText(site.host) || !count(site.opened) || !count(site.browser) || !count(site.skipped)) continue;
    const depth = site.averageDepth;
    sites.push({
      host: site.host, opened: site.opened, browser: site.browser, skipped: site.skipped,
      depth: typeof depth === 'number' && depth >= 0 && depth <= 1 ? `${Math.round(depth * 100)}%` : '',
    });
  }

  return { exportedAt: data.exportedAt.slice(0, 10), feeds, articles, sites };
}

type Request = (url: string) => Promise<Response>;

export async function readGist(url: string, request: Request): Promise<Snapshot> {
  const address = gistAddress(url);
  if (!address) throw new Error('MacのFountで「GistのURLをコピー」を選び、同期設定に貼り付けてください。');

  if (address.owner) {
    const latest = `https://gist.githubusercontent.com/${address.owner}/${address.id}/raw/${fileName}`;
    const file = await request(latest);
    if (file.ok) return parseSnapshot(await file.json());
    if (file.status !== 404) throw new Error(`Gistの同期ファイルを取得できませんでした（HTTP ${file.status}）。`);
  }

  const response = await request(`https://api.github.com/gists/${address.id}`);
  if (response.status === 404) throw new Error('Gistが見つかりません。URLを確認してください。');
  if (response.status === 429 || response.headers.get('x-ratelimit-remaining') === '0') {
    throw new Error('GitHubの取得制限に達しました。時間をおいて更新してください。');
  }
  if (!response.ok) throw new Error(`GitHubからGistを取得できませんでした（HTTP ${response.status}）。`);

  const gist = record(await response.json());
  const file = record(record(gist?.files)?.[fileName]);
  if (!file) throw new Error('このGistにfount-sync.jsonがありません。');

  if (file.truncated !== true && isText(file.content)) return parseSnapshot(JSON.parse(file.content));
  const raw = file.raw_url;
  if (!isText(raw) || !rawURL.test(raw) || raw.split('/')[4]?.toLowerCase() !== address.id) {
    throw new Error('同期ファイルのURLを確認できませんでした。');
  }
  const full = await request(raw);
  if (!full.ok) throw new Error('同期ファイルを取得できませんでした。');
  return parseSnapshot(await full.json());
}
