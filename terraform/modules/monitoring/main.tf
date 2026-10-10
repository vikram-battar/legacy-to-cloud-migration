variable "name" {
  type = string
}

variable "ecs_service_name" {
  type = string
}

variable "ecs_cluster_name" {
  type = string
}

variable "alb_target_group_arn_suffix" {
  type        = string
  description = "Target group ARN suffix, for the UnHealthyHostCount alarm dimension"
}

variable "sns_email" {
  type        = string
  default     = ""
  description = "Optional email for alarm notifications (empty = no subscription)"
}

resource "aws_sns_topic" "alarms" {
  name = "${var.name}-alarms"
  tags = { Name = "${var.name}-alarms" }
}

resource "aws_sns_topic_subscription" "email" {
  count     = var.sns_email == "" ? 0 : 1
  topic_arn = aws_sns_topic.alarms.arn
  protocol  = "email"
  endpoint  = var.sns_email
}

# The two alarms that catch 90% of real incidents for a small service:
# the ALB sees no healthy targets, or ECS can't keep tasks running.
resource "aws_cloudwatch_metric_alarm" "unhealthy_hosts" {
  alarm_name          = "${var.name}-unhealthy-targets"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 2
  metric_name         = "UnHealthyHostCount"
  namespace           = "AWS/ApplicationELB"
  period              = 60
  statistic           = "Maximum"
  threshold           = 0
  alarm_description   = "ALB has unhealthy targets — the app may be down"
  alarm_actions       = [aws_sns_topic.alarms.arn]

  dimensions = {
    TargetGroup  = var.alb_target_group_arn_suffix
    LoadBalancer = "app/${var.name}-alb"
  }
}

resource "aws_cloudwatch_metric_alarm" "ecs_running_tasks" {
  alarm_name          = "${var.name}-ecs-tasks-low"
  comparison_operator = "LessThanThreshold"
  evaluation_periods  = 2
  metric_name         = "RunningTaskCount"
  namespace           = "ECS/ContainerInsights"
  period              = 60
  statistic           = "Minimum"
  threshold           = 1
  alarm_description   = "Fewer than 1 ECS task running — service degraded"
  alarm_actions       = [aws_sns_topic.alarms.arn]
  treat_missing_data  = "breaching"

  dimensions = {
    ServiceName = var.ecs_service_name
    ClusterName = var.ecs_cluster_name
  }
}

output "sns_topic_arn" {
  value = aws_sns_topic.alarms.arn
}
