output "state_machine_arn" {
  description = "ARN of the pipeline state machine, used to start a run"
  value       = aws_sfn_state_machine.pipeline.arn
}
