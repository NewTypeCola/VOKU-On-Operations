import { test, before, after } from "node:test";
import assert from "node:assert/strict";
import { readFile, readdir } from "node:fs/promises";
import { createHash, randomUUID } from "node:crypto";
import { PGlite } from "@electric-sql/pglite";
const db = new PGlite();
const key = "a".repeat(64),
  owner = randomUUID(),
  member = randomUUID(),
  staff = randomUUID(),
  ownerSession = randomUUID();
const record = "voku_1988_1_voku_reporters_desk_01";
const legacyEntity = randomUUID(),
  legacySession = randomUUID();
let totalsBeforeMigration;
const scalar = async (sql, args = []) =>
  Object.values((await db.query(sql, args)).rows[0])[0];
const today = () =>
  new Date(Date.now() + 9 * 3600000).toISOString().slice(0, 10);
async function as(uid, sql, args = [], aal = "aal2") {
  await db.exec("begin");
  try {
    await db.query("select set_config('request.jwt.claims',$1,true)", [
      JSON.stringify({ sub: uid, aal, session_id: ownerSession }),
    ]);
    await db.exec(uid ? "set local role authenticated" : "set local role anon");
    const result = await scalar(sql, args);
    await db.exec("commit");
    return result;
  } catch (error) {
    await db.exec("rollback");
    throw error;
  }
}
const event = (name, data = {}) => ({
  id: randomUUID(),
  at: new Date().toISOString(),
  seq: 1,
  name,
  route: "reader",
  ...data,
});
const payload = (events, extra = {}) => ({
  v: 1,
  visitor: randomUUID(),
  session: randomUUID(),
  events,
  source: "direct",
  campaign: "none",
  ...extra,
});
const context = {
  rateKey: "f".repeat(64),
  environment: "production",
  device: "mobile",
  release: "test",
};
const ingest = (body, uid = null, ctx = context) =>
  as(uid, "select public.usage_ingest($1,$2,$3)", [key, body, ctx]);
const report = (audience = "real") =>
  as(owner, "select public.ops_usage_report($1,$2,$3)", [
    today(),
    today(),
    audience,
  ]);
before(async () => {
  await db.exec(`create role anon;create role authenticated;create role service_role bypassrls;
 create schema auth;create schema storage;
 create table auth.users(id uuid primary key,email text unique,email_confirmed_at timestamptz,raw_user_meta_data jsonb default '{}',raw_app_meta_data jsonb default '{}',created_at timestamptz default now());
 create table auth.sessions(id uuid primary key,user_id uuid references auth.users(id) on delete cascade);
 create table auth.identities(id uuid primary key default gen_random_uuid(),user_id uuid references auth.users(id) on delete cascade,provider text,identity_data jsonb);
 create function auth.jwt() returns jsonb language sql stable as $$select coalesce(nullif(current_setting('request.jwt.claims',true),'')::jsonb,'{}')$$;
 create function auth.uid() returns uuid language sql stable as $$select nullif(auth.jwt()->>'sub','')::uuid$$;
 grant usage on schema auth,storage to anon,authenticated;
 create table storage.buckets(id text primary key,name text,public boolean,file_size_limit bigint,allowed_mime_types text[]);
 create table storage.objects(id uuid primary key default gen_random_uuid(),bucket_id text,name text,metadata jsonb default '{}',owner_id text,unique(bucket_id,name));
 alter table storage.objects enable row level security;grant select,insert,update,delete on storage.objects to anon,authenticated;`);
  for (const file of (
    await readdir(new URL("./fixtures/community/", import.meta.url))
  ).sort())
    await db.exec(
      await readFile(
        new URL("./fixtures/community/" + file, import.meta.url),
        "utf8",
      ),
    );
  for (const name of [
    "20261012034823_operations_dashboard.sql",
    "20261014104157_usage_analytics.sql",
    "20261014104239_usage_catalog.sql",
    "20261014110418_usage_relation_indexes.sql",
  ])
    await db.exec(
      await readFile(
        new URL("../supabase/migrations/" + name, import.meta.url),
        "utf8",
      ),
    );
  await db.query(
    "insert into voku_metrics.config values('ingest_hash',voku_metrics.hash($1))",
    [key],
  );
  await db.query(
    "insert into voku_ops.invitations(email,name,role) values('metrics@example.test','통계 담당','owner')",
  );
  await db.query(
    "insert into auth.users(id,email,email_confirmed_at,raw_user_meta_data) values($1,'metrics@example.test',now(),'{\"account_channel\":\"voku_operations\"}')",
    [owner],
  );
  await db.query("insert into auth.sessions values($1,$2)", [
    ownerSession,
    owner,
  ]);
  for (const [id, role] of [
    [member, "member"],
    [staff, "admin"],
  ]) {
    await db.query(
      "insert into auth.users(id,email,email_confirmed_at) values($1,$2,now())",
      [id, id + "@example.test"],
    );
    await db.query(
      "update voku_private.members set role=$2,profile_complete=true where id=$1",
      [id, role],
    );
  }
  await db.query(
    "insert into voku_metrics.sessions(id,visitor,first_at,last_at,is_returning,audience,source,campaign,device,release,environment) values($1,'legacy-browser',now(),now(),false,'real','direct','none','desktop','legacy','production')",
    [legacySession],
  );
  await db.query(
    "insert into voku_metrics.events(id,session_id,occurred_at,seq,name,route,entity_id,value) values(gen_random_uuid(),$1,now(),1,'post_created','post',$2,0)",
    [legacySession, legacyEntity],
  );
  totalsBeforeMigration = (await report("all")).totals;
  await db.exec(
    "create role analysis_alice login; create role analysis_bob login;",
  );
  const migration = (
    await readdir(new URL("../supabase/migrations/", import.meta.url))
  ).find((n) => n.endsWith("_usage_backend_analysis.sql"));
  await db.exec(
    await readFile(
      new URL("../supabase/migrations/" + migration, import.meta.url),
      "utf8",
    ),
  );
  await db.exec("grant voku_usage_reader to analysis_alice,analysis_bob;");
});
after(() => db.close());

