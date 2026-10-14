-- Cover new foreign keys before telemetry volume grows; no data or authority changes.
create index metrics_events_record on voku_metrics.events(record_id);
create index metrics_snapshots_creator on voku_metrics.snapshots(created_by);
