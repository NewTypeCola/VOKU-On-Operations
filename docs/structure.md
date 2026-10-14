# 데스크톱 운영자 앱 구조

2026-10-14에 voku-video의 현재 운영 구조를 먼저 읽기 전용으로 조사하고 갱신했다. 현재 웹앱의 공개 글 주소, 예시 콘텐츠 표시, 선택 프로필 정보를 목록/상세 데이터에 반영했다. 회원 계정과 운영자 계정의 분리, 게시판 관리자의 역할은 그대로 유지한다.

- `src/App.tsx`: 로그인·OTP·MFA, 운영 셸, 운영 현황과 커뮤니티 관리. 운영 안내·처리 기록 포함.
- `src/api.ts`, `types.ts`, `preview.ts`: checked RPC 계약, 화면 데이터 타입, 원격 연결 없는 미리보기.
- `src/analytics/AnalyticsPage.tsx`: 기간/대상, 이용 흐름, 아카이브, 유입·이동·이탈, 기능·참여, 수집 품질. 상세 90일/장기 일별 집계.
- `src/analytics/api.ts`, `types.ts`: 통계 RPC와 스냅샷 계약. 조회·내보내기는 모든 활성 운영자에게 허용되며 AAL2 필요.
- `src/analytics/export.ts`: UTF-8 CSV, 수식 주입 방지, JSON 다운로드. 원시 브라우저·계정 식별값은 포함하지 않음.
- `src/analytics/preview.ts`: 화면 검증용 예시. `PREVIEW` 표기가 들어간 보고서만 생성하며 실제 서버에 저장하지 않음.
- `supabase/migrations`: 기존 운영자 분리 + 통계 저장·checked RPC + 공개 카탈로그 + 자동 보관 작업. community SQL의 소유자는 voku-video.
- `tests/fixtures/community`: 현재 웹앱 SQL의 격리 테스트용 사본. 실제 웹앱이나 배포 환경을 덮어쓰지 않음.
- `tests/operations.test.mjs`: 계정·MFA·권한·변경 충돌·감사·기존 게시판 호환성.
- `tests/analytics*.test.mjs`: 수집 제한·식별값 처리·중복·제외·열람·전환·보관·보고서·CSV 검증.
- `scripts/verify-live.mjs`, `verify-analytics-live.mjs`: 공개 키만 사용한 운영 환경 검증. 분석 검사에서 생성하는 이벤트는 test로 분리.
- `docs/analytics.md`: 지표 정의, 데이터 한계, 보관/개인정보, 배포·보고 절차의 기준 문서.

Cloudflare 프로젝트 voku의 회원 화면 → 같은 출처 collector → 공유 Supabase voku_metrics → 이 운영 화면이 연결된다. 게시판 관리자 화면은 기존 웹앱에서 유지하고, 운영 통계를 그 권한에 붙이지 않는다. 운영자 로그인 키도 `voku-operations-auth-v1`로 별도다.

운영자 앱은 비공개 `NewTypeCola/voku-operates` 저장소의 `main`과 Cloudflare Pages `voku-operates` 프로젝트를 연결했다. `npm ci && npm test && npm run build`를 통과한 결과를 `https://voku-operates.pages.dev/`에서 제공한다. 브라우저에는 공유 Supabase의 공개 연결 키만 들어간다. 수집 전용 비밀값은 웹앱의 Pages Function에만 있으며 운영자 앱에는 없다. 공개 호스팅은 로그인 화면 제공에 사용하며, 통계·회원·처리 기록은 서버 권한 검사 뒤에만 조회된다.

2026-10-12의 `artifacts/webapp-preservation.json`은 최초 구현 당시의 읽기 전용 검증이다. 이번 10월 14일 사용자의 추가 승인으로 웹앱 계측·정책·성능 관련 파일을 수정했으므로, 그 과거 파일을 현재 무변경의 근거로 사용하지 않는다.
