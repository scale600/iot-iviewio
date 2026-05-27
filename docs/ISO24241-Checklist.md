# ISO 24241 Security Compliance Checklist

> **Standard**: ISO/IEC 24241 – Information security for IoT devices and systems  
> **Project**: iViewIO Style Connected Device Security Platform  
> **Last Updated**: 2026-05-27

---

## How to Use This Document

Each control below lists:
- **Requirement** – what ISO 24241 mandates
- **Implementation** – what this project actually does
- **Evidence** – code path or screenshot reference

---

## 1. Authentication and Identification (Section 6.2)

### 1.1 Device Identity
| Field | Detail |
|-------|--------|
| **Requirement** | Every device shall have a unique, verifiable identity. |
| **Implementation** | Each device registered as an AWS IoT Thing with a unique X.509 client certificate (mTLS). The `DEVICE_ID` is bound to the certificate CN and enforced in the IoT Policy. |
| **Evidence** | [`device-simulator/simulator.py`](../device-simulator/simulator.py) → `TrailerSimulator.__init__()`, `tls_set()` call; [`infra/main.tf`](../infra/main.tf) → `aws_iot_thing`, `aws_iot_policy` |

### 1.2 Certificate Lifecycle
| Field | Detail |
|-------|--------|
| **Requirement** | Device credentials shall have defined expiry and renewal procedures. |
| **Implementation** | AWS IoT Core certificates provisioned with defined validity period. Automated rotation runbook: generate new cert, attach to Thing, revoke old cert. Script: `scripts/rotate-cert.sh`. |
| **Evidence** | [`docs/cert-rotation-runbook.md`](cert-rotation-runbook.md), [`scripts/rotate-cert.sh`](../scripts/rotate-cert.sh) |

---

## 2. Authorization and Access Control (Section 6.3)

### 2.1 Least Privilege for Device
| Field | Detail |
|-------|--------|
| **Requirement** | A device shall only have access to resources it needs to function. |
| **Implementation** | IoT Policy restricts device to: Connect with its own ClientID; Publish only to its own `telemetry` and `shadow/update` topics; Subscribe/Receive only on its own `command`, `shadow/update/delta`, and `jobs/notify-next` topics. Cross-device access is structurally impossible. |
| **Evidence** | [`infra/main.tf`](../infra/main.tf) → `aws_iot_policy.device_policy` |

### 2.2 API Authorization
| Field | Detail |
|-------|--------|
| **Requirement** | Management interfaces shall require authenticated access. |
| **Implementation** | API Gateway command endpoint (`POST /device/{id}/command`) requires `X-Api-Key` header. API key issued per deployment, stored in GitHub Secrets, scoped to a Usage Plan with request throttling. Telemetry GET similarly gated by API key. |
| **Evidence** | [`infra/main.tf`](../infra/main.tf) → `aws_api_gateway_api_key.dashboard`, `aws_api_gateway_usage_plan.dashboard` |

### 2.3 IAM Least Privilege
| Field | Detail |
|-------|--------|
| **Requirement** | Cloud service accounts shall follow least privilege. |
| **Implementation** | Lambda execution role grants only: DynamoDB PutItem/GetItem/Query on the single telemetry table; SNS Publish to the single alert topic; IoT Publish + UpdateThingShadow; CloudWatch Logs write. No wildcard service actions. |
| **Evidence** | [`infra/main.tf`](../infra/main.tf) → `aws_iam_role_policy.lambda_policy` |

---

## 3. Data Protection (Section 6.4)

### 3.1 Data in Transit
| Field | Detail |
|-------|--------|
| **Requirement** | All communication between device and cloud shall be encrypted. |
| **Implementation** | MQTT over TLS 1.2+ on port 8883. AWS IoT Core enforces TLS 1.2 minimum. Mutual TLS with X.509 certificates. Custom domain `iot.iviewio.com` via ACM-issued certificate. Dashboard served over HTTPS via CloudFront + ACM. |
| **Evidence** | [`device-simulator/simulator.py`](../device-simulator/simulator.py) → `client.tls_set()` |

### 3.2 Data at Rest – Database
| Field | Detail |
|-------|--------|
| **Requirement** | Stored device data shall be encrypted. |
| **Implementation** | DynamoDB table `IoTTelemetry` has `server_side_encryption.enabled = true` (AES-256, AWS-managed key). TTL set to 30 days to minimize data retention. |
| **Evidence** | [`infra/main.tf`](../infra/main.tf) → `aws_dynamodb_table.telemetry`, `server_side_encryption` block |

### 3.3 Data at Rest – Firmware Store
| Field | Detail |
|-------|--------|
| **Requirement** | Firmware artifacts shall be stored securely. |
| **Implementation** | S3 firmware bucket has server-side encryption (AES-256) enabled and all public access blocked. Files accessible only via time-limited pre-signed URLs (1 hour). |
| **Evidence** | [`infra/main.tf`](../infra/main.tf) → `aws_s3_bucket_server_side_encryption_configuration.firmware`, `aws_s3_bucket_public_access_block.firmware` |

---

## 4. Logging and Audit Trail (Section 6.5)

