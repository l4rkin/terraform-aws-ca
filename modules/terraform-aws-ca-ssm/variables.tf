variable "parameter_key" {
  description = "Key to store information under in SSM parameter store"
  default     = "serverlessca-info"
}

variable "parameter_value" {
  description = "Information to store in SSM parameter store"
  default     = {}
}

variable "kms_arn" {
  description = "ARN of KMS used to encrypt parameter"
}