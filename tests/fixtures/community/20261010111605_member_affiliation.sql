-- Optional admission year and VOKU cohort. Existing profiles retain NULL values.
-- These details are returned only to the member and authorized staff.
begin;
alter table voku_private.members
  add column admission_year smallint check (admission_year between 1900 and 9999),
  add column cohort smallint check (cohort between 1 and 999);

create function voku_private.parse_affiliation(p_year text, p_cohort text)
returns table (admission_year smallint, cohort smallint)
language plpgsql set search_path='' as $$
begin
  p_year := nullif(btrim(p_year),'');
  p_cohort := nullif(btrim(p_cohort),'');
  if p_year is not null then
    if p_year !~ '^[0-9]{4}$' then raise exception '학번은 네 자리 입학년도로 저장해야 합니다.'; end if;
    if p_year::integer < 1900 or p_year::integer > extract(year from current_date)::integer + 1 then
      raise exception '입학년도를 확인해 주세요.';
    end if;
  end if;
  if p_cohort is not null then
    if p_cohort !~ '^[0-9]{1,3}$' then raise exception '기수는 1~999 사이의 숫자로 입력해 주세요.'; end if;
    if p_cohort::integer < 1 then raise exception '기수는 1~999 사이의 숫자로 입력해 주세요.'; end if;
  end if;
  return query select p_year::smallint, p_cohort::smallint;
end $$;
revoke all on function voku_private.parse_affiliation(text,text) from public,anon,authenticated;

create or replace function voku_private.create_member() returns trigger language plpgsql security definer set search_path='' as $$
declare n text := btrim(coalesce(new.raw_user_meta_data->>'nickname','')); affiliation record;
begin
  if n !~ '^[가-힣a-zA-Z0-9_]{2,16}$' then raise exception '닉네임은 한글, 영문, 숫자, 밑줄 2~16자로 입력해 주세요.'; end if;
  select * into affiliation from voku_private.parse_affiliation(new.raw_user_meta_data->>'admission_year',new.raw_user_meta_data->>'cohort');
  insert into public.community_profiles(id,nickname) values(new.id,n);
  insert into voku_private.members(id,admission_year,cohort) values(new.id,affiliation.admission_year,affiliation.cohort); -- ignores any supplied role
  return new;
end $$;

create or replace function voku_private.profile_json(uid uuid) returns jsonb language sql stable security definer set search_path='' as $$
  select jsonb_build_object('id',p.id,'nickname',p.nickname,'admissionYear',m.admission_year,'cohort',m.cohort,'joinedAt',p.created_at,'role',m.role,'suspendedUntil',m.suspended_until,'suspensionReason',m.suspension_reason)
  from public.community_profiles p join voku_private.members m using(id) where p.id=uid;
$$;