async function asLogin(login, fn) {
  assert.ok(
    [
      "analysis_alice",
      "analysis_bob",
      "anon",
      "authenticated",
      "service_role",
    ].includes(login),
  );
  await db.exec(`set session authorization ${login}`);
  try {
    return await fn();
  } finally {
    await db.exec("rollback; set session authorization postgres; reset role");
  }
}
const reason = "아카이브 열람 이후 재방문 경로를 확인합니다";
const prepare = (
  purpose = "archive_journey",
  audience = "real",
  why = reason,
  from = today(),
  to = today(),
) =>
  scalar("select voku_analysis.prepare($1,$2,$3,$4,$5)", [
    from,
    to,
    purpose,
    why,
    audience,
  ]);
const read = (id) => scalar("select voku_analysis.read_result($1)", [id]);

test("migration removes legacy content UUIDs while preserving existing aggregate metrics", async () => {
  assert.deepEqual((await report("all")).totals, totalsBeforeMigration);
  const stored = await scalar(
    "select entity_key from voku_metrics.events where session_id=$1",
    [legacySession],
  );
  assert.match(stored, /^[a-f0-9]{64}$/);
  assert.notEqual(stored, legacyEntity);
});

test("app roles cannot reach backend analysis; the reader cannot access or mutate source/member/audit tables", async () => {
  for (const login of ["anon", "authenticated", "service_role"])
    await asLogin(login, () =>
      assert.rejects(
        () => prepare(),
        /permission denied|backend_role_required/,
      ),
    );
  await asLogin("analysis_alice", async () => {
    for (const sql of [
      "select * from voku_metrics.events",
      "select * from voku_metrics.config",
      "select * from auth.users",
      "select * from public.community_profiles",
      "select * from public.community_posts",
      "select * from voku_analysis.results",
      "select * from voku_analysis.requests",
      "delete from voku_analysis.requests",
      "update voku_metrics.events set value=0",
      "select voku_analysis.maintain()",
      "set role authenticated",
    ])
      await assert.rejects(() => db.exec(sql), /permission denied/);
  });
});

