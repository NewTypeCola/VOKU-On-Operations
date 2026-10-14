// Uses only the public key; all generated events are explicitly test activity.
import fs from "node:fs";
import assert from "node:assert/strict";
import { randomUUID } from "node:crypto";
const settings = Object.fromEntries(
  fs
    .readFileSync(".env.local", "utf8")
    .split("\n")
    .filter((line) => /^[A-Z_]+=/.test(line))
    .map((line) => {
      const at = line.indexOf("=");
      return [
        line.slice(0, at),
        line
          .slice(at + 1)
          .trim()
          .replace(/^['"]|['"]$/g, ""),
      ];
    }),
);
const origin = "https://voku.pages.dev";
const session = randomUUID(),
  visitor = randomUUID();
const events = [
  {
    id: randomUUID(),
    seq: 1,
    at: new Date().toISOString(),
    name: "page_view",
    route: "archive",
  },
  {
    id: randomUUID(),
    seq: 2,
    at: new Date().toISOString(),
    name: "read_open",
    route: "reader",
    record: "voku_1988_1_voku_reporters_desk_01",
  },
];
const body = { v: 1, test: true, visitor, session, source: "direct", events };
const send = (data, requestOrigin = origin) =>
  fetch(origin + "/api/usage", {
    method: "POST",
    headers: {
      Origin: requestOrigin,
      "Content-Type": "application/json",
      "User-Agent": "VOKU-Analytics-Verification/1",
    },
    body: JSON.stringify(data),
  });
const first = await send(body);
assert.equal(first.status, 200);
const received = await first.json();
assert.equal(received.accepted, 2);
const retry = await send(body);
const duplicate = await retry.json();
assert.equal(duplicate.duplicate, 2);
const crossOrigin = await send(body, "https://example.invalid");
assert.equal(crossOrigin.status, 403);
const rpc = async (name, args) =>
  fetch(settings.VITE_SUPABASE_URL + "/rest/v1/rpc/" + name, {
    method: "POST",
    headers: {
      apikey: settings.VITE_SUPABASE_PUBLISHABLE_KEY,
      "Content-Type": "application/json",
    },
    body: JSON.stringify(args),
  });
const today = new Date(Date.now() + 9 * 3600000).toISOString().slice(0, 10);
const unauthorized = await rpc("ops_usage_report", {
  p_from: today,
  p_to: today,
});
assert.ok([401, 403].includes(unauthorized.status));
const bypass = await rpc("usage_ingest", {
  p_key: "wrong",
  p_payload: body,
  p_context: {},
});
assert.ok([401, 403].includes(bypass.status));
const result = {
  at: new Date().toISOString(),
  environment: origin,
  test: true,
  session,
  accepted: received.accepted,
  duplicate: duplicate.duplicate,
  crossOrigin: crossOrigin.status,
  anonymousReport: unauthorized.status,
  collectorBypass: bypass.status,
};
fs.mkdirSync("artifacts", { recursive: true });
fs.writeFileSync(
  "artifacts/analytics-live-http.json",
  JSON.stringify(result, null, 2) + "\n",
);
console.log(JSON.stringify(result, null, 2));
