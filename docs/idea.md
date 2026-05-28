# Project Proposal: iViewIO Style Connected Device Security Platform (MVP)

## Objective

Register a virtual smart device (e.g., a lock and temperature/humidity sensor on an expandable trailer) with AWS IoT Core, relay commands from the cloud, build an OTA update pipeline, and apply the key security controls from ISO 21434.

---

## Project Components (12 Phases — as implemented)

### Phase 1: Simulated Device (Python + MQTT)

**Implementation**: Python script running locally (macOS)

**Features**:
- Connect to AWS IoT Core via MQTT over TLS 1.2+ (X.509 mTLS, port 8883)
- Custom domain `iot.iviewio.com` (ACM certificate, Cloudflare DNS-only)
- Publish temperature, humidity, and battery level to `device/+/telemetry` every 30 seconds
- Subscribe to `device/+/command` → apply lock/unlock state
- Device Shadow update on every state change
- AWS IoT Jobs OTA handling: SHA-256 hash verification + status reporting

### Phase 2: AWS IoT Core + Rules Engine + Device Registry

**Configuration**:
- Thing registration: `Trailer_Sim_01` registered in AWS IoT Core
- Policy: least-privilege, topic-scoped per device ID
  - `iot:Subscribe` uses `topicfilter/` prefix; `iot:Receive` uses `topic/` prefix (critical distinction)
- IoT Rule: `SELECT * FROM 'device/+/telemetry'` → Lambda trigger
- Device Shadow: lock state sync between cloud and simulator
- Custom domain: `iot.iviewio.com` via `aws_iot_domain_configuration` (ACM + Cloudflare)
- IoT V2 CloudWatch logging: INFO level, role `IoTLoggingRole` → log group `AWSIotLogsV2`

### Phase 3: Backend API + Command Relay (AWS Lambda + API Gateway)

- **Lambda 1 (TelemetryHandler)**: save received data to DynamoDB + send SNS alert if temperature ≥ 60°C
- **Lambda 2 (CommandRelay)**: `POST /device/{id}/command` with `{"action": "lock/unlock"}` → MQTT publish + Device Shadow update
- **Lambda 3 (TelemetryQuery)**: `GET /device/{id}/telemetry?limit=N` → DynamoDB query → JSON response (added for web dashboard)
- **Auth**: API Key + Usage Plan throttling on all endpoints; CORS OPTIONS MOCK integration for browser access
- **CORS fix**: added OPTIONS MOCK methods to both `/telemetry` and `/command` after dashboard moved to CloudFront

### Phase 4: OTA Update Pipeline (Simulated)

**Implementation**:
- Upload virtual firmware (JSON file) to private S3 bucket (`iot-firmware-*`)
- Deliver update via AWS IoT Jobs with pre-signed S3 URL (1 hour validity)
- Device verifies SHA-256 hash before install; updates `self.firmware_version` only on success
- Job status reported back: `SUCCEEDED` or `FAILED` with reason

**Security**:
- Private S3 bucket (public access blocked, AES-256 encryption)
- Time-limited pre-signed URL (1 hour)
- SHA-256 firmware integrity verification (in code)
- Hash mismatch test confirmed: job status → `FAILED`, reason: `Hash verification failed`

### Phase 5: Web Dashboard (Added — not in original plan)

- New Lambda `IoTTelemetryQuery` + GET API endpoint
- S3 static website bucket for dashboard HTML
- Dark-theme dashboard: telemetry table, lock/unlock buttons, 30s auto-refresh, temperature alert highlighting
- Custom domain `dashboard.iviewio.com` via CloudFront + ACM (HTTPS)
- CORS issue resolved: OPTIONS MOCK integration added to API Gateway

### Phase 6: GitHub Actions CI/CD (Added — not in original plan)

- `.github/workflows/lint.yml`: flake8 + black (line-length=100) + terraform fmt/validate
- `.github/workflows/deploy.yml`: PR → terraform plan; main push → terraform apply + Lambda zip deploy
- S3 remote backend for Terraform state (`iot-tfstate-{accountId}-us-east-1`)
- GitHub Secrets: `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`, `ALERT_EMAIL`, `DEVICE_CERT_ARN`, `ACM_CERT_ARN`

### Phase 7: ISO 21434 Security Controls

**Documentation**: dedicated `docs/ISO21434-Checklist.md` (not README.md as originally planned)

