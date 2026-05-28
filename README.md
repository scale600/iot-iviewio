# iViewIO Style Connected Device Security Platform

[![Deploy](https://github.com/scale600/iot-iviewio/actions/workflows/deploy.yml/badge.svg)](https://github.com/scale600/iot-iviewio/actions/workflows/deploy.yml)
[![Lint](https://github.com/scale600/iot-iviewio/actions/workflows/lint.yml/badge.svg)](https://github.com/scale600/iot-iviewio/actions/workflows/lint.yml)

An end-to-end IoT security platform demonstrating AWS IoT Core, MQTT over mTLS, OTA firmware updates, and ISO 21434 security controls — built as a portfolio project targeting iViewIO's IoT Cloud Platform Engineer role.

**Live dashboard**: [https://dashboard.iviewio.com](https://dashboard.iviewio.com)

---

## Architecture

```
[Python Simulator]  ──  MQTT/TLS 1.2+, port 8883, X.509 mTLS
        │                       iot.iviewio.com (custom domain, ACM)
        ▼
[AWS IoT Core]
  ├── Thing Registry   (Trailer_Sim_01, unique X.509 identity)
  ├── IoT Policy       (least-privilege, topic-scoped)
  ├── Device Shadow    (lock state sync)
  ├── IoT Jobs         (OTA update delivery)
  └── Topic Rule       (device/+/telemetry → Lambda)
        │
        ├──► [Lambda: TelemetryHandler] ──► [DynamoDB: IoTTelemetry]
        │                                    (AES-256, TTL 30d)
        │             └──► [SNS Alert] ──► [Email] (temp ≥ 60°C)
        │
        └──► [Lambda: TelemetryQuery]  ──► [API Gateway GET /telemetry]
                                                    │
[API Gateway: POST /device/{id}/command]            │
  API Key auth + Usage Plan throttling              │
        │                                           ▼
[Lambda: CommandRelay] ──► [IoT MQTT publish]  [CloudFront]
                                    │               │
                                    ▼               ▼
                           [Simulator: lock/unlock]  [dashboard.iviewio.com]
                                                        S3 static site

[S3: Firmware Bucket] (private, AES-256)
  └── Pre-signed URL (1h) ──► [IoT Jobs] ──► [Simulator: SHA-256 verify + install]

[GitHub Actions CI/CD]
  ├── PR   → terraform plan + lint (flake8, black, terraform fmt/validate)
  └── main → terraform apply + Lambda zip deploy
```

---

## Security Controls (ISO 21434)

See [docs/ISO21434-Checklist.md](docs/ISO21434-Checklist.md) for the full compliance matrix.

| ISO 21434 Clause | Control | Status |
|------------------|---------|--------|
| Clause 10.4 Cybersecurity Design | X.509 mTLS per device | ✅ |
| Clause 10.4 Cybersecurity Design | Certificate rotation script | ✅ |
| Clause 10.4 Cybersecurity Design | Least-privilege IoT Policy | ✅ |
| Clause 10.4 Cybersecurity Design | API Key + Usage Plan | ✅ |
| Clause 10.4 Cybersecurity Design | TLS 1.2+ in transit | ✅ |
| Clause 10.4 Cybersecurity Design | AES-256 at rest (DynamoDB + S3) | ✅ |
| Clause 8.3 Cybersecurity Monitoring | IoT V2 CloudWatch + CloudTrail | ✅ |
| Clause 8.6 Vulnerability Management | SHA-256 firmware integrity check | ✅ |
| Clause 13.4 Cybersecurity Updates | IoT Jobs OTA + rollback on failure | ✅ |

---

## Project Structure

```
iot-iviewio/
├── device-simulator/
│   ├── simulator.py           # Python MQTT device (paho-mqtt, mTLS)
│   ├── requirements.txt
│   └── certs/                 # X.509 certs (git-ignored, never committed)
├── lambda/
│   ├── telemetry_handler.py   # IoT Rule → DynamoDB + SNS alert
│   ├── command_relay.py       # API Gateway → MQTT publish + Shadow
│   └── telemetry_query.py     # DynamoDB query → REST API response
├── infra/
│   └── main.tf                # Terraform: 50+ AWS resources
├── scripts/
│   └── rotate-cert.sh         # Automated X.509 certificate rotation
├── docs/
│   ├── ISO21434-Checklist.md  # Security controls mapped to code
│   ├── cert-rotation-runbook.md
│   └── self-assessment.md     # JD mapping + Q&A
├── demo/
│   └── cloudwatch-dashboard.png
└── .github/workflows/
    ├── deploy.yml             # terraform apply + Lambda deploy
    └── lint.yml               # flake8 + black + terraform fmt/validate
```

---

## Quick Start

### Prerequisites

- AWS account + AWS CLI configured (`aws configure`)
- Python 3.10+, Terraform 1.5+

### 1. Provision device certificate

```bash
aws iot create-keys-and-certificate \
  --set-as-active \
  --certificate-pem-outfile device-simulator/certs/device.pem.crt \
  --public-key-outfile  device-simulator/certs/public.pem.key \
  --private-key-outfile device-simulator/certs/private.pem.key

curl -o device-simulator/certs/AmazonRootCA1.pem \
  https://www.amazontrust.com/repository/AmazonRootCA1.pem

export CERT_ARN="arn:aws:iot:us-east-1:ACCOUNT_ID:cert/xxxx"
```

### 2. Deploy infrastructure

```bash
cd infra
cp terraform.tfvars.example terraform.tfvars   # fill in your values
terraform init
terraform apply
```

### 3. Run the device simulator

```bash
cd device-simulator
python3 -m venv .venv && source .venv/bin/activate
pip install -r requirements.txt
python3 simulator.py --endpoint iot.iviewio.com
```

### 4. Send a lock/unlock command

```bash
API_KEY=$(cd infra && terraform output -raw dashboard_api_key)

curl -X POST \
  -H "X-Api-Key: $API_KEY" \
  -H "Content-Type: application/json" \
  -d '{"action": "lock"}' \
  https://esn9dxqf0e.execute-api.us-east-1.amazonaws.com/prod/device/Trailer_Sim_01/command
```

### 5. OTA firmware update

```bash
# Upload firmware
aws s3 cp firmware-1.1.0.json s3://$(cd infra && terraform output -raw firmware_bucket)/

# Create OTA job
aws iot create-job \
  --job-id "ota-v1-1-0" \
  --targets "arn:aws:iot:us-east-1:ACCOUNT_ID:thing/Trailer_Sim_01" \
  --document '{"firmwareUrl":"<presigned-url>","sha256":"<hash>","version":"1.1.0"}' \
  --target-selection SNAPSHOT
```

---

## Cost Estimate

| Service | Free Tier | This project |
|---------|-----------|--------------|
| IoT Core | 500K msg/month | ~9K/month (30s interval) |
| Lambda | 1M invocations | ~9K/month |
| DynamoDB | 25 GB | < 1 MB |
| API Gateway | 1M calls | Minimal |
| S3 | 5 GB | < 1 MB |
| CloudFront | 1TB transfer | Minimal |

**Expected cost: $0** within free tier limits.

## Teardown

```bash
cd infra && terraform destroy
```
