# 이용 분석 배포·검증 기록

이 문서의 최초 배포·검증 기록은 **2026-10-14, 한국 시간 기준**이다. 당시 구현·자동 검증·운영 환경 확인을 구분하며, 이용 수치는 검증 활동이지 서비스의 실사용 실적이 아니다. 현재 저장소·배포 상태는 아래 2026-10-15 확인 내용과 구분해 읽는다.

## 현재 저장소·배포 상태 (2026-10-15 확인, KST)

두 저장소는 현재 공개 상태다. `NewTypeCola/voku-video` → `NewTypeCola/VOKU-On`, `NewTypeCola/voku-operates` → `NewTypeCola/VOKU-On-Operations`로 기존 저장소의 이름을 변경하고 공개했으며, 별도의 비공개 배포 저장소를 두고 있지 않다. Cloudflare 연결 화면에는 이전 이름이 남아 있지만 GitHub 저장소 ID는 각각 같고, 이름 변경 후의 커밋도 계속 수신하고 있다.

| 공개 저장소 | Cloudflare Pages 프로젝트 / 운영 주소 | 확인한 운영 배포 커밋 | 해당 빌드 테스트 |
| --- | --- | --- | --- |
| [VOKU-On](https://github.com/NewTypeCola/VOKU-On) | `voku` / [voku.pages.dev](https://voku.pages.dev/) | [31ef4d0](https://github.com/NewTypeCola/VOKU-On/commit/31ef4d0c573f686523d90e7f9a5b86e3acdccfef) | 176개 통과 |
| [VOKU-On-Operations](https://github.com/NewTypeCola/VOKU-On-Operations) | `voku-operates` / [voku-operates.pages.dev](https://voku-operates.pages.dev/) | [116898a](https://github.com/NewTypeCola/VOKU-On-Operations/commit/116898a7621b7f8df5ba5e201f5ba30d1df55895) | 44개 통과 |

Cloudflare 운영 배포는 각각 2026-10-15 09:59 KST([be7fbc7b](https://be7fbc7b.voku.pages.dev/)), 10:27 KST([ac868031](https://ac868031.voku-operates.pages.dev/))에 성공했다. 두 프로젝트 모두 공개 저장소의 `main` 자동 배포가 활성화되어 있다. GitHub Actions workflow를 사용하는 대신 Cloudflare 빌드에서 테스트·타입 검사·빌드를 수행한다. 빌드 명령은 [VOKU On 구조 문서](https://github.com/NewTypeCola/VOKU-On/blob/main/docs/structure-2026-10-14.md)와 [운영자 앱 구조 문서](structure.md)에 기록했다. GitHub의 공개 커밋에 연결된 **Cloudflare Pages** check와 Cloudflare 배포 상세에서 커밋·배포 URL·결과를 대응시킬 수 있다.

확인 시점에 운영 배포 이후의 변경은 문서·스크린샷·라이선스뿐이며 앱 소스·빌드 설정은 동일하다. 최근 문서 전용 커밋은 `[CF-Pages-Skip]` 접두어로 배포를 생략해 Cloudflare에서 `skipped`로 표시된다. 따라서 공개 `main`의 최신 SHA와 운영 배포 SHA는 다를 수 있다. 생략된 빌드에는 GitHub check가 생성되지 않으므로, check가 없다는 사실만으로 배포 실패나 CI 부재를 판단하지 않는다. [Cloudflare GitHub 연동·배포 생략 공식 안내](https://developers.cloudflare.com/pages/configuration/git-integration/github-integration/#skipping-a-build-via-a-commit-message).

## 최초 배포와 구조 (2026-10-14 당시)

이하 검증 수치·보안 관측·증거 파일은 당시 상태를 보존한 기록이며, 2026-10-15 재검증 결과나 현재 운영 지표로 갱신한 값이 아니다.

- 회원 웹앱: https://voku.pages.dev / 당시 비공개 `NewTypeCola/voku-video`(현재 공개 `NewTypeCola/VOKU-On`)의 `main`.
- 운영자 앱: https://voku-operates.pages.dev / 당시 비공개 `NewTypeCola/voku-operates`(현재 공개 `NewTypeCola/VOKU-On-Operations`)의 `main`. 당시 Cloudflare Git 연결 및 자동 빌드·배포 설정을 완료했다.
- 공유 Supabase `awvnzjdtdcdcjtfinuuy`. `voku_metrics` 추가, 기존 운영자 AAL2 검사 재사용. 커뮤니티 관리자 역할·기존 Auth 흐름 유지.
- 원격 적용 SQL: `20261014104157_usage_analytics`, `20261014104239_usage_catalog`, `20261014104439_usage_retention`, `20261014110418_usage_relation_indexes`.
- 최초 수집 가능 배포 완료: **2026-10-14 20:01:49 KST**. `config.started_at`을 이 실제 가동 시점으로 정렬했다. 이전 DB 설치 시각은 수집 가동 시각으로 사용하지 않는다.
- 웹앱 기존 `content/` 작업은 수정·커밋하지 않았다. 구조 조사 문서는 웹앱 `docs/structure-2026-10-14.md`와 이 저장소 `docs/structure.md`에 있다.

## 자동 검증

| 검사 | 결과 |
| --- | --- |
| 웹앱 테스트 | **176개 통과**, Cloudflare 운영 빌드에서도 통과 |
| 운영자 앱 테스트 | **25개 통과**, 실제 적용 SQL을 PGlite에서 재현 |
| TypeScript·Vite | 두 앱 빌드 통과 |
| 원본 자료 검사 | 카탈로그 5,330회차 / 66,010쪽, 기존 캐시·이미지 무결성 통과 |
| 웹앱 초기 JS | 변경 전 821,887 → 변경 후 807,759 bytes; gzip 251,664 → 247,261 |
| 홈 JS | 변경 전 853,400 → 변경 후 840,256 bytes; 기존 용량 예산 유지 |
| CSV·JSON | CSV 수식 주입 방어, 서버 스냅샷·감사 기록·SHA-256 일치, 예시 다운로드 파일의 체크섬 별도 확인 |

격리 DB 테스트는 일반회원·게시판 운영진·미인증/AAL1 접근 거부, 전용 운영자 AAL2 접근, 수집 키 검증, 중복 제거, 서버 측 예시 판별, 관리자·테스트·봇 제외, 실제 작성자 확인, 열람 시간·쪽수·후속 참여, 삭제·보관을 포함한다. 브라우저의 페이지 점프만으로 완독 지표가 올라가지 않는 것도 확인했다.

## 실제 운영 환경 확인

1. 같은 출처 `/api/usage`에 test로 명시한 2건을 전송: 2건 수신. 같은 UUID 재전송: 중복 2건, 추가 적재 없음.
2. 다른 Origin: 403. 비로그인 통계 RPC: 401. 공개 키만으로 수집 RPC 우회: 401.
3. 실제 사이트 브라우저에서 `?usage_test=1`로 1988년 1학기 VOKU 기자석 01회를 열고, 이미지 로딩·1→2쪽 이동·글쓰기 진입을 확인했다. 게시글이나 댓글은 발행하지 않았다.
4. 20:05 KST 확인 시 HTTP 검사와 브라우저 활동 합계 **28건**, 활성 이미지 열람 **73.002초**, 확인한 쪽 **2쪽**, 30초 이상 열람 **1건**, 열람 후 글쓰기 진입 **1건**, 실제 작성 **0건**. **28건 전부 test, real 이벤트 0건**이었다. 실제 이용자가 아직 관측되지 않은 상태를 가상 실적으로 채우지 않았다.
5. 이 확인에서 수집 거부 0건, 중복 2건, 오류 이벤트 0건. LCP·TTFB도 수신했다. 단일 검증 세션의 성능 값은 실제 이용자 전체 성능의 대표값으로 사용하지 않는다.
6. 운영 DB의 일별 정리 함수를 직접 실행하여 real/all 분리 집계를 확인했다. 매일 **04:20 KST** cron 활성 상태를 확인했다. 미래의 첫 예약 실행까지 관측한 것은 아니다.
7. 배포된 운영자 주소에서 비로그인 시 로그인 화면을 확인했다. 예시 모드로 분석 화면·필터·탭·다운로드를 점검했다. **운영자의 비밀번호·인증 앱 번호를 대신 입력하지 않았으며, 실제 계정으로 로그인한 통계 화면의 클릭 검증은 하지 않았다.** 실제 적재·분류·집계는 운영 DB 조회로 확인했다.

모바일 390px에서 큐시트 페이지의 가로 넘침이 없었고, 데스크톱 1440px에서 분석 화면의 가로 넘침·콘솔 오류가 없었다. 브라우저는 화면 크기만 바꿨으므로 이 검증 세션의 기기 분류는 desktop이다. Codex 검증 브라우저의 테스트 표시를 유지했으며 일반 사용자는 자신의 브라우저에서 기존 방식으로 이용한다.

최초 배포 검증에서 Cloudflare `_routes.json`의 collector 경로 누락을 발견했다. `/api/usage`와 `/api/usage/*`를 추가하고, 실제 운영 주소의 수신 성공 및 경로 회귀 테스트까지 확인한 후 검증 완료로 처리했다.

## 보안 점검과 남은 운영 항목

- 새 분석 테이블 9개 모두 RLS 사용, anon/authenticated의 직접 SELECT 권한 없음. 수집 전용 키는 Cloudflare 비밀 변수와 DB 해시로만 보관하며 브라우저·Git에 들어가지 않는다.
- 보안 검사에서 새 분석 RPC의 공개 SECURITY DEFINER 경고는 없었다. RLS에 허용 정책이 없다는 INFO는 직접 접근을 막고 검증된 함수로만 사용하는 의도된 구성이다.
- 새 테이블의 외래키 인덱스 두 개를 추가했고 누락 INFO가 해소됐다. 초기 데이터가 적어 나타나는 unused-index INFO는 관측 기간이 쌓인 뒤 검토한다.
- 기존 커뮤니티 함수의 SECURITY DEFINER WARN(anon 5 / authenticated 10), 기존 RLS 성능 WARN 5건, 기존 유출 비밀번호 보호 비활성 WARN은 이번 분석 추가 전부터 있었다. 기존 공개 읽기와 내부 권한 검사 구조를 일괄 변경하지 않았다. 비밀번호 보호는 별도 Auth 운영 항목으로 남겼다. [관련 공식 안내](https://supabase.com/docs/guides/auth/password-security#password-strength-and-leaked-password-protection), [함수 권한 경고](https://supabase.com/docs/guides/database/database-linter?lint=0028_anon_security_definer_function_executable), [RLS 성능 안내](https://supabase.com/docs/guides/database/database-linter?lint=0003_auth_rls_initplan).
- 상세 기록은 90일 기준 일 단위 정리, 서버 재방문 식별값은 마지막 관측 후 180일, 식별값 없는 집계·보고서는 5년이다. 개인정보 선택·기록 삭제는 공개 개인정보처리방침에 반영했다. 법률상 포괄적 적합성을 인증한 것은 아니다.
- 기존 누적 조회수·작성 기록은 참고 지표로 유지한다. 과거의 날짜별 방문·회차 열람은 복원할 수 없다. 브라우저 수는 사람 수와 다르며 외부 제출 시 수집 시작·제외 기준·누락 가능성을 함께 기재한다.

## 증거 파일

- `artifacts/analytics-live-http.json`: 공개 HTTP 검증 응답.
- `artifacts/analytics-live-aggregate.json`: 20:05 KST 시점의 식별값 없는 운영 DB 집계. 이후 수집 시작 메타데이터를 위 가동 시점으로 정렬했다.
- `artifacts/analytics-deployment.json`: 확인된 앱 버전·Cloudflare 배포 ID·CI 결과. 이 파일의 버전은 해당 검증 시점이며 문서 추가 커밋은 별도다.
- `artifacts/analytics-live-reader.jpg`: 실제 운영 사이트에서 확인한 큐시트.
- `artifacts/analytics-hosted-preview.jpg`: 배포 사이트의 분석 화면. 화면 수치는 명시적으로 예시 데이터다.