test("a purpose receipt must commit before data can be returned, including savepoints", async () => {
  await ingest(payload([event("page_view", { route: "home" })]));
  let receipt;
  await asLogin("analysis_alice", async () => {
    await db.exec("begin");
    receipt = await prepare();
    assert.equal(Object.hasOwn(receipt, "events"), false);
    await db.exec("savepoint read_attempt");
    await assert.rejects(
      () => read(receipt.requestId),
      /commit_purpose_before_reading/,
    );
    await db.exec("rollback to savepoint read_attempt; commit");
    const data = await read(receipt.requestId);
    assert.ok(data.events.length > 0);
    assert.equal(
      createHash("sha256").update(data.canonicalEvents).digest("hex"),
      data.sha256,
    );
  });
  assert.equal(
    await scalar(
      "select count(*)::int from voku_analysis.requests where id=$1",
      [receipt.requestId],
    ),
    1,
  );
  assert.equal(
    await scalar(
      "select count(*)::int from voku_analysis.deliveries where request_id=$1",
      [receipt.requestId],
    ),
    1,
  );
});

test("rolling back a result read cannot erase its previously committed purpose and result checksum", async () => {
  let receipt;
  await asLogin("analysis_alice", async () => {
    receipt = await prepare();
    await db.exec("begin");
    assert.equal((await read(receipt.requestId)).sha256, receipt.sha256);
    await db.exec("rollback");
  });
  assert.equal(
    await scalar(
      "select count(*)::int from voku_analysis.requests where id=$1",
      [receipt.requestId],
    ),
    1,
  );
});

test("principals cannot read another analyst result and audit records cannot be rewritten", async () => {
  const receipt = await asLogin("analysis_alice", () => prepare());
  await asLogin("analysis_bob", async () => {
    await assert.rejects(() => read(receipt.requestId), /request_not_found/);
    assert.deepEqual(await scalar("select voku_analysis.my_requests()"), []);
  });
  const actor = await scalar(
    "select db_actor::text from voku_analysis.requests where id=$1",
    [receipt.requestId],
  );
  assert.equal(actor, "analysis_alice");
  await asLogin("analysis_alice", () =>
    assert.rejects(
      () =>
        db.query("update voku_analysis.requests set reason=$1 where id=$2", [
          "다른 사유로 바꾸려는 시도",
          receipt.requestId,
        ]),
      /permission denied/,
    ),
  );
});

test("return visits stay connected within one request; identifiers and absolute times do not escape", async () => {
  const p = payload([
    event("read_open", { record }),
    event("read_tick", { record, value: 30000 }),
  ]);
  await ingest(p);
  await db.query(
    "update voku_metrics.visitors set first_at=now()-interval '1 day' where key=(select visitor from voku_metrics.sessions where id=$1)",
    [p.session],
  );
  const another = payload([event("read_open", { record })], {
    visitor: p.visitor,
  });
  await ingest(another);
  const post = await scalar(
    "insert into public.community_posts(author_id,category,title,body,record_id) values($1,'추억','확인','본문',$2) returning id",
    [member, record],
  );
  await ingest(
    { ...another, events: [event("post_created", { entity: post })] },
    member,
  );
  const rawKey = await scalar(
    "select visitor from voku_metrics.sessions where id=$1",
    [p.session],
  );
  const first = await asLogin("analysis_alice", async () =>
    read((await prepare()).requestId),
  );
  const rows = first.events.filter((e) => e.record === record);
  assert.equal(new Set(rows.map((e) => e.browser)).size, 1);
  assert.equal(new Set(rows.map((e) => e.visit)).size, 2);
  assert.ok(rows.some((e) => e.returning));
  const serialized = JSON.stringify(first);
  for (const secret of [
    p.visitor,
    p.session,
    another.session,
    rawKey,
    post,
    member,
  ])
    assert.ok(!serialized.includes(secret));
  assert.ok(
    !/occurred_at|entity_id|entity_key|author_id|email|received_at/.test(
      serialized,
    ),
  );
  assert.ok(rows.every((e) => Number.isInteger(e.elapsedSeconds)));
  const second = await asLogin("analysis_alice", async () =>
    read((await prepare()).requestId),
  );
  assert.notEqual(first.events[0].browser, second.events[0].browser);
  const stored = await scalar(
    "select entity_key from voku_metrics.events where name='post_created' order by received_at desc limit 1",
  );
  assert.match(stored, /^[a-f0-9]{64}$/);
  assert.equal(
    await scalar(
      "select count(*)::int from information_schema.columns where table_schema='voku_metrics' and table_name='events' and column_name='entity_id'",
    ),
    0,
  );
});

