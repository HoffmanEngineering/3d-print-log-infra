output "zone_id" {
  description = "Route 53 hosted zone id for the sending domain."
  value       = aws_route53_zone.this.zone_id
}

output "name_servers" {
  description = "Name servers to delegate the sending domain to from the parent zone."
  value       = aws_route53_zone.this.name_servers
}

output "identity_arn" {
  description = "SES identity ARN."
  value       = aws_sesv2_email_identity.this.arn
}

output "configuration_set_name" {
  description = "Configuration set the API must send with."
  value       = aws_sesv2_configuration_set.this.configuration_set_name
}

output "configuration_set_arn" {
  description = "Configuration set ARN."
  value       = aws_sesv2_configuration_set.this.arn
}

output "sns_topic_arn" {
  description = "Topic that receives SES events; the API checks incoming messages against it."
  value       = aws_sns_topic.events.arn
}

output "sender_user_name" {
  description = "IAM user whose access key the API uses."
  value       = aws_iam_user.sender.name
}
