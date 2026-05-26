"""
AC Future Style Connected Device Security Platform
Simulates a trailer IoT device (lock + temp/humidity sensors)
connecting to AWS IoT Core via MQTT over TLS (X.509 mTLS).
"""

import json
import random
import time
import argparse
import logging
import hashlib
from pathlib import Path

import paho.mqtt.client as mqtt

logging.basicConfig(level=logging.INFO, format="%(asctime)s [%(levelname)s] %(message)s")
log = logging.getLogger(__name__)

DEVICE_ID = "Trailer_Sim_01"
FIRMWARE_VERSION = "1.0.0"
TELEMETRY_INTERVAL = 30  # seconds

TOPIC_TELEMETRY = f"device/{DEVICE_ID}/telemetry"
TOPIC_COMMAND = f"device/{DEVICE_ID}/command"
TOPIC_SHADOW_UPDATE = f"$aws/things/{DEVICE_ID}/shadow/update"
TOPIC_SHADOW_DELTA = f"$aws/things/{DEVICE_ID}/shadow/update/delta"
TOPIC_JOB_NOTIFY = f"$aws/things/{DEVICE_ID}/jobs/notify-next"
TOPIC_JOB_UPDATE = f"$aws/things/{DEVICE_ID}/jobs/{{job_id}}/update"


class TrailerSimulator:
    def __init__(self, endpoint: str, cert: str, key: str, ca: str):
        self.endpoint = endpoint
        self.is_locked = True
        self.firmware_version = FIRMWARE_VERSION

        self.client = mqtt.Client(client_id=DEVICE_ID, protocol=mqtt.MQTTv311)
        self.client.tls_set(ca_certs=ca, certfile=cert, keyfile=key)
        self.client.on_connect = self._on_connect
        self.client.on_message = self._on_message
        self.client.on_disconnect = self._on_disconnect

    def connect(self):
        log.info(f"Connecting to {self.endpoint}:8883 as {DEVICE_ID}")
        self.client.connect(self.endpoint, port=8883, keepalive=60)
        self.client.loop_start()

    def disconnect(self):
        self.client.loop_stop()
        self.client.disconnect()

    def _on_connect(self, client, userdata, flags, rc):
        if rc != 0:
            log.error(f"Connection failed with code {rc}")
            return
        log.info("Connected to AWS IoT Core")
        client.subscribe(TOPIC_COMMAND, qos=1)
        client.subscribe(TOPIC_SHADOW_DELTA, qos=1)
        client.subscribe(TOPIC_JOB_NOTIFY, qos=1)
        log.info(f"Subscribed to command/shadow/jobs topics")
        self._publish_shadow()

    def _on_disconnect(self, client, userdata, rc):
        log.warning(f"Disconnected (rc={rc}). Reconnecting...")

    def _on_message(self, client, userdata, msg):
        topic = msg.topic
        try:
            payload = json.loads(msg.payload.decode())
        except json.JSONDecodeError:
            log.warning(f"Non-JSON payload on {topic}")
            return

        log.info(f"Received on {topic}: {payload}")

        if topic == TOPIC_COMMAND:
            self._handle_command(payload)
        elif topic == TOPIC_SHADOW_DELTA:
            self._handle_shadow_delta(payload)
        elif topic == TOPIC_JOB_NOTIFY:
            self._handle_ota_job(payload)

    def _handle_command(self, payload: dict):
        action = payload.get("action", "").lower()
        if action == "lock":
            self.is_locked = True
            log.info("Lock command received: LOCKED")
        elif action == "unlock":
            self.is_locked = False
            log.info("Unlock command received: UNLOCKED")
        else:
            log.warning(f"Unknown command action: {action}")
        self._publish_shadow()

    def _handle_shadow_delta(self, payload: dict):
        desired_lock = payload.get("state", {}).get("locked")
        if desired_lock is not None:
            self.is_locked = bool(desired_lock)
            log.info(f"Shadow delta applied: locked={self.is_locked}")
            self._publish_shadow()

    def _handle_ota_job(self, payload: dict):
        execution = payload.get("execution", {})
        job_id = execution.get("jobId")
        job_doc = execution.get("jobDocument", {})

        if not job_id:
            return

        firmware_url = job_doc.get("firmwareUrl", "")
        expected_hash = job_doc.get("sha256", "")
        new_version = job_doc.get("version", self.firmware_version)

        log.info(f"OTA Job received: job_id={job_id}, target_version={new_version}")

        # Simulate download + hash verification
        simulated_content = f"firmware-{new_version}".encode()
        actual_hash = hashlib.sha256(simulated_content).hexdigest()

        if expected_hash and actual_hash != expected_hash:
            log.error(f"Firmware hash mismatch! Rejecting OTA job {job_id}")
            self._update_job_status(job_id, "FAILED", "Hash verification failed")
            return

        # Simulate install (1 second)
        log.info(f"Installing firmware v{new_version}...")
        time.sleep(1)
        self.firmware_version = new_version
        log.info(f"Firmware updated to v{self.firmware_version}")
        self._update_job_status(job_id, "SUCCEEDED", f"Updated to {new_version}")

    def _update_job_status(self, job_id: str, status: str, reason: str = ""):
        topic = TOPIC_JOB_UPDATE.format(job_id=job_id)
        payload = {
            "status": status,
            "statusDetails": {"reason": reason},
        }
        self.client.publish(topic, json.dumps(payload), qos=1)

    def _publish_shadow(self):
        state = {
            "state": {
                "reported": {
                    "locked": self.is_locked,
                    "firmwareVersion": self.firmware_version,
                }
            }
        }
        self.client.publish(TOPIC_SHADOW_UPDATE, json.dumps(state), qos=1)

    def publish_telemetry(self):
        payload = {
            "deviceId": DEVICE_ID,
            "timestamp": int(time.time()),
            "temperature": round(random.uniform(15.0, 75.0), 2),
            "humidity": round(random.uniform(30.0, 90.0), 2),
            "batteryLevel": round(random.uniform(10.0, 100.0), 2),
            "locked": self.is_locked,
            "firmwareVersion": self.firmware_version,
        }
        self.client.publish(TOPIC_TELEMETRY, json.dumps(payload), qos=1)
        log.info(f"Telemetry published: temp={payload['temperature']}°C, locked={payload['locked']}")

    def run(self):
        self.connect()
        try:
            while True:
                self.publish_telemetry()
                time.sleep(TELEMETRY_INTERVAL)
        except KeyboardInterrupt:
            log.info("Shutting down simulator")
        finally:
            self.disconnect()


def main():
    parser = argparse.ArgumentParser(description="AC Future Trailer IoT Simulator")
    parser.add_argument("--endpoint", required=True, help="AWS IoT Core endpoint (e.g. xxxxx.iot.ap-northeast-1.amazonaws.com)")
    parser.add_argument("--cert", default="certs/device.pem.crt", help="Device certificate path")
    parser.add_argument("--key", default="certs/private.pem.key", help="Private key path")
    parser.add_argument("--ca", default="certs/AmazonRootCA1.pem", help="Amazon Root CA path")
    args = parser.parse_args()

    for path in [args.cert, args.key, args.ca]:
        if not Path(path).exists():
            raise FileNotFoundError(f"Certificate file not found: {path}")

    sim = TrailerSimulator(
        endpoint=args.endpoint,
        cert=args.cert,
        key=args.key,
        ca=args.ca,
    )
    sim.run()


if __name__ == "__main__":
    main()
