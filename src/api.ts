import { createClient } from "@supabase/supabase-js";
import type {
  Detail,
  Kind,
  Listing,
  Operator,
  Overview,
  Query,
  Item,
} from "./types";
const url = import.meta.env.VITE_SUPABASE_URL || "";
const key = import.meta.env.VITE_SUPABASE_PUBLISHABLE_KEY || "";
export const configured =
  /^https:\/\/[a-z0-9-]+\.supabase\.co\/?$/.test(url) &&
  key.startsWith("sb_publishable_");
export const previewMode =
  new URLSearchParams(location.search).get("preview") === "1";
export const supabase =
  configured && !previewMode
    ? createClient(url, key, {
        auth: {
          storageKey: "voku-operations-auth-v1",
          flowType: "pkce",
          persistSession: true,
          autoRefreshToken: true,
          detectSessionInUrl: false,
        },
      })
    : null;
export function errorText(error: unknown): string {
  const msg =
    error instanceof Error
      ? error.message
      : String((error as { message?: string })?.message || error);
  if (/ops_conflict/.test(msg))
    return "다른 관리자가 항목을 변경했습니다. 새로고침 후 다시 확인해 주세요.";
  if (/ops_login_required|session_not_found/.test(msg))
    return "로그인이 만료되었습니다. 다시 로그인해 주세요.";
  if (/ops_access_denied/.test(msg))
    return "접근 가능한 운영자 계정이 아닙니다. 운영자 전용 이메일과 접근 상태를 확인해 주세요.";
  if (/ops_permission_denied/.test(msg))
    return "이 작업을 수행할 권한이 없습니다.";
  if (/ops_mfa_required/.test(msg))
    return "2단계 인증이 필요합니다. 다시 로그인해 주세요.";
  if (/Invalid login credentials/.test(msg))
    return "이메일 또는 비밀번호를 확인해 주세요.";
  if (/Email not confirmed/.test(msg))
    return "이메일 인증을 완료해 주세요. 운영자 등록 탭에서 인증번호를 확인할 수 있습니다.";
  if (/Database error saving new user/.test(msg))
    return "등록 명단에 없는 이메일이거나 가입을 완료할 수 없습니다. 최고운영자에게 등록 상태를 확인해 주세요.";
  if (/already registered|already been registered/.test(msg))
    return "이미 등록된 계정입니다. 로그인을 이용해 주세요.";
  if (/rate limit|too many/i.test(msg))
    return "요청이 많습니다. 잠시 후 다시 시도해 주세요.";
  if (/invalid.*(otp|token)|expired|code.*invalid/i.test(msg))
    return "인증번호가 올바르지 않거나 만료되었습니다. 새 인증번호를 확인해 주세요.";
  if (/duplicate key|unique constraint/i.test(msg))
    return "이미 등록된 이메일입니다. 운영자 목록을 확인해 주세요.";
  if (/fetch|network|Load failed/i.test(msg))
    return "서버에 연결하지 못했습니다. 연결 상태를 확인하고 다시 시도해 주세요.";
  if (/function.*does not exist|schema cache|PGRST202/i.test(msg))
    return "운영 서버가 아직 준비되지 않았습니다. 데이터베이스 설치 상태를 확인해 주세요.";
  return msg;
}
async function rpc<T>(name: string, args = {}): Promise<T> {
  if (!supabase) throw Error("Supabase 공개 연결 설정이 필요합니다.");
  const { data, error } = await supabase.rpc(name, args);
  if (error) throw error;
  return data as T;
}
const liveApi = {
  me: () => rpc<Operator>("ops_me"),
  overview: () => rpc<Overview>("ops_overview"),
  list: (kind: Kind, query: Query) =>
    rpc<Listing>("ops_list", { p_kind: kind, p_query: query }),
  detail: (kind: Kind, id: string) =>
    rpc<Detail>("ops_detail", { p_kind: kind, p_id: id }),
  mutate: (
    kind: Kind,
    action: string,
    items: Item[],
    reason: string,
    value: Record<string, unknown> = {},
  ) =>
    rpc<{ changed: number }>("ops_mutate", {
      p_kind: kind,
      p_action: action,
      p_targets: items.map(({ id, version }) => ({ id, version })),
      p_reason: reason,
      p_value: value,
    }),
  invite: (email: string, name: string, role: string, reason: string) =>
    rpc<{ id: string }>("ops_invite", {
      p_email: email,
      p_name: name,
      p_role: role,
      p_reason: reason,
    }),
};
export type Api = typeof liveApi;
export async function getApi(): Promise<Api> {
  return previewMode ? (await import("./preview")).previewApi : liveApi;
}
export async function photoUrl(path: string) {
  if (previewMode || !supabase) return "";
  const { data, error } = await supabase.storage
    .from("community-photos")
    .createSignedUrl(path, 60);
  if (error) throw error;
  return data.signedUrl;
}
