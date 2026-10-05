variable "aws_region" {
  description = "AWS region for SES and its supporting resources. The AWS project is pinned to US East (Ohio) and cannot create regional resources anywhere else."
  type        = string
  default     = "us-east-2"

  validation {
    condition     = var.aws_region == "us-east-2"
    error_message = "The AWS project only allows regional resources in us-east-2, and the API's Email__Ses__Region and the DKIM signing zone (dkim.amazonses.com) assume it. Update all three before changing region."
  }
}

variable "ses_event_webhook_url" {
  description = "HTTPS endpoint on the API that receives SES events from SNS. Null until the API endpoint is deployed."
  type        = string
  default     = null
}

variable "alerts_email" {
  description = "Inbox that receives SES reputation alarms. Sensitive because plans are posted to public PRs."
  type        = string
  sensitive   = true
}

variable "dmarc_rua" {
  description = "Where DMARC aggregate reports for the sending subdomain are sent."
  type        = string
  default     = "mailto:dmarc@3dprintlog.com"
}
