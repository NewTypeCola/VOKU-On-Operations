import type { Api } from "./api";
import type { Item, Kind, Query, Operator } from "./types";
const now = new Date();
const ago = (d: number, h = 0) =>
  new Date(now.getTime() - d * 86400000 - h * 3600000).toISOString();
const authors = [
  "정은·38기",
  "민수·29기",
  "서연·42기",
  "윤호·31기",
  "지수·35기",
];
const subjects = [
  "1989년 가을 정기 방송의 기억을 찾습니다",
  "오랜만에 다시 듣는 그날의 선곡",
  "이번 주말, 학교 앞에서 만나요",
  "큐시트 속 낯익은 이름들을 발견했어요",
  "VOKU 동문 여러분, 반갑습니다",
  "1994년 축제 방송을 기억하시나요",
  "예전 방송실 사진을 함께 나눕니다",
  "아카이브 이용 중 궁금한 점이 있어요",
];
const rows: Record<Kind, Item[]> = {
  posts: [],
  comments: [],
  reports: [],
  members: [],
  files: [],
  operators: [],
  audit: [],
};
for (let n = 0; n < 43; n++)
  rows.posts.push({
    id: `post-${n}`,
    title: subjects[n % 8],
    body: "방송실에서 함께했던 시간이 떠오릅니다. 보관해 두었던 기록을 살펴보다가 동문 여러분과 나누고 싶어 글을 남깁니다.\n\n이 화면의 글과 회원 정보는 동작 확인을 위한 예시 데이터입니다.",
    category: ["추억", "음악", "동문소식", "일상", "질문"][n % 5],
    author: authors[n % 5],
    status: n === 7 || n === 13 ? "hidden" : "published",
    createdAt: ago(Math.floor(n / 5), n % 5),
    version: "v1",
    pinned: n < 2,
    locked: n === 7,
    commentCount: n % 6,
    views: 24 + n * 7,
    secret: n === 8,
  });
for (let n = 0; n < 17; n++)
  rows.comments.push({
    id: `comment-${n}`,
    title:
      n === 2
        ? "예시: 검토가 필요한 댓글"
        : "그때의 방송이 생각나네요. 소중한 기록 감사합니다.",
    body: "이 댓글은 화면 확인용 예시입니다. 동문들과 함께했던 시간이 오래 기억에 남습니다.",
    category: "추억",
    author: authors[n % 5],
    status: n === 4 ? "hidden" : "published",
    createdAt: ago(n % 6),
    version: "v1",
    postId: `post-${n % 8}`,
    postTitle: subjects[n % 8],
  });
for (let n = 0; n < 7; n++)
  rows.reports.push({
    id: `report-${n}`,
    title: subjects[n % 8],
    body: "신고 대상 본문 예시입니다. 원문과 신고 사유를 함께 확인한 후 처리합니다.",
    category: ["광고·도배", "개인정보 노출", "욕설·비방"][n % 3],
    author: authors[n % 5],
    targetAuthor: authors[(n + 1) % 5],
    status: n < 4 ? "open" : n === 4 ? "resolved" : "dismissed",
    detail: [
      "게시글에 외부 광고 링크가 반복되어 있습니다.",
      "본문에 개인 연락처가 포함된 것 같습니다.",
      "댓글 내용을 확인해 주세요.",
    ][n % 3],
    createdAt: ago(n < 4 ? 0 : 2, n + 1),
    version: "v1",
    postId: `post-${n}`,
    targetStatus: "published",
    resolution: n < 4 ? "" : "검토 후 처리한 예시 기록입니다.",
  });
for (let n = 0; n < 26; n++)
  rows.members.push({
    id: `member-${n}`,
    title: authors[n % 5] + ` ${n + 1}`,
    author: authors[n % 5],
    category: n === 0 ? "admin" : n === 1 ? "moderator" : "member",
    role: n === 0 ? "admin" : n === 1 ? "moderator" : "member",
    status: n === 4 ? "suspended" : n === 7 ? "incomplete" : "active",
    createdAt: ago(n + 1),
    version: "v1",
    admissionYear: 1986 + (n % 15),
    cohort: 24 + (n % 15),
    body: n === 4 ? "반복 게시로 인한 이용 제한 예시" : "",
    suspendedUntil:
      n === 4
        ? new Date(now.getTime() + 7 * 86400000).toISOString()
        : undefined,
  });
rows.operators = [
  {
    id: "preview-owner",
    title: "VOKU 운영실",
    author: "preview@example.invalid",
    email: "preview@example.invalid",
    role: "owner",
    category: "owner",
    status: "active",
    createdAt: ago(21),
    version: "v1",
  },
  {
    id: "preview-viewer",
    title: "기록 담당자",
    author: "viewer@example.invalid",
    email: "viewer@example.invalid",
    role: "viewer",
    category: "viewer",
    status: "active",
    createdAt: ago(10),
    version: "v1",
  },
];
rows.audit = [
  {
    id: "audit-initial",
    title: subjects[7],
    body: "내용 확인 후 안내 게시글을 공지로 고정했습니다. (예시)",
    author: "VOKU 운영실",
    category: "pin",
    status: "recorded",
    source: "operations",
    createdAt: ago(0, 2),
    version: "",
  },
];
const copy = <T>(v: T): T => structuredClone(v);
const me: Operator = {
  id: "preview-owner",
  name: "VOKU 운영실",
  email: "preview@example.invalid",
  role: "owner",
};
const filter = (kind: Kind, q: Query) =>
  rows[kind].filter(
    (i) =>
      (!q.status || i.status === q.status) &&
      (!q.category || i.category === q.category) &&
      (!q.pinned || i.pinned) &&
      (!q.q ||
        (q.field === "title"
          ? i.title
          : q.field === "author"
            ? i.author
            : [i.title, i.body, i.author, i.detail].join(" ")
        )
          .toLowerCase()
          .includes(q.q.toLowerCase())) &&
      (!q.from ||
        i.createdAt >= new Date(q.from + "T00:00:00+09:00").toISOString()) &&
      (!q.to ||
        i.createdAt <
          new Date(
            new Date(q.to + "T00:00:00+09:00").getTime() + 86400000,
          ).toISOString()),
  );
