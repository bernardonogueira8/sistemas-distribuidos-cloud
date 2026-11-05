resource "google_logging_metric" "api_request_count" {
  project     = var.project_id
  name        = "api_request_count"
  description = "Completed API requests emitted by the application request logger, excluding load balancer health checks."

  filter = <<-EOT
    resource.type="gce_instance"
    log_id("gcplogs-docker-driver")
    jsonPayload.message:"\"type\":\"request\""
    NOT jsonPayload.message:"GoogleHC/1.0"
  EOT

  metric_descriptor {
    metric_kind  = "DELTA"
    value_type   = "INT64"
    unit         = "1"
    display_name = "API requests"

    labels {
      key         = "region"
      value_type  = "STRING"
      description = "Compute region derived from the VM zone."
    }

    labels {
      key         = "zone"
      value_type  = "STRING"
      description = "Compute zone serving the request."
    }
  }

  label_extractors = {
    region = "REGEXP_EXTRACT(resource.labels.zone, \"^(.+)-[a-z]$\")"
    zone   = "EXTRACT(resource.labels.zone)"
  }
}

resource "google_monitoring_dashboard" "api_requests" {
  project = var.project_id
  dashboard_json = jsonencode({
    displayName = "API request traffic"
    gridLayout = {
      columns = 2
      widgets = [
        {
          title = "Load balancer frontend requests (global)"
          xyChart = {
            dataSets = [{
              timeSeriesQuery = {
                timeSeriesFilter = {
                  filter = "metric.type=\"loadbalancing.googleapis.com/application_lb/request_count\" AND resource.type=\"gce_forwarding_rule\" AND metric.labels.load_balancing_scheme=\"EXTERNAL_MANAGED\""
                  aggregation = {
                    alignmentPeriod    = "60s"
                    perSeriesAligner   = "ALIGN_DELTA"
                    crossSeriesReducer = "REDUCE_SUM"
                    groupByFields      = ["resource.labels.forwarding_rule_id"]
                  }
                }
              }
              plotType = "LINE"
            }]
            yAxis = { label = "Requests / minute", scale = "LINEAR" }
          }
        },
        {
          title = "Load balancer backend requests (aggregate)"
          xyChart = {
            dataSets = [{
              timeSeriesQuery = {
                timeSeriesFilter = {
                  filter = "metric.type=\"loadbalancing.googleapis.com/application_lb/backend_request_count\" AND resource.type=\"gce_backend_service\" AND metric.labels.load_balancing_scheme=\"EXTERNAL_MANAGED\""
                  aggregation = {
                    alignmentPeriod    = "60s"
                    perSeriesAligner   = "ALIGN_DELTA"
                    crossSeriesReducer = "REDUCE_SUM"
                    groupByFields      = ["resource.labels.backend_service_id"]
                  }
                }
              }
              plotType = "LINE"
            }]
            yAxis = { label = "Requests / minute", scale = "LINEAR" }
          }
        },
        {
          title = "API requests by region (application logs)"
          xyChart = {
            dataSets = [{
              timeSeriesQuery = {
                timeSeriesFilter = {
                  filter = "metric.type=\"logging.googleapis.com/user/api_request_count\" AND resource.type=\"gce_instance\""
                  aggregation = {
                    alignmentPeriod    = "60s"
                    perSeriesAligner   = "ALIGN_DELTA"
                    crossSeriesReducer = "REDUCE_SUM"
                    groupByFields      = ["metric.labels.region"]
                  }
                }
              }
              plotType = "LINE"
            }]
            yAxis = { label = "Requests / minute", scale = "LINEAR" }
          }
        },
        {
          title = "API requests by zone (application logs)"
          xyChart = {
            dataSets = [{
              timeSeriesQuery = {
                timeSeriesFilter = {
                  filter = "metric.type=\"logging.googleapis.com/user/api_request_count\" AND resource.type=\"gce_instance\""
                  aggregation = {
                    alignmentPeriod    = "60s"
                    perSeriesAligner   = "ALIGN_DELTA"
                    crossSeriesReducer = "REDUCE_SUM"
                    groupByFields      = ["metric.labels.region", "metric.labels.zone"]
                  }
                }
              }
              plotType = "LINE"
            }]
            yAxis = { label = "Requests / minute", scale = "LINEAR" }
          }
        },
        {
          title = "API requests by instance (application logs)"
          xyChart = {
            dataSets = [{
              timeSeriesQuery = {
                timeSeriesFilter = {
                  filter = "metric.type=\"logging.googleapis.com/user/api_request_count\" AND resource.type=\"gce_instance\""
                  aggregation = {
                    alignmentPeriod    = "60s"
                    perSeriesAligner   = "ALIGN_DELTA"
                    crossSeriesReducer = "REDUCE_SUM"
                    groupByFields      = ["metric.labels.region", "resource.labels.instance_id"]
                  }
                }
              }
              plotType = "LINE"
            }]
            yAxis = { label = "Requests / minute", scale = "LINEAR" }
          }
        }
      ]
    }
  })
}