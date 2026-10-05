data "aws_caller_identity" "current" {}
data "aws_region" "current" {}

locals {
  mail_from_domain = "${var.mail_from_subdomain}.${var.domain}"
}

# The apply role cannot delete hosted zones, so destroying this one is a deliberate manual act.
resource "aws_route53_zone" "this" {
  name = var.domain

  lifecycle {
    prevent_destroy = true
  }
}

# --- Identity and DKIM -------------------------------------------------------------------------

# The default configuration set means a send that omits one still publishes events, so a leaked
# key cannot send mail the webhook never hears about.
resource "aws_sesv2_email_identity" "this" {
  email_identity         = var.domain
  configuration_set_name = aws_sesv2_configuration_set.this.configuration_set_name

  dkim_signing_attributes {
    next_signing_key_length = "RSA_2048_BIT"
  }
}

# The token list is a set, so it is iterated, never indexed.
resource "aws_route53_record" "dkim" {
  for_each = toset(aws_sesv2_email_identity.this.dkim_signing_attributes[0].tokens)

  zone_id = aws_route53_zone.this.zone_id
  name    = "${each.value}._domainkey.${var.domain}"
  type    = "CNAME"
  ttl     = 600
  records = ["${each.value}.${var.dkim_signing_hosted_zone}"]
}

# --- MAIL FROM (SPF alignment) -----------------------------------------------------------------

resource "aws_sesv2_email_identity_mail_from_attributes" "this" {
  email_identity         = aws_sesv2_email_identity.this.email_identity
  mail_from_domain       = local.mail_from_domain
  behavior_on_mx_failure = "USE_DEFAULT_VALUE"
}

resource "aws_route53_record" "mail_from_mx" {
  zone_id = aws_route53_zone.this.zone_id
  name    = local.mail_from_domain
  type    = "MX"
  ttl     = 600
  records = ["10 feedback-smtp.${data.aws_region.current.region}.amazonses.com"]
}

resource "aws_route53_record" "mail_from_spf" {
  zone_id = aws_route53_zone.this.zone_id
  name    = local.mail_from_domain
  type    = "TXT"
  ttl     = 600
  records = ["v=spf1 include:amazonses.com -all"]
}

# --- DMARC for the sending subdomain -----------------------------------------------------------

resource "aws_route53_record" "dmarc" {
  zone_id = aws_route53_zone.this.zone_id
  name    = "_dmarc.${var.domain}"
  type    = "TXT"
  ttl     = 600
  records = ["v=DMARC1; p=none; rua=${var.dmarc_rua}; fo=1; adkim=r; aspf=r"]
}

# --- Configuration set and event publishing ----------------------------------------------------

resource "aws_sesv2_configuration_set" "this" {
  configuration_set_name = "${var.name}-events"

  delivery_options {
    tls_policy = "REQUIRE"
  }

  reputation_options {
    reputation_metrics_enabled = true
  }

  sending_options {
    sending_enabled = true
  }

  suppression_options {
    suppressed_reasons = ["BOUNCE", "COMPLAINT"]
  }
}

resource "aws_sns_topic" "events" {
  name = "${var.name}-ses-events"
}

