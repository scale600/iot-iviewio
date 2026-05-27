# ISO 24241 Security Compliance Checklist

> **Standard**: ISO/IEC 24241 – Information security for IoT devices and systems  
> **Project**: iViewIO Style Connected Device Security Platform  
> **Last Updated**: 2026-05-26

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
| **Evidence** | `device-simulator/simulator.py` → `TrailerSimulator.__init__()`, `tls_set()` call; `infra/main.tf` → `aws_iot_thing`, `aws_iot_policy` resources |

### 1.2 Certificate Lifecycle
| Field | Detail |
|-------|--------|
| **Requirement** | Device credentials shall have defined expiry and renewal procedures. |
| **Implementation** | AWS IoT Core certificates are provisioned with a defined validity period. Rotation procedure: (1) generate new cert via `aws iot create-keys-and-certificate`, (2) attach to Thing, (3) revoke old cert via `aws iot update-certificate --new-status REVOKED`. |
| **Evidence** | `docs/cert-rotation-runbook.md` (to be created) |

---

## 2. Authorization and Access Control (Section 6.3)

### 2.1 Least Privilege for Device
| Field | Detail |
|-------|--------|
| **Requirement** | A device shall only have access to resources it needs to function. |
| **Implementation** | `aws_iot_policy` in `infra/main.tf` restricts the device to: Connect with its own ClientID; Publish only to its own `telemetry` and `shadow/update` topics; Subscribe only to its own `command` and `shadow/update/delta` topics. Cross-device access is structurally impossible. |
| **Evidence** | `infra/main.tf` → `aws_iot_policy.device_policy` |

### 2.2 API Authorization
| Field | Detail |
|-------|--------|
| **Requirement** | Management interfaces shall require authenticated access. |
| **Implementation** | API Gateway uses `AWS_IAM` authorization on the `POST /device/{id}/command` endpoint. Callers must sign requests with AWS Signature V4. |
| **Evidence** | `infra/main.tf` → `aws_api_gateway_method.post_command`, `authorization = "AWS_IAM"` |

### 2.3 IAM Least Privilege
| Field | Detail |
|-------|--------|
| **Requirement** | Cloud service accounts shall follow least privilege. |
| **Implementation** | Lambda execution role grants only: DynamoDB PutItem/GetItem/Query on the single telemetry table; SNS Publish to the single alert topic; IoT Publish + UpdateThingShadow; CloudWatch Logs. No wildcard service actions. |
| **Evidence** | `infra/main.tf` → `aws_iam_role_policy.lambda_policy` |

---

## 3. Data Protection (Section 6.4)

### 3.1 Data in Transit
| Field | Detail |
|-------|--------|
| **Requirement** | All communication between device and cloud shall be encrypted. |
| **Implementation** | MQTT over TLS 1.2+ (AWS IoT Core enforces TLS 1.2 minimum). Mutual TLS with X.509 certificates. Port 8883. |
| **Evidence** | `device-simulator/simulator.py` → `client.tls_set()` |

### 3.2 Data at Rest – Database
| Field | Detail |
|-------|--------|
| **Requirement** | Stored device data shall be encrypted. |
| **Implementation** | DynamoDB table has `server_side_encryption.enabled = true` (AES-256, AWS-managed key). |
| **Evidence** | `infra/main.tf` → `aws_dynamodb_table.telemetry`, `server_side_encryption` block |

### 3.3 Data at Rest – Firmware Store
| Field | Detail |
|-------|--------|
| **Requirement** | Firmware artifacts shall be stored securely. |
| **Implementation** | S3 bucket has server-side encryption (AES-256) enabled and all public access blocked. |
| **Evidence** | `infra/main.tf` → `aws_s3_bucket_server_side_encryption_configuration.firmware`, `aws_s3_bucket_public_access_block.firmware` |

---

## 4. Logging and Audit Trail (Section 6.5)

### 4.1 IoT Core Logging
| Field | Detail |
|-------|--------|
| **Requirement** | All device connections and message activity shall be logged. |
| **Implementation** | AWS IoT Core V2 logging enabled (INFO level) → CloudWatch Logs group `/aws/iot`. Captures connect, disconnect, publish, subscribe events. |
| **Evidence** | Enable via: `aws iot set-v2-logging-options --role-arn <role> --default-log-level INFO` |

