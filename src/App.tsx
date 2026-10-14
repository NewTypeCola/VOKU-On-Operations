import {
  useCallback,
  useEffect,
  useRef,
  useState,
  type FormEvent,
  type ReactNode,
} from "react";
import AnalyticsPage from "./analytics/AnalyticsPage";
import { googleAuthOptions } from "./auth";
import {
  Activity,
  ArrowDownToLine,
  ArrowRight,
  Bell,
  Check,
  CheckCheck,
  ChevronDown,
  ChevronLeft,
  ChevronRight,
  CircleHelp,
  Clock3,
  ExternalLink,
  FileText,
  Flag,
  FolderOpen,
  LayoutDashboard,
  LockKeyhole,
  LogOut,
  Menu,
  MessageSquare,
  MoreHorizontal,
  PanelRightClose,
  Pin,
  Plus,
  RefreshCw,
  Search,
  ShieldCheck,
  SlidersHorizontal,
  Users,
  X,
} from "lucide-react";
import {
  configured,
  errorText,
  finishAuth,
  getApi,
  photoUrl,
  previewMode,
  supabase,
  type Api,
} from "./api";
import {
  actionLabels,
  emptyQuery,
  roleLabels,
  stateLabels,
  titles,
  type Detail,
  type Item,
  type Kind,
  type Listing,
  type Operator,
  type Overview,
  type Page,
  type Query,
} from "./types";

const date = (value?: string, time = false) =>
  value
    ? new Intl.DateTimeFormat("ko-KR", {
        timeZone: "Asia/Seoul",
        year: "numeric",
        month: "2-digit",
        day: "2-digit",
        ...(time ? { hour: "2-digit", minute: "2-digit" } : {}),
      }).format(new Date(value))
    : "—";
