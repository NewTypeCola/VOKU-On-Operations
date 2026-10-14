import { test, before, after } from "node:test";
import assert from "node:assert/strict";
import { readFile, readdir } from "node:fs/promises";
import { PGlite } from "@electric-sql/pglite";

// Real PostgreSQL/RLS/trigger tests in isolation; no production requests.
const db = new PGlite();
const id = (n) => `00000000-0000-4000-8000-${String(n).padStart(12, "0")}`;
const member = id(1),
  staff = id(2),
  owner = id(10),
  operator = id(11),
  viewer = id(12),
  unverified = id(13);
const post = id(100),
  second = id(101),
  deleted = id(102),
  secret = id(103),
  comment = id(200),
  report = id(300),
  commentReport = id(301);
const session = (uid) => uid.replace("00000000-", "11111111-");
const scalar = async (sql, args = []) =>
  Object.values((await db.query(sql, args)).rows[0])[0];
async function as(
  uid,
  sql,
  args = [],
  { aal = "aal2", sess = session(uid), role = "authenticated" } = {},
) {
  await db.exec("begin");
  try {
    await db.query("select set_config('request.jwt.claims',$1,true)", [
      JSON.stringify({ sub: uid, aal, session_id: sess }),
    ]);
    await db.exec(`set local role ${role}`);
    return await scalar(sql, args);
  } finally {
    await db.exec("rollback");
  }
}
async function call(uid, sql, args = [], options = {}) {
  await db.exec("begin");
  try {
    await db.query("select set_config('request.jwt.claims',$1,true)", [
      JSON.stringify({
        sub: uid,
        aal: options.aal || "aal2",
        session_id: options.sess || session(uid),
      }),
    ]);
    await db.exec("set local role authenticated");
    const result = await scalar(sql, args);
    await db.exec("commit");
    return result;
  } catch (e) {
    await db.exec("rollback");
    throw e;
  }
}
const list = (uid, kind, query = {}) =>
  as(uid, "select public.ops_list($1,$2)", [kind, query]);
const detail = (uid, kind, target) =>
  as(uid, "select public.ops_detail($1,$2)", [kind, target]);
