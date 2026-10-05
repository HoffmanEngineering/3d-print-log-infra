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
  description = "SES DKIM signing hosted zone for the region. AWS documents that this varies by region, so it is never assumed; us-east-1 uses dkim.amazonses.com."
  type        = string
}

variable "event_webhook_url" {
  description = "HTTPS endpoint that receives SES events from SNS. When null, no subscription is created."
  type        = string
  default     = null
}

variable "sender_user_name" {
  description = "Name of the IAM user the API sends as. Its access key is created by hand so the secret never enters state."
  type        = string
}
