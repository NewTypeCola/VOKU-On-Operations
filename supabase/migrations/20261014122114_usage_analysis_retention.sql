-- Expired result caches are removed within the next 15-minute job run.
select cron.schedule('voku-analysis-retention','*/15 * * * *',$job$
 select voku_analysis.maintain();
 delete from cron.job_run_details where jobid=(select jobid from cron.job where jobname='voku-analysis-retention') and end_time<now()-interval '30 days';
$job$);
