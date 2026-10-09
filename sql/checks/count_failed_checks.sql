-- How many error checks failed for this run. 0 means it's OK to publish.
-- Placeholders: ${prefix}, ${run_id}
SELECT count(*) AS failed_checks
FROM ${prefix}_audit.check_results
WHERE run_id = '${run_id}'
  AND severity = 'error'
  AND failures > 0
