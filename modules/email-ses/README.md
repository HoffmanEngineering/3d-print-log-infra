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
- an IAM user that may send only from this identity and configuration set, and only as
  `*@<domain>`. **No access key is created**: make one by hand so the secret never enters state.

## Inputs

| Name | Description | Default |
|---|---|---|
| `name` | Prefix for resource names | — |
| `domain` | Sending domain | — |
| `mail_from_subdomain` | MAIL FROM label | `bounce` |
| `dmarc_rua` | DMARC aggregate report URI | — |
| `dkim_signing_hosted_zone` | SES DKIM signing zone for the region (`dkim.amazonses.com` in `us-east-1`) | — |
| `event_webhook_url` | API endpoint for SES events; null = no subscription | `null` |
| `sender_user_name` | IAM user the API sends as | — |

## Outputs

`zone_id`, `name_servers`, `identity_arn`, `configuration_set_name`, `configuration_set_arn`,
`sns_topic_arn`, `sender_user_name`.

## After apply

AWS documents that the DKIM signing zone varies by region, so confirm what SES actually expects:

```bash
aws sesv2 get-email-identity --email-identity mail.3dprintlog.com \
  --query '{status: DkimAttributes.Status, zone: DkimAttributes.SigningHostedZone}'
```

`status` must reach `SUCCESS` (after the parent zone delegates to `name_servers`), and `zone` must
equal `dkim_signing_hosted_zone`.