export const previewApi: Api = {
  me: async () => copy(me),
  overview: async () =>
    copy({
      pendingReports: rows.reports.filter((r) => r.status === "open").length,
      posts: rows.posts.filter((r) => r.status === "published").length,
      comments: rows.comments.filter((r) => r.status === "published").length,
      members: rows.members.length,
      newMembers: 2,
      hiddenPosts: rows.posts.filter((r) => r.status === "hidden").length,
      suspendedMembers: rows.members.filter((r) => r.status === "suspended")
        .length,
      pinnedPosts: rows.posts.filter(
        (r) => r.pinned && r.status === "published",
      ).length,
      reports: rows.reports.filter((r) => r.status === "open").slice(0, 5),
      recentPosts: rows.posts
        .filter((r) => r.status === "published")
        .slice(0, 5),
      audit: rows.audit.slice(0, 5),
      daily: Array.from({ length: 7 }, (_, n) => ({
        date: ago(6 - n).slice(0, 10),
        posts: [3, 5, 4, 8, 6, 4, 7][n],
        comments: [6, 7, 5, 10, 8, 7, 9][n],
      })),
    }),
  list: async (k, q) => {
    const found = filter(k, q);
    return copy({
      items: found.slice((q.page - 1) * q.pageSize, q.page * q.pageSize),
      total: found.length,
      page: q.page,
      pageSize: q.pageSize,
    });
  },
  detail: async (k, id) => {
    const item = rows[k].find((i) => i.id === id);
    if (!item) throw Error("항목이 없습니다.");
    return copy({
      item,
      history: rows.audit.filter((a) => a.targetId === id),
      photos: [],
    });
  },
  mutate: async (k, action, items, reason, value = {}) => {
    if (reason.trim().length < 2) throw Error("처리 사유를 입력해 주세요.");
    const selected = items.map((i) => {
      const row = rows[k].find((r) => r.id === i.id);
      if (!row || row.version !== i.version) throw Error("ops_conflict");
      if (k === "members" && row.role !== "member")
        throw Error("게시판 관리자와 운영진은 변경할 수 없습니다.");
      if (k === "operators" && row.id === me.id)
        throw Error("자신의 권한은 변경할 수 없습니다.");
      return row;
    });
    for (const row of selected) {
      const before = copy(row);
      const states: Record<string, string> = {
        hide: "hidden",
        restore: "published",
        resolve_hide: "resolved",
        dismiss: "dismissed",
        suspend: "suspended",
        unsuspend: "active",
        disable: "disabled",
        enable: "active",
        cancel_invite: "cancelled",
      };
      if (states[action]) row.status = states[action];
      if (action === "pin" || action === "unpin") row.pinned = action === "pin";
      if (action === "lock" || action === "unlock")
        row.locked = action === "lock";
      if (action === "role") row.role = row.category = String(value.role);
      if (action === "suspend") {
        row.suspendedUntil = new Date(
          Date.now() + Number(value.days) * 86400000,
        ).toISOString();
        row.body = reason;
      }
      if (action === "unsuspend") {
        row.suspendedUntil = undefined;
        row.body = "";
      }
      if (k === "reports") {
        row.resolution = reason;
        row.resolvedAt = new Date().toISOString();
        if (action === "resolve_hide") {
          const p = rows.posts.find((p) => p.id === row.postId);
          if (p) {
            p.status = "hidden";
            p.version = crypto.randomUUID();
          }
        }
      }
      row.version = crypto.randomUUID();
      rows.audit.unshift({
        id: crypto.randomUUID(),
        title: row.title,
        body: reason,
        author: me.name,
        category: action,
        status: "recorded",
        source: "operations",
        targetKind: k,
        targetId: row.id,
        createdAt: new Date().toISOString(),
        version: "",
        before,
        after: copy(row),
      });
    }
    return { changed: items.length };
  },
  invite: async (email, name, role, reason) => {
    if (rows.operators.some((i) => i.email === email))
      throw Error("이미 등록된 이메일입니다.");
    const id = crypto.randomUUID();
    rows.operators.unshift({
      id,
      title: name,
      author: email,
      email,
      role,
      category: role,
      status: "invited",
      createdAt: new Date().toISOString(),
      version: "v1",
    });
    rows.audit.unshift({
      id: crypto.randomUUID(),
      title: name,
      author: me.name,
      body: reason,
      category: "invite",
      status: "recorded",
      source: "operations",
      createdAt: new Date().toISOString(),
      version: "",
    });
    return { id };
  },
};
