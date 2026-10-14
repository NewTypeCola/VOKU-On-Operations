-- Cron runs at 04:20 KST. Only this job's execution history is pruned.
create extension if not exists pg_cron;
select cron.schedule('voku-usage-retention','20 19 * * *',$job$
 select voku_metrics.maintain();
 delete from cron.job_run_details where jobid=(select jobid from cron.job where jobname='voku-usage-retention') and end_time<now()-interval '30 days';
$job$);
