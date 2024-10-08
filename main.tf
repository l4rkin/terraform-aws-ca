module "kms_tls_keygen" {
  # Symmetric KMS key used for asymmetric key generation for TLS certs without CSR
  source = "./modules/terraform-aws-ca-kms"

  project     = "${var.project}-tls-keygen"
  env         = var.env
  description = "${var.project}-${var.env} asymmetric key generation for TLS certs without CSR"
}

module "dynamodb" {
  # Stores certificate details and private keys of TLS certs without CSR
  source = "./modules/terraform-aws-ca-dynamodb"

  project          = var.project
  env              = var.env
  kms_arn_resource = var.kms_arn_resource == "" ? module.kms_tls_keygen.kms_arn : var.kms_arn_resource
}

module "configuration_info_ssm_param" {
  # Stores information about the configuration of ServerlessCA for parsing by external tools
  source          = "./modules/terraform-aws-ca-ssm"
  kms_arn         = var.kms_arn_resource == "" ? module.kms_tls_keygen.kms_arn : var.kms_arn_resource
  parameter_key   = var.config_ssm_parameter_name
  parameter_value = {
    project = var.project
    env     = var.env
    region  = data.aws_region.current.name
  }
}

module "external_s3" {
  #checkov:skip=CKV2_AWS_61:Lifecycle configuration not needed for long-lived static content
  # S3 bucket for CRL and CA certificate publication
  source = "./modules/terraform-aws-ca-s3"

  purpose                = "${var.project}-ca-external-${var.env}"
  global_bucket          = true
  bucket_prefix          = var.bucket_prefix
  access_logs            = var.access_logs
  log_bucket             = var.log_bucket
  oai_arn                = var.public_crl ? module.ca_cloudfront[0].cloudfront_origin_access_identity_arn : ""
  public_crl             = var.public_crl
  server_side_encryption = false
  app_aws_principals     = var.s3_aws_principals
}

module "internal_s3" {
  #checkov:skip=CKV2_AWS_61:Lifecycle configuration not needed for long-lived static content
  # S3 bucket for internal processing of JSON files for certificates to be issued and revoked
  source = "./modules/terraform-aws-ca-s3"

  purpose       = "${var.project}-ca-internal-${var.env}"
  global_bucket = true
  bucket_prefix = var.bucket_prefix
  access_logs   = var.access_logs
  log_bucket    = var.log_bucket
  kms_key_alias = var.kms_key_alias == "" ? module.kms_tls_keygen.kms_alias_arn : var.kms_key_alias
}

resource "aws_s3_object" "cert_info" {
  # JSON files with details of certificates to be issued and revoked
  for_each = toset(var.cert_info_files)

  key          = "${each.key}.json"
  bucket       = module.internal_s3.s3_bucket_name
  acl          = "private"
  content_type = "application/json"
  source       = "${path.cwd}/certs/${var.env}/${each.key}.json"
  source_hash  = filemd5("${path.cwd}/certs/${var.env}/${each.key}.json")
  kms_key_id   = var.kms_arn_resource == "" ? module.kms_tls_keygen.kms_alias_target_key_arn : null
}

resource "aws_s3_object" "csrs" {
  # Certificate Signing Request (CSR) files for processing
  for_each = toset(var.csr_files)

  key          = "csrs/${each.key}"
  bucket       = module.internal_s3.s3_bucket_name
  acl          = "private"
  content_type = "text/plain"
  source       = "${path.cwd}/certs/${var.env}/csrs/${each.key}"
  source_hash  = filemd5("${path.cwd}/certs/${var.env}/csrs/${each.key}")
  kms_key_id   = var.kms_arn_resource == "" ? module.kms_tls_keygen.kms_alias_target_key_arn : null
}

module "rsa_tls_cert_lambda" {
  # Lambda function to issue TLS certificates signed by Issuing CA KMS private key
  source = "./modules/terraform-aws-ca-lambda"

  project                         = var.project
  env                             = var.env
  function_name                   = "tls-cert"
  description                     = "issue TLS certificates signed by KMS private key"
  external_s3_bucket              = module.external_s3.s3_bucket_name
  internal_s3_bucket              = module.internal_s3.s3_bucket_name
  logging_account_id              = var.logging_account_id
  subscription_filter_destination = var.subscription_filter_destination
  filter_pattern                  = var.filter_pattern
  issuing_ca_list                 = var.issuing_ca_list
  lambda_role_arn                 = module.tls_keygen_iam.lambda_role_arn
  domain                          = var.hosted_zone_domain
  runtime                         = var.runtime
  public_crl                      = var.public_crl
  max_cert_lifetime               = var.max_cert_lifetime
  allowed_invocation_principals   = var.aws_principals
  sns_topic_arn                   = module.sns_ca_notifications.sns_topic_arn
}

module "cloudfront_certificate" {
  source = "./modules/terraform-aws-ca-acm"
  count  = var.public_crl ? 1 : 0

  domain_name = var.hosted_zone_domain
  zone_id     = var.hosted_zone_id

  providers = {
    aws = aws.us-east-1 # certificates for CloudFront must be in this region
  }
}

module "ca_cloudfront" {
  # CloudFront distribution for CRL and CA certificate publication
  source = "./modules/terraform-aws-ca-cloudfront"
  count  = var.public_crl ? 1 : 0

  project                     = var.project
  base_domain                 = var.hosted_zone_domain
  bucket_name                 = module.external_s3.s3_bucket_name
  bucket_regional_domain_name = module.external_s3.s3_bucket_regional_domain_name
  certificate_arn             = module.cloudfront_certificate[0].certificate_arn
  environment                 = var.env
  zone_id                     = var.hosted_zone_id
}

module "step-function-role" {
  # IAM role and policy for step function to orchestrate Lambda functions
  source = "./modules/terraform-aws-ca-iam"

  project                = var.project
  env                    = var.env
  function_name          = "ca"
  kms_arn_resource       = var.kms_arn_resource == "" ? module.kms_tls_keygen.kms_arn : var.kms_arn_resource
  ddb_table_arn          = module.dynamodb.ddb_table_arn
  policy                 = "state"
  assume_role_policy     = "state"
  external_s3_bucket_arn = module.external_s3.s3_bucket_arn
  internal_s3_bucket_arn = module.internal_s3.s3_bucket_arn
}

module "step-function" {
  # step function to orchestrate Lambda functions
  source = "./modules/terraform-aws-ca-step-function"

  project            = var.project
  env                = var.env
  role_arn           = module.step-function-role.lambda_role_arn
  kms_arn            = var.kms_arn_resource == "" ? module.kms_tls_keygen.kms_arn : var.kms_arn_resource
  internal_s3_bucket = module.internal_s3.s3_bucket_name
  cert_info_files    = var.cert_info_files
}

module "scheduler-role" {
  # IAM role and policy for scheduler
  source = "./modules/terraform-aws-ca-iam"

  project            = var.project
  env                = var.env
  function_name      = "scheduler"
  kms_arn_resource   = var.kms_arn_resource == "" ? module.kms_tls_keygen.kms_arn : var.kms_arn_resource
  ddb_table_arn      = module.dynamodb.ddb_table_arn
  policy             = "scheduler"
  assume_role_policy = "scheduler"
}

module "scheduler" {
  # triggers step function once per day by default
  source = "./modules/terraform-aws-ca-scheduler"

  project             = var.project
  env                 = var.env
  role_arn            = module.scheduler-role.lambda_role_arn
  target_arn          = module.step-function.state_machine_arn
  schedule_expression = var.schedule_expression
}

module "db-reader-role" {
  # IAM role and policy for DynamoDB reader from other AWS account
  source = "./modules/terraform-aws-ca-iam"
  count  = var.aws_principals == [] ? 0 : 1

  project            = var.project
  env                = var.env
  function_name      = "db-reader"
  aws_principals     = var.aws_principals
  kms_arn_resource   = var.kms_arn_resource == "" ? module.kms_tls_keygen.kms_arn : var.kms_arn_resource
  ddb_table_arn      = module.dynamodb.ddb_table_arn
  policy             = "db_reader"
  assume_role_policy = "db_reader"
}

module "sns_ca_notifications" {
  source = "./modules/terraform-aws-ca-sns"

  project                       = var.project
  function                      = "ca-notifications"
  env                           = var.env
  custom_sns_topic_display_name = var.custom_sns_topic_display_name
  custom_sns_topic_name         = var.custom_sns_topic_name
  kms_key_arn                   = coalesce(var.kms_arn_resource, module.kms_tls_keygen.kms_arn)
  email_subscriptions           = var.sns_email_subscriptions
  lambda_subscriptions          = var.sns_lambda_subscriptions
  sqs_subscriptions             = var.sns_sqs_subscriptions
}