-- How many error-level checks failed in this run. 0 means the build can be published.
-- Placeholders: ${prefix}, ${run_id}
SELECT count(*) AS failed_checks
FROM ${prefix}_audit.check_results
WHERE run_id = '${run_id}'
  AND severity = 'error'
  AND failures > 0
