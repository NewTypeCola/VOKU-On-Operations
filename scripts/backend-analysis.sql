-- Use only with the separately authorized backend DB connection.
-- psql --no-psqlrc --quiet --tuples-only --no-align \
--   -v from=2026-10-14 -v to=2026-10-14 -v purpose=archive_journey \
--   -v reason='아카이브 탐색과 실제 열람 사이의 경로를 확인합니다' \
--   -v audience=real -f scripts/backend-analysis.sql
-- Configure PGSERVICE / PGPASSFILE locally; never put credentials in this file.
\set ON_ERROR_STOP on
\set AUTOCOMMIT on
begin;
set local role voku_usage_reader;
set local statement_timeout = '15s';
select voku_analysis.prepare(:'from'::date, :'to'::date, :'purpose', :'reason', :'audience)->>'requestId' as analysis_request \gset
commit;
-- A separate committed transaction is required; do not merge these stages.
begin;
set local role voku_usage_reader;
set local statement_timeout = '15s';
select jsonb_pretty(voku_analysis.read_result(:'analysis_request'::uuid));
commit;
