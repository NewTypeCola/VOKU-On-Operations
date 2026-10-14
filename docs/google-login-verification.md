# Google 전용 운영자 로그인 검증

2026-10-14, `voku-operates`의 로그인 화면을 수정했습니다. 기존 최고운영자는 Google identity만 있고 비밀번호가 없는 계정이었으므로, 이메일·비밀번호 화면에서는 로그인할 수 없었습니다.

## 변경

- Google 로그인 버튼 하나로 진입합니다. 이메일·비밀번호 입력, 별도 가입, 이메일 OTP 화면을 제거했습니다.
- 기존 Supabase Google 제공자를 사용합니다. PKCE 코드를 한 번만 교환하고 인증 매개변수를 주소에서 제거합니다. 로그인 취소·잘못된 콜백·만료·통신 실패 시 다시 시작할 수 있습니다.
- 운영자 명단, 활성 상태, 세션, AAL2 검사와 웹앱 회원/게시판 관리자 분리는 유지합니다. 공유 Auth의 이메일 제공자나 기존 계정을 삭제·변경하지 않았습니다.
- 사용자 승인 후 Supabase Redirect URLs에 운영 주소와 로컬 5230 포트 주소 2개를 추가했습니다. Site URL `https://voku.pages.dev/`와 기존 허용 주소 12개를 유지해 총 15개입니다.
- 허용되지 않은 배포 미리보기 호스트에서는 OAuth를 시작하지 않고 운영 주소를 안내합니다.

## 확인한 결과

- `npm test`: 31개 통과. 기존 DB 권한/분리/분석 테스트 25개와 Google 복귀 주소 제한·콜백 정리·동시 교환·취소·만료·네트워크 실패·예시 모드 테스트 6개입니다.
- `npm run build`: TypeScript 검사와 프로덕션 빌드 통과. 기본 번들이 약 500 kB라는 Vite 경고는 남아 있습니다.
- 1280px 로컬 브라우저에서 이메일/비밀번호 입력이 없고 가로 넘침이 없음을 확인했습니다. Google 버튼이 실제 Google 계정 선택 페이지를 엽니다.
- 로그인 취소 콜백은 한국어 안내를 표시하며 주소에서 오류 매개변수를 제거했습니다. 해당 흐름의 브라우저 오류는 없었습니다.
- 기존 최고운영자의 Google 로그인이 실제 Supabase를 거쳐 `http://127.0.0.1:5230/`로 돌아와 **2단계 인증** 화면을 열었습니다. 콜백 코드도 주소에서 제거되었습니다. 로컬 검증 세션은 로그아웃했습니다.
- `node scripts/verify-google-auth.mjs`: 실제 Supabase OAuth 시작과 익명 취소 응답이 운영 주소·127.0.0.1·localhost의 정확한 주소로 돌아옵니다. Google 사용자 로그인을 생성하는 검사가 아니며 코드·state·쿠키·토큰을 저장하지 않습니다. 결과는 `artifacts/google-auth-redirects.json`입니다.
- `node scripts/verify-live.mjs`: 실제 운영 API 비로그인 요청 401, 기존 공개 커뮤니티 피드 200. 결과는 `artifacts/live-api-verification.json`입니다.

## 운영 배포 확인

- 코드 커밋 `3e5ad4c`를 `main`에 푸시했고 Cloudflare Pages 검사 `f8d2db20-263a-47e1-a7f6-590b724d043f`가 `success`로 완료되었습니다.
- `https://voku-operates.pages.dev/`에서 Google 로그인 버튼만 표시되고 이메일/비밀번호 입력이 없음을 확인했습니다. 1289×1028 화면에서 가로 넘침이 없습니다.
- 운영 주소에서도 Google 로그인 후 2단계 인증 화면으로 복귀했고 콜백 코드가 주소에서 제거되었습니다.
- 추가 인증 완료 후 실제 **이용 분석·보고서** 화면이 열린 것을 확인했습니다. 해당 화면의 오류 알림과 브라우저 오류는 없었습니다.

인증 앱의 새 비밀키 등록이나 6자리 인증번호 입력은 대신 수행하지 않았습니다. 인증 코드·QR·토큰은 검증 결과에 보관하지 않습니다. 최종 배포 확인은 `artifacts/google-auth-production.json`에 기록합니다.

공식 근거: [Supabase Google 로그인](https://supabase.com/docs/guides/auth/social-login/auth-google), [OAuth 복귀 주소](https://supabase.com/docs/guides/auth/redirect-urls).