### 4.1 IoT Core Logging
| Field | Detail |
|-------|--------|
| **Requirement** | All device connections and message activity shall be logged. |
| **Implementation** | AWS IoT Core V2 logging enabled (INFO level) → CloudWatch Logs group `AWSIotLogsV2`. Captures connect, disconnect, publish, subscribe, and authorization events. IAM role `IoTLoggingRole` grants IoT → CloudWatch write access. |
| **Evidence** | `aws iot get-v2-logging-options` → `defaultLogLevel: INFO`; CloudWatch → Log Groups → `AWSIotLogsV2` |

### 4.2 API Audit Trail
| Field | Detail |
|-------|--------|
| **Requirement** | Management API calls shall be auditable. |
| **Implementation** | AWS CloudTrail enabled (account-level) captures all API Gateway and Lambda invocations with caller identity, timestamp, and source IP. |
| **Evidence** | CloudTrail console → Event history (filter: `eventSource = apigateway.amazonaws.com`) |

### 4.3 CloudWatch Dashboard
| Field | Detail |
|-------|--------|
| **Requirement** | Security events shall be visible to operators. |
| **Implementation** | CloudWatch dashboard `iViewIO-IoT-Security` configured with 4 widgets: device connection count, telemetry message rate, Lambda error rate per function, SNS alert count. |
| **Evidence** | [`demo/cloudwatch-dashboard.png`](../demo/cloudwatch-dashboard.png) |

---

## 5. Vulnerability Management – Firmware Integrity (Section 6.6)

### 5.1 Firmware Hash Verification
| Field | Detail |
|-------|--------|
| **Requirement** | Devices shall verify the integrity of firmware before installation. |
| **Implementation** | OTA Job Document includes a `sha256` field. Device computes `hashlib.sha256()` of the downloaded firmware and compares against the expected hash. Installation is aborted on mismatch; job marked `FAILED` with reason `Hash verification failed`. |
| **Evidence** | [`device-simulator/simulator.py`](../device-simulator/simulator.py) → `TrailerSimulator._handle_ota_job()` |

### 5.2 Firmware Signed URL
| Field | Detail |
|-------|--------|
| **Requirement** | Firmware download links shall be access-controlled and time-limited. |
| **Implementation** | Firmware files stored in private S3 bucket with all public access blocked. Download URL generated as a pre-signed S3 URL (valid 1 hour) and embedded in the OTA Job Document. |
| **Evidence** | [`scripts/rotate-cert.sh`](../scripts/rotate-cert.sh) → `aws s3 presign` usage |

---

## 6. Secure Update Mechanism (Section 6.7)

### 6.1 OTA Update Channel
| Field | Detail |
|-------|--------|
| **Requirement** | Firmware updates shall be delivered over a secure, authenticated channel. |
| **Implementation** | Updates delivered via AWS IoT Jobs over mTLS-authenticated MQTT. Device receives job on `$aws/things/{id}/jobs/notify-next`. Job execution status reported back to IoT Jobs API. |
| **Evidence** | [`device-simulator/simulator.py`](../device-simulator/simulator.py) → `_handle_ota_job()`, `_update_job_status()` |

### 6.2 Rollback Capability
| Field | Detail |
|-------|--------|
| **Requirement** | A failed update shall not leave the device in an unrecoverable state. |
| **Implementation** | `self.firmware_version` is updated only after successful hash verification and simulated install. On failure, function returns early; previous version remains active; job status set to `FAILED`. |
| **Evidence** | [`device-simulator/simulator.py`](../device-simulator/simulator.py) → `_handle_ota_job()` early return on hash mismatch |

---

## Summary Matrix

| ISO 24241 Section | Control | Status |
|-------------------|---------|--------|
| 6.2 Authentication | X.509 device identity (mTLS) | ✅ Implemented |
| 6.2 Authentication | Certificate expiry/renewal automation | ✅ Runbook + script created |
| 6.3 Authorization | Device least privilege (IoT Policy) | ✅ Implemented |
| 6.3 Authorization | API key authentication | ✅ Implemented |
| 6.3 Authorization | Lambda IAM least privilege | ✅ Implemented |
| 6.4 Data Protection | TLS 1.2+ in transit (mTLS + HTTPS) | ✅ Implemented |
| 6.4 Data Protection | DynamoDB AES-256 at rest | ✅ Implemented |
| 6.4 Data Protection | S3 AES-256 at rest | ✅ Implemented |
| 6.5 Audit Logging | IoT Core V2 logging (INFO) | ✅ Configured |
| 6.5 Audit Logging | CloudTrail API audit trail | ✅ Configured |
| 6.5 Audit Logging | CloudWatch security dashboard | ✅ Configured |
| 6.6 Vuln Management | Firmware SHA-256 hash verification | ✅ Implemented |
| 6.6 Vuln Management | Time-limited signed firmware URL | ✅ Implemented |
| 6.7 Secure Update | IoT Jobs OTA channel (mTLS) | ✅ Implemented |
| 6.7 Secure Update | Rollback on hash mismatch | ✅ Implemented |

**Legend**: ✅ Implemented  ⚠️ Partial  ❌ Not yet applied