const mutate = async (
  uid,
  kind,
  action,
  ids,
  reason = "검토 후 처리",
  value = {},
) => {
  const targets = await Promise.all(
    ids.map(async (i) => ({
      id: i,
      version: (
        await scalar(
          "select payload from voku_ops.entities where kind=$1 and id=$2",
          [kind, i],
        )
      ).version,
    })),
  );
  return call(uid, "select public.ops_mutate($1,$2,$3,$4,$5)", [
    kind,
    action,
    targets,
    reason,
    value,
  ]);
};
let originalFunctions;
before(async () => {
  await db.exec(`create role anon; create role authenticated; create role service_role bypassrls;
    create schema auth; create schema storage;
    create table auth.users(id uuid primary key,email text unique,email_confirmed_at timestamptz,raw_user_meta_data jsonb default '{}',raw_app_meta_data jsonb default '{}',created_at timestamptz default now());
    create table auth.sessions(id uuid primary key,user_id uuid references auth.users(id) on delete cascade);
    create table auth.identities(id uuid primary key default gen_random_uuid(),user_id uuid references auth.users(id) on delete cascade,provider text);
    create function auth.jwt() returns jsonb language sql stable as $$ select coalesce(nullif(current_setting('request.jwt.claims',true),'')::jsonb,'{}') $$;
    create function auth.uid() returns uuid language sql stable as $$ select nullif(auth.jwt()->>'sub','')::uuid $$;
    grant usage on schema auth,storage to anon,authenticated;
    create table storage.buckets(id text primary key,name text,public boolean,file_size_limit bigint,allowed_mime_types text[]);
    create table storage.objects(id uuid primary key default gen_random_uuid(),bucket_id text,name text,metadata jsonb default '{}');
    alter table storage.objects enable row level security; grant select,insert,delete on storage.objects to anon,authenticated;`);
  for (const file of (
    await readdir(new URL("./fixtures/community/", import.meta.url))
  ).sort()) {
    await db.exec(
      await readFile(
        new URL(`./fixtures/community/${file}`, import.meta.url),
        "utf8",
      ),
    );
  }
  originalFunctions = (
    await db.query(
      "select p.oid::regprocedure::text signature,pg_get_functiondef(p.oid) definition from pg_proc p join pg_namespace n on p.pronamespace=n.oid where n.nspname='voku_private' or (n.nspname='public' and proname like 'community_%') order by 1",
    )
  ).rows;
  await db.exec(
    await readFile(
      new URL(
        "../supabase/migrations/20261012034823_operations_dashboard.sql",
        import.meta.url,
      ),
      "utf8",
    ),
  );
  for (const [uid, email] of [
    [member, "member@example.test"],
    [staff, "staff@example.test"],
  ]) {
    await db.query(
      "insert into auth.users(id,email,email_confirmed_at) values($1,$2,now())",
      [uid, email],
    );
    await db.query(
      "update voku_private.members set profile_complete=true,role=$2 where id=$1",
      [uid, uid === staff ? "admin" : "member"],
    );
    await db.query("insert into auth.sessions values($1,$2)", [
      session(uid),
      uid,
    ]);
  }
  for (const [uid, role] of [
    [owner, "owner"],
    [operator, "operator"],
    [viewer, "viewer"],
    [unverified, "operator"],
  ]) {
    await db.query(
      "insert into voku_ops.invitations(email,name,role) values($1,$2,$3)",
      [`${role}${uid.slice(-2)}@example.test`, role, role],
    );
    await db.query(
      'insert into auth.users(id,email,email_confirmed_at,raw_user_meta_data) values($1,$2,$3,\'{"account_channel":"voku_operations","role":"owner"}\')',
      [
        uid,
        `${role}${uid.slice(-2)}@example.test`,
        uid === unverified ? null : new Date().toISOString(),
      ],
    );
    await db.query("insert into auth.sessions values($1,$2)", [
      session(uid),
      uid,
    ]);
  }
  for (const [pid, title, status, isSecret] of [
    [post, "첫 게시글", "published", false],
    [second, "두 번째 글", "published", false],
    [deleted, "삭제된 원문", "deleted", false],
    [secret, "비밀 글", "published", true],
  ]) {
    await db.query(
      "insert into public.community_posts(id,author_id,category,title,body,status,is_secret) values($1,$2,'일상',$3,'원문입니다',$4,$5)",
      [pid, member, title, status, isSecret],
    );
  }
  await db.query(
    "insert into public.community_comments(id,post_id,author_id,body) values($1,$2,$3,'댓글 원문')",
    [comment, post, member],
  );
  await db.query(
    "insert into public.community_reports(id,reporter_id,post_id,reason) values($1,$2,$3,'광고·도배')",
    [report, staff, post],
  );
  await db.query(
    "insert into public.community_reports(id,reporter_id,post_id,comment_id,reason) values($1,$2,$3,$4,'욕설·비방')",
    [commentReport, staff, post, comment],
  );
  await db.query(
    "insert into public.community_media(author_id,post_id,path,position) values($1,$2,'test/secret.jpg',0)",
    [member, secret],
  );
  await db.query(
    "insert into storage.objects(bucket_id,name) values('community-photos','test/secret.jpg')",
  );
});
after(() => db.close());

