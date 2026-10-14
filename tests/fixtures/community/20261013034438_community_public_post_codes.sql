-- Short public addresses are an additional key. Existing UUIDs and foreign keys
-- remain unchanged, including posts managed by the separate operations app.
begin;
alter table public.community_posts add column public_code text;
alter table public.community_posts add constraint community_posts_public_code_key unique(public_code);
alter table public.community_posts add constraint community_posts_public_code_format check(public_code ~ '^[A-Za-z0-9_-]{10}$');

create function voku_private.assign_post_code() returns trigger
language plpgsql security definer set search_path='' as $$
declare candidate text;
begin
  if TG_OP='UPDATE' and OLD.public_code is not null then
    NEW.public_code := OLD.public_code;
    return NEW;
  end if;
  for attempt in 1..16 loop
    candidate := substr(translate(encode(uuid_send(gen_random_uuid()),'base64'),'+/','-_'),1,10);
    -- Serialize the exceptionally rare collision before checking it. The unique
    -- constraint remains the final safeguard, also for concurrent inserts.
    perform pg_advisory_xact_lock(hashtextextended('community_post_code:'||candidate,0));
    if not exists(select 1 from public.community_posts where public_code=candidate) then
      NEW.public_code := candidate;
      return NEW;
    end if;
  end loop;
  raise exception '게시글 주소를 만들지 못했습니다. 다시 시도해 주세요.';
end $$;
revoke all on function voku_private.assign_post_code() from public,anon,authenticated;
create trigger community_assign_post_code before insert or update of public_code
on public.community_posts for each row execute function voku_private.assign_post_code();
update public.community_posts set public_code=null where public_code is null;
alter table public.community_posts alter column public_code set not null;

-- Wrap the currently installed serializer to preserve every existing privacy
-- rule and any operations-dashboard extensions instead of replacing its body.
alter function voku_private.post_json(uuid) rename to post_json_before_public_code;
create function voku_private.post_json(pid uuid) returns jsonb
language sql stable security definer set search_path='' as $$
  select voku_private.post_json_before_public_code(pid)
    || jsonb_build_object('publicCode',p.public_code)
  from public.community_posts p where p.id=pid;
$$;
revoke all on function voku_private.post_json(uuid) from public,anon,authenticated;

-- This resolves only the identifier. The existing thread reader decides which
-- body/comments the caller may see, including secret, hidden and deleted posts.
create function public.community_post_by_code(p_code text) returns jsonb
language plpgsql stable security definer set search_path='' as $$
declare pid uuid;
begin
  if p_code is null or p_code !~ '^[A-Za-z0-9_-]{10}$' then
    raise exception '글을 찾을 수 없거나 공개되지 않은 글입니다.';
  end if;
  select id into pid from public.community_posts where public_code=p_code;
  return public.community_post(pid);
end $$;
revoke all on function public.community_post_by_code(text) from public,anon,authenticated;
grant execute on function public.community_post_by_code(text) to anon,authenticated;
commit;
