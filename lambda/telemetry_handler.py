"""
Lambda: Telemetry Handler
Triggered by IoT Rule on topic: device/+/telemetry
- Stores data in DynamoDB
- Publishes SNS alert if temperature >= 60°C
"""

import json
import os
import boto3
from datetime import datetime, timezone

dynamodb = boto3.resource("dynamodb")
sns = boto3.client("sns")

TABLE_NAME = os.environ["TELEMETRY_TABLE"]
SNS_TOPIC_ARN = os.environ["ALERT_SNS_TOPIC_ARN"]
TEMP_ALERT_THRESHOLD = float(os.environ.get("TEMP_ALERT_THRESHOLD", "60.0"))


def handler(event, context):
    """
    event shape (mapped by IoT Rule SELECT *):
    {
        "deviceId": "Trailer_Sim_01",
        "timestamp": 1234567890,
        "temperature": 65.2,
        "humidity": 55.0,
        "batteryLevel": 80.0,
        "locked": true,
        "firmwareVersion": "1.0.0"
    }
    """
    device_id = event.get("deviceId", "unknown")
    ts = event.get("timestamp", int(datetime.now(timezone.utc).timestamp()))
    temperature = float(event.get("temperature", 0))

    table = dynamodb.Table(TABLE_NAME)
    table.put_item(
        Item={
            "deviceId": device_id,
            "timestamp": ts,
            "temperature": str(temperature),
            "humidity": str(event.get("humidity", 0)),
            "batteryLevel": str(event.get("batteryLevel", 0)),
            "locked": event.get("locked", True),
            "firmwareVersion": event.get("firmwareVersion", "unknown"),
            "ttl": ts + 86400 * 30,  # 30-day TTL
        }
    )

    if temperature >= TEMP_ALERT_THRESHOLD:
        sns.publish(
            TopicArn=SNS_TOPIC_ARN,
            Subject=f"[ALERT] High temperature on {device_id}",
            Message=json.dumps(
                {
                    "deviceId": device_id,
                    "temperature": temperature,
                    "threshold": TEMP_ALERT_THRESHOLD,
                    "timestamp": ts,
                }
            ),
        )

    return {"statusCode": 200, "body": f"Stored telemetry for {device_id}"}
