export type Kind =
  | "posts"
  | "comments"
  | "reports"
  | "members"
  | "files"
  | "operators"
  | "audit";
export type Page = "overview" | Kind | "settings" | "analytics";
export type Operator = {
  id: string;
  name: string;
  email: string;
  role: "owner" | "operator" | "viewer";
  mfaRequired?: boolean;
};
export type Item = {
  id: string;
  title: string;
  status: string;
  category: string;
  author: string;
  createdAt: string;
  version: string;
  body?: string;
  authorId?: string;
  updatedAt?: string;
  pinned?: boolean;
  locked?: boolean;
  secret?: boolean;
  views?: number;
  commentCount?: number;
  recordId?: string;
  postId?: string;
  postTitle?: string;
  commentId?: string;
  targetAuthor?: string;
  targetStatus?: string;
  detail?: string;
  resolution?: string;
  resolvedAt?: string;
  admissionYear?: number;
  cohort?: number;
  suspendedUntil?: string;
  role?: string;
  email?: string;
  path?: string;
  targetKind?: Kind;
  targetId?: string;
  source?: string;
  publicCode?: string;
  sample?: boolean;
  introduction?: string;
  before?: Record<string, unknown>;
  after?: Record<string, unknown>;
};
export type Query = {
  q: string;
  field: string;
  status: string;
  category: string;
  from: string;
  to: string;
  pinned: boolean;
  page: number;
  pageSize: number;
};
export type Listing = {
  items: Item[];
  total: number;
  page: number;
  pageSize: number;
};
export type Detail = {
  item: Item;
  history: Item[];
  photos: { id: string; path: string }[];
};
export type Overview = {
  pendingReports: number;
  posts: number;
  comments: number;
  members: number;
  newMembers: number;
  hiddenPosts: number;
  suspendedMembers: number;
  pinnedPosts: number;
  reports: Item[];
  recentPosts: Item[];
  audit: Item[];
  daily: { date: string; posts: number; comments: number }[];
};
export const emptyQuery: Query = {
  q: "",
  field: "all",
  status: "",
  category: "",
  from: "",
  to: "",
  pinned: false,
  page: 1,
  pageSize: 20,
};
export const titles: Record<Page, string> = {
  analytics: "이용 분석·보고서",
  overview: "운영 현황",
  posts: "게시글 관리",
  comments: "댓글 관리",
  reports: "신고 처리",
  members: "회원 관리",
  files: "첨부파일",
  operators: "운영자·권한",
  audit: "처리 기록",
  settings: "운영 안내",
};
export const roleLabels: Record<string, string> = {
  owner: "최고운영자",
  operator: "운영자",
  viewer: "조회 담당자",
  member: "일반회원",
  moderator: "게시판 운영진",
  admin: "게시판 관리자",
};
export const stateLabels: Record<string, string> = {
  published: "공개",
  hidden: "숨김",
  deleted: "작성자 삭제",
  open: "미처리",
  resolved: "처리 완료",
  dismissed: "반려",
  active: "정상",
  suspended: "이용 제한",
  incomplete: "가입 미완료",
  disabled: "접근 중지",
  invited: "등록 대기",
  cancelled: "등록 취소",
  unattached: "미연결",
  recorded: "기록",
};
export const actionLabels: Record<string, string> = {
  hide: "숨김 처리",
  restore: "공개 복원",
  pin: "공지 고정",
  unpin: "공지 해제",
  lock: "댓글 잠금",
  unlock: "댓글 잠금 해제",
  resolve_hide: "숨김 후 신고 처리",
  dismiss: "신고 반려",
  suspend: "이용 제한",
  unsuspend: "이용 제한 해제",
  role: "역할 변경",
  disable: "접근 중지",
  enable: "접근 재개",
  cancel_invite: "등록 취소",
  invite: "운영자 등록 허용",
  post_visibility: "글 공개 상태 변경",
  post_pin: "공지 변경",
  post_lock: "댓글 잠금 변경",
  resolve_report: "신고 처리",
  restore_member: "이용 제한 해제",
  set_role: "게시판 역할 변경",
};