- **Authentication & Identification**: X.509 mTLS per device; certificate rotation via `scripts/rotate-cert.sh`
- **Access Control**: least-privilege IoT Policy; API Key + Usage Plan; Lambda IAM scoped to single table/topic
- **Data Protection**: TLS 1.2+ in transit; DynamoDB AES-256 + 30-day TTL; S3 AES-256 private bucket
- **Logging & Audit**: IoT V2 CloudWatch (INFO); CloudTrail; CloudWatch dashboard `iViewIO-IoT-Security` (4 widgets)
- **Vulnerability Management**: SHA-256 firmware hash verification; pre-signed URL for download
- **Secure Updates**: IoT Jobs OTA over mTLS; rollback on hash mismatch

**Additional deliverables**:
- `scripts/rotate-cert.sh`: 5-step automated certificate rotation
- `docs/cert-rotation-runbook.md`: manual runbook with script reference
- `docs/self-assessment.md`: JD requirements mapping + 6 Q&A

---

## Tech Stack (as implemented)

| Technology | Role in Project | Notes |
|------------|-----------------|-------|
| AWS IoT Core | MQTT broker, device registry, IoT Jobs | Custom domain via ACM |
| AWS Lambda (×3) | Telemetry handler, command relay, telemetry query | Python 3.12 |
| API Gateway | REST API (GET telemetry, POST command) | API Key + CORS |
| DynamoDB | Device telemetry storage | AES-256, TTL 30d |
| S3 | Firmware bucket + dashboard static site | Private + public |
| SNS | Temperature alert emails (≥ 60°C) | |
| CloudFront | HTTPS CDN for dashboard.iviewio.com | ACM certificate |
| ACM | TLS certificates (iot + api + dashboard subdomains) | DNS validation |
| CloudWatch | IoT V2 logs + Lambda logs + security dashboard | |
| CloudTrail | API call audit trail | Account-level |
| Terraform | IaC for all 50+ AWS resources | S3 remote state |
| GitHub Actions | CI/CD: lint + terraform apply + Lambda deploy | |
| Cloudflare | DNS for iviewio.com subdomains | |
| Python + paho-mqtt | Simulator device | mTLS, loop_start() |

---

## Deliverables (completed)

**GitHub Repository**: [github.com/scale600/iot-iviewio](https://github.com/scale600/iot-iviewio)

```
iot-iviewio/
├── device-simulator/simulator.py      # Python MQTT device (mTLS, OTA, Shadow)
├── lambda/
│   ├── telemetry_handler.py           # IoT Rule → DynamoDB + SNS
│   ├── command_relay.py               # API Gateway → MQTT + Shadow
│   └── telemetry_query.py             # DynamoDB query → REST API
├── infra/main.tf                      # Terraform: 50+ AWS resources
├── scripts/rotate-cert.sh             # Automated X.509 cert rotation
├── docs/
│   ├── ISO21434-Checklist.md          # All controls ✅ with code links
│   ├── cert-rotation-runbook.md
│   └── self-assessment.md             # JD mapping + Q&A
├── demo/
│   ├── cloudwatch-dashboard.png
│   ├── mqtt-received.png
│   └── ota-success.png
└── .github/workflows/
    ├── deploy.yml                     # Deploy: ✅
    └── lint.yml                       # Lint: ✅
```

**Live endpoints**:
- Dashboard: **https://dashboard.iviewio.com**
- MQTT endpoint: `iot.iviewio.com:8883`
- API: `https://esn9dxqf0e.execute-api.us-east-1.amazonaws.com/prod/`

---

## Additional Advice

For this project to be effective in technical reviews:

1. **Must be runnable live**: be ready to immediately demo on request — start the simulator and send an API request in real time.
2. **No security mistakes**: no hardcoded credentials anywhere — all via GitHub Secrets → Terraform variables
3. **ISO 21434 beyond a checklist**: explain depth, e.g. "Clause 8.6 requires vulnerability management including credential lifecycle — I automated certificate rotation in `scripts/rotate-cert.sh` with 5 steps: generate, attach, policy attach, revoke old, detach old."
4. **Real debugging story**: the `iot:Receive` vs `topicfilter/` bug — diagnosed via CloudWatch IoT V2 logs at DEBUG level — is a strong talking point

---

## Possible Extensions (if time allows)

- Cognito + JWT for mobile app API security (addresses "mobile security")
- RDS (PostgreSQL) + KMS encryption for database security (addresses "DB security")
- Architecture diagram in draw.io → PNG (for README visual)
- Screencast recording (YouTube Unlisted) for demo

---

## Final Outcome

> "I built a connected device security platform based on AWS IoT Core as a personal project, implemented ISO 21434 security controls in practice, and deployed it with a live HTTPS dashboard and automated CI/CD pipeline."

Keywords: IoT Cloud Platform, MQTT/mTLS, OTA, Device Shadow, IoT Jobs, Terraform IaC, GitHub Actions CI/CD, Security Audit Logging, ISO 21434