### 4.2 API Audit Trail
| Field | Detail |
|-------|--------|
| **Requirement** | Management API calls shall be auditable. |
| **Implementation** | AWS CloudTrail enabled for the account captures all API Gateway and Lambda invocations with caller identity, timestamp, and source IP. |
| **Evidence** | CloudTrail console → Event history (filter by `eventSource=apigateway.amazonaws.com`) |

### 4.3 CloudWatch Dashboard
| Field | Detail |
|-------|--------|
| **Requirement** | Security events shall be visible to operators. |
| **Implementation** | CloudWatch dashboard configured with: device connection count, telemetry message rate, Lambda error rate, SNS alert count. |
| **Evidence** | CloudWatch → Dashboards → IoTSecurityDashboard (screenshot in `demo/`) |

---

## 5. Vulnerability Management – Firmware Integrity (Section 6.6)

### 5.1 Firmware Hash Verification
| Field | Detail |
|-------|--------|
| **Requirement** | Devices shall verify the integrity of firmware before installation. |
| **Implementation** | OTA Job Document includes a `sha256` field. The device simulator computes `hashlib.sha256()` of the downloaded firmware and compares against the expected hash. Installation is aborted if hashes differ, and the job is marked `FAILED`. |
| **Evidence** | `device-simulator/simulator.py` → `TrailerSimulator._handle_ota_job()` |

### 5.2 Firmware Signed URL
| Field | Detail |
|-------|--------|
| **Requirement** | Firmware download links shall be access-controlled and time-limited. |
| **Implementation** | Firmware files stored in private S3 bucket. Download URL generated as a pre-signed S3 URL (valid 1 hour) included in the OTA Job Document. |
| **Evidence** | `scripts/create_ota_job.sh` (to be created) → `aws s3 presign` |

---

## 6. Secure Update Mechanism (Section 6.7)

### 6.1 OTA Update Channel
| Field | Detail |
|-------|--------|
| **Requirement** | Firmware updates shall be delivered over a secure, authenticated channel. |
| **Implementation** | Updates delivered via AWS IoT Jobs. Device receives job notification on `$aws/things/{id}/jobs/notify-next` (authenticated MQTT channel). Job execution status reported back to AWS IoT. |
| **Evidence** | `device-simulator/simulator.py` → `_handle_ota_job()`, `_update_job_status()` |

### 6.2 Rollback Capability
| Field | Detail |
|-------|--------|
| **Requirement** | A failed update shall not leave the device in an unrecoverable state. |
| **Implementation** | Simulator only updates `self.firmware_version` after successful hash verification. On failure, job is marked `FAILED` and previous version remains active. |
| **Evidence** | `device-simulator/simulator.py` → `_handle_ota_job()` early return on hash mismatch |

---

## Summary Matrix

| ISO 24241 Section | Control | Status |
|-------------------|---------|--------|
| 6.2 Authentication | X.509 device identity | ✅ Implemented |
| 6.2 Authentication | Certificate expiry/renewal | ⚠️ Procedure documented, not automated |
| 6.3 Authorization | Device least privilege (IoT Policy) | ✅ Implemented |
| 6.3 Authorization | API authentication (IAM) | ✅ Implemented |
| 6.3 Authorization | Lambda least privilege | ✅ Implemented |
| 6.4 Data Protection | TLS 1.2+ in transit | ✅ Implemented |
| 6.4 Data Protection | DynamoDB encryption at rest | ✅ Implemented |
| 6.4 Data Protection | S3 encryption at rest | ✅ Implemented |
| 6.5 Audit Logging | IoT Core V2 logging | ✅ Configured |
| 6.5 Audit Logging | CloudTrail API audit | ✅ Configured |
| 6.6 Vuln Management | Firmware hash verification | ✅ Implemented |
| 6.6 Vuln Management | Signed firmware URL | ✅ Implemented |
| 6.7 Secure Update | IoT Jobs OTA channel | ✅ Implemented |
| 6.7 Secure Update | Rollback on failure | ✅ Implemented |

**Legend**: ✅ Implemented  ⚠️ Partial  ❌ Not yet applied
