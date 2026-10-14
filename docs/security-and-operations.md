# 운영자 계정과 권한 구조

## 데이터 경계

운영자 인증은 공개 웹앱과 분리된 프런트엔드에서 처리합니다. 운영 웹앱은 동일 프로젝트의 공개 키와 사용자 JWT만 사용하며 서버 역할 키를 번들에 넣지 않습니다. Auth 세션 저장 키는 `voku-operations-auth-v1`로 기존 웹앱과 분리됩니다.

`voku_ops` 스키마의 `operators`, `invitations`, `audit`는 RLS를 활성화하고 익명·인증 역할의 테이블 접근을 모두 회수했습니다. PostgREST에는 검사된 `public.ops_*` 래퍼만 제공합니다. 내부 SECURITY DEFINER 함수는 빈 search_path, 스키마 명시, 사용자·역할·MFA 검사를 사용합니다. 기본 PUBLIC 함수 실행 권한도 회수했습니다.

## 가입과 접속

- 최고운영자가 전용 이메일을 `invitations`에 등록합니다. 기존 Auth 사용자 이메일은 거부합니다.
- 운영자 화면은 Google 로그인만 제공합니다. 공유 Auth의 이메일 제공자나 기존 웹앱의 로그인 방식은 변경하지 않습니다. Google 로그인 성공만으로 운영자 권한을 부여하지 않습니다.
- PKCE 콜백은 한 번만 교환하고 인증 코드·오류·토큰 매개변수를 즉시 주소에서 제거합니다. Google 로그인 취소, 다른 브라우저에서 열린 콜백, 만료된 코드에는 다시 시작할 수 있는 안내를 표시합니다. 복귀 주소는 운영 도메인과 로컬 5230 포트의 정확한 주소로 제한합니다. 임의 리다이렉트와 와일드카드는 사용하지 않습니다.
- Auth INSERT 전 서버 트리거가 등록 명단을 잠그고 확인하여 신뢰된 `raw_app_meta_data.voku_account_type`을 지정합니다. 브라우저의 역할/메타데이터로 권한을 결정하지 않습니다.
- 해당 계정에는 기존 회원 생성 트리거가 실행되지 않고 `operators`만 생성됩니다. 기존 일반 가입은 동일한 `voku_private.create_member()`를 실행합니다.
- 계정 활성 상태, 이메일 확인, 현재 `auth.sessions`의 사용자/세션 ID, 커뮤니티 프로필 부재, AAL2를 매 RPC에서 검사합니다. 접근 중지/역할 변경은 이후 요청부터 바로 적용됩니다.
- 운영자 계정에 커뮤니티 프로필을 추가하려는 DB INSERT도 차단합니다. 기존 커뮤니티 쓰기 RPC는 회원 자격 검사에서 운영자를 거부합니다.
- `ops_me()`는 AAL1에서도 자신의 정보만 반환하여 인증 앱 설정 화면을 열 수 있게 합니다. 실제 운영 정보는 반환하지 않습니다.

## 처리와 이력

허용된 작업만 받을 수 있습니다. 사용자 입력을 동적 SQL로 실행하지 않습니다. 대상 최대 50개를 정렬해서 잠그며 행의 버전을 대조합니다. 하나라도 달라졌거나 권한 검사가 실패하면 전체 트랜잭션을 되돌립니다. 사유는 2~500자이며 읽기 전용 변경 이력에 기록합니다.

기존 `community_reports.resolved_by`는 커뮤니티 회원 FK입니다. 운영자는 커뮤니티 회원이 아니므로 이 필드는 비워 두고, `voku_ops.audit`의 actor_id/actor_name으로 실제 담당자를 기록합니다. 기존 FK와 게시판 관리자 기능은 유지됩니다.

운영자/등록 명단과 그 권한 변경 기록은 최고운영자만 읽습니다. 다른 운영자도 API에서 차단합니다. 게시판 관리자의 기존 조치는 통합 이력에 출처를 구분해 표시합니다.

첨부사진은 기존 비공개 버킷을 유지하며, 확인된 운영자에게 게시글에 연결된 사진만 SELECT로 허용합니다. UI의 서명 URL은 60초 유효하며 이미 발급된 URL은 만료 전까지 유효합니다. 운영 화면은 사진 업로드·영구삭제 권한을 추가하지 않습니다.

## 마이그레이션

`supabase/migrations/20261012034823_operations_dashboard.sql`은 기존 커뮤니티 스키마 위에 적용합니다. 신규 파일은 Supabase CLI `migration new`로 생성한 뒤, MCP 적용 결과의 서버 버전 `20261012034823`에 파일명을 맞췄습니다. 이미 공유 서버에 적용되어 있으므로 반복 적용하지 마세요. 최초 이메일 등록과 기존 계정 삭제는 사용자 지정 데이터이므로 범용 마이그레이션과 분리하여 실행했습니다.

## Supabase 점검 결과

새 운영 테이블의 `RLS Enabled No Policy` INFO는 의도한 기본 거부 상태입니다. 클라이언트 테이블 권한을 회수하고 검사된 함수만 사용하므로 공개 SELECT 정책을 추가하지 않습니다. [검사 설명](https://supabase.com/docs/guides/database/database-linter?lint=0008_rls_enabled_no_policy)

기존 커뮤니티 공개/인증 SECURITY DEFINER 함수 경고와 유출 비밀번호 보호 설정 경고는 작업 전에도 있었으며 변경하지 않았습니다. 운영 래퍼에서 새 SECURITY DEFINER 노출 경고는 발생하지 않았습니다. [공개 함수 검사](https://supabase.com/docs/guides/database/database-linter?lint=0028_anon_security_definer_function_executable), [인증 함수 검사](https://supabase.com/docs/guides/database/database-linter?lint=0029_authenticated_security_definer_function_executable), [비밀번호 보호 설정](https://supabase.com/docs/guides/auth/password-security#password-strength-and-leaked-password-protection)

새 감사 이력 인덱스의 미사용 INFO는 설치 직후 조회 통계입니다. 기존 커뮤니티 FK 인덱스와 RLS 성능 경고는 이 변경의 범위에 포함하지 않았습니다. [미사용 인덱스 검사](https://supabase.com/docs/guides/database/database-linter?lint=0005_unused_index)
