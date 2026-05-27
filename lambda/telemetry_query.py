"""
Lambda: Telemetry Query
Triggered by API Gateway: GET /device/{deviceId}/telemetry?limit=20
- Queries DynamoDB for recent telemetry records
- Returns JSON with CORS headers for browser access
"""

import json
import os
import boto3
from boto3.dynamodb.conditions import Key

dynamodb = boto3.resource("dynamodb")
TABLE_NAME = os.environ["TELEMETRY_TABLE"]
TEMP_ALERT_THRESHOLD = float(os.environ.get("TEMP_ALERT_THRESHOLD", "60.0"))

CORS_HEADERS = {
    "Access-Control-Allow-Origin": "*",
    "Access-Control-Allow-Headers": "Content-Type,X-Api-Key",
    "Content-Type": "application/json",
}


def handler(event, context):
    device_id = event.get("pathParameters", {}).get("deviceId")
    if not device_id:
        return _error(400, "deviceId path parameter is required")

    query_params = event.get("queryStringParameters") or {}
    limit = min(int(query_params.get("limit", 20)), 100)

    table = dynamodb.Table(TABLE_NAME)
    response = table.query(
        KeyConditionExpression=Key("deviceId").eq(device_id),
        ScanIndexForward=False,
        Limit=limit,
    )

    items = []
    for item in response.get("Items", []):
        temperature = float(item.get("temperature", 0))
        items.append({
            "deviceId": item.get("deviceId"),
            "timestamp": int(item.get("timestamp", 0)),
            "temperature": temperature,
            "humidity": float(item.get("humidity", 0)),
            "batteryLevel": float(item.get("batteryLevel", 0)),
            "locked": bool(item.get("locked", True)),
            "firmwareVersion": item.get("firmwareVersion", "unknown"),
            "alert": temperature >= TEMP_ALERT_THRESHOLD,
        })

    return {
        "statusCode": 200,
        "headers": CORS_HEADERS,
        "body": json.dumps({
            "deviceId": device_id,
            "count": len(items),
            "threshold": TEMP_ALERT_THRESHOLD,
            "items": items,
        }),
    }


def _error(code, message):
    return {
        "statusCode": code,
        "headers": CORS_HEADERS,
        "body": json.dumps({"error": message}),
    }
