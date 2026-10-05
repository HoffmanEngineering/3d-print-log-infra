output "mail_name_servers" {
  description = "Add these as NS records for host 'mail' at Namecheap to delegate mail.3dprintlog.com."
  value       = module.email_mail.name_servers
}

output "ses_configuration_set_name" {
  description = "Email:Ses:ConfigurationSet in the API's App Service settings."
  value       = module.email_mail.configuration_set_name
}

output "ses_events_topic_arn" {
  description = "Email:Ses:EventsTopicArn in the API's App Service settings."
  value       = module.email_mail.sns_topic_arn
}

output "ses_sender_user_name" {
  description = "Create the API's access key for this user by hand (see README)."
  value       = module.email_mail.sender_user_name
}

output "ses_events_dlq_url" {
  description = "Dead-letter queue for SES events the webhook did not accept (see modules/email-ses README)."
  value       = module.email_mail.events_dlq_url
}
