-- Reuse prepare()'s request-scoped browser alias to invalidate only affected
-- snapshots. Unknown or repeated visitor erasures must leave other results intact.
create or replace function voku_metrics.erase(p_key text,p_visitor uuid) returns void
language plpgsql security definer set search_path='' as $$
declare k text; salt text;
begin
 if not exists(select 1 from voku_metrics.config where key='ingest_hash' and value=voku_metrics.hash(p_key)) then
  raise exception 'metrics_collector_required' using errcode='42501';
 end if;
 k:=voku_metrics.hash((select value from voku_metrics.config where key='identity_salt')||p_visitor::text);
 select value into strict salt from voku_metrics.config where key='analysis_salt';
 delete from voku_analysis.results r
 where r.payload @> jsonb_build_array(jsonb_build_object(
  'browser','b_'||left(voku_metrics.hash(salt||r.request_id::text||k),24)
 ));
 delete from voku_metrics.sessions where visitor=k;
 delete from voku_metrics.visitors where key=k;
 -- Keep audit receipts/checksums and non-identifying aggregates unchanged.
end $$;