const num = (n: number) => n.toLocaleString("ko-KR");
const icons = {
  analytics: Activity,
  overview: LayoutDashboard,
  posts: FileText,
  comments: MessageSquare,
  reports: Flag,
  members: Users,
  files: FolderOpen,
  operators: ShieldCheck,
  audit: Clock3,
  settings: CircleHelp,
};
const captions: Record<Page, string> = {
  analytics: "유입부터 큐시트 열람과 참여까지, 관측된 실사용을 확인합니다.",
  overview: "오늘 확인할 일부터 차근차근 살펴보세요.",
  posts: "게시판의 글과 공지를 한곳에서 관리합니다.",
  comments: "대화의 맥락을 확인하고 댓글을 관리합니다.",
  reports: "원문과 신고 사유를 함께 확인한 뒤 처리해 주세요.",
  members: "회원의 가입 정보와 이용 상태를 확인합니다.",
  files: "게시글에 첨부된 사진과 연결 상태를 확인합니다.",
  operators: "운영자 전용 계정과 담당 권한을 관리합니다.",
  audit: "모든 운영 조치의 담당자와 사유를 확인합니다.",
  settings: "계정, 권한, 처리 기준을 확인합니다.",
};
const categories = ["일상", "추억", "음악", "질문", "동문소식"];
const statuses: Record<Kind, string[]> = {
  posts: ["published", "hidden", "deleted"],
  comments: ["published", "hidden", "deleted"],
  reports: ["open", "resolved", "dismissed"],
  members: ["active", "suspended", "incomplete"],
  files: ["published", "hidden", "deleted", "unattached"],
  operators: ["active", "invited", "disabled", "cancelled"],
  audit: [],
};
type Route = { page: Page; query: Query; id: string };
function readRoute(): Route {
  const [page = "overview", search = ""] = location.hash
    .replace(/^#\/?/, "")
    .split("?");
  const p = new URLSearchParams(search);
  return {
    page: page in titles ? (page as Page) : "overview",
    id: p.get("item") || "",
    query: {
      ...emptyQuery,
      q: p.get("q") || "",
      field: p.get("field") || "all",
      status: p.get("status") || "",
      category: p.get("category") || "",
      pinned: p.get("pinned") === "true",
      from: p.get("from") || "",
      to: p.get("to") || "",
      page: Math.max(1, Number(p.get("page")) || 1),
      pageSize: 50 === Number(p.get("pageSize")) ? 50 : 20,
    },
  };
}
function navigate(
  page: Page,
  query: Partial<Query> = {},
  id = "",
  replace = false,
) {
  const p = new URLSearchParams();
  const q = { ...emptyQuery, ...query };
  Object.entries(q).forEach(([k, v]) => {
    if (v !== emptyQuery[k as keyof Query]) p.set(k, String(v));
  });
  if (id) p.set("item", id);
  const hash = `#/${page}${p.size ? "?" + p.toString() : ""}`;
  if (replace) {
    history.replaceState(null, "", location.pathname + location.search + hash);
    window.dispatchEvent(new HashChangeEvent("hashchange"));
  } else location.hash = hash;
}
function Badge({ status }: { status: string }) {
  return (
    <span className={`badge status-${status}`}>
      <i />
      {stateLabels[status] || status}
    </span>
  );
}
function Empty({
  title = "검색 결과가 없습니다",
  text = "검색어나 필터를 바꿔 다시 확인해 주세요.",
}: {
  title?: string;
  text?: string;
}) {
  return (
    <div className="empty">
      <FolderOpen size={34} />
      <strong>{title}</strong>
      <p>{text}</p>
    </div>
  );
}
function Failure({ error, retry }: { error: string; retry?: () => void }) {
  return (
    <div className="error-box" role="alert">
      <Flag size={18} />
      <span>{error}</span>
      {retry && <button onClick={retry}>다시 시도</button>}
    </div>
  );
}
function Busy() {
  return (
    <div className="busy" role="status">
      <span className="spinner" /> 불러오는 중입니다
    </div>
  );
}

export default function App() {
  const [api, setApi] = useState<Api>();
  const [operator, setOperator] = useState<Operator>();
  const [checking, setChecking] = useState(!previewMode);
  const [denied, setDenied] = useState("");
  const [authError, setAuthError] = useState("");
  const callbackChecked = useRef(false);
  useEffect(() => {
    let active = true;
    getApi().then((v) => {
      if (active) setApi(v);
    });
    return () => {
      active = false;
    };
  }, []);
  const refreshIdentity = useCallback(async () => {
    if (!api) return;
    if (previewMode) {
      setOperator(await api.me());
      setChecking(false);
      return;
    }
    if (!supabase) {
      setChecking(false);
      return;
    }
    try {
      const message = await finishAuth();
      if (!callbackChecked.current) {
        callbackChecked.current = true;
        setAuthError(message);
      }
      const { data, error } = await supabase.auth.getSession();
      if (error) throw error;
      if (!data.session) {
        setOperator(undefined);
        setDenied("");
        return;
      }
      const me = await api.me();
      setOperator(me);
      setDenied("");
    } catch (e) {
      setOperator(undefined);
      setDenied(errorText(e));
    } finally {
      setChecking(false);
    }
  }, [api]);
  useEffect(() => {
    void refreshIdentity();
    if (!supabase || previewMode) return;
    const { data } = supabase.auth.onAuthStateChange(() => {
      queueMicrotask(() => {
        void refreshIdentity();
      });
    });
    return () => data.subscription.unsubscribe();
  }, [refreshIdentity]);
  const logout = async () => {
    if (previewMode) {
      location.href = location.pathname;
      return;
    }
    await supabase?.auth.signOut({ scope: "local" });
    setOperator(undefined);
    setDenied("");
  };
  if (checking || !api)
    return (
      <div className="initial-load">
        <img src="/brand/voku-logo.webp" alt="VOKU" />
        <Busy />
      </div>
    );
  if (!operator)
    return (
      <AuthPanel
        denied={denied}
        authError={authError}
        onStart={() => setAuthError("")}
        onLogout={logout}
      />
    );
  if (operator.mfaRequired && !previewMode)
    return (
      <MfaPanel
        operator={operator}
        onDone={refreshIdentity}
        onLogout={logout}
      />
    );
  return (
    <Dashboard
      api={api}
      operator={operator}
      onLogout={logout}
      onIdentityError={refreshIdentity}
    />
  );
}

function AuthPanel({
  denied,
  authError,
  onStart,
  onLogout,
}: {
  denied: string;
  authError: string;
  onStart: () => void;
  onLogout: () => void;
}) {
  const [pending, setPending] = useState(false);
  const [error, setError] = useState("");
  const options = googleAuthOptions(location.origin);
  useEffect(() => {
    const restore = () => setPending(false);
    window.addEventListener("pageshow", restore);
    return () => window.removeEventListener("pageshow", restore);
  }, []);
  async function signIn() {
    if (!supabase || !options || pending) return;
    setPending(true);
    setError("");
    onStart();
    try {
      const { error } = await supabase.auth.signInWithOAuth(options);
      if (error) throw error;
    } catch (e) {
      setError(errorText(e));
      setPending(false);
    }
  }
  return (
    <main className="auth-layout">
      <section className="auth-intro">
        <a href={location.pathname} className="brand">
          <img src="/brand/voku-logo.webp" alt="VOKU" />
          <span>
            On <small>운영 관리</small>
          </span>
        </a>
        <div className="auth-intro-main">
          <span className="eyebrow">VOKU ON · OPERATIONS</span>
          <h1>
            함께 쌓은 기록,
            <br />
            세심하게 이어가기.
          </h1>
          <p>
            동문들의 이야기와 소중한 기록이
            <br />
            편안하게 오갈 수 있도록 관리합니다.
          </p>
          <div className="auth-features">
            <span>
              <FileText size={18} /> 게시글과 댓글
            </span>
            <span>
              <Flag size={18} /> 신고와 회원
            </span>
            <span>
              <ShieldCheck size={18} /> 운영 권한과 기록
            </span>
          </div>
        </div>
        <div className="auth-foot">
          VOICE OF KONKUK UNIVERSITY <span>VOKU</span>
        </div>
      </section>
      <section className="auth-form-wrap">
        <div className="auth-form">
          <span className="mini-label">운영자 전용</span>
          <h2>{denied ? "접근 권한 확인" : "운영실에 오신 것을 환영합니다"}</h2>
          <p>등록된 운영자 Google 계정으로 로그인해 주세요.</p>
          {denied ? (
            <>
              <Failure error={denied} />
              <button className="primary wide" onClick={onLogout}>
                다른 Google 계정으로 로그인
              </button>
            </>
          ) : (
            <>
              {(error || authError) && <Failure error={error || authError} />}
              <button
                className="google-sign-in wide"
                onClick={() => void signIn()}
                disabled={pending || !configured || !options}
              >
                <svg
                  width="20"
                  height="20"
                  viewBox="0 0 48 48"
                  aria-hidden="true"
                >
                  <path
                    fill="#EA4335"
                    d="M24 9.5c3.54 0 6.71 1.22 9.21 3.6l6.85-6.85C35.9 2.38 30.47 0 24 0 14.62 0 6.51 5.38 2.56 13.22l7.98 6.19C12.43 13.72 17.74 9.5 24 9.5z"
                  />
                  <path
                    fill="#4285F4"
                    d="M46.98 24.55c0-1.57-.15-3.09-.38-4.55H24v9.02h12.94c-.58 2.96-2.26 5.48-4.78 7.18l7.73 6c4.51-4.18 7.09-10.36 7.09-17.65z"
                  />
                  <path
                    fill="#FBBC05"
                    d="M10.53 28.59A14.4 14.4 0 0 1 9.75 24c0-1.59.27-3.13.76-4.59l-7.98-6.19A23.87 23.87 0 0 0 0 24c0 3.87.93 7.53 2.56 10.78l7.97-6.19z"
                  />
                  <path
                    fill="#34A853"
                    d="M24 48c6.48 0 11.93-2.13 15.91-5.8l-7.73-6c-2.15 1.45-4.92 2.3-8.18 2.3-6.26 0-11.57-4.22-13.47-9.91l-7.98 6.19C6.51 42.62 14.62 48 24 48z"
                  />
                </svg>
                {pending
                  ? "Google 로그인으로 이동 중…"
                  : "Google 계정으로 로그인"}
              </button>
              {!options && (
                <p className="form-notice">
                  이 주소에서는 Google 로그인을 지원하지 않습니다.{" "}
                  <a href="https://voku-operates.pages.dev/">
                    운영자 대시보드로 이동
                  </a>
                </p>
              )}
              <p className="auth-google-help">
                로그인 후 인증 앱으로 2단계 인증을 진행합니다.
                <br />
                처음 접속하는 운영자는 인증 앱을 연결해 주세요.
              </p>
              <p className="fine-print">
                최고운영자가 등록한 이메일만 접근할 수 있습니다.
              </p>
            </>
          )}
          {!configured && (
            <Failure error="운영 서버 연결 설정을 확인할 수 없습니다. 담당자에게 문의해 주세요." />
          )}
          <div className="auth-security">
            <LockKeyhole size={16} />
            <span>운영자 계정은 웹앱 회원·게시판 관리자와 분리됩니다.</span>
          </div>
          <a className="preview-link" href="?preview=1#/overview">
            예시 데이터로 화면 둘러보기 <ExternalLink size={13} />
          </a>
        </div>
      </section>
    </main>
  );
}

function MfaPanel({
  operator,
  onDone,
  onLogout,
}: {
  operator: Operator;
  onDone: () => void;
  onLogout: () => void;
}) {
  const [factor, setFactor] = useState("");
  const [ready, setReady] = useState(false);
  const [qr, setQr] = useState("");
  const [secret, setSecret] = useState("");
  const [code, setCode] = useState("");
  const [error, setError] = useState("");
  const [busy, setBusy] = useState(false);
  useEffect(() => {
    let live = true;
    supabase!.auth.mfa.listFactors().then(({ data, error }) => {
      if (!live) return;
      if (error) setError(errorText(error));
      else setFactor(data.totp.find((f) => f.status === "verified")?.id || "");
      setReady(true);
    });
    return () => {
      live = false;
    };
  }, []);
  async function enroll() {
    setBusy(true);
    setError("");
    try {
      const { data: old, error: oldError } =
        await supabase!.auth.mfa.listFactors();
      if (oldError) throw oldError;
      for (const f of old.all.filter(
        (f) => f.factor_type === "totp" && f.status === "unverified",
      )) {
        const { error } = await supabase!.auth.mfa.unenroll({ factorId: f.id });
        if (error) throw error;
      }
      const { data, error } = await supabase!.auth.mfa.enroll({
        factorType: "totp",
        friendlyName: "VOKU 운영자 인증",
        issuer: "VOKU On Operations",
      });
      if (error) throw error;
      setFactor(data.id);
      setQr(data.totp.qr_code);
      setSecret(data.totp.secret);
    } catch (e) {
      setError(errorText(e));
    } finally {
      setBusy(false);
    }
  }
  async function verify(e: FormEvent) {
    e.preventDefault();
    setBusy(true);
    setError("");
    try {
      const { error } = await supabase!.auth.mfa.challengeAndVerify({
        factorId: factor,
        code,
      });
      if (error) throw error;
      onDone();
    } catch (e) {
      setError(errorText(e));
    } finally {
      setBusy(false);
    }
  }
  return (
    <main className="mfa-page">
      <div className="mfa-card">
        <ShieldCheck size={36} className="green" />
        <h1>2단계 인증</h1>
        <p>{operator.name}님, 인증 앱으로 운영실 접근을 확인합니다.</p>
        {!ready ? (
          <Busy />
        ) : !factor ? (
          <>
            <p className="fine-print">
              Google Authenticator 등 인증 앱을 연결해 주세요.
              <br />
              Google 로그인 후 6자리 인증번호로 한 번 더 확인합니다.
            </p>
            <button className="primary wide" onClick={enroll} disabled={busy}>
              인증 앱 연결
            </button>
          </>
        ) : (
          <form onSubmit={verify}>
            {qr && (
              <>
                <img
                  className="qr"
                  src={
                    qr.startsWith("data:")
                      ? qr
                      : `data:image/svg+xml;utf8,${encodeURIComponent(qr)}`
                  }
                  alt="인증 앱에 등록할 QR 코드"
                />
                <details>
                  <summary>QR 코드를 스캔할 수 없나요?</summary>
                  <code className="secret">{secret}</code>
                </details>
              </>
            )}
            <label>
              인증 앱의 6자리 번호
              <input
                autoFocus
                inputMode="numeric"
                autoComplete="one-time-code"
                pattern="[0-9]{6}"
                maxLength={6}
                required
                value={code}
                onChange={(e) => setCode(e.target.value)}
                placeholder="000000"
              />
            </label>
            <button className="primary wide" disabled={busy}>
              인증하고 운영실 열기 <ArrowRight size={16} />
            </button>
          </form>
        )}
        {error && <Failure error={error} />}
        <button className="text-button" onClick={onLogout}>
          로그아웃
        </button>
      </div>
    </main>
  );
}

function Dashboard({
  api,
  operator,
  onLogout,
  onIdentityError,
}: {
  api: Api;
  operator: Operator;
  onLogout: () => void;
  onIdentityError: () => void;
}) {
  const [route, setRoute] = useState(readRoute);
  const [overview, setOverview] = useState<Overview>();
  const [revision, setRevision] = useState(0);
  const [toast, setToast] = useState("");
  const [navOpen, setNavOpen] = useState(false);
  const [overviewError, setOverviewError] = useState("");
  useEffect(() => {
    const change = () => {
      setRoute(readRoute());
      setNavOpen(false);
    };
    window.addEventListener("hashchange", change);
    return () => window.removeEventListener("hashchange", change);
  }, []);
  useEffect(() => {
    let live = true;
    setOverviewError("");
    api
      .overview()
      .then((v) => {
        if (live) setOverview(v);
      })
      .catch((e) => {
        if (live) {
          setOverviewError(errorText(e));
          if (
            /ops_access_denied|ops_mfa_required|ops_login_required/.test(
              e.message,
            )
          )
            onIdentityError();
        }
      });
    return () => {
      live = false;
    };
  }, [api, revision, onIdentityError]);
  useEffect(() => {
    if (!toast) return;
    const t = setTimeout(() => setToast(""), 4500);
    return () => clearTimeout(t);
  }, [toast]);
  const changed = (message: string) => {
    setToast(message);
    setRevision((r) => r + 1);
  };
  const nav = (page: Page, label?: string) => {
    const Icon = icons[page];
    return (
      <button
        key={page}
        className={`nav-item ${route.page === page ? "active" : ""}`}
        aria-current={route.page === page ? "page" : undefined}
        onClick={() => navigate(page)}
      >
        <Icon size={18} />
        <span>{label || titles[page]}</span>
        {page === "reports" && !!overview?.pendingReports && (
          <b>{overview.pendingReports}</b>
        )}
      </button>
    );
  };
  const canAccess = route.page !== "operators" || operator.role === "owner";
  return (
    <div className={`app ${navOpen ? "nav-open" : ""}`}>
      <a
        className="skip"
        href="#main"
        onClick={(e) => {
          e.preventDefault();
          document.getElementById("main")?.focus();
        }}
      >
        본문 바로가기
      </a>
      <aside className="sidebar">
        <a className="brand" href="#/overview">
          <img src="/brand/voku-logo.webp" alt="VOKU" />
          <span>
            On<small>운영 관리</small>
          </span>
        </a>
        <div className="workspace">
          <span className="workspace-icon">V</span>
          <div>
            <strong>VOKU On</strong>
            <small>동문 커뮤니티</small>
          </div>
          <span className="live-dot" />
        </div>
        <nav aria-label="운영 메뉴">
          {nav("overview")}
          <p className="nav-label">서비스 분석</p>
          {nav("analytics")}
          <p className="nav-label">커뮤니티 관리</p>
          {nav("posts")}
          {nav("comments")}
          {nav("reports")}
          {nav("members")}
          {nav("files")}
          <p className="nav-label">운영 설정</p>
          {operator.role === "owner" && nav("operators")}
          {nav("audit")}
          {nav("settings")}
        </nav>
        <div className="sidebar-bottom">
          <div className="separation">
            <ShieldCheck size={17} />
            <div>
              운영자 전용 공간<small>게시판 관리자와 권한 분리</small>
            </div>
          </div>
          <div className="user-card">
            <span className="avatar">{operator.name.slice(0, 1)}</span>
            <div>
              <strong>{operator.name}</strong>
              <small>{roleLabels[operator.role]}</small>
            </div>
            <button aria-label="로그아웃" title="로그아웃" onClick={onLogout}>
              <LogOut size={17} />
            </button>
          </div>
        </div>
      </aside>
      {navOpen && (
        <button
          className="nav-scrim"
          aria-label="메뉴 닫기"
          onClick={() => setNavOpen(false)}
        />
      )}
      <div className="main-shell">
        <header className="topbar">
          <div className="breadcrumb">
            <button
              className="mobile-menu icon-button"
              aria-label="메뉴 열기"
              onClick={() => setNavOpen(!navOpen)}
            >
              <Menu size={19} />
            </button>
            <span>운영 관리</span>
            <ChevronRight size={13} />
            <strong>{titles[route.page]}</strong>
          </div>
          <div className="top-tools">
            <span className={`connection ${previewMode ? "preview" : ""}`}>
              <i />
              {previewMode ? "예시 데이터" : "공유 서버 연결"}
            </span>
            <button
              className="icon-button notification-button"
              aria-label="미처리 신고 보기"
              onClick={() => navigate("reports", { status: "open" })}
            >
              <Bell size={18} />
              {!!overview?.pendingReports && <i />}
            </button>
            <span className="top-avatar">{operator.name.slice(0, 1)}</span>
          </div>
        </header>
        {previewMode && (
          <div className="preview-banner">
            <span>
              <span className="preview-tag">미리보기</span>예시 데이터로 동작을
              확인하는 화면입니다. 변경 사항은 새로고침하면 초기화됩니다.
            </span>
            <a href={location.pathname}>
              실제 운영자 로그인 <ArrowRight size={14} />
            </a>
          </div>
        )}
        <main id="main" className="main-content" tabIndex={-1}>
          <div className="page-heading">
            <div>
              <div className="page-eyebrow">
                {route.page === "overview"
                  ? "OPERATION OVERVIEW"
                  : "VOKU ON · COMMUNITY"}
              </div>
              <h1>{titles[route.page]}</h1>
              <p>{captions[route.page]}</p>
            </div>
            <div className="page-tools">
              <span className="today">
                {new Intl.DateTimeFormat("ko-KR", {
                  timeZone: "Asia/Seoul",
                  month: "long",
                  day: "numeric",
                  weekday: "long",
                }).format(new Date())}
              </span>
              <button
                className="secondary"
                onClick={() => setRevision((r) => r + 1)}
              >
                <RefreshCw size={15} />
                새로고침
              </button>
            </div>
          </div>
          {!canAccess ? (
            <Failure error="최고운영자만 운영자 권한을 관리할 수 있습니다." />
          ) : route.page === "overview" ? (
            <>
              {overviewError ? (
                <Failure
                  error={overviewError}
                  retry={() => setRevision((r) => r + 1)}
                />
              ) : overview ? (
                <OverviewPage data={overview} />
              ) : (
                <Busy />
              )}
            </>
          ) : route.page === "analytics" ? (
            <AnalyticsPage
              revision={revision}
              onIdentityError={onIdentityError}
            />
          ) : route.page === "settings" ? (
            <Settings operator={operator} />
          ) : (
            <ListPage
              key={route.page}
              api={api}
              kind={route.page}
              query={route.query}
              selectedId={route.id}
              operator={operator}
              revision={revision}
              changed={changed}
              onIdentityError={onIdentityError}
            />
          )}
          <footer className="main-footer">
            <span>
              VOKU On <i>·</i> 함께 지키는 우리의 기록
            </span>
            <span>운영 관리 시스템</span>
          </footer>
        </main>
      </div>
      {toast && (
        <div className="toast" role="status">
          <CheckCheck size={18} />
          {toast}
          <button aria-label="알림 닫기" onClick={() => setToast("")}>
            <X size={15} />
          </button>
        </div>
      )}
    </div>
  );
}

function OverviewPage({ data }: { data: Overview }) {
  const metrics = [
    {
      label: "미처리 신고",
      value: data.pendingReports,
      note: "확인이 필요한 신고",
      icon: Flag,
      page: "reports" as Page,
      status: "open",
      accent: true,
    },
    {
      label: "공개 게시글",
      value: data.posts,
      note: `고정된 공지 ${data.pinnedPosts}건`,
      icon: FileText,
      page: "posts" as Page,
      status: "published",
    },
    {
      label: "전체 회원",
      value: data.members,
      note: `오늘 가입 ${data.newMembers}명`,
      icon: Users,
      page: "members" as Page,
      status: "",
    },
    {
      label: "공개 댓글",
      value: data.comments,
      note: "동문들이 나누는 이야기",
      icon: MessageSquare,
      page: "comments" as Page,
      status: "published",
    },
  ];
  const max = Math.max(
    ...data.daily.map((d) => Math.max(d.posts, d.comments)),
    1,
  );
  return (
    <>
      <section className="metric-grid" aria-label="운영 요약">
        {metrics.map((m) => (
          <button
            className={`metric ${m.accent ? "accent" : ""}`}
            key={m.label}
            onClick={() => navigate(m.page, { status: m.status })}
          >
            <div className="metric-top">
              <span>{m.label}</span>
              <m.icon size={19} />
            </div>
            <div className="metric-value">
              {num(m.value)}
              <span>{m.page === "members" ? "명" : "건"}</span>
            </div>
            <div className="metric-note">
              {m.note}
              <ArrowRight size={15} />
            </div>
          </button>
        ))}
      </section>
      <section className="overview-grid">
        <div className="panel priority-panel">
          <PanelTitle
            title="처리할 신고"
            count={data.pendingReports}
            subtitle="원문을 확인하고 필요한 조치를 진행해 주세요."
            action={() => navigate("reports", { status: "open" })}
          />
          {data.reports.length ? (
            <div className="task-list">
              {data.reports.map((r) => (
                <button
                  className="task-row"
                  key={r.id}
                  onClick={() => navigate("reports", { status: "open" }, r.id)}
                >
                  <span
                    className={`reason-icon ${r.category === "개인정보 노출" ? "purple" : ""}`}
                  >
                    <Flag size={17} />
                  </span>
                  <div>
                    <div className="task-title">
                      <span className="reason-label">{r.category}</span>
                      <span className="dot-divider">·</span>
                      <span className="muted">{date(r.createdAt)}</span>
                    </div>
                    <strong>{r.title}</strong>
                    <small>신고자 {r.author}</small>
                  </div>
                  <ChevronRight size={17} />
                </button>
              ))}
            </div>
          ) : (
            <Empty
              title="확인할 신고가 없습니다"
              text="새로운 신고가 접수되면 이곳에 표시됩니다."
            />
          )}
          <div className="panel-foot">
            <ShieldCheck size={15} />
            <span>처리 사유와 담당자가 기록됩니다.</span>
          </div>
        </div>
        <div className="panel activity-panel">
          <PanelTitle
            title="최근 7일의 이야기"
            subtitle="일별 게시글과 댓글 등록 수"
          />
          <div className="chart-legend">
            <span>
              <i />
              게시글
            </span>
            <span>
              <i />
              댓글
            </span>
          </div>
          <div className="bar-chart" aria-label="최근 7일 게시글과 댓글 그래프">
            {data.daily.map((d) => (
              <div className="chart-day" key={d.date}>
                <div
                  className="bars"
                  title={`${d.date} 게시글 ${d.posts}개, 댓글 ${d.comments}개`}
                >
                  <span style={{ height: `${(d.posts / max) * 100}%` }} />
                  <span style={{ height: `${(d.comments / max) * 100}%` }} />
                </div>
                <span>{d.date.slice(5).replace("-", ".")}</span>
                <span className="sr-only">
                  게시글 {d.posts}개, 댓글 {d.comments}개
                </span>
              </div>
            ))}
          </div>
          <div className="chart-summary">
            <span>일주일 동안 등록된 게시글</span>
            <strong>
              {num(data.daily.reduce((s, d) => s + d.posts, 0))}
              <small>건</small>
            </strong>
          </div>
        </div>
      </section>
      <section className="overview-bottom">
        <div className="panel">
          <PanelTitle title="최근 게시글" action={() => navigate("posts")} />
          {data.recentPosts.length ? (
            <div className="compact-table">
              {data.recentPosts.map((p) => (
                <button key={p.id} onClick={() => navigate("posts", {}, p.id)}>
                  <span className="category-tag">{p.category}</span>
                  <strong>
                    {p.pinned && <Pin size={13} />} {p.title}
                  </strong>
                  <span>{p.author}</span>
                  <span>{date(p.createdAt).slice(6)}</span>
                </button>
              ))}
            </div>
          ) : (
            <Empty
              title="아직 게시글이 없습니다"
              text="웹앱에 등록된 글이 표시됩니다."
            />
          )}
        </div>
        <div className="panel">
          <PanelTitle title="최근 처리 기록" action={() => navigate("audit")} />
          {data.audit.length ? (
            <div className="timeline">
              {data.audit.map((a) => (
                <button key={a.id} onClick={() => navigate("audit", {}, a.id)}>
                  <span className="timeline-dot">
                    <Check size={12} />
                  </span>
                  <div>
                    <strong>{actionLabels[a.category] || a.category}</strong>
                    <p>{a.title}</p>
                    <small>
                      {a.author} <i>·</i> {date(a.createdAt, true)}
                    </small>
                  </div>
                </button>
              ))}
            </div>
          ) : (
            <Empty
              title="아직 처리 기록이 없습니다"
              text="첫 운영 조치부터 이력이 남습니다."
            />
          )}
        </div>
      </section>
      <section className="quick-status">
        <div>
          <span className="small-icon">
            <SlidersHorizontal size={18} />
          </span>
          <strong>운영 상태를 확인하세요</strong>
        </div>
        <button onClick={() => navigate("posts", { status: "hidden" })}>
          숨김 게시글 <b>{data.hiddenPosts}</b>
          <ChevronRight size={15} />
        </button>
        <button onClick={() => navigate("members", { status: "suspended" })}>
          이용 제한 회원 <b>{data.suspendedMembers}</b>
          <ChevronRight size={15} />
        </button>
        <button onClick={() => navigate("posts", { pinned: true })}>
          고정된 공지 <b>{data.pinnedPosts}</b>
          <ChevronRight size={15} />
        </button>
      </section>
    </>
  );
}
function PanelTitle({
  title,
  subtitle,
  count,
  action,
}: {
  title: string;
  subtitle?: string;
  count?: number;
  action?: () => void;
}) {
  return (
    <div className="panel-heading">
      <div>
        <h2>
          {title}
          {count !== undefined && <b>{count}</b>}
        </h2>
        {subtitle && <p>{subtitle}</p>}
      </div>
      {action && (
        <button className="text-button" onClick={action}>
          전체보기 <ChevronRight size={14} />
        </button>
      )}
    </div>
  );
}

function ListPage({
  api,
  kind,
  query,
  selectedId,
  operator,
  revision,
  changed,
  onIdentityError,
}: {
  api: Api;
  kind: Kind;
  query: Query;
  selectedId: string;
  operator: Operator;
  revision: number;
  changed: (s: string) => void;
  onIdentityError: () => void;
}) {
  const [listing, setListing] = useState<Listing>();
  const [error, setError] = useState("");
  const [loading, setLoading] = useState(true);
  const [selected, setSelected] = useState<string[]>([]);
  const [draft, setDraft] = useState(query);
  const [action, setAction] = useState("");
  const [actionItems, setActionItems] = useState<Item[]>([]);
  const [showInvite, setShowInvite] = useState(false);
  const [detail, setDetail] = useState<Detail>();
  const [detailError, setDetailError] = useState("");
  const [localRevision, setLocalRevision] = useState(0);
  const serialized = JSON.stringify(query);
  useEffect(() => {
    setDraft(query);
    setSelected([]);
    let live = true;
    setLoading(true);
    setError("");
    api
      .list(kind, query)
      .then((v) => {
        if (live) setListing(v);
      })
      .catch((e) => {
        if (live) {
          setError(errorText(e));
          setListing(undefined);
          if (
            /ops_access_denied|ops_mfa_required|ops_login_required/.test(
              e.message,
            )
          )
            onIdentityError();
        }
      })
      .finally(() => {
        if (live) setLoading(false);
      });
    return () => {
      live = false;
    };
  }, [api, kind, serialized, revision, localRevision, onIdentityError]);
  useEffect(() => {
    let live = true;
    setDetail(undefined);
    setDetailError("");
    if (selectedId)
      api
        .detail(kind, selectedId)
        .then((v) => {
          if (live) setDetail(v);
        })
        .catch((e) => {
          if (live) {
            setDetailError(errorText(e));
            if (
              /ops_access_denied|ops_mfa_required|ops_login_required/.test(
                e.message,
              )
            )
              onIdentityError();
          }
        });
    return () => {
      live = false;
    };
  }, [api, kind, selectedId, revision, localRevision, onIdentityError]);
  const writable =
    operator.role !== "viewer" && !["files", "audit"].includes(kind);
  const selectable = writable && kind !== "operators";
  const pageCount = Math.max(
    1,
    Math.ceil((listing?.total || 0) / query.pageSize),
  );
  const changeQuery = (change: Partial<Query>) =>
    navigate(kind, { ...query, ...change });
  const chooseAction = (name: string, items?: Item[]) => {
    setActionItems(
      items || listing?.items.filter((i) => selected.includes(i.id)) || [],
    );
    setAction(name);
  };
  const finish = (message: string) => {
    setAction("");
    setShowInvite(false);
    setSelected([]);
    changed(message);
  };
  const bulkActions =
    kind === "posts"
      ? ["hide", "restore", "pin", "unpin", "lock", "unlock"]
      : kind === "comments"
        ? ["hide", "restore"]
        : kind === "reports"
          ? ["resolve_hide", "dismiss"]
          : kind === "members"
            ? ["suspend", "unsuspend"]
            : [];
  const closeDetail = () => navigate(kind, query, "", true);
  const submitSearch = (e: FormEvent) => {
    e.preventDefault();
    if (draft.from && draft.to && draft.from > draft.to) {
      setError("시작일은 종료일보다 이전이어야 합니다.");
      return;
    }
    navigate(kind, { ...draft, page: 1 });
  };
  return (
    <>
      <section className="panel list-panel">
        <div className="list-tabs">
          <div className="filter-tabs" role="group" aria-label="상태 필터">
            <button
              className={!query.status && !query.pinned ? "selected" : ""}
              onClick={() =>
                changeQuery({ status: "", pinned: false, page: 1 })
              }
            >
              전체
              {!query.status && !query.pinned && listing && (
                <b>{num(listing.total)}</b>
              )}
            </button>
            {statuses[kind].map((s) => (
              <button
                key={s}
                className={query.status === s ? "selected" : ""}
                onClick={() =>
                  changeQuery({ status: s, pinned: false, page: 1 })
                }
              >
                {stateLabels[s]}
              </button>
            ))}
            {kind === "posts" && (
              <button
                className={query.pinned ? "selected" : ""}
                onClick={() =>
                  changeQuery({ status: "", pinned: true, page: 1 })
                }
              >
                <Pin size={13} />
                공지
              </button>
            )}
          </div>
          {kind === "operators" && (
            <button
              className="primary small"
              onClick={() => setShowInvite(true)}
            >
              <Plus size={15} />
              운영자 등록
            </button>
          )}
        </div>
        <form className="search-form" onSubmit={submitSearch}>
          <label className="search-type">
            <span className="sr-only">검색 대상</span>
            <select
              value={draft.field}
              onChange={(e) => setDraft({ ...draft, field: e.target.value })}
            >
              <option value="all">통합 검색</option>
              <option value="title">
                {kind === "members" || kind === "operators" ? "이름" : "제목"}
              </option>
              <option value="author">
                {kind === "reports" ? "신고자" : "작성자 / 담당자"}
              </option>
            </select>
          </label>
          <label className="search-box">
            <Search size={17} />
            <input
              aria-label="검색어"
              placeholder={
                kind === "members"
                  ? "닉네임, 입학년도, 기수를 검색하세요"
                  : "제목, 내용, 작성자를 검색하세요"
              }
              value={draft.q}
              onChange={(e) => setDraft({ ...draft, q: e.target.value })}
            />
            {draft.q && (
              <button
                type="button"
                className="icon-button"
                aria-label="검색어 지우기"
                onClick={() => setDraft({ ...draft, q: "" })}
              >
                <X size={14} />
              </button>
            )}
          </label>
          {["posts", "comments", "files"].includes(kind) && (
            <select
              aria-label="게시판"
              value={draft.category}
              onChange={(e) => setDraft({ ...draft, category: e.target.value })}
            >
              <option value="">전체 게시판</option>
              {categories.map((c) => (
                <option key={c}>{c}</option>
              ))}
            </select>
          )}
          <div className="date-filter">
            <input
              type="date"
              aria-label="시작일"
              value={draft.from}
              onChange={(e) => setDraft({ ...draft, from: e.target.value })}
            />
            <span>–</span>
            <input
              type="date"
              aria-label="종료일"
              value={draft.to}
              onChange={(e) => setDraft({ ...draft, to: e.target.value })}
            />
          </div>
          <button className="secondary" type="submit">
            검색
          </button>
          <button
            className="text-button reset"
            type="button"
            onClick={() => navigate(kind)}
          >
            초기화
          </button>
        </form>
        <div className="list-meta">
          <p>
            총 <b>{num(listing?.total || 0)}</b>건{" "}
            <span>
              · {query.page} / {pageCount} 페이지
            </span>
          </p>
          <div>
            <span className="muted">최신순</span>
            <select
              aria-label="페이지당 항목 수"
              value={query.pageSize}
              onChange={(e) =>
                changeQuery({ pageSize: Number(e.target.value), page: 1 })
              }
            >
              <option value={20}>20개씩 보기</option>
              <option value={50}>50개씩 보기</option>
            </select>
          </div>
        </div>
        {selected.length > 0 && (
          <div className="selection-bar">
            <strong>{selected.length}개 선택</strong>
            {bulkActions.map((a) => (
              <button key={a} onClick={() => chooseAction(a)}>
                {actionLabels[a]}
              </button>
            ))}
            <button className="selection-clear" onClick={() => setSelected([])}>
              선택 해제 <X size={13} />
            </button>
          </div>
        )}
        {error && (
          <Failure error={error} retry={() => setLocalRevision((r) => r + 1)} />
        )}
        <div
          className={`table-wrap ${loading ? "is-loading" : ""}`}
          aria-busy={loading}
        >
          {loading && !listing ? (
            <Busy />
          ) : !listing?.items.length ? (
            <Empty
              title={
                query.q ||
                query.status ||
                query.category ||
                query.from ||
                query.to ||
                query.pinned
                  ? "검색 결과가 없습니다"
                  : `${titles[kind]} 항목이 없습니다`
              }
              text={
                query.q || query.status
                  ? "검색어나 필터를 바꿔 다시 확인해 주세요."
                  : "등록된 데이터가 생기면 목록에 표시됩니다."
              }
            />
          ) : (
            <table className="data-table">
              <thead>
                <tr>
                  {selectable && (
                    <th className="check-cell">
                      <input
                        type="checkbox"
                        aria-label="현재 페이지 전체 선택"
                        checked={listing.items.every((i) =>
                          selected.includes(i.id),
                        )}
                        onChange={(e) =>
                          setSelected(
                            e.target.checked
                              ? listing.items.map((i) => i.id)
                              : [],
                          )
                        }
                      />
                    </th>
                  )}
                  <th className="number-cell">번호</th>
                  <th className="subject-cell">
                    {kind === "members"
                      ? "회원"
                      : kind === "operators"
                        ? "운영자"
                        : kind === "audit"
                          ? "처리 내용"
                          : kind === "files"
                            ? "파일명"
                            : "제목 / 내용"}
                  </th>
                  <th>
                    {kind === "reports"
                      ? "신고 사유"
                      : kind === "members" || kind === "operators"
                        ? "역할"
                        : kind === "audit"
                          ? "처리 유형"
                          : "게시판"}
                  </th>
                  <th>
                    {kind === "reports"
                      ? "신고자"
                      : kind === "members"
                        ? "입학년도 / 기수"
                        : kind === "operators"
                          ? "이메일"
                          : kind === "audit"
                            ? "담당자"
                            : "작성자"}
                  </th>
                  <th>상태</th>
                  <th className="date-cell">
                    {kind === "members" || kind === "operators"
                      ? "등록일"
                      : "등록 / 처리일"}
                  </th>
                  <th className="row-arrow">
                    <span className="sr-only">상세보기</span>
                  </th>
                </tr>
              </thead>
              <tbody>
                {listing.items.map((item, index) => (
                  <tr
                    key={item.id}
                    className={
                      selected.includes(item.id)
                        ? "checked"
                        : selectedId === item.id
                          ? "focused-row"
                          : ""
                    }
                  >
                    {selectable && (
                      <td className="check-cell">
                        <input
                          type="checkbox"
                          aria-label={`${item.title} 선택`}
                          checked={selected.includes(item.id)}
                          onChange={(e) =>
                            setSelected(
                              e.target.checked
                                ? [...selected, item.id]
                                : selected.filter((v) => v !== item.id),
                            )
                          }
                        />
                      </td>
                    )}
                    <td className="number-cell">
                      {listing.total -
                        (query.page - 1) * query.pageSize -
                        index}
                    </td>
                    <td className="subject-cell">
                      <button
                        className="row-title"
                        onClick={() => navigate(kind, query, item.id)}
                      >
                        {item.pinned && (
                          <span className="pinned">
                            <Pin size={12} />
                            공지
                          </span>
                        )}
                        {item.secret && <LockKeyhole size={13} />}
                        <span>{item.title}</span>
                        {kind === "posts" && !!item.commentCount && (
                          <small>[{item.commentCount}]</small>
                        )}
                      </button>
                      {kind === "comments" && (
                        <div className="row-sub">원글 · {item.postTitle}</div>
                      )}
                      {kind === "audit" && (
                        <div className="row-sub">{item.body}</div>
                      )}
                    </td>
                    <td>
                      <span className="category-text">
                        {kind === "members" || kind === "operators"
                          ? roleLabels[item.category]
                          : kind === "audit"
                            ? actionLabels[item.category] || item.category
                            : item.category || "—"}
                      </span>
                    </td>
                    <td className="author-cell">
                      {kind === "members"
                        ? `${item.admissionYear || "—"} / ${item.cohort ? item.cohort + "기" : "—"}`
                        : item.author}
                    </td>
                    <td>
                      {kind === "audit" ? (
                        <span className="source-tag">
                          {item.source === "community" ? "게시판" : "운영실"}
                        </span>
                      ) : (
                        <Badge status={item.status} />
                      )}
                    </td>
                    <td className="date-cell">{date(item.createdAt)}</td>
                    <td className="row-arrow">
                      <button
                        aria-label={`${item.title} 상세보기`}
                        className="icon-button"
                        onClick={() => navigate(kind, query, item.id)}
                      >
                        <ChevronRight size={15} />
                      </button>
                    </td>
                  </tr>
                ))}
              </tbody>
            </table>
          )}
        </div>
        <div className="list-footer">
          <span>
            {selectable
              ? "선택한 항목을 한 번에 처리할 수 있습니다."
              : kind === "operators"
                ? "항목을 열어 담당 권한과 접근 상태를 관리합니다."
                : "읽기 전용 목록입니다."}
          </span>
          <div className="pagination" aria-label="페이지 이동">
            <button
              aria-label="이전 페이지"
              disabled={query.page <= 1 || loading}
              onClick={() => changeQuery({ page: query.page - 1 })}
            >
              <ChevronLeft size={16} />
            </button>
            {Array.from(
              { length: Math.min(5, pageCount) },
              (_, i) =>
                Math.max(1, Math.min(query.page - 2, pageCount - 4)) + i,
            ).map((p) => (
              <button
                key={p}
                className={p === query.page ? "current" : ""}
                aria-current={p === query.page ? "page" : undefined}
                onClick={() => changeQuery({ page: p })}
              >
                {p}
              </button>
            ))}
            <button
              aria-label="다음 페이지"
              disabled={query.page >= pageCount || loading}
              onClick={() => changeQuery({ page: query.page + 1 })}
            >
              <ChevronRight size={16} />
            </button>
          </div>
        </div>
      </section>
      {operator.role === "viewer" && (
        <div className="permission-note">
          <ShieldCheck size={16} />
          조회 담당자는 내용을 확인할 수 있으며 변경 작업은 수행할 수 없습니다.
        </div>
      )}
      {kind === "members" && (
        <div className="permission-note">
          <ShieldCheck size={16} />
          게시판 관리자·운영진의 기존 역할은 유지됩니다. 이용 제한은
          일반회원에게만 적용할 수 있습니다.
        </div>
      )}
      {selectedId && (
        <Dialog onClose={closeDetail} className="detail-dialog">
          <div className="detail-heading">
            <span>
              {titles[kind]} <ChevronRight size={13} />
              상세보기
            </span>
            <button
              className="icon-button"
              aria-label="상세 닫기"
              onClick={closeDetail}
            >
              <PanelRightClose size={20} />
            </button>
          </div>
          {detailError ? (
            <Failure
              error={detailError}
              retry={() => setLocalRevision((r) => r + 1)}
            />
          ) : detail ? (
            <ItemDetail
              detail={detail}
              kind={kind}
              operator={operator}
              chooseAction={(a) => chooseAction(a, [detail.item])}
            />
          ) : (
            <Busy />
          )}
        </Dialog>
      )}
      {action && (
        <ActionDialog
          action={action}
          items={actionItems}
          kind={kind}
          api={api}
          onClose={() => setAction("")}
          onDone={finish}
        />
      )}{" "}
      {showInvite && (
        <InviteDialog
          api={api}
          onClose={() => setShowInvite(false)}
          onDone={finish}
        />
      )}
    </>
  );
}

function Dialog({
  children,
  onClose,
  className = "",
}: {
  children: ReactNode;
  onClose: () => void;
  className?: string;
}) {
  const ref = useRef<HTMLDialogElement>(null);
  useEffect(() => {
    const d = ref.current!;
    d.showModal();
    return () => {
      d.close();
    };
  }, []);
  return (
    <dialog
      ref={ref}
      className={className}
      aria-label={
        className === "detail-dialog" ? "항목 상세" : "운영 작업 확인"
      }
      onCancel={(e) => {
        e.preventDefault();
        onClose();
      }}
    >
      {children}
    </dialog>
  );
}
function ItemDetail({
  detail,
  kind,
  operator,
  chooseAction,
}: {
  detail: Detail;
  kind: Kind;
  operator: Operator;
  chooseAction: (a: string) => void;
}) {
  const i = detail.item;
  const [photos, setPhotos] = useState<{ url: string; id: string }[]>([]);
  const [photoError, setPhotoError] = useState("");
  useEffect(() => {
    let active = true;
    setPhotos([]);
    setPhotoError("");
    Promise.all(
      detail.photos.map(async (p) => ({
        id: p.id,
        url: await photoUrl(p.path),
      })),
    )
      .then((v) => {
        if (active) setPhotos(v.filter((p) => p.url));
      })
      .catch(() => {
        if (active)
          setPhotoError(
            "첨부사진을 불러오지 못했습니다. 창을 다시 열어 확인해 주세요.",
          );
      });
    return () => {
      active = false;
    };
  }, [detail]);
  let actions: string[] = [];
  if (operator.role !== "viewer" && i.status !== "deleted") {
    if (kind === "posts") {
      actions = [
        i.status === "hidden" ? "restore" : "hide",
        i.pinned ? "unpin" : "pin",
        i.locked ? "unlock" : "lock",
      ];
      if (i.secret || i.status !== "published")
        actions = actions.filter((a) => a !== "pin");
    }
    if (kind === "comments")
      actions = [i.status === "hidden" ? "restore" : "hide"];
    if (kind === "reports" && i.status === "open")
      actions = ["resolve_hide", "dismiss"];
    if (kind === "members" && i.role === "member")
      actions = [i.status === "suspended" ? "unsuspend" : "suspend"];
    if (
      kind === "operators" &&
      operator.role === "owner" &&
      i.id !== operator.id
    )
      actions =
        i.status === "invited"
          ? ["cancel_invite"]
          : i.status === "cancelled"
            ? []
            : ["role", i.status === "active" ? "disable" : "enable"];
  }
  return (
    <>
      <div className="detail-body">
        <div className="detail-tags">
          <Badge status={i.status} />
          <span>
            {roleLabels[i.category] || actionLabels[i.category] || i.category}
          </span>
          {i.secret && (
            <span>
              <LockKeyhole size={13} />
              비밀글
            </span>
          )}
        </div>
        <h2>{i.title}</h2>
        <dl className="detail-meta">
          <div>
            <dt>
              {kind === "reports"
                ? "신고자"
                : kind === "members"
                  ? "닉네임"
                  : kind === "operators"
                    ? "이메일"
                    : "작성자 / 담당자"}
            </dt>
            <dd>{i.author}</dd>
          </div>
          <div>
            <dt>등록일</dt>
            <dd>{date(i.createdAt, true)}</dd>
          </div>
          {i.postTitle && (
            <div>
              <dt>연결된 글</dt>
              <dd>{i.postTitle}</dd>
            </div>
          )}
          {i.targetAuthor && (
            <div>
              <dt>신고 대상 작성자</dt>
              <dd>{i.targetAuthor}</dd>
            </div>
          )}
          {i.suspendedUntil && (
            <div>
              <dt>이용 제한 종료</dt>
              <dd>{date(i.suspendedUntil, true)}</dd>
            </div>
          )}
          {i.email && (
            <div>
              <dt>운영 역할</dt>
              <dd>{roleLabels[i.role || ""]}</dd>
            </div>
          )}
          {i.path && (
            <div>
              <dt>저장 경로</dt>
              <dd className="break-anywhere">{i.path}</dd>
            </div>
          )}
        </dl>
        {i.publicCode && (
          <p className="fine-print">
            공개 주소:{" "}
            <a
              href={`https://voku.pages.dev/p/${i.publicCode}`}
              target="_blank"
              rel="noreferrer"
            >
              {i.publicCode} <ExternalLink size={12} />
            </a>
          </p>
        )}
        {i.sample && (
          <p className="report-note">
            예시 콘텐츠 · 기본 실사용 통계에서 제외됩니다.
          </p>
        )}
        {i.introduction && (
          <section className="original">
            <span className="section-label">선택 프로필 · 자기소개</span>
            <p>{i.introduction}</p>
          </section>
        )}
        {kind === "reports" && (
          <div className="report-note">
            <span className="section-label">신고 사유</span>
            <strong>{i.category}</strong>
            <p>{i.detail || "추가 설명이 없습니다."}</p>
          </div>
        )}
        {i.body && (
          <section className="original">
            <span className="section-label">
              {kind === "reports"
                ? "신고 대상 원문"
                : kind === "audit"
                  ? "처리 사유"
                  : kind === "members"
                    ? "이용 제한 사유"
                    : "내용"}
            </span>
            <p>{i.body}</p>
          </section>
        )}
        {photos.length > 0 && (
          <div className="photo-grid">
            {photos.map((p) => (
              <a key={p.id} href={p.url} target="_blank" rel="noreferrer">
                <img src={p.url} alt="게시글 첨부사진" />
              </a>
            ))}
          </div>
        )}
        {photoError && <p className="fine-print">{photoError}</p>}
        {kind === "files" && i.postId && (
          <button
            className="secondary"
            onClick={() => navigate("posts", {}, i.postId)}
          >
            연결된 게시글 보기 <ArrowRight size={14} />
          </button>
        )}
        {i.resolution && (
          <section className="resolution">
            <span className="section-label">처리 결과</span>
            <p>{i.resolution}</p>
            <small>{date(i.resolvedAt, true)}</small>
          </section>
        )}
        {i.before && (
          <section className="change-details">
            <span className="section-label">변경 내역</span>
            {["status", "pinned", "locked", "role", "suspendedUntil"]
              .filter(
                (k) =>
                  JSON.stringify(i.before?.[k]) !==
                  JSON.stringify(i.after?.[k]),
              )
              .map((k) => (
                <div key={k}>
                  <span>
                    {
                      {
                        status: "상태",
                        pinned: "공지 고정",
                        locked: "댓글 잠금",
                        role: "역할",
                        suspendedUntil: "제한 종료",
                      }[k]
                    }
                  </span>
                  <code>
                    {String(i.before?.[k] ?? "—")} →{" "}
                    {String(i.after?.[k] ?? "—")}
                  </code>
                </div>
              ))}
          </section>
        )}
        {kind !== "audit" && (
          <section className="detail-history">
            <h3>
              이 항목의 처리 기록 <span>{detail.history.length}</span>
            </h3>
            {detail.history.length ? (
              detail.history.map((a) => (
                <div key={a.id}>
                  <strong>{actionLabels[a.category] || a.category}</strong>
                  <p>{a.body}</p>
                  <small>
                    {a.author} · {date(a.createdAt, true)}
                  </small>
                </div>
              ))
            ) : (
              <p className="muted">아직 처리 기록이 없습니다.</p>
            )}
          </section>
        )}
      </div>
      {actions.length > 0 && (
        <div className="detail-actions">
          {actions.map((a, index) => (
            <button
              key={a}
              className={index === 0 ? "primary" : "secondary"}
              onClick={() => chooseAction(a)}
            >
              {actionLabels[a]}
            </button>
          ))}
        </div>
      )}
    </>
  );
}

function ActionDialog({
  api,
  kind,
  action,
  items,
  onClose,
  onDone,
}: {
  api: Api;
  kind: Kind;
  action: string;
  items: Item[];
  onClose: () => void;
  onDone: (s: string) => void;
}) {
  const [reason, setReason] = useState("");
  const [days, setDays] = useState(7);
  const [role, setRole] = useState(items[0]?.role || "operator");
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState("");
  async function submit(e: FormEvent) {
    e.preventDefault();
    setBusy(true);
    setError("");
    try {
      const result = await api.mutate(kind, action, items, reason, {
        days,
        role,
      });
      onDone(
        `${result.changed}건 ${actionLabels[action]} 완료${previewMode ? " · 미리보기" : ""}`,
      );
    } catch (e) {
      setError(errorText(e));
    } finally {
      setBusy(false);
    }
  }
  return (
    <Dialog
      onClose={() => {
        if (!busy) onClose();
      }}
      className="action-dialog"
    >
      <div className="modal-heading">
        <h2>{actionLabels[action]}</h2>
        <button
          className="icon-button"
          aria-label="처리창 닫기"
          disabled={busy}
          onClick={onClose}
        >
          <X size={19} />
        </button>
      </div>
      <form onSubmit={submit}>
        <div className="action-summary">
          <strong>{items.length}개 항목을 처리합니다</strong>
          <p>
            {items[0]?.title}
            {items.length > 1 ? ` 외 ${items.length - 1}개` : ""}
          </p>
        </div>
        {action === "resolve_hide" && (
          <p className="fine-print">
            신고 대상 글 또는 댓글을 숨기고 신고를 처리 완료로 변경합니다.
          </p>
        )}
        {action === "suspend" && (
          <label>
            이용 제한 기간
            <select
              value={days}
              onChange={(e) => setDays(Number(e.target.value))}
            >
              <option value={1}>1일</option>
              <option value={7}>7일</option>
              <option value={30}>30일</option>
              <option value={365}>1년</option>
            </select>
          </label>
        )}
        {action === "role" && (
          <label>
            변경할 역할
            <select value={role} onChange={(e) => setRole(e.target.value)}>
              <option value="owner">최고운영자</option>
              <option value="operator">운영자</option>
              <option value="viewer">조회 담당자</option>
            </select>
          </label>
        )}
        <label>
          처리 사유 <span className="required">필수</span>
          <textarea
            autoFocus
            required
            minLength={2}
            maxLength={500}
            rows={4}
            value={reason}
            onChange={(e) => setReason(e.target.value)}
            placeholder="다른 담당자도 이해할 수 있도록 사유를 남겨 주세요."
          />
          <span className="character-count">{reason.length} / 500</span>
        </label>
        {error && <Failure error={error} />}
        <div className="modal-footer">
          <button
            className="secondary"
            type="button"
            disabled={busy}
            onClick={onClose}
          >
            취소
          </button>
          <button
            className="primary"
            disabled={busy || reason.trim().length < 2}
          >
            {busy ? "처리 중…" : `${actionLabels[action]} 확정`}
          </button>
        </div>
      </form>
    </Dialog>
  );
}
function InviteDialog({
  api,
  onClose,
  onDone,
}: {
  api: Api;
  onClose: () => void;
  onDone: (s: string) => void;
}) {
  const [email, setEmail] = useState("");
  const [name, setName] = useState("");
  const [role, setRole] = useState("operator");
  const [reason, setReason] = useState("");
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState("");
  async function submit(e: FormEvent) {
    e.preventDefault();
    setBusy(true);
    try {
      await api.invite(email.trim(), name.trim(), role, reason.trim());
      onDone(
        "운영자 등록 명단에 추가했습니다. 등록 화면에서 계정을 만들 수 있습니다.",
      );
    } catch (e) {
      setError(errorText(e));
    } finally {
      setBusy(false);
    }
  }
  return (
    <Dialog
      onClose={() => {
        if (!busy) onClose();
      }}
      className="action-dialog"
    >
      <div className="modal-heading">
        <h2>운영자 등록 허용</h2>
        <button
          className="icon-button"
          aria-label="등록창 닫기"
          disabled={busy}
          onClick={onClose}
        >
          <X size={19} />
        </button>
      </div>
      <p className="fine-print">
        기존 회원과 다른 Google 계정 이메일을 등록해 주세요. 담당자가 해당
        Google 계정으로 처음 로그인한 뒤 인증 앱으로 2단계 인증을 설정합니다.
      </p>
      <form onSubmit={submit}>
        <label>
          담당자 이름
          <input
            autoFocus
            required
            maxLength={40}
            value={name}
            onChange={(e) => setName(e.target.value)}
          />
        </label>
        <label>
          운영자 전용 이메일
          <input
            type="email"
            required
            maxLength={254}
            value={email}
            onChange={(e) => setEmail(e.target.value)}
          />
        </label>
        <label>
          역할
          <select value={role} onChange={(e) => setRole(e.target.value)}>
            {["operator", "viewer", "owner"].map((r) => (
              <option key={r} value={r}>
                {roleLabels[r]}
              </option>
            ))}
          </select>
        </label>
        <label>
          등록 사유
          <textarea
            required
            minLength={2}
            maxLength={500}
            value={reason}
            onChange={(e) => setReason(e.target.value)}
            rows={2}
          />
        </label>
        {error && <Failure error={error} />}
        <div className="modal-footer">
          <button
            type="button"
            className="secondary"
            onClick={onClose}
            disabled={busy}
          >
            취소
          </button>
          <button className="primary" disabled={busy}>
            {busy ? "등록 중…" : "등록 허용"}
          </button>
        </div>
      </form>
    </Dialog>
  );
}
function Settings({ operator }: { operator: Operator }) {
  return (
    <div className="settings-grid">
      <section className="panel settings-panel">
        <ShieldCheck size={24} />
        <h2>분리된 운영 권한</h2>
        <p>
          현재 계정은 <strong>{roleLabels[operator.role]}</strong>입니다.
        </p>
        <table>
          <thead>
            <tr>
              <th>역할</th>
              <th>업무 범위</th>
            </tr>
          </thead>
          <tbody>
            <tr>
              <td>최고운영자</td>
              <td>운영 조치와 운영자 계정·권한 관리</td>
            </tr>
            <tr>
              <td>운영자</td>
              <td>글·댓글·신고 처리, 일반회원 이용 제한</td>
            </tr>
            <tr>
              <td>조회 담당자</td>
              <td>운영 정보와 처리 기록 조회</td>
            </tr>
          </tbody>
        </table>
        <p className="fine-print">
          웹앱의 게시판 관리자와 운영진은 별도 역할입니다. 이곳에서 운영자로
          자동 승격되거나 역할이 변경되지 않습니다.
        </p>
      </section>
      <section className="panel settings-panel">
        <Clock3 size={24} />
        <h2>운영 처리 기준</h2>
        <ul>
          <li>원문과 신고 사유를 함께 확인합니다.</li>
          <li>숨김·복원 등 모든 변경에 사유를 남깁니다.</li>
          <li>작성자가 삭제한 콘텐츠는 복원하지 않습니다.</li>
          <li>동시에 변경된 항목은 다시 확인한 뒤 처리합니다.</li>
        </ul>
        <div className="info-note">
          처리 기록에서 담당자, 시간, 사유와 변경 내역을 확인할 수 있습니다.
          날짜는 한국 시간 기준입니다.
        </div>
      </section>
      <section className="panel settings-panel full">
        <FolderOpen size={24} />
        <h2>연결된 서비스</h2>
        <div className="service-row">
          <strong>VOKU On 커뮤니티</strong>
          <Badge status="active" />
          <span>게시글 · 댓글 · 신고 · 회원 · 첨부사진</span>
        </div>
        <p className="fine-print">
          아카이브 원본과 웹앱의 정적 배너 편집은 현재 운영 메뉴에 포함되지
          않습니다. 웹앱 내부의 게시판 관리자 화면은 그대로 유지됩니다.
        </p>
      </section>
    </div>
  );
}
