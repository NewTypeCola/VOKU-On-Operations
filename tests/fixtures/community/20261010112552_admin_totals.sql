-- Whole-community counts, independent of filtered or limited result lists.
begin;
create or replace function public.community_admin(p_query text default '') returns jsonb language plpgsql stable security definer set search_path='' as $$
begin
  if not voku_private.is_staff() then raise exception '운영 권한이 필요합니다.'; end if;
  return jsonb_build_object(
    'stats',jsonb_build_object(
      'pendingReports',(select count(*) from public.community_reports where status='open'),
      'pinnedPosts',(select count(*) from public.community_posts where pinned and status='published'),
      'suspendedMembers',(select count(*) from voku_private.members where suspended_until>now())
    ),
    'reports',(select coalesce(jsonb_agg(voku_private.report_json(id) order by created_at desc),'[]') from (select id,created_at from public.community_reports order by (status='open') desc,created_at desc limit 100) r),
    'members',(select coalesce(jsonb_agg(voku_private.profile_json(id) order by created_at desc),'[]') from (select cp.id,cp.created_at from public.community_profiles cp join voku_private.members cm on cm.id=cp.id where strpos(lower(concat_ws(' ',cp.nickname,cm.admission_year::text,right(cm.admission_year::text,2)||'학번',cm.cohort::text||'기')),lower(p_query))>0 order by cp.created_at desc limit 100) m),
    'posts',(select coalesce(jsonb_agg(voku_private.post_json(id) order by created_at desc),'[]') from (select id,created_at from public.community_posts where status<>'deleted' and strpos(lower(title),lower(p_query))>0 order by created_at desc limit 100) p),
    'audit',(select coalesce(jsonb_agg(jsonb_build_object('id',a.id,'actor',p.nickname,'action',a.action,'target',a.target,'reason',a.reason,'date',a.created_at) order by a.created_at desc),'[]') from (select * from voku_private.audit order by created_at desc limit 100) a join public.community_profiles p on p.id=a.actor_id));
end $$;
commit;
