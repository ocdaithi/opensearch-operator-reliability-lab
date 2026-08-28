resource "aws_budgets_budget" "account_cost" {
  account_id   = var.expected_aws_account_id
  name         = local.budget_name
  budget_type  = "COST"
  limit_amount = "50"
  limit_unit   = "USD"
  time_unit    = "MONTHLY"
  metrics      = ["UnblendedCost"]

  lifecycle {
    prevent_destroy = true
  }

  filter_expression {
    not {
      dimensions {
        key    = "RECORD_TYPE"
        values = ["Credit", "Refund"]
      }
    }
  }

  dynamic "notification" {
    for_each = local.actual_budget_thresholds

    content {
      comparison_operator        = "GREATER_THAN"
      threshold                  = notification.value
      threshold_type             = "ABSOLUTE_VALUE"
      notification_type          = "ACTUAL"
      subscriber_email_addresses = [var.budget_notification_email]
    }
  }

  notification {
    comparison_operator        = "GREATER_THAN"
    threshold                  = 50
    threshold_type             = "ABSOLUTE_VALUE"
    notification_type          = "FORECASTED"
    subscriber_email_addresses = [var.budget_notification_email]
  }
}
