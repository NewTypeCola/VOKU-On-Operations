import test from "node:test";
import assert from "node:assert/strict";
import { csvCell, reportCsv } from "../src/analytics/export.ts";
test("CSV quotes delimiters and neutralizes spreadsheet formulas", () => {
  assert.equal(csvCell('=HYPERLINK("evil")'), '"\'=HYPERLINK(""evil"")"');
  assert.equal(csvCell("line\nnext"), '"line\nnext"');
  assert.equal(csvCell("+1"), '"\'+1"');
  const report = {
    definition: "v1",
    from: "2026-10-14",
    to: "2026-10-14",
    audience: "real",
    timezone: "Asia/Seoul",
    totals: { sessions: 3 },
    coverage: { accepted: 5 },
    excluded: { test: 2 },
    daily: [],
    archive: [],
    sources: [],
    devices: [],
    routes: [],
    transitions: [],
    features: [],
    errors: [],
    performance: [],
    legacy: { posts: 7 },
  };
  const csv = reportCsv(report);
  assert.ok(csv.startsWith("\ufeff"));
  assert.ok(csv.includes('"real"'));
  assert.ok(csv.includes('"sessions"'));
});
