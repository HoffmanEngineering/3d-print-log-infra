variable "aws_region" {
  description = "AWS region for SES and its supporting resources."
  type        = string
  default     = "us-east-1"
}

variable "ses_event_webhook_url" {
  description = "HTTPS endpoint on the API that receives SES events from SNS. Null until the API endpoint is deployed."
  type        = string
  default     = null
}

variable "alerts_email" {
  description = "Inbox that receives SES reputation alarms."
  type        = string
}

variable "dmarc_rua" {
  description = "Where DMARC aggregate reports for the sending subdomain are sent."
  type        = string
  default     = "mailto:dmarc@3dprintlog.com"
}
