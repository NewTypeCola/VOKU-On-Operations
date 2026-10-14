import { readFile, writeFile } from "node:fs/promises";
import assert from "node:assert/strict";
const env = Object.fromEntries(
  (await readFile(new URL("../.env.local", import.meta.url), "utf8"))
    .split("\n")
    .filter((l) => l.includes("=") && !l.startsWith("#"))
    .map((l) => [
      l.slice(0, l.indexOf("=")),
      l.slice(l.indexOf("=") + 1).trim(),
    ]),
);
const headers = {
  apikey: env.VITE_SUPABASE_PUBLISHABLE_KEY,
  "Content-Type": "application/json",
};
const ops = await fetch(`${env.VITE_SUPABASE_URL}/rest/v1/rpc/ops_overview`, {
  method: "POST",
  headers,
  body: "{}",
});
assert.ok(
  [401, 403].includes(ops.status),
  `Unauthenticated ops access returned ${ops.status}`,
);
const feed = await fetch(
  `${env.VITE_SUPABASE_URL}/rest/v1/rpc/community_feed`,
  { method: "POST", headers, body: "{}" },
);
assert.equal(
  feed.status,
  200,
  "Existing public community feed must still work",
);
const result = {
  verifiedAt: new Date().toISOString(),
  anonymousOperationsDenied: ops.status,
  existingPublicCommunityFeed: feed.status,
};
await writeFile(
  new URL("../artifacts/live-api-verification.json", import.meta.url),
  JSON.stringify(result, null, 2) + "\n",
);
console.log(JSON.stringify(result));
