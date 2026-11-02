"""Log RDS cluster events (delivered through SNS) as structured JSON lines.

Each failover produces several events (started, completed, instance roles changed);
querying them in CloudWatch Logs Insights gives the failover timeline:

    fields event_time, event_id, message
    | filter type = "rds_event"
    | sort event_time asc
"""

import json
from datetime import datetime, timezone


def handler(event, context):
    records = event.get("Records", [])
    for record in records:
        sns = record.get("Sns", {})
        raw = sns.get("Message", "{}")
        try:
            msg = json.loads(raw)
        except json.JSONDecodeError:
            msg = {"Event Message": raw}

        print(json.dumps({
            "type": "rds_event",
            "received_at": datetime.now(timezone.utc).isoformat(),
            "sns_timestamp": sns.get("Timestamp"),
            "event_time": msg.get("Event Time"),
            "source_id": msg.get("Source ID"),
            "event_id": msg.get("Event ID"),
            "message": msg.get("Event Message"),
        }))

    return {"processed": len(records)}
