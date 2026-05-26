# AC Future Style Connected Device Security Platform

An end-to-end IoT security platform demonstrating AWS IoT Core, MQTT over TLS, OTA firmware updates, and ISO 24241 security controls — built as a portfolio project targeting AC Future's IoT Cloud Platform Engineer role.

## Architecture

```
[Python Simulator]
  MQTT/TLS (port 8883)
  X.509 mTLS
        │
        ▼
[AWS IoT Core]
  ├── Thing Registry (Trailer_Sim_01)
  ├── Device Shadow (lock state)
  ├── IoT Jobs (OTA updates)
  └── Topic Rule: device/+/telemetry
        │
        ▼
[Lambda: TelemetryHandler] ──► [DynamoDB: IoTTelemetry]
        │                              (AES-256, TTL 30d)
        └──► [SNS Alert] ──► [Email] (temp ≥ 60°C)

[API Gateway: POST /device/{id}/command]
  AWS_IAM auth
        │
        ▼
[Lambda: CommandRelay] ──► [IoT Core MQTT publish]
                                    │
                                    ▼
                           [Python Simulator: lock/unlock]

[S3: Firmware Bucket] (private, AES-256)
  └── Pre-signed URL ──► [IoT Jobs] ──► [Simulator: hash verify + install]
```

## Project Structure

```
fc-future/
├── device-simulator/
│   ├── simulator.py       # Python MQTT device (paho-mqtt)
│   ├── requirements.txt
│   └── certs/             # X.509 certs (git-ignored)
├── lambda/
│   ├── telemetry_handler.py   # IoT Rule → DynamoDB + SNS
│   └── command_relay.py       # API Gateway → MQTT publish
├── infra/
│   └── main.tf            # Terraform (IoT, DynamoDB, Lambda, API GW, S3)
├── docs/
│   └── ISO24241-Checklist.md  # Security controls mapped to code
└── demo/                  # Screenshots, screencasts
```

## Quick Start

### Prerequisites

- AWS account + AWS CLI configured (`aws configure`)
- Python 3.10+
- Terraform 1.5+

### 1. Provision certificates

```bash
aws iot create-keys-and-certificate \
  --set-as-active \
  --certificate-pem-outfile device-simulator/certs/device.pem.crt \
  --public-key-outfile device-simulator/certs/public.pem.key \
  --private-key-outfile device-simulator/certs/private.pem.key

# Download Amazon Root CA
curl -o device-simulator/certs/AmazonRootCA1.pem \
  https://www.amazontrust.com/repository/AmazonRootCA1.pem

# Save the certificate ARN from the output above
export CERT_ARN="arn:aws:iot:ap-northeast-1:123456789:cert/xxxx"
```

### 2. Deploy infrastructure

```bash
cd infra
terraform init
terraform apply \
  -var="device_cert_arn=$CERT_ARN" \
  -var="alert_email=your@email.com"
```

### 3. Run the simulator

```bash
cd device-simulator
pip install -r requirements.txt

IOT_ENDPOINT=$(aws iot describe-endpoint --endpoint-type iot:Data-ATS --query endpointAddress --output text)

python simulator.py --endpoint $IOT_ENDPOINT
```

### 4. Send a command

```bash
# Get API URL from Terraform output
API_URL=$(cd infra && terraform output -raw api_gateway_url)

aws apigateway test-invoke-method ... # or use curl with SigV4
```

## Security Controls (ISO 24241 Mapping)

See [docs/ISO24241-Checklist.md](docs/ISO24241-Checklist.md) for the full compliance matrix.

Key highlights:
- **Authentication**: X.509 mTLS per device, unique IoT Thing identity
- **Authorization**: Least-privilege IoT Policy (topic-scoped), AWS_IAM on API
- **Data in transit**: TLS 1.2+ enforced by AWS IoT Core
- **Data at rest**: DynamoDB and S3 AES-256 server-side encryption
- **Firmware integrity**: SHA-256 hash verification before OTA install
- **Audit**: CloudTrail + IoT Core V2 logs → CloudWatch

## Cost Estimate (Free Tier)

| Service | Free Tier | This project |
|---------|-----------|--------------|
| IoT Core messages | 500K/month | ~9K/month (30s interval) |
| Lambda | 1M invocations | ~9K/month |
| DynamoDB | 25 GB storage | < 1 MB |
| API Gateway | 1M calls | Minimal |
| S3 | 5 GB | < 1 MB |

**Expected cost: $0** within free tier limits.

> **Warning**: Always run `terraform destroy` after testing to avoid idle charges.

## Teardown

```bash
cd infra
terraform destroy
```
