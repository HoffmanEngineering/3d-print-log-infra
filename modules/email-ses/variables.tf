variable "name" {
  description = "Prefix for resource names, e.g. printlog-mail."
  type        = string
}

variable "domain" {
  description = "Sending domain. A Route 53 hosted zone is created for it; the parent zone must delegate to its name servers."
  type        = string
}

variable "mail_from_subdomain" {
  description = "Label of the custom MAIL FROM domain under var.domain, which gives SPF alignment for DMARC."
  type        = string
  default     = "bounce"
}

variable "dmarc_rua" {
  description = "Aggregate-report destination for the sending domain's DMARC record (mailto: URI)."
  type        = string
}

variable "dkim_signing_hosted_zone" {
  description = "SES DKIM signing hosted zone for the region. AWS documents that this varies by region, so it is never assumed; us-east-1 and us-east-2 use dkim.amazonses.com."
  type        = string
}

variable "event_webhook_url" {
  description = "HTTPS endpoint that receives SES events from SNS. When null or empty, no subscription is created."
  type        = string
  default     = null
}

variable "sender_user_name" {
  description = "Name of the IAM user the API sends as. Its access key is created by hand so the secret never enters state."
  type        = string
}

variable "sender_permissions_boundary_arn" {
  description = "ARN of the permissions boundary bootstrap creates for the sender user. The apply role may only create or change /printlog/ users that carry it."
  type        = string
}

variable "alarm_topic_arn" {
  description = "SNS topic notified when SES events land in the dead-letter queue. Null = no alarm."
  type        = string
  default     = null
}