# Without this policy SES cannot publish to the topic and every event is silently dropped.
data "aws_iam_policy_document" "events_topic" {
  statement {
    sid       = "AllowSesPublish"
    actions   = ["sns:Publish"]
    resources = [aws_sns_topic.events.arn]

    principals {
      type        = "Service"
      identifiers = ["ses.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "AWS:SourceAccount"
      values   = [data.aws_caller_identity.current.account_id]
    }

    condition {
      test     = "StringEquals"
      variable = "AWS:SourceArn"
      values   = [aws_sesv2_configuration_set.this.arn]
    }
  }
}

resource "aws_sns_topic_policy" "events" {
  arn    = aws_sns_topic.events.arn
  policy = data.aws_iam_policy_document.events_topic.json
}

# Open and click tracking are deliberately not enabled: Apple Mail makes opens meaningless and
# click tracking rewrites every link.
resource "aws_sesv2_configuration_set_event_destination" "sns" {
  configuration_set_name = aws_sesv2_configuration_set.this.configuration_set_name
  event_destination_name = "sns"

  event_destination {
    enabled              = true
    matching_event_types = ["BOUNCE", "COMPLAINT", "DELIVERY", "REJECT"]

    sns_destination {
      topic_arn = aws_sns_topic.events.arn
    }
  }

  depends_on = [aws_sns_topic_policy.events]
}

# SNS retries an HTTPS endpoint for about an hour and treats most 4xx responses as permanent, then
# discards the message. The dead-letter queue keeps those events for replay (see README).
resource "aws_sqs_queue" "events_dlq" {
  name                      = "${var.name}-ses-events-dlq"
  message_retention_seconds = 1209600
  sqs_managed_sse_enabled   = true
}

data "aws_iam_policy_document" "events_dlq" {
  statement {
    sid       = "AllowSnsDeadLetter"
    actions   = ["sqs:SendMessage"]
    resources = [aws_sqs_queue.events_dlq.arn]

    principals {
      type        = "Service"
      identifiers = ["sns.amazonaws.com"]
    }

    condition {
      test     = "ArnEquals"
      variable = "aws:SourceArn"
      values   = [aws_sns_topic.events.arn]
    }
  }
}

resource "aws_sqs_queue_policy" "events_dlq" {
  queue_url = aws_sqs_queue.events_dlq.id
  policy    = data.aws_iam_policy_document.events_dlq.json
}

resource "aws_cloudwatch_metric_alarm" "events_dlq" {
  count = var.alarm_topic_arn == null ? 0 : 1

  alarm_name          = "${var.name}-ses-events-dlq"
  alarm_description   = "SES events could not be delivered to the API webhook and are waiting in the dead-letter queue."
  namespace           = "AWS/SQS"
  metric_name         = "ApproximateNumberOfMessagesVisible"
  dimensions          = { QueueName = aws_sqs_queue.events_dlq.name }
  statistic           = "Maximum"
  period              = 300
  evaluation_periods  = 1
  threshold           = 0
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"
  alarm_actions       = [var.alarm_topic_arn]
}

# The API confirms the subscription itself, after verifying the SNS signature.
# Empty is treated like null because CI passes an unset repository variable as "".
resource "aws_sns_topic_subscription" "webhook" {
  count = var.event_webhook_url == null || var.event_webhook_url == "" ? 0 : 1

  topic_arn                       = aws_sns_topic.events.arn
  protocol                        = "https"
  endpoint                        = var.event_webhook_url
  endpoint_auto_confirms          = false
  confirmation_timeout_in_minutes = 5
  redrive_policy                  = jsonencode({ deadLetterTargetArn = aws_sqs_queue.events_dlq.arn })

  depends_on = [aws_sqs_queue_policy.events_dlq]
}

# --- Sender identity for the API ----------------------------------------------------------------

# The boundary is created by bootstrap, outside Terraform, so the apply role can never widen what
# this user's key is able to do — even by rewriting the inline policy below.
resource "aws_iam_user" "sender" {
  name                 = var.sender_user_name
  path                 = "/printlog/"
  permissions_boundary = var.sender_permissions_boundary_arn
}

data "aws_iam_policy_document" "sender" {
  statement {
    sid     = "SendFromThisDomainOnly"
    actions = ["ses:SendEmail"]
    resources = [
      aws_sesv2_email_identity.this.arn,
      aws_sesv2_configuration_set.this.arn,
    ]

    condition {
      test     = "StringLike"
      variable = "ses:FromAddress"
      values   = ["*@${var.domain}"]
    }
  }
}

# No aws_iam_access_key on purpose: the key is created by hand so the secret never lands in state.
resource "aws_iam_user_policy" "sender" {
  name   = "ses-send"
  user   = aws_iam_user.sender.name
  policy = data.aws_iam_policy_document.sender.json
}
