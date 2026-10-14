import { test } from "node:test";
import assert from "node:assert/strict";
import {
  createOAuthCompletion,
  googleAuthOptions,
  operatorOrigins,
  readAuthCallback,
} from "../src/auth.ts";

test("Google OAuth returns only to exact operator origins", () => {
  for (const origin of operatorOrigins) {
    assert.deepEqual(googleAuthOptions(origin), {
      provider: "google",
      options: {
        redirectTo: origin + "/",
        queryParams: { prompt: "select_account" },
      },
    });
  }
  for (const origin of [
    "https://voku.pages.dev",
    "https://preview.voku-operates.pages.dev",
    "https://voku-operates.pages.dev.attacker.example",
    "http://localhost:9999",
  ])
    assert.equal(googleAuthOptions(origin), null);
});

test("callback cleans auth parameters while preserving dashboard navigation", () => {
  const result = readAuthCallback(
    "https://voku-operates.pages.dev/?code=one-time&sb_flow_id=flow&from=bookmark#/analytics",
  );
  assert.equal(result.code, "one-time");
  assert.equal(result.flowId, "flow");
  assert.equal(result.cleanUrl, "/?from=bookmark#/analytics");
  assert.equal(
    readAuthCallback("https://voku-operates.pages.dev/#/analytics").callback,
    false,
  );
  assert.equal(
    readAuthCallback(
      "https://voku-operates.pages.dev/#access_token=secret&refresh_token=secret&provider_token=secret",
    ).cleanUrl,
    "/",
  );
});

test("concurrent identity refreshes exchange PKCE once, after removing code from URL", async () => {
  const events = [];
  const flowId = "777d9325-b741-4fc1-8090-55266cce0cbe";
  const finish = createOAuthCompletion(
    {
      async exchangeCodeForSession(code, options) {
        events.push({ code, options });
        return { error: null };
      },
    },
    `https://voku-operates.pages.dev/?code=one-time&sb_flow_id=${flowId}`,
    (url) => events.push(url),
  );
  assert.deepEqual(await Promise.all([finish(), finish(), finish()]), [
    "",
    "",
    "",
  ]);
  assert.deepEqual(events, ["/", { code: "one-time", options: { flowId } }]);
});

test("canceled and invalid callbacks never attempt session exchange or expose provider text", async () => {
  const auth = {
    exchangeCodeForSession() {
      assert.fail("must not exchange");
    },
  };
  for (const suffix of [
    "#error=access_denied&error_description=secret-value",
    "?error=server_error&error_description=secret-value",
    "?code=%3Cscript%3E",
    "#access_token=secret-value",
    "?code=",
  ]) {
    let cleaned;
    const message = await createOAuthCompletion(
      auth,
      "https://voku-operates.pages.dev/" + suffix,
      (url) => {
        cleaned = url;
      },
    )();
    assert.ok(message.length > 0);
    assert.equal(cleaned, "/");
    assert.doesNotMatch(message, /secret-value|<script>/);
  }
});

test("expired PKCE and connection failures offer retry without leaking server details", async () => {
  const failing = [
    async () => ({ error: { message: "sensitive-server-detail" } }),
    async () => {
      throw new Error("sensitive-server-detail");
    },
  ];
  for (const exchangeCodeForSession of failing) {
    const message = await createOAuthCompletion(
      { exchangeCodeForSession },
      "https://voku-operates.pages.dev/?code=expired",
      () => {},
    )();
    assert.match(message, /다시/);
    assert.doesNotMatch(message, /sensitive-server-detail/);
  }
});

test("normal navigation and preview mode do not run authentication", async () => {
  const auth = {
    exchangeCodeForSession() {
      assert.fail("must not exchange");
    },
  };
  const replace = () => assert.fail("must not replace ordinary URL");
  assert.equal(
    await createOAuthCompletion(
      auth,
      "https://voku-operates.pages.dev/#/analytics",
      replace,
    )(),
    "",
  );
  assert.equal(
    await createOAuthCompletion(
      null,
      "https://voku-operates.pages.dev/?preview=1",
      replace,
    )(),
    "",
  );
});
