
resource "aws_ssm_parameter" "configuration_info" {
  name        = var.parameter_key
  description = "Information about the configuration of ServerlessCA"
  type        = "SecureString"
  value       = jsonencode(var.parameter_value)
}