# email-ses

One SES sending domain, fully described in code:

- a Route 53 hosted zone for the domain (the parent zone delegates to it with `NS` records),
- the SES v2 domain identity with Easy DKIM (2048-bit) and its three `CNAME` records,
- a custom MAIL FROM domain (`bounce.<domain>` by default) with `MX` and SPF, so SPF aligns for DMARC,
- `_dmarc.<domain>` at `p=none` with aggregate reports to `dmarc_rua`,
- a configuration set (TLS required, reputation metrics on, bounces and complaints suppressed),
- an SNS topic with a policy that lets only SES publish to it, plus an event destination for
  `BOUNCE`, `COMPLAINT`, `DELIVERY` and `REJECT`,
- an optional HTTPS subscription to the API webhook (`event_webhook_url`), which the API confirms,
  with an encrypted SQS dead-letter queue for events SNS gives up on, and an alarm on it when
  `alarm_topic_arn` is set,
- the configuration set as the identity's **default**, so a send that omits it still publishes
  events,
- an IAM user that may call only `ses:SendEmail`, from this identity and configuration set, as
  `*@<domain>`, under a permissions boundary created by bootstrap. **No access key is created**:
  make one by hand so the secret never enters state.

The hosted zone has `prevent_destroy`, and the apply role cannot delete zones.

## Inputs

| Name | Description | Default |
|---|---|---|
| `name` | Prefix for resource names | — |
| `domain` | Sending domain | — |
| `mail_from_subdomain` | MAIL FROM label | `bounce` |
| `dmarc_rua` | DMARC aggregate report URI | — |
| `dkim_signing_hosted_zone` | SES DKIM signing zone for the region (`dkim.amazonses.com` in `us-east-1` and `us-east-2`) | — |
| `event_webhook_url` | API endpoint for SES events; null = no subscription | `null` |
| `sender_user_name` | IAM user the API sends as | — |
| `sender_permissions_boundary_arn` | Boundary bootstrap creates for the sender user | — |
| `alarm_topic_arn` | Topic notified when events reach the DLQ; null = no alarm | `null` |

## Outputs

`zone_id`, `name_servers`, `identity_arn`, `configuration_set_name`, `configuration_set_arn`,
`sns_topic_arn`, `sender_user_name`, `events_dlq_url`.

## After apply

AWS documents that the DKIM signing zone varies by region, so confirm what SES actually expects:

```bash
aws sesv2 get-email-identity --email-identity mail.3dprintlog.com \
  --query '{status: DkimAttributes.Status, zone: DkimAttributes.SigningHostedZone}'
```

`status` must reach `SUCCESS` (after the parent zone delegates to `name_servers`), and `zone` must
equal `dkim_signing_hosted_zone`.

## Replaying dead-lettered events

SNS retries the webhook for about an hour, and treats most `4xx` responses (a wrong
`Email__Ses__EventsTopicArn`, for example) as permanent. Either way the event lands in the
dead-letter queue, which keeps it for 14 days. Each message body is the original signed SNS
envelope, and the API does not reject old envelopes, so a replay is the same POST SNS would have
made:

```bash
QUEUE=$(terraform output -raw ses_events_dlq_url)
aws sqs receive-message --queue-url "$QUEUE" --max-number-of-messages 10   --query 'Messages[].[ReceiptHandle,Body]' --output json > dlq.json
# For each entry: POST the Body to the webhook, then delete it once the API returns 2xx.
curl -fsS -X POST -H 'Content-Type: text/plain; charset=UTF-8'   -H 'x-amz-sns-message-type: Notification' --data-binary @body.json https://<api-host>/api/email-events/ses
aws sqs delete-message --queue-url "$QUEUE" --receipt-handle "<handle>"
```

Fix whatever made the API refuse the event before replaying, or it goes straight back.
