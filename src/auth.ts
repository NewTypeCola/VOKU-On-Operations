import type { SupabaseClient } from "@supabase/supabase-js";

export const operatorOrigins = [
  "https://voku-operates.pages.dev",
  "http://127.0.0.1:5230",
  "http://localhost:5230",
] as const;

export function googleAuthOptions(origin: string) {
  if (!operatorOrigins.some((allowed) => allowed === origin)) return null;
  return {
    provider: "google" as const,
    options: {
      redirectTo: origin + "/",
      queryParams: { prompt: "select_account" },
    },
  };
}

const callbackKeys = [
  "code",
  "sb_flow_id",
  "error",
  "error_code",
  "error_description",
  "access_token",
  "refresh_token",
  "provider_token",
  "provider_refresh_token",
  "expires_in",
  "expires_at",
  "token_type",
];
export function readAuthCallback(href: string) {
  const url = new URL(href);
  const hash = new URLSearchParams(url.hash.slice(1));
  const value = (key: string) => url.searchParams.get(key) || hash.get(key);
  const code = value("code");
  const flowId = value("sb_flow_id");
  const error = value("error");
  const callback = callbackKeys.some(
    (key) => url.searchParams.has(key) || hash.has(key),
  );
  for (const key of callbackKeys) url.searchParams.delete(key);
  if (callbackKeys.some((key) => hash.has(key))) url.hash = "";
  return {
    callback,
    code,
    flowId,
    error,
    cleanUrl: url.pathname + url.search + url.hash,
  };
}

// One shared exchange for StrictMode, auth-state notifications and identity refreshes.
// The SDK owns PKCE verification; an authorization code alone never grants access.
export function createOAuthCompletion(
  auth: Pick<SupabaseClient["auth"], "exchangeCodeForSession"> | null,
  href: string,
  replaceUrl: (url: string) => void,
) {
  let completion: Promise<string> | undefined;
  return () =>
    (completion ??= (async () => {
      if (!auth) return "";
      const result = readAuthCallback(href);
      if (!result.callback) return "";
      replaceUrl(result.cleanUrl);
      if (result.error)
        return result.error === "access_denied"
          ? "Google 로그인이 취소되었습니다. 아래 버튼으로 다시 시작해 주세요."
          : "Google 로그인을 완료하지 못했습니다. 아래 버튼으로 다시 시작해 주세요.";
      if (!result.code || !/^[a-zA-Z0-9_-]{1,2048}$/.test(result.code))
        return "로그인 응답이 올바르지 않습니다. Google 로그인을 다시 시작해 주세요.";
      try {
        const { error } = await auth.exchangeCodeForSession(
          result.code,
          result.flowId ? { flowId: result.flowId } : undefined,
        );
        if (error)
          return "로그인 연결이 만료되었거나 다른 브라우저에서 열렸습니다. 이 화면에서 Google 로그인을 다시 시작해 주세요.";
        return "";
      } catch {
        return "로그인 서버에 연결하지 못했습니다. 연결을 확인하고 다시 시도해 주세요.";
      }
    })());
}