create or replace function public.community_action(p_action text,p_payload jsonb default '{}') returns jsonb language plpgsql security definer set search_path='' as $$
declare uid uuid:=voku_private.require_member(); staff boolean:=voku_private.is_staff(); pid uuid; cid uuid; target uuid; p public.community_posts; c public.community_comments; r public.community_reports; value boolean; v_reason text:=btrim(coalesce(p_payload->>'reason','')); own_role text; target_role text; affiliation record;
begin
  select role into own_role from voku_private.members where id=uid;
  if p_action='profile' then
    if coalesce(p_payload->>'nickname','') !~ '^[가-힣a-zA-Z0-9_]{2,16}$' then raise exception '닉네임은 한글, 영문, 숫자, 밑줄 2~16자로 입력해 주세요.'; end if;
    select * into affiliation from voku_private.parse_affiliation(
      case when p_payload ? 'admissionYear' then p_payload->>'admissionYear' else (select admission_year::text from voku_private.members where id=uid) end,
      case when p_payload ? 'cohort' then p_payload->>'cohort' else (select cohort::text from voku_private.members where id=uid) end
    );
    perform voku_private.throttle(uid,'profile',30);
    update voku_private.members set admission_year=affiliation.admission_year,cohort=affiliation.cohort where id=uid;
    update public.community_profiles set nickname=p_payload->>'nickname' where id=uid;
  elsif p_action='post_save' then
    pid:=nullif(p_payload->>'id','')::uuid;
    if pid is null then
      perform voku_private.throttle(uid,'post',30);
      if coalesce((p_payload->>'notice')::boolean,false) and not staff then raise exception '공지 작성은 운영진만 할 수 있습니다.'; end if;
      insert into public.community_posts(author_id,category,title,body,record_id,pinned) values(uid,p_payload->>'category',btrim(p_payload->>'title'),btrim(p_payload->>'body'),nullif(p_payload->>'recordId',''),coalesce((p_payload->>'notice')::boolean,false)) returning id into pid;
    else
      select * into p from public.community_posts where id=pid for update;
      if p.id is null or p.author_id<>uid or p.status<>'published' then raise exception '본인의 공개된 글만 수정할 수 있습니다.'; end if;
      update public.community_posts set category=p_payload->>'category',title=btrim(p_payload->>'title'),body=btrim(p_payload->>'body'),record_id=nullif(p_payload->>'recordId',''),updated_at=now() where id=pid;
    end if;
  elsif p_action in ('suspend','restore_member','set_role') then
    if not staff then raise exception '운영 권한이 필요합니다.'; end if;
    target:=(p_payload->>'userId')::uuid;
    select role into target_role from voku_private.members where id=target for update;
    if target=uid or target_role is null or target_role='admin' or (target_role='moderator' and own_role<>'admin') then raise exception '이 회원에 대한 관리 권한이 없습니다.'; end if;
    if p_action='set_role' then
      if own_role<>'admin' or coalesce(p_payload->>'role','') not in ('member','moderator') then raise exception '관리자만 운영진 권한을 변경할 수 있습니다.'; end if;
      update voku_private.members set role=p_payload->>'role' where id=target;
    elsif p_action='suspend' then
      if char_length(v_reason)<2 or char_length(v_reason)>500 or coalesce((p_payload->>'days')::integer,0) not in (1,7,30,36500) then raise exception '제한 기간과 사유를 입력해 주세요.'; end if;
      update voku_private.members set suspended_until=now()+make_interval(days=>(p_payload->>'days')::integer),suspension_reason=v_reason where id=target;
    else update voku_private.members set suspended_until=null,suspension_reason='' where id=target; end if;
    insert into voku_private.audit(actor_id,action,target,reason) values(uid,p_action,target::text,v_reason);
  elsif p_action='read_notifications' then
    update public.community_notifications set is_read=true where user_id=uid;
  elsif p_action='block' then
    target:=(p_payload->>'userId')::uuid;
    if target=uid or exists(select 1 from voku_private.members where id=target and role<>'member') then raise exception '본인이나 운영진은 차단할 수 없습니다.'; end if;
    if coalesce((p_payload->>'value')::boolean,false) then insert into public.community_blocks values(uid,target) on conflict do nothing; else delete from public.community_blocks where user_id=uid and target_id=target; end if;
  elsif p_action='resolve_report' then
    if not staff then raise exception '운영 권한이 필요합니다.'; end if;
    select * into r from public.community_reports where id=(p_payload->>'id')::uuid for update;
    if r.id is null or r.status<>'open' then raise exception '이미 처리했거나 없는 신고입니다.'; end if;
    if char_length(v_reason)<2 or char_length(v_reason)>500 then raise exception '처리 사유를 입력해 주세요.'; end if;
    if p_payload->>'decision'='hide' then
      if r.comment_id is not null then update public.community_comments set status='hidden' where id=r.comment_id and status='published'; else update public.community_posts set status='hidden' where id=r.post_id and status='published'; end if;
    elsif coalesce(p_payload->>'decision','')<>'dismiss' then raise exception '처리 방식을 선택해 주세요.'; end if;
    update public.community_reports set status=case when p_payload->>'decision'='hide' then 'resolved' else 'dismissed' end,resolution=v_reason,resolved_at=now(),resolved_by=uid where id=r.id;
    insert into voku_private.audit(actor_id,action,target,reason) values(uid,'report_'||(p_payload->>'decision'),r.id::text,v_reason);
  else
    pid:=(p_payload->>'postId')::uuid;
    select * into p from public.community_posts where id=pid for update;
    if p.id is null or p.status='deleted' or (p.status<>'published' and not staff) then raise exception '공개되지 않았거나 없는 글입니다.'; end if;
    if p_action='post_delete' then
      if p.author_id<>uid then raise exception '본인의 글만 삭제할 수 있습니다.'; end if;
      update public.community_posts set status='deleted',updated_at=now() where id=pid;
    elsif p_action in ('post_pin','post_lock','post_visibility') then
      if not staff then raise exception '운영 권한이 필요합니다.'; end if;
      value:=coalesce((p_payload->>'value')::boolean,false);
      if p_action='post_pin' then update public.community_posts set pinned=value where id=pid;
      elsif p_action='post_lock' then update public.community_posts set locked=value where id=pid;
      else
        if char_length(v_reason)<2 or char_length(v_reason)>500 then raise exception '처리 사유를 입력해 주세요.'; end if;
        update public.community_posts set status=case when value then 'hidden' else 'published' end where id=pid;
      end if;
      insert into voku_private.audit(actor_id,action,target,reason) values(uid,p_action,pid::text,coalesce(v_reason,'')||' ['||value||']');
    elsif p_action='comment_save' then
      if p.locked then raise exception '댓글 작성이 잠긴 글입니다.'; end if;
      cid:=nullif(p_payload->>'id','')::uuid;
      if cid is null then
        perform voku_private.throttle(uid,'comment',5);
        target:=nullif(p_payload->>'parentId','')::uuid;
        if target is not null and not exists(select 1 from public.community_comments where id=target and post_id=pid and parent_id is null and status='published') then raise exception '답글을 달 수 없는 댓글입니다.'; end if;
        insert into public.community_comments(post_id,author_id,parent_id,body) values(pid,uid,target,btrim(p_payload->>'body')) returning id into cid;
        insert into public.community_notifications(user_id,post_id,text) select recipient,pid,(select nickname from public.community_profiles where id=uid)||'님이 댓글을 남겼습니다.' from (select p.author_id recipient union select author_id from public.community_comments where id=target) recipients where recipient<>uid;
      else
        select * into c from public.community_comments where id=cid for update;
        if c.author_id<>uid or c.post_id<>pid or c.status<>'published' or c.id is null then raise exception '본인의 댓글만 수정할 수 있습니다.'; end if;
        update public.community_comments set body=btrim(p_payload->>'body'),updated_at=now() where id=cid;
      end if;
    elsif p_action='comment_delete' then
      cid:=(p_payload->>'id')::uuid;
      select * into c from public.community_comments where id=cid for update;
      if c.id is null or c.post_id<>pid or (c.author_id<>uid and not staff) then raise exception '댓글을 삭제할 권한이 없습니다.'; end if;
      if c.author_id<>uid and (char_length(v_reason)<2 or char_length(v_reason)>500) then raise exception '처리 사유를 입력해 주세요.'; end if;
      update public.community_comments set status=case when c.author_id=uid then 'deleted' else 'hidden' end where id=cid;
      if c.author_id<>uid then insert into voku_private.audit(actor_id,action,target,reason) values(uid,'comment_hide',cid::text,v_reason); end if;
    elsif p_action in ('like','bookmark') then
      value:=coalesce((p_payload->>'value')::boolean,false);
      if p_action='like' then
        if p.author_id=uid then raise exception '본인의 글에는 추천할 수 없습니다.'; end if;
        if value then insert into public.community_likes values(uid,pid) on conflict do nothing; else delete from public.community_likes where user_id=uid and post_id=pid; end if;
      else
        if value then insert into public.community_bookmarks(user_id,post_id) values(uid,pid) on conflict do nothing; else delete from public.community_bookmarks where user_id=uid and post_id=pid; end if;
      end if;
    elsif p_action='report' then
      perform voku_private.throttle(uid,'report',10);
      cid:=nullif(p_payload->>'commentId','')::uuid;
      if cid is not null and not exists(select 1 from public.community_comments where id=cid and post_id=pid and status='published') then raise exception '신고할 댓글을 찾을 수 없습니다.'; end if;
      insert into public.community_reports(reporter_id,post_id,comment_id,reason,detail) values(uid,pid,cid,v_reason,coalesce(p_payload->>'detail',''));
    else raise exception '지원하지 않는 요청입니다.';
    end if;
  end if;
  return jsonb_build_object('postId',pid,'commentId',cid);
