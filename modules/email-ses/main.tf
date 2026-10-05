data "aws_caller_identity" "current" {}
data "aws_region" "current" {}

locals {
  mail_from_domain = "${var.mail_from_subdomain}.${var.domain}"
}

resource "aws_route53_zone" "this" {
  name = var.domain
}

# --- Identity and DKIM -------------------------------------------------------------------------

resource "aws_sesv2_email_identity" "this" {
  email_identity = var.domain

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

# The API confirms the subscription itself, after verifying the SNS signature.
resource "aws_sns_topic_subscription" "webhook" {
  count = var.event_webhook_url == null ? 0 : 1

  topic_arn                       = aws_sns_topic.events.arn
  protocol                        = "https"
  endpoint                        = var.event_webhook_url
  endpoint_auto_confirms          = false
  confirmation_timeout_in_minutes = 5
}

# --- Sender identity for the API ----------------------------------------------------------------

resource "aws_iam_user" "sender" {
  name = var.sender_user_name
  path = "/printlog/"
}

data "aws_iam_policy_document" "sender" {
  statement {
    sid     = "SendFromThisDomainOnly"
    actions = ["ses:SendEmail", "ses:SendRawEmail"]
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
