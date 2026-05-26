"""
Lambda: Command Relay
Triggered by API Gateway: POST /device/{deviceId}/command
- Validates request body
- Publishes MQTT command to the target device via AWS IoT Core Data Plane
- Updates Device Shadow
"""

import json
import os
import boto3
from botocore.exceptions import ClientError

iot_data = boto3.client("iot-data", endpoint_url=f"https://{os.environ['IOT_ENDPOINT']}")
ALLOWED_ACTIONS = {"lock", "unlock"}


def handler(event, context):
    device_id = event.get("pathParameters", {}).get("deviceId")
    if not device_id:
        return _error(400, "deviceId path parameter is required")

    try:
        body = json.loads(event.get("body") or "{}")
    except json.JSONDecodeError:
        return _error(400, "Invalid JSON body")

    action = body.get("action", "").lower()
    if action not in ALLOWED_ACTIONS:
        return _error(400, f"action must be one of {sorted(ALLOWED_ACTIONS)}")

    command_payload = json.dumps({"action": action, "source": "api"})
    topic = f"device/{device_id}/command"

    try:
        iot_data.publish(topic=topic, qos=1, payload=command_payload)
    except ClientError as e:
        return _error(500, f"Failed to publish command: {e.response['Error']['Message']}")

    # Mirror desired state to Device Shadow
    shadow_payload = json.dumps(
        {"state": {"desired": {"locked": action == "lock"}}}
    )
    try:
        iot_data.update_thing_shadow(
            thingName=device_id,
            payload=shadow_payload,
        )
    except ClientError as e:
        # Shadow update failure is non-fatal; command was already sent
        print(f"Shadow update warning: {e}")

    return {
        "statusCode": 200,
        "headers": {"Content-Type": "application/json"},
        "body": json.dumps({"deviceId": device_id, "action": action, "status": "sent"}),
    }


def _error(code: int, message: str) -> dict:
    return {
        "statusCode": code,
        "headers": {"Content-Type": "application/json"},
        "body": json.dumps({"error": message}),
    }
