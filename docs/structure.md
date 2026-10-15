# 데스크톱 운영자 앱 구조

2026-10-14에 VOKU On(당시 저장소 이름 `voku-video`)의 운영 구조를 먼저 읽기 전용으로 조사하고 갱신했다. 당시 웹앱의 공개 글 주소, 예시 콘텐츠 표시, 선택 프로필 정보를 목록/상세 데이터에 반영했다. 회원 계정과 운영자 계정의 분리, 게시판 관리자의 역할은 그대로 유지한다. 아래 저장소·배포 정보는 2026-10-15에 다시 확인했다.

- `src/App.tsx`, `src/auth.ts`: Google 로그인·PKCE·MFA, 운영 셸, 운영 현황과 커뮤니티 관리. 운영 안내·처리 기록 포함.
- `src/api.ts`, `types.ts`, `preview.ts`: checked RPC 계약, 화면 데이터 타입, 원격 연결 없는 미리보기.
- `src/analytics/AnalyticsPage.tsx`: 기간/대상, 이용 흐름, 아카이브, 유입·이동·이탈, 기능·참여, 수집 품질. 상세 90일/장기 일별 집계.
- `src/analytics/api.ts`, `types.ts`: 통계 RPC와 스냅샷 계약. 조회·내보내기는 모든 활성 운영자에게 허용되며 AAL2 필요.
- `src/analytics/export.ts`: UTF-8 CSV, 수식 주입 방지, JSON 다운로드. 원시 브라우저·계정 식별값은 포함하지 않음.
- `src/analytics/preview.ts`: 화면 검증용 예시. `PREVIEW` 표기가 들어간 보고서만 생성하며 실제 서버에 저장하지 않음.
- `supabase/migrations`: 기존 운영자 분리 + 통계 저장·checked RPC + 공개 카탈로그 + 자동 보관 작업. community SQL의 소유 저장소는 [VOKU-On](https://github.com/NewTypeCola/VOKU-On).
- `tests/fixtures/community`: 현재 웹앱 SQL의 격리 테스트용 사본. 실제 웹앱이나 배포 환경을 덮어쓰지 않음.
- `tests/operations.test.mjs`: 계정·MFA·권한·변경 충돌·감사·기존 게시판 호환성.
- `tests/analytics*.test.mjs`: 수집 제한·식별값 처리·중복·제외·열람·전환·보관·보고서·CSV 검증.
- `scripts/verify-live.mjs`, `verify-analytics-live.mjs`: 공개 키만 사용한 운영 환경 검증. 분석 검사에서 생성하는 이벤트는 test로 분리.
- `docs/analytics.md`: 지표 정의, 데이터 한계, 보관/개인정보, 배포·보고 절차의 기준 문서.
- `voku_analysis` 비공개 DB 스키마: 목적 기록 후에만 받는 분석 결과, 별도 읽기 전용 역할과 감사 역할. 앱의 조회 API에는 노출하지 않음. [백엔드 분석 절차](backend-analysis.md).
- `tests/backend-analysis.test.mjs`: 분석 역할·원본/회원정보 접근 차단·감사 기록 확정·결과 최소화·보관·삭제·기존 통계 보존 검증.

Cloudflare 프로젝트 voku의 회원 화면 → 같은 출처 collector → 공유 Supabase voku_metrics → 이 운영 화면이 연결된다. 게시판 관리자 화면은 기존 웹앱에서 유지하고, 운영 통계를 그 권한에 붙이지 않는다. 운영자 로그인 키도 `voku-operations-auth-v1`로 별도다.

## 저장소와 배포 (2026-10-15 확인, KST)

공개 GitHub 저장소 [NewTypeCola/VOKU-On-Operations](https://github.com/NewTypeCola/VOKU-On-Operations)의 `main`을 Cloudflare Pages 프로젝트 `voku-operates`와 연결해 [voku-operates.pages.dev](https://voku-operates.pages.dev/)에서 제공한다. 이전 이름 `NewTypeCola/voku-operates`의 비공개 저장소를 이름 변경 후 공개한 것이며, 별도의 비공개 배포 저장소가 아니다. Cloudflare Git 연결 화면의 이전 이름도 같은 저장소를 가리키며, 이름 변경 후의 커밋을 계속 수신하고 있다.

`main` 자동 배포가 활성화되어 있다. GitHub Actions 대신 Cloudflare에서 `npm ci && npm test && npm run build`를 실행하고 `dist`를 배포한다. `build`에는 TypeScript 검사가 포함된다. 실행된 빌드 결과는 공개 커밋의 **Cloudflare Pages** check에서 확인할 수 있다.

확인 시점의 운영 배포는 [116898a](https://github.com/NewTypeCola/VOKU-On-Operations/commit/116898a7621b7f8df5ba5e201f5ba30d1df55895), 배포 URL은 [ac868031.voku-operates.pages.dev](https://ac868031.voku-operates.pages.dev/)이다. 2026-10-15 10:27 KST 배포가 성공했고, 해당 빌드에서 테스트 44개가 통과했다. 이후 문서·스크린샷·라이선스 커밋은 `[CF-Pages-Skip]`으로 배포를 생략했다. 공개 `main`과 운영 배포의 커밋 SHA는 다르지만, 확인 시점의 앱 소스·빌드 설정에는 차이가 없다. 두 앱의 대응 버전과 과거 검증 결과는 [배포·검증 기록](analytics-verification.md)에서 구분한다.

브라우저에는 공유 Supabase의 공개 연결 키만 들어간다. 수집 전용 비밀값은 웹앱의 Pages Function에만 있으며 운영자 앱에는 없다. 공개 호스팅은 로그인 화면 제공에 사용하며, 통계·회원·처리 기록은 서버 권한 검사 뒤에만 조회된다.

2026-10-12의 `artifacts/webapp-preservation.json`은 최초 구현 당시의 읽기 전용 검증이다. 2026-10-14 사용자의 추가 승인으로 웹앱 계측·정책·성능 관련 파일을 수정했으므로, 그 과거 파일을 현재 무변경의 근거로 사용하지 않는다.
