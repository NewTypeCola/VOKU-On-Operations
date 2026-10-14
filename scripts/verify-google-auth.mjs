import assert from "node:assert/strict";
import { createHash, randomBytes } from "node:crypto";
import { readFile, writeFile } from "node:fs/promises";
import { operatorOrigins } from "../src/auth.ts";

const env = Object.fromEntries(
  (await readFile(new URL("../.env.local", import.meta.url), "utf8"))
    .split("\n")
    .filter((line) => line.includes("=") && !line.startsWith("#"))
    .map((line) => [
      line.slice(0, line.indexOf("=")),
      line.slice(line.indexOf("=") + 1).trim(),
    ]),
);

// Exercise an anonymous OAuth cancellation, not an account sign-in. Never log
// authorization URLs, state, cookies, tokens or provider/account information.
const checks = [];
for (const origin of operatorOrigins) {
  const authorize = new URL("/auth/v1/authorize", env.VITE_SUPABASE_URL);
  authorize.searchParams.set("provider", "google");
  authorize.searchParams.set("redirect_to", origin + "/");
  authorize.searchParams.set(
    "code_challenge",
    createHash("sha256")
      .update(randomBytes(32).toString("base64url"))
      .digest("base64url"),
  );
  authorize.searchParams.set("code_challenge_method", "s256");
  const start = await fetch(authorize, {
    redirect: "manual",
    headers: { apikey: env.VITE_SUPABASE_PUBLISHABLE_KEY },
  });
  assert.equal(start.status, 302, "Google OAuth must start successfully");
  const google = new URL(start.headers.get("location"));
  assert.equal(google.hostname, "accounts.google.com");
  const state = google.searchParams.get("state");
  assert.ok(state, "Supabase must supply OAuth state");
  const callback = new URL("/auth/v1/callback", env.VITE_SUPABASE_URL);
  callback.searchParams.set("state", state);
  callback.searchParams.set("error", "access_denied");
  const cancel = await fetch(callback, {
    redirect: "manual",
    headers: {
      Cookie: start.headers
        .getSetCookie()
        .map((cookie) => cookie.split(";")[0])
        .join("; "),
    },
  });
  assert.equal(cancel.status, 302);
  const returned = new URL(cancel.headers.get("location"));
  assert.equal(
    returned.origin,
    origin,
    "OAuth must return to the requested operator origin",
  );
  assert.equal(returned.pathname, "/");
  checks.push({
    origin,
    authorizeStatus: start.status,
    canceledStatus: cancel.status,
    returnedToExpectedOrigin: true,
  });
}
const evidence = {
  verifiedAt: new Date().toISOString(),
  checks,
  signedInUser: false,
};
await writeFile(
  new URL("../artifacts/google-auth-redirects.json", import.meta.url),
  JSON.stringify(evidence, null, 2) + "\n",
);
console.log(JSON.stringify(evidence, null, 2));
