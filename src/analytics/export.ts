export function csvCell(value: unknown) {
  const text = String(value ?? "");
  // Spreadsheet formula injection also applies to names from public archive metadata.
  return (
    '"' +
    (/^[\s]*[=+@-]/.test(text) ? "'" + text : text).replaceAll('"', '""') +
    '"'
  );
}
export function reportCsv(report: Record<string, unknown>) {
  const rows: unknown[][] = [
    ["VOKU On 이용 분석", report.definition],
    ["기간", report.from, report.to],
    ["대상", report.audience],
    ["시간대", report.timezone],
  ];
  const section = (name: string, items: Record<string, unknown>[]) => {
    rows.push([], [name]);
    if (!items.length) {
      rows.push(["관측 기록 없음"]);
      return;
    }
    const keys = [...new Set(items.flatMap(Object.keys))];
    rows.push(keys);
    for (const item of items) rows.push(keys.map((k) => item[k]));
  };
  if (Array.isArray(report.days)) {
    rows.push(["주의", report.notice]);
    section(
      "일별 집계",
      report.days.map((d) => ({ day: d.day, ...d.data.totals })),
    );
  } else {
    section("기간 지표", [report.totals as Record<string, unknown>]);
    section("수집 상태", [report.coverage as Record<string, unknown>]);
    section("제외한 이벤트", [report.excluded as Record<string, unknown>]);
    section(
      "일별 지표",
      (report.daily as { day: string; totals: Record<string, unknown> }[]).map(
        (d) => ({ day: d.day, ...d.totals }),
      ),
    );
    for (const key of [
      "archive",
      "sources",
      "devices",
      "routes",
      "transitions",
      "features",
      "errors",
      "performance",
    ])
      section(key, report[key] as Record<string, unknown>[]);
    section("기존 DB 참고 지표", [report.legacy as Record<string, unknown>]);
  }
  return "\ufeff" + rows.map((row) => row.map(csvCell).join(",")).join("\r\n");
}
export function download(content: string, filename: string, mime: string) {
  const url = URL.createObjectURL(new Blob([content], { type: mime }));
  const link = document.createElement("a");
  link.href = url;
  link.download = filename;
  link.click();
  setTimeout(() => URL.revokeObjectURL(url), 1000);
}
