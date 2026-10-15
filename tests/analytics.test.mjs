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
    ...(await readdir(new URL("../supabase/migrations/", import.meta.url)))
      .filter(
        (n) =>
          n.endsWith("_usage_backend_analysis.sql") ||
          n.endsWith("_scope_analysis_erasure.sql"),
      )
      .sort(),
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
});
after(() => db.close());
test("no direct tables, no collector bypass, and operations AAL2 is mandatory", async () => {
  await assert.rejects(
    () => as(null, "select * from voku_metrics.events"),
    /permission denied/,
  );
  await assert.rejects(
    () => as(member, "select * from voku_metrics.events"),
    /permission denied/,
  );
  await assert.rejects(
    () =>
      as(null, "select public.usage_ingest($1,$2,$3)", [
        "wrong",
        payload([event("page_view")]),
        context,
      ]),
    /collector_required/,
  );
  await assert.rejects(
    () => as(staff, "select public.ops_usage_report($1,$1)", [today()]),
    /ops_access_denied/,
  );
  await assert.rejects(
    () => as(owner, "select public.ops_usage_report($1,$1)", [today()], "aal1"),
    /ops_mfa_required/,
  );
  assert.equal((await report()).totals.events, 0);
});
test("ingestion is idempotent, strips unknown properties, and rejects raw strings/invalid records", async () => {
  const batch = payload([
    event("page_view", {
      route: "home",
      email: "secret@example.test",
      query: "sensitive search",
    }),
    event("search", { detail: "sensitive raw query" }),
    event("read_page", { record: "voku_unknown", page: 1 }),
  ]);
  assert.deepEqual(await ingest(batch), {
    accepted: 1,
    rejected: 2,
    duplicate: 0,
  });
  assert.equal((await ingest(batch)).duplicate, 1);
  const rows = await db.query("select * from voku_metrics.events");
  assert.ok(!JSON.stringify(rows).includes("secret@example"));
  assert.ok(!JSON.stringify(rows).includes("sensitive"));
  assert.equal((await report()).totals.pageViews, 1);
});
test("real, test, bot, staff and preview traffic stay separable; staff logout remains excluded", async () => {
  const staffBatch = payload([event("page_view", { route: "home" })]);
  await ingest(staffBatch, staff);
  await ingest({
    ...staffBatch,
    events: [event("page_view", { route: "archive" })],
  });
  await ingest(payload([event("page_view")], { test: true }));
  await ingest(payload([event("page_view")]), null, { ...context, bot: true });
  await ingest(payload([event("page_view")]), null, {
    ...context,
    environment: "preview",
  });
  const data = await report();
  assert.equal(data.totals.pageViews, 1);
  assert.equal(data.excluded.staff, 2);
  assert.equal(data.excluded.test, 2);
  assert.equal(data.excluded.bot, 1);
  assert.equal((await report("all")).totals.pageViews, 6);
});
test("sample content is classified from the DB even when the client says it is real", async () => {
  const post = await scalar(
    "insert into public.community_posts(author_id,category,title,body,sample_batch) values($1,'일상','예시','예시','test') returning id",
    [member],
  );
  await ingest(
    payload([
      event("post_view", { route: "post", entity: post }),
      event("page_view", { route: "post", entity: post }),
    ]),
  );
  assert.equal((await report()).excluded.sample, 2);
});
test("qualified reading requires 30 active seconds; jumping to the last page does not complete", async () => {
  const p = payload([
    event("read_open", { record }),
    event("read_tick", { record, value: 15000 }),
    event("read_tick", { record, value: 15000 }),
    event("read_page", { record, page: 17 }),
  ]);
  await ingest(p);
  const data = await report();
  assert.equal(data.totals.qualifiedReads, 1);
  assert.equal(data.totals.completeReads, 0);
  assert.equal(data.totals.readPages, 1);
  await ingest({
    ...p,
    events: Array.from({ length: 16 }, (_, i) =>
      event("read_page", { record, page: i + 1 }),
    ),
  });
  assert.equal((await report()).totals.completeReads, 1);
});
test("only owned real creations can prove a read-to-community conversion, and retries cannot inflate it", async () => {
  const post = await scalar(
    "insert into public.community_posts(author_id,category,title,body,record_id) values($1,'추억','작성','본문',$2) returning id",
    [member, record],
  );
  const p = payload([
    event("read_open", { record }),
    event("read_tick", { record, value: 30000 }),
    event("reader_compose", { record }),
  ]);
  await ingest(p, member);
  await new Promise((resolve) => setTimeout(resolve, 5));
  assert.equal(
    (await ingest({ ...p, events: [event("post_created", { entity: post })] }))
      .rejected,
    1,
  );
  assert.equal(
    (
      await ingest(
        { ...p, events: [event("post_created", { entity: post })] },
        member,
      )
    ).accepted,
    1,
  );
  assert.equal(
    (
      await ingest(
        { ...p, events: [event("post_created", { entity: post })] },
        member,
      )
    ).duplicate,
    1,
  );
  const data = await report();
  assert.equal(data.totals.readToCommunity, 1);
  assert.equal(data.totals.posts, 1);
});
test("reports are dated, checksummed immutable snapshots with an audit entry", async () => {
  const out = await as(owner, "select public.ops_usage_export($1,$1)", [
    today(),
  ]);
  assert.equal(
    createHash("sha256").update(out.canonicalPayload).digest("hex"),
    out.sha256,
  );
  assert.equal(JSON.parse(out.canonicalPayload).timezone, "Asia/Seoul");
  assert.equal(
    await scalar(
      "select count(*)::int from voku_ops.audit where action='analytics_export'",
    ),
    1,
  );
  await assert.rejects(
    () => as(member, "select public.ops_usage_export($1,$1)", [today()]),
    /ops_access_denied/,
  );
});
test("retention preserves daily aggregates, deletes old identities, and browser erasure removes retained events", async () => {
  const p = payload([event("page_view", { route: "home" })]);
  await ingest(p);
  await db.query(
    "update voku_metrics.events set occurred_at=now()-interval '91 days'+interval '2 hours' where session_id=$1",
    [p.session],
  );
  await db.query(
    "update voku_metrics.visitors set last_at=now()-interval '181 days' where key=(select visitor from voku_metrics.sessions where id=$1)",
    [p.session],
  );
  await db.exec("select voku_metrics.maintain()");
  assert.equal(
    await scalar(
      "select count(*)::int from voku_metrics.events where session_id=$1",
      [p.session],
    ),
    0,
  );
  assert.ok((await scalar("select count(*)::int from voku_metrics.daily")) > 0);
  const erase = payload([event("page_view")]);
  await ingest(erase);
  await as(null, "select public.usage_erase($1,$2)", [key, erase.visitor]);
  assert.equal(
    await scalar(
      "select count(*)::int from voku_metrics.events where session_id=$1",
      [erase.session],
    ),
    0,
  );
  assert.ok(
    (await as(owner, "select public.ops_usage_trend($1,$1)", [today()])).days
      .length,
  );
});