test("existing community functions are byte-for-byte unchanged", async () => {
  const current = (
    await db.query(
      "select p.oid::regprocedure::text signature,pg_get_functiondef(p.oid) definition from pg_proc p join pg_namespace n on p.pronamespace=n.oid where n.nspname='voku_private' or (n.nspname='public' and proname like 'community_%') order by 1",
    )
  ).rows;
  assert.deepEqual(current, originalFunctions);
});
test("allowlisted signup creates separate identity with server-side role; community signup still works", async () => {
  assert.equal(
    await scalar(
      "select count(*)::int from public.community_profiles where id=$1",
      [owner],
    ),
    0,
  );
  assert.equal(
    await scalar("select role from voku_ops.operators where id=$1", [operator]),
    "operator",
  );
  assert.equal(
    await scalar(
      "select count(*)::int from public.community_profiles where id=$1",
      [member],
    ),
    1,
  );
  assert.equal(
    await scalar(
      "select count(*)::int from voku_ops.invitations where claimed_at is not null",
    ),
    4,
  );
  await assert.rejects(
    db.query(
      "insert into public.community_profiles(id,nickname) values($1,'겹침계정')",
      [owner],
    ),
    /커뮤니티 회원/,
  );
});
test("forged channel/app role and cancelled invitations cannot create operators", async () => {
  await assert.rejects(
    db.query(
      'insert into auth.users(id,email,raw_user_meta_data) values($1,\'forged@example.test\',\'{"account_channel":"voku_operations","role":"owner"}\')',
      [id(20)],
    ),
    /등록 명단/,
  );
  await db.query(
    "insert into voku_ops.invitations(email,name,role,active) values('cancelled@example.test','취소','owner',false)",
  );
  await assert.rejects(
    db.query(
      "insert into auth.users(id,email) values($1,'cancelled@example.test')",
      [id(21)],
    ),
    /취소/,
  );
  await db.query(
    "insert into auth.users(id,email,raw_user_meta_data) values($1,'ordinary@example.test','{\"role\":\"owner\"}')",
    [id(22)],
  );
  assert.equal(
    await scalar("select role from voku_private.members where id=$1", [id(22)]),
    "member",
  );
});
test("anonymous, ordinary members and board admins cannot access operations", async () => {
  await assert.rejects(
    as(member, "select public.ops_overview()", [], { role: "anon" }),
    /permission denied/,
  );
  for (const uid of [member, staff])
    await assert.rejects(list(uid, "posts"), /ops_access_denied/);
});
test("confirmed email, live session and AAL2 required; AAL1 exposes own identity only", async () => {
  assert.equal(
    (await as(owner, "select public.ops_me()", [], { aal: "aal1" }))
      .mfaRequired,
    true,
  );
  await assert.rejects(
    as(owner, "select public.ops_overview()", [], { aal: "aal1" }),
    /ops_mfa_required/,
  );
  await assert.rejects(
    as(owner, "select public.ops_me()", [], { sess: id(999) }),
    /ops_access_denied/,
  );
  await assert.rejects(
    as(owner, "select public.ops_me()", [], { sess: session(operator) }),
    /ops_access_denied/,
  );
  await assert.rejects(
    as(unverified, "select public.ops_me()"),
    /ops_access_denied/,
  );
});
test("private tables and helpers deny direct client access", async () => {
  for (const sql of [
    "select count(*) from voku_ops.operators",
    "select count(*) from voku_ops.audit",
    "select count(*) from voku_ops.entities",
    "select voku_ops.require_operator()",
  ])
    await assert.rejects(as(owner, sql), /permission denied/);
});
test("owner-only accounts; viewer reads but cannot mutate", async () => {
  assert.equal(
    (await list(owner, "operators")).items.some((i) => i.id === owner),
    true,
  );
  for (const uid of [operator, viewer])
    await assert.rejects(list(uid, "operators"), /ops_permission_denied/);
  assert.equal((await list(viewer, "posts")).total, 4);
  await assert.rejects(
    mutate(viewer, "posts", "hide", [post]),
    /ops_permission_denied/,
  );
});
test("search, pagination and overview are real filtered database results", async () => {
  assert.equal(
    (await list(owner, "posts", { q: "두 번째", pageSize: 1 })).items[0].id,
    second,
  );
  assert.equal((await list(owner, "posts", { status: "deleted" })).total, 1);
  assert.equal(
    (await list(owner, "posts", { page: 2, pageSize: 2 })).items.length,
    2,
  );
  const data = await as(owner, "select public.ops_overview()");
  assert.equal(data.pendingReports, 2);
  assert.equal(data.daily.length, 7);
});
test("moderation records actor, reason and before/after; stale versions rejected", async () => {
  const stale = (await detail(owner, "posts", post)).item;
  assert.deepEqual(await mutate(operator, "posts", "hide", [post]), {
    changed: 1,
  });
  const result = await detail(owner, "posts", post);
  assert.equal(result.item.status, "hidden");
  assert.equal(result.history[0].author, "operator");
  assert.equal(result.history[0].before.status, "published");
  assert.equal(result.history[0].after.status, "hidden");
  await assert.rejects(
    call(owner, "select public.ops_mutate($1,$2,$3,$4)", [
      "posts",
      "restore",
      [{ id: post, version: stale.version }],
      "내용 재확인",
    ]),
    /ops_conflict/,
  );
  await mutate(owner, "posts", "restore", [post]);
});
test("batch actions are atomic and require a meaningful reason", async () => {
  const valid = (await detail(owner, "posts", post)).item;
  await assert.rejects(
    call(owner, "select public.ops_mutate($1,$2,$3,$4)", [
      "posts",
      "hide",
      [
        { id: post, version: valid.version },
        { id: second, version: "stale" },
      ],
      "일괄 검토",
    ]),
    /ops_conflict/,
  );
  assert.equal((await detail(owner, "posts", post)).item.status, "published");
  await assert.rejects(mutate(owner, "posts", "hide", [post], " "), /2~500/);
  await assert.rejects(mutate(owner, "posts", "hide", [post, post]), /중복/);
  await assert.rejects(mutate(owner, "posts", "restore", [deleted]), /삭제한/);
  await assert.rejects(mutate(owner, "posts", "pin", [secret]), /일반 글/);
});
test("pin, comment locking and comment restoration work", async () => {
  await mutate(operator, "posts", "pin", [post]);
  await mutate(operator, "posts", "lock", [post]);
  let p = (await detail(owner, "posts", post)).item;
  assert.equal(p.pinned, true);
  assert.equal(p.locked, true);
  await mutate(operator, "posts", "unpin", [post]);
  await mutate(operator, "posts", "unlock", [post]);
  await mutate(operator, "comments", "hide", [comment]);
  assert.equal(
    (await detail(owner, "comments", comment)).item.status,
    "hidden",
  );
  await mutate(operator, "comments", "restore", [comment]);
  assert.equal(
    (await detail(owner, "comments", comment)).item.status,
    "published",
  );
});
test("report resolution hides correct target; dismissal leaves target intact", async () => {
  await mutate(operator, "reports", "resolve_hide", [commentReport]);
  assert.equal(
    (await detail(owner, "comments", comment)).item.status,
    "hidden",
  );
  assert.equal((await detail(owner, "posts", post)).item.status, "published");
  assert.equal(
    (await detail(owner, "reports", commentReport)).item.status,
    "resolved",
  );
  await mutate(operator, "reports", "dismiss", [report]);
  assert.equal((await detail(owner, "posts", post)).item.status, "published");
  await assert.rejects(
    mutate(owner, "reports", "resolve_hide", [report]),
    /이미 처리/,
  );
});
test("member suspensions preserve board administrator role", async () => {
  await assert.rejects(
    mutate(owner, "members", "suspend", [staff], "확인 사유", { days: 7 }),
    /게시판 관리자/,
  );
  await mutate(operator, "members", "suspend", [member], "신고 내용 확인", {
    days: 7,
  });
  assert.equal(
    (await detail(owner, "members", member)).item.status,
    "suspended",
  );
  await mutate(operator, "members", "unsuspend", [member]);
  assert.equal((await detail(owner, "members", member)).item.status, "active");
});
test("allowlist management and its audit are owner-only; no overlap with existing email", async () => {
  await assert.rejects(
    call(operator, "select public.ops_invite($1,$2,$3,$4)", [
      "a@example.test",
      "보조",
      "viewer",
      "채용 확인",
    ]),
    /ops_permission_denied/,
  );
  await assert.rejects(
    call(owner, "select public.ops_invite($1,$2,$3,$4)", [
      "member@example.test",
      "보조",
      "viewer",
      "채용 확인",
    ]),
    /기존 회원/,
  );
  const invitation = await call(
    owner,
    "select public.ops_invite($1,$2,$3,$4)",
    ["new@example.test", "보조", "viewer", "담당자 추가"],
  );
  const log = (await list(owner, "audit")).items.find(
    (i) => i.targetId === invitation.id,
  );
  assert.ok(log);
  assert.equal(
    (await list(operator, "audit")).items.some(
      (i) => i.targetKind === "operators",
    ),
    false,
  );
  await assert.rejects(
    detail(operator, "audit", log.id),
    /ops_permission_denied/,
  );
  await mutate(owner, "operators", "cancel_invite", [invitation.id]);
  assert.equal(
    (await detail(owner, "operators", invitation.id)).item.status,
    "cancelled",
  );
});
test("cannot remove own privilege; disabling operators takes effect immediately", async () => {
  await assert.rejects(
    mutate(owner, "operators", "disable", [owner]),
    /자신의/,
  );
  await mutate(owner, "operators", "role", [operator], "조회 업무로 변경", {
    role: "viewer",
  });
  await assert.rejects(
    mutate(operator, "posts", "hide", [post]),
    /ops_permission_denied/,
  );
  await mutate(owner, "operators", "disable", [operator]);
  await assert.rejects(
    as(operator, "select public.ops_me()"),
    /ops_access_denied/,
  );
  await mutate(owner, "operators", "enable", [operator]);
  assert.equal((await as(operator, "select public.ops_me()")).role, "viewer");
});
test("private photo access requires AAL2; operator cannot become community staff", async () => {
  assert.equal(
    await as(
      owner,
      "select count(*)::int from storage.objects where name='test/secret.jpg'",
    ),
    1,
  );
  assert.equal(
    await as(
      owner,
      "select count(*)::int from storage.objects where name='test/secret.jpg'",
      [],
      { aal: "aal1" },
    ),
    0,
  );
  assert.equal(
    await as(viewer, "select voku_ops.media_readable('test/secret.jpg')"),
    true,
  );
  await assert.rejects(
    as(owner, "select voku_private.is_staff()"),
    /permission denied/,
  );
  await assert.rejects(
    as(owner, "select public.community_admin()"),
    /회원 정보를 찾을 수 없습니다|관리자|권한|운영진/,
  );
  const board = await as(staff, "select public.community_admin()");
  assert.ok(board);
});
