import { previewMode, supabase } from "../api";
import type { Snapshot, UsageReport, UsageTrend } from "./types";
async function rpc<T>(name: string, args: Record<string, unknown>): Promise<T> {
  if (!supabase) throw Error("운영 서버 연결이 필요합니다.");
  const { data, error } = await supabase.rpc(name, args);
  if (error) throw error;
  return data as T;
}
export async function usageReport(
  from: string,
  to: string,
  audience: string,
  trend = false,
): Promise<UsageReport | UsageTrend> {
  if (previewMode) {
    const { exampleReport } = await import("./preview");
    const report = exampleReport(from, to, audience);
    return trend
      ? {
          definition: report.definition,
          from,
          to,
          audience,
          timezone: "Asia/Seoul",
          notice: "화면 확인용 예시입니다. 실사용 실적이 아닙니다.",
          days: report.daily.map((d) => ({
            day: d.day,
            calculatedAt: report.generatedAt,
            data: { ...report, totals: d.totals },
          })),
        }
      : report;
  }
  return rpc(trend ? "ops_usage_trend" : "ops_usage_report", {
    p_from: from,
    p_to: to,
    p_audience: audience,
  });
}
export async function usageExport(
  from: string,
  to: string,
  audience: string,
  trend = false,
): Promise<Snapshot> {
  if (previewMode) {
    const report = await usageReport(from, to, audience, trend),
      canonicalPayload = JSON.stringify(report),
      bytes = await crypto.subtle.digest(
        "SHA-256",
        new TextEncoder().encode(canonicalPayload),
      );
    return {
      id: "PREVIEW-" + crypto.randomUUID(),
      createdAt: new Date().toISOString(),
      canonicalPayload,
      sha256: Array.from(new Uint8Array(bytes), (b) =>
        b.toString(16).padStart(2, "0"),
      ).join(""),
    };
  }
  return rpc("ops_usage_export", {
    p_from: from,
    p_to: to,
    p_audience: audience,
    p_trend: trend,
  });
}
