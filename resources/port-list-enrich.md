CSV import the port-list.csv to index "enrich_port-list"

PUT /_enrich/policy/port-list
{
  "match": {
    "indices": "enrich_port-list",
    "match_field": "port",
    "enrich_fields": ["protocol", "description"]
  }
}

PUT /_enrich/policy/port-list/_execute

PUT _ingest/pipeline/honeypot_ingest_to_ecs
{
  "processors": [
    {
      "grok": {
        "field": "message",
        "patterns": [
          "host: %{IP:source.ip}"
        ],
        "tag": "source.ip",
        "description": "source.ip"
      }
    },
    {
      "geoip": {
        "field": "source.ip",
        "target_field": "source.geo",
        "ignore_missing": true,
        "ignore_failure": true
      }
    },
    {
      "grok": {
        "field": "message",
        "patterns": [
          "port: %{INT:dest_port}"
        ],
        "description": "dest_port"
      }
    },
    {
      "enrich": {
        "field": "dest_port",
        "policy_name": "port-list",
        "target_field": "dest_port_info",
        "ignore_missing": true,
        "ignore_failure": true
      }
    },
    {
      "rename": {
        "field": "dest_port",
        "target_field": "destination.port",
        "ignore_missing": true
      }
    },
    {
      "rename": {
        "field": "dest_port_info.protocol",
        "target_field": "network.protocol",
        "ignore_missing": true
      }
    },
    {
      "rename": {
        "field": "dest_port_info.description",
        "target_field": "destination.port_description",
        "ignore_missing": true
      }
    },
    {
      "remove": {
        "field": [
          "dest_port",
          "dest_port_info"
        ],
        "ignore_missing": true,
        "ignore_failure": true
      }
    },
    {
      "grok": {
        "field": "message",
        "patterns": [
          "\\\"PASSWORD\\\": \\\"%{DATA:user.password}\\\""
        ],
        "ignore_missing": true,
        "description": "user.password"
      }
    },
    {
      "grok": {
        "field": "message",
        "patterns": [
          "\\\"USERNAME\\\": \\\"%{DATA:user.name}\\\""
        ],
        "ignore_missing": true,
        "description": "user.name"
      }
    }
  ],
  "on_failure": [
    {
      "set": {
        "field": "error.message",
        "value": "{{ _ingest.on_failure_message }}"
      }
    }
  ]
}