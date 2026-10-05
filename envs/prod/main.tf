locals {
  tags = {
    project    = "3d-print-log"
    managed-by = "terraform"
    repo       = "3d-print-log-infra"
  }
}

# --- Email (SES) -------------------------------------------------------------------------------

module "email_mail" {
  source = "../../modules/email-ses"

  name                     = "printlog-mail"
  domain                   = "mail.3dprintlog.com"
  dkim_signing_hosted_zone = "dkim.amazonses.com"
  dmarc_rua                = var.dmarc_rua
  event_webhook_url        = var.ses_event_webhook_url
  sender_user_name         = "printlog-api-ses-sender"
}

# Account-wide backstop: SES itself refuses to send to addresses that bounced or complained, even
# if the API's own suppression list missed an event.
resource "aws_sesv2_account_suppression_attributes" "this" {
  suppressed_reasons = ["BOUNCE", "COMPLAINT"]
}

# --- Reputation alarms -------------------------------------------------------------------------

resource "aws_sns_topic" "alerts" {
  name = "printlog-alerts"
}

# Email subscriptions must be confirmed from the inbox once after the first apply.
resource "aws_sns_topic_subscription" "alerts_email" {
  topic_arn = aws_sns_topic.alerts.arn
  protocol  = "email"
  endpoint  = var.alerts_email
}

# These are SES's own representative rates, which the API cannot reproduce from its data. AWS
# reviews accounts at 0.1% complaints / 5% bounces; alarm a little before either.
resource "aws_cloudwatch_metric_alarm" "ses_complaint_rate" {
  alarm_name          = "printlog-ses-complaint-rate"
  alarm_description   = "SES complaint rate is approaching the 0.1% review threshold."
  namespace           = "AWS/SES"
  metric_name         = "Reputation.ComplaintRate"
  statistic           = "Maximum"
  period              = 3600
  evaluation_periods  = 1
  threshold           = 0.0008
  comparison_operator = "GreaterThanOrEqualToThreshold"
  treat_missing_data  = "notBreaching"
  alarm_actions       = [aws_sns_topic.alerts.arn]
  ok_actions          = [aws_sns_topic.alerts.arn]
}

resource "aws_cloudwatch_metric_alarm" "ses_bounce_rate" {
  alarm_name          = "printlog-ses-bounce-rate"
  alarm_description   = "SES bounce rate is approaching the 5% review threshold."
  namespace           = "AWS/SES"
  metric_name         = "Reputation.BounceRate"
  statistic           = "Maximum"
  period              = 3600
  evaluation_periods  = 1
  threshold           = 0.04
  comparison_operator = "GreaterThanOrEqualToThreshold"
  treat_missing_data  = "notBreaching"
  alarm_actions       = [aws_sns_topic.alerts.arn]
  ok_actions          = [aws_sns_topic.alerts.arn]
}