test("invalid/oversized scopes and personal identifiers in reasons fail before creating a receipt", async () => {
  const count = await scalar(
    "select count(*)::int from voku_analysis.requests",
  );
  await asLogin("analysis_alice", async () => {
    await assert.rejects(() => prepare("unknown"), /purpose/);
    await assert.rejects(
      () => prepare("archive_journey", "all"),
      /diagnostic_purpose/,
    );
    await assert.rejects(
      () => prepare("incident", "all", "특정 이메일 user@example.test 확인"),
      /nonpersonal_reason/,
    );
    await assert.rejects(() => prepare("returning", "real", "짧음"), /purpose/);
    await assert.rejects(
      () => prepare("returning", "real", reason, "2020-01-01", today()),
      /date_range/,
    );
    await assert.rejects(
      () => prepare("returning", "real", reason, null, today()),
      /date_range/,
    );
  });
  assert.equal(
    await scalar("select count(*)::int from voku_analysis.requests"),
    count,
  );
});

test("normal analysis excludes test/staff/sample traffic; diagnostics must name their purpose", async () => {
  await ingest(payload([event("feature", { detail: "menu" })], { test: true }));
  await ingest(payload([event("feature", { detail: "menu" })]), staff);
  const real = await asLogin("analysis_alice", async () =>
    read((await prepare()).requestId),
  );
  assert.ok(real.events.every((e) => e.audience === "real" && !e.sample));
  const diagnostic = await asLogin("analysis_alice", async () =>
    read((await prepare("data_quality", "test")).requestId),
  );
  assert.ok(diagnostic.events.length > 0);
  assert.ok(diagnostic.events.every((e) => e.audience === "test"));
});

test("result size is bounded and incomplete journeys are explicitly marked", async () => {
  const p = payload([event("page_view")]);
  await ingest(p);
  await db.query(
    "insert into voku_metrics.events(id,session_id,occurred_at,seq,name,route,value) select gen_random_uuid(),$1,now(),g,'page_view','archive',0 from generate_series(1,5001) g",
    [p.session],
  );
  const data = await asLogin("analysis_alice", async () =>
    read((await prepare()).requestId),
  );
  assert.equal(data.rows, 5000);
  assert.equal(data.events.length, 5000);
  assert.equal(data.truncated, true);
  await db.query("delete from voku_metrics.sessions where id=$1", [p.session]);
});

test("privacy erasure invalidates cached results while preserving the non-journey audit trail", async () => {
  const p = payload([event("page_view")]);
  await ingest(p);
  const receipt = await asLogin("analysis_alice", () => prepare());
  await as(null, "select public.usage_erase($1,$2)", [key, p.visitor]);
  await asLogin("analysis_alice", () =>
    assert.rejects(() => read(receipt.requestId), /unavailable/),
  );
  assert.equal(
    await scalar(
      "select count(*)::int from voku_analysis.requests where id=$1",
      [receipt.requestId],
    ),
    1,
  );
  assert.equal(
    await scalar("select count(*)::int from voku_analysis.results"),
    0,
  );
});

test("expired results are unreadable and housekeeping removes results and year-old audit records", async () => {
  const receipt = await asLogin("analysis_bob", () => prepare());
  await db.query(
    "update voku_analysis.requests set expires_at=now()-interval '1 second' where id=$1",
    [receipt.requestId],
  );
  await db.query(
    "update voku_analysis.results set expires_at=now()-interval '1 second' where request_id=$1",
    [receipt.requestId],
  );
  await asLogin("analysis_bob", () =>
    assert.rejects(() => read(receipt.requestId), /expired/),
  );
  await db.query(
    "update voku_analysis.requests set created_at=now()-interval '366 days' where id=$1",
    [receipt.requestId],
  );
  await db.exec("select voku_analysis.maintain()");
  assert.equal(
    await scalar(
      "select count(*)::int from voku_analysis.requests where id=$1",
      [receipt.requestId],
    ),
    0,
  );
  assert.equal(
    await scalar(
      "select count(*)::int from voku_analysis.results where request_id=$1",
      [receipt.requestId],
    ),
    0,
  );
});

test("per-principal preparation quota prevents unbounded extraction jobs", async () => {
  await asLogin("analysis_bob", async () => {
    for (let i = 0; i < 20; i++) await prepare();
    await assert.rejects(() => prepare(), /hourly_request_limit/);
  });
});