exception when unique_violation then raise exception '이미 사용 중인 닉네임이거나 이미 접수한 신고입니다.';
end $$;

create or replace function public.community_admin(p_query text default '') returns jsonb language plpgsql stable security definer set search_path='' as $$
begin
  if not voku_private.is_staff() then raise exception '운영 권한이 필요합니다.'; end if;
  return jsonb_build_object(
    'reports',(select coalesce(jsonb_agg(voku_private.report_json(id) order by created_at desc),'[]') from (select id,created_at from public.community_reports order by (status='open') desc,created_at desc limit 100) r),
    'members',(select coalesce(jsonb_agg(voku_private.profile_json(id) order by created_at desc),'[]') from (select cp.id,cp.created_at from public.community_profiles cp join voku_private.members cm on cm.id=cp.id where strpos(lower(concat_ws(' ',cp.nickname,cm.admission_year::text,right(cm.admission_year::text,2)||'학번',cm.cohort::text||'기')),lower(p_query))>0 order by cp.created_at desc limit 100) m),
    'posts',(select coalesce(jsonb_agg(voku_private.post_json(id) order by created_at desc),'[]') from (select id,created_at from public.community_posts where status<>'deleted' and strpos(lower(title),lower(p_query))>0 order by created_at desc limit 100) p),
    'audit',(select coalesce(jsonb_agg(jsonb_build_object('id',a.id,'actor',p.nickname,'action',a.action,'target',a.target,'reason',a.reason,'date',a.created_at) order by a.created_at desc),'[]') from (select * from voku_private.audit order by created_at desc limit 100) a join public.community_profiles p on p.id=a.actor_id));
end $$;

commit;
