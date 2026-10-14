import { useEffect, useState, type ReactNode } from "react";
import { Download, RefreshCw, ArrowRight, Info } from "lucide-react";
import { errorText, previewMode } from "../api";
import { usageExport, usageReport } from "./api";
import { download, reportCsv } from "./export";
import type { Row, UsageReport, UsageTrend } from "./types";
import "./analytics.css";
const number = (n: unknown) => Number(n || 0).toLocaleString("ko-KR");
const mins = (n: unknown) => `${(Number(n || 0) / 60000).toFixed(1)}분`;
const date = (n: string | null) =>
  n
    ? new Date(n).toLocaleString("ko-KR", { timeZone: "Asia/Seoul" })
    : "아직 없음";
const day = (offset = 0) =>
  new Date(Date.now() + 9 * 3600000 - offset * 86400000)
    .toISOString()
    .slice(0, 10);
const labels: Record<string, string> = {
  home: "홈",
  archive: "아카이브",
  reader: "큐시트 열람",
  board: "커뮤니티",
  post: "게시글",
  write: "글쓰기",
  search: "통합 검색",
  auth: "로그인·가입",
  account: "내 정보",
  news: "동문 소식",
  notifications: "알림",
  admin: "게시판 관리자",
  saved: "보관함",
  example: "예시 콘텐츠",
  other: "기타",
  direct: "직접·출처 없음",
  internal: "서비스 내부",
  mobile: "모바일",
  desktop: "데스크톱",
  tablet: "태블릿",
  none: "없음",
  search_results: "검색 결과 있음",
  search_empty: "검색 결과 없음",
  reader_action_zoom: "확대·축소",
  reader_action_rotate: "회전",
  reader_action_jump: "쪽 이동",
  reader_action_share: "회차 공유",
  reader_action_fit: "화면 맞춤",
  reader_action_resume: "이어 읽기",
  reader_compose: "큐시트로 글쓰기",
  archive_filter_year: "연도 선택",
  archive_filter_term: "학기 선택",
  archive_filter_program: "프로그램 선택",
  community_action_like: "글 추천",
  community_action_bookmark: "글 스크랩",
  community_action_archive_bookmark: "큐시트 저장",
  community_action_comment_like: "댓글 공감",
  community_action_report: "신고",
  auth_sign_in: "로그인",
  auth_sign_out: "로그아웃",
  feature_banner: "배너 열기",
  feature_menu: "메뉴 열기",
  image: "이미지 오류",
  rpc: "서버 요청",
  script: "스크립트 오류",
  unknown: "분류되지 않은 오류",
};
const label = (n: unknown) => labels[String(n)] || String(n ?? "—");
type Column = {
  key: string;
  label: string;
  render?: (value: unknown, row: Row) => ReactNode;
};
function Grid({
  title,
  caption,
  rows,
  columns,
}: {
  title: string;
  caption?: string;
  rows: Row[];
  columns: Column[];
}) {
  const [limit, setLimit] = useState(30);
  return (
    <section className="panel analytics-table">
      <div className="analytics-section-title">
        <h3>{title}</h3>
        <span>{rows.length.toLocaleString()}개 항목</span>
      </div>
      {caption && <p className="analytics-caption">{caption}</p>}
      <div className="analytics-scroll">
        <table>
          <thead>
            <tr>
              {columns.map((c) => (
                <th key={c.key} scope="col">
                  {c.label}
                </th>
              ))}
            </tr>
          </thead>
          <tbody>
            {rows.slice(0, limit).map((row, i) => (
              <tr key={i}>
                {columns.map((c) => (
                  <td key={c.key}>
                    {c.render
                      ? c.render(row[c.key], row)
                      : typeof row[c.key] === "number"
                        ? number(row[c.key])
                        : String(row[c.key] ?? "—")}
                  </td>
                ))}
              </tr>
            ))}
            {!rows.length && (
              <tr>
                <td colSpan={columns.length} className="analytics-empty">
                  이 기간에 관측된 기록이 없습니다.
                </td>
              </tr>
            )}
          </tbody>
        </table>
      </div>
      {rows.length > limit && (
        <button className="secondary" onClick={() => setLimit((n) => n + 100)}>
          100개 더 보기 · 내보내기에는 전체 포함
        </button>
      )}
    </section>
  );
}
function Daily({
  rows,
}: {
  rows: { day: string; totals: UsageReport["totals"] }[];
}) {
  const max = Math.max(1, ...rows.map((d) => d.totals.sessions));
  return (
    <section className="panel analytics-daily">
      <h3>날짜별 방문과 실제 열람</h3>
      <p className="analytics-caption">
        방문 세션 <i className="legend visits" /> · 30초 이상 열람한 세션×회차{" "}
        <i className="legend reads" /> · 한국 시간
      </p>
      <div
        className="analytics-bars"
        role="img"
        aria-label="날짜별 방문과 열람 막대 그래프. 아래 표에서 수치를 확인할 수 있습니다."
      >
        {rows.map((d) => (
          <div
            key={d.day}
            title={`${d.day} 방문 ${d.totals.sessions}, 열람 ${d.totals.qualifiedReads}`}
          >
            <div className="bar-pair">
              <i style={{ height: `${(d.totals.sessions / max) * 100}%` }} />
              <i
                style={{
                  height: `${Math.min(100, (d.totals.qualifiedReads / max) * 100)}%`,
                }}
              />
            </div>
            <small>{d.day.slice(5)}</small>
          </div>
        ))}
      </div>
      <details>
        <summary>일별 수치 표</summary>
        <Grid
          title="일별 관측"
          rows={rows.map((d) => ({ day: d.day, ...d.totals }))}
          columns={[
            { key: "day", label: "날짜" },
            { key: "browsers", label: "브라우저" },
            { key: "sessions", label: "세션" },
            { key: "qualifiedReads", label: "30초 열람" },
            { key: "readMs", label: "열람 시간", render: mins },
            { key: "readToCommunity", label: "열람 후 작성 세션" },
          ]}
        />
      </details>
    </section>
  );
}
export default function AnalyticsPage({
  revision,
  onIdentityError,
}: {
  revision: number;
  onIdentityError: () => void;
}) {
  const [from, setFrom] = useState(day(6)),
    [to, setTo] = useState(day()),
    [audience, setAudience] = useState("real"),
    [mode, setMode] = useState<"detail" | "trend">("detail");
  const [selection, setSelection] = useState({ from, to, audience, mode }),
    [data, setData] = useState<UsageReport | UsageTrend>(),
    [busy, setBusy] = useState(false),
    [error, setError] = useState(""),
    [exporting, setExporting] = useState(false),
    [receipt, setReceipt] = useState("");
  const [tab, setTab] = useState("overview");
  useEffect(() => {
    let active = true;
    setBusy(true);
    setError("");
    setData(undefined);
    setReceipt("");
    usageReport(
      selection.from,
      selection.to,
      selection.audience,
      selection.mode === "trend",
    )
      .then((r) => {
        if (active) setData(r);
      })
      .catch((e) => {
        if (active) {
          setError(errorText(e));
          if (
            /ops_access_denied|ops_mfa_required|ops_login_required/.test(
              e.message,
            )
          )
            onIdentityError();
        }
      })
      .finally(() => {
        if (active) setBusy(false);
      });
    return () => {
      active = false;
    };
  }, [selection, revision, onIdentityError]);
  const apply = () => {
    if (
      !from ||
      !to ||
      from > to ||
      to > day() ||
      (mode === "detail" && from < day(89)) ||
      (Date.parse(to) - Date.parse(from)) / 86400000 >
        (mode === "detail" ? 89 : 366)
    ) {
      setError(
        mode === "detail"
          ? "최근 90일 안의 올바른 기간을 선택해 주세요."
          : "한 번에 최대 367일을 선택해 주세요.",
      );
      return;
    }
    setSelection({ from, to, audience, mode });
  };
  const exportData = async (format: "csv" | "json") => {
    setExporting(true);
    setError("");
    try {
      const snapshot = await usageExport(
        selection.from,
        selection.to,
        selection.audience,
        selection.mode === "trend",
      );
      const name = `VOKU-${previewMode ? "EXAMPLE-" : ""}${selection.from}_${selection.to}-${selection.audience}-${snapshot.id}`;
      download(
        format === "json"
          ? JSON.stringify(snapshot, null, 2)
          : reportCsv(JSON.parse(snapshot.canonicalPayload)),
        `${name}.${format}`,
        format === "json" ? "application/json" : "text/csv;charset=utf-8",
      );
      setReceipt(`보고서 ${snapshot.id} · SHA-256 ${snapshot.sha256}`);
    } catch (e) {
      setError(errorText(e));
    } finally {
      setExporting(false);
    }
  };
  const r = data && "totals" in data ? data : undefined;
  const trend = data && "days" in data ? data : undefined;
  return (
    <div className="analytics">
      <form
        className="panel analytics-filters"
        onSubmit={(e) => {
          e.preventDefault();
          apply();
        }}
      >
        <label>
          분석 범위
          <select
            value={mode}
            onChange={(e) => setMode(e.target.value as typeof mode)}
          >
            <option value="detail">상세 이용 분석 · 최근 90일</option>
            <option value="trend">장기 일별 집계 · 최대 5년 보관</option>
          </select>
        </label>
        <label>
          시작일
          <input
            type="date"
            value={from}
            onChange={(e) => setFrom(e.target.value)}
            max={to}
            min={mode === "detail" ? day(89) : undefined}
          />
        </label>
        <span className="date-separator">~</span>
        <label>
          종료일
          <input
            type="date"
            value={to}
            onChange={(e) => setTo(e.target.value)}
            min={from}
            max={day()}
          />
        </label>
        <label>
          집계 대상
          <select
            value={audience}
            onChange={(e) => setAudience(e.target.value)}
          >
            <option value="real">실사용 관측만</option>
            <option value="all">전체 · 테스트·운영 활동 포함</option>
          </select>
        </label>
        <button className="primary" disabled={busy}>
          <RefreshCw size={15} />
          조회
        </button>
        <div className="analytics-presets">
          {[7, 30, 90].map((n) => (
            <button
              key={n}
              type="button"
              className="secondary"
              onClick={() => {
                setFrom(day(n - 1));
                setTo(day());
                setMode("detail");
                setSelection({
                  from: day(n - 1),
                  to: day(),
                  audience,
                  mode: "detail",
                });
              }}
            >
              최근 {n}일
            </button>
          ))}
        </div>
      </form>
      <div
        className={`analytics-scope ${selection.audience === "all" ? "analytics-warning" : ""}`}
      >
        <Info size={18} />
        <span>
          <strong>
            {previewMode
              ? "화면 확인용 예시 · 실적 아님"
              : selection.audience === "real"
                ? "실사용 관측 기준"
                : "전체 활동 · 외부 제출용 실적과 구분"}
          </strong>
          <br />
          관리자·테스트·판별된 자동화·예시 콘텐츠를 기본 제외합니다. 브라우저
          수는 사람 수와 다르며, 관측되지 않은 이용은 포함되지 않습니다.
        </span>
        <div>
          <button
            className="secondary"
            disabled={!data || busy || exporting}
            onClick={() => void exportData("csv")}
          >
            <Download size={15} />
            CSV
          </button>
          <button
            className="secondary"
            disabled={!data || busy || exporting}
            onClick={() => void exportData("json")}
          >
            증빙 JSON
          </button>
        </div>
      </div>
      {error && (
        <p className="analytics-error" role="alert">
          {error}
        </p>
      )}
      {receipt && (
        <p className="analytics-receipt" role="status">
          {receipt}
        </p>
      )}
      {busy && (
        <p role="status" className="analytics-empty">
          기간 통계를 불러오고 있습니다…
        </p>
      )}
      {trend && (
        <>
          <p className="analytics-caption">{trend.notice}</p>
          {trend.days.length ? (
            <Daily
              rows={trend.days.map((d) => ({
                day: d.day,
                totals: d.data.totals,
              }))}
            />
          ) : (
            <div className="panel analytics-empty">
              아직 보관된 일별 집계가 없습니다. 매일 04:20에 생성됩니다. 오늘
              기록은 상세 이용 분석에서 확인할 수 있습니다.
            </div>
          )}
        </>
      )}
      {r && (
        <>
          <div className="analytics-kpis">
            {[
              [
                "관측 브라우저",
                number(r.totals.browsers),
                "재방문 " + number(r.totals.returningBrowsers),
              ],
              [
                "방문 세션",
                number(r.totals.sessions),
                "탭 기준 · 30분 비활동 시 새 세션",
              ],
              [
                "30초 이상 열람",
                number(r.totals.qualifiedReads),
                "동일 세션·회차별 1회",
              ],
              [
                "활성 열람 시간",
                mins(r.totals.readMs),
                "화면에 보이는 로드된 이미지",
              ],
              [
                "열람 후 작성",
                number(r.totals.readToCommunity),
                "글·댓글 작성으로 이어진 세션",
              ],
            ].map(([title, value, help]) => (
              <div className="panel" key={title}>
                <span>{title}</span>
                <strong>{value}</strong>
                <small>{help}</small>
              </div>
            ))}
          </div>
          <div className="analytics-tabs" role="tablist" aria-label="분석 항목">
            {[
              ["overview", "이용 흐름"],
              ["archive", "아카이브 열람"],
              ["paths", "유입·이동·이탈"],
              ["features", "기능·참여"],
              ["quality", "오류·수집 상태"],
            ].map(([key, title]) => (
              <button
                role="tab"
                aria-selected={tab === key}
                key={key}
                onClick={() => setTab(key)}
              >
                {title}
              </button>
            ))}
          </div>
          <div role="tabpanel">
            {tab === "overview" && (
              <>
                <section className="panel analytics-flow">
                  <h3>큐시트 열람 뒤 어떤 행동으로 이어졌나요?</h3>
                  <div>
                    <article>
                      <strong>{number(r.totals.qualifiedSessions)}</strong>
                      <span>30초 이상 열람한 세션</span>
                    </article>
                    <ArrowRight />
                    <article>
                      <strong>{number(r.totals.readToCompose)}</strong>
                      <span>그 뒤 글쓰기로 진입</span>
                    </article>
                    <article>
                      <strong>{number(r.totals.readToCommunity)}</strong>
                      <span>그 뒤 글·댓글 작성 완료</span>
                    </article>
                  </div>
                  <p className="analytics-caption">
                    작성 전환율{" "}
                    {r.totals.qualifiedSessions
                      ? `${((r.totals.readToCommunity / r.totals.qualifiedSessions) * 100).toFixed(1)}%`
                      : "—"}{" "}
                    · 같은 세션에서 30초 열람을 먼저 충족한 경우입니다. 후속
                    작성과 글쓰기 진입은 각각 집계하며, 인과관계를 의미하지
                    않습니다.
                  </p>
                </section>
                <Daily rows={r.daily} />
              </>
            )}
            {tab === "archive" && (
              <>
                <div className="analytics-notes">
                  열람 시작 {number(r.totals.readOpens)}회 · 읽은 쪽{" "}
                  {number(r.totals.readPages)}쪽 · 90% 이상 쪽 확인{" "}
                  {number(r.totals.completeReads)}회<br />
                  읽은 쪽은 2초 이상 화면에 보인 이미지입니다. 마지막 쪽으로
                  바로 이동해도 완독으로 계산하지 않습니다. 90% 확인도 내용을
                  이해했다는 뜻은 아닙니다.
                </div>
                <Grid
                  title="회차별 탐색·열람 성과"
                  caption="전체 관측 회차가 내보내기에 포함됩니다. 시간은 페이지가 보이고 최근 60초 이내 조작이 있을 때만 측정합니다."
                  rows={r.archive}
                  columns={[
                    {
                      key: "title",
                      label: "프로그램 / 회차",
                      render: (v, row) => (
                        <span>
                          {String(v)}
                          <small className="analytics-id">{row.id}</small>
                        </span>
                      ),
                    },
                    { key: "year", label: "연도", render: (v) => String(v) },
                    { key: "term", label: "학기" },
                    { key: "reads", label: "세션×회차" },
                    { key: "qualifiedReads", label: "30초 이상" },
                    { key: "completeReads", label: "90% 쪽 확인" },
                    { key: "readMs", label: "활성 시간", render: mins },
                    { key: "toCommunity", label: "후속 작성" },
                  ]}
                />
              </>
            )}
            {tab === "paths" && (
              <>
                <div className="analytics-two">
                  <Grid
                    title="유입 경로"
                    rows={r.sources}
                    columns={[
                      { key: "source", label: "출처", render: label },
                      { key: "campaign", label: "캠페인" },
                      { key: "sessions", label: "세션" },
                      { key: "is_returning", label: "재방문 세션" },
                    ]}
                  />
                  <Grid
                    title="기기 범주"
                    rows={r.devices}
                    columns={[
                      { key: "device", label: "기기", render: label },
                      { key: "sessions", label: "세션" },
                    ]}
                  />
                </div>
                <Grid
                  title="화면별 입구와 마지막 관측 지점"
                  caption="이탈은 세션에서 마지막으로 관측된 화면입니다. 열린 세션이나 전송 유실은 실제 종료와 다를 수 있습니다."
                  rows={r.routes}
                  columns={[
                    { key: "route", label: "화면", render: label },
                    { key: "views", label: "화면 보기" },
                    { key: "entries", label: "첫 화면" },
                    { key: "exits", label: "마지막 화면" },
                    { key: "activeMs", label: "활성 시간", render: mins },
                  ]}
                />
                <Grid
                  title="화면 사이 이동"
                  rows={r.transitions}
                  columns={[
                    { key: "previous", label: "이전 화면", render: label },
                    { key: "route", label: "다음 화면", render: label },
                    { key: "count", label: "이동 횟수" },
                  ]}
                />
              </>
            )}
            {tab === "features" && (
              <>
                <Grid
                  title="기능별 이용"
                  caption="검색어·본문·입력 내용은 수집하지 않습니다. 작성 완료는 DB의 작성자와 실제 레코드를 검증하고 중복 제거합니다."
                  rows={r.features}
                  columns={[
                    {
                      key: "name",
                      label: "기능",
                      render: (v, row) => label(`${v}_${row.detail}`),
                    },
                    { key: "detail", label: "분류", render: label },
                    { key: "count", label: "횟수" },
                  ]}
                />
                <section className="panel analytics-legacy">
                  <h3>기존 기록 · 별도 참고 자료</h3>
                  <p>{r.legacy.notice}</p>
                  <p>
                    기간 내 DB 게시글 {number(r.legacy.posts)} · 댓글{" "}
                    {number(r.legacy.comments)} / 전체 예시 글{" "}
                    {number(r.legacy.samplePosts)} · 운영진 글{" "}
                    {number(r.legacy.staffPosts)} / 누적 조회{" "}
                    {number(r.legacy.cumulativePostViews)} · 현재 큐시트 저장{" "}
                    {number(r.legacy.archiveBookmarks)}
                  </p>
                </section>
              </>
            )}
            {tab === "quality" && (
              <>
                <div className="analytics-two">
                  <Grid
                    title="오류 범주"
                    caption="메시지·스택·URL 원문을 저장하지 않습니다."
                    rows={r.errors}
                    columns={[
                      { key: "route", label: "화면", render: label },
                      { key: "detail", label: "오류", render: label },
                      { key: "count", label: "건수" },
                    ]}
                  />
                  <Grid
                    title="성능 표본"
                    caption="LCP·INP·TTFB는 ms, CLS는 ×1,000. RPC는 1초 이상 요청만 집계합니다. 기기·표본 수와 함께 해석하세요."
                    rows={r.performance}
                    columns={[
                      { key: "metric", label: "지표" },
                      { key: "samples", label: "표본" },
                      {
                        key: "p50",
                        label: "P50",
                        render: (v) => number(Math.round(Number(v))),
                      },
                      {
                        key: "p75",
                        label: "P75",
                        render: (v) => number(Math.round(Number(v))),
                      },
                      {
                        key: "p95",
                        label: "P95",
                        render: (v) => number(Math.round(Number(v))),
                      },
                    ]}
                  />
                </div>
                <section className="panel analytics-health">
                  <h3>수집 범위와 검증</h3>
                  <dl>
                    <dt>수집 시작</dt>
                    <dd>{date(r.coverage.startedAt)}</dd>
                    <dt>마지막 수신</dt>
                    <dd>{date(r.coverage.lastReceivedAt)}</dd>
                    <dt>보관 작업 마지막 실행</dt>
                    <dd>{date(r.coverage.maintenanceAt)}</dd>
                    <dt>수신 / 거부 / 중복 제거</dt>
                    <dd>
                      {number(r.coverage.accepted)} /{" "}
                      {number(r.coverage.rejected)} /{" "}
                      {number(r.coverage.duplicates)}
                    </dd>
                    <dt>브라우저가 보고한 전송 유실</dt>
                    <dd>
                      {number(r.coverage.clientDropped)} · 보고하지 못한 유실은
                      알 수 없음
                    </dd>
                    <dt>기본 제외 이벤트</dt>
                    <dd>
                      관리자 {number(r.excluded.staff)} · 테스트{" "}
                      {number(r.excluded.test)} · 자동화{" "}
                      {number(r.excluded.bot)} · 예시{" "}
                      {number(r.excluded.sample)}
                    </dd>
                    <dt>통계 저장 용량</dt>
                    <dd>
                      {(r.coverage.storageBytes / 1048576).toFixed(1)} MiB
                    </dd>
                    <dt>보관 정책</dt>
                    <dd>원시 90일 · 재방문 식별값 180일 · 집계·보고서 5년</dd>
                  </dl>
                </section>
              </>
            )}
          </div>
          <details className="panel analytics-definition">
            <summary>지표 정의와 외부 제출 시 주의사항</summary>
            <p>
              브라우저 식별값은 180일 후 바뀌며 로그인 계정과 결합해 사람을
              추정하지 않습니다. 사이트 데이터 삭제·기기 변경·여러 브라우저
              사용은 중복을 만듭니다. 재방문은 이 식별값의 최초 관측에서 30분
              이상 지난 뒤 생성된 새 세션입니다.
            </p>
            <p>
              화면을 숨기거나 60초간 조작이 없으면 활성 시간을 더하지 않습니다.
              천천히 읽는 시간은 실제보다 적게 측정될 수 있습니다. 통계
              차단·통신 실패·자바스크립트 미실행·판별되지 않은 자동화의 영향이
              있습니다. 수집 시작 전 이용은 복원하지 않으며, 수치는 관측된
              이용을 설명합니다.
            </p>
            <p>
              일별 브라우저·세션·회차 수를 더한 값을 기간 순이용자 수로 발표하면
              안 됩니다. JSON 증빙에는 지표 버전·기간·대상·수집 상태와 원문
              SHA-256이 포함되며, 내보내기 시점의 스냅샷이 서버에 보관됩니다.
            </p>
          </details>
        </>
      )}
    </div>
  );
}
