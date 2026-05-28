# Self-Assessment Report

> **Purpose**: Map iViewIO JD requirements against this project's implementation.  
> **Target Role**: IoT Security Engineer — iViewIO  
> **Project**: iViewIO Style Connected Device Security Platform

---

## 1. JD Requirements ↔ Project Implementation

| JD Requirement | Project Implementation | Evidence |
|----------------|----------------------|----------|
| **IoT device security design** | X.509 mTLS device authentication via AWS IoT Core; unique client certificate per device bound to Thing name | `infra/main.tf` → `aws_iot_policy`, `aws_iot_thing` |
| **MQTT protocol & TLS** | paho-mqtt over TLS 1.2+, port 8883, mutual authentication with CA chain validation | `device-simulator/simulator.py` → `tls_set()` |
| **Cloud platform (AWS)** | AWS IoT Core, Lambda, DynamoDB, API Gateway, S3, SNS, CloudFront, ACM, CloudWatch, CloudTrail | `infra/main.tf` (full IaC) |
| **IaC / Infrastructure automation** | Full Terraform deployment (50+ resources). S3 remote state, GitHub Actions CI/CD | `infra/main.tf`, `.github/workflows/` |
| **Firmware OTA security** | SHA-256 integrity verification before install; time-limited pre-signed S3 URL; rollback on failure | `device-simulator/simulator.py` → `_handle_ota_job()` |
| **Least privilege access control** | Scoped IoT policy per device; Lambda IAM role limited to exact DynamoDB table + SNS topic | `infra/main.tf` → `aws_iot_policy`, `aws_iam_role_policy` |
| **Security audit logging** | IoT V2 CloudWatch logging (INFO); CloudTrail for all API calls; CloudWatch dashboard | Phase 10 |
| **Security standards (ISO/IEC)** | ISO 21434 compliance checklist with evidence per control | `docs/ISO21434-Checklist.md` |
| **REST API design** | API Gateway REST API with API Key auth, throttling, CORS, Lambda proxy integration | `infra/main.tf` → API Gateway resources |
| **CI/CD pipeline** | GitHub Actions: lint (flake8, black, terraform fmt/validate) + deploy (terraform apply + Lambda zip deploy) | `.github/workflows/` |

---

## 2. Interview Answer Drafts

### Q1. How did you implement IoT device authentication?

I used X.509 mTLS on AWS IoT Core. Each device holds a unique client certificate, and both the server and client verify each other's certificates on connection. The IoT Policy restricts each device's topic access to its own device ID, structurally preventing cross-device access. Certificate rotation is automated via `scripts/rotate-cert.sh`, mapping directly to ISO 21434 Clause 8.6 (Vulnerability Management) requirements.

### Q2. What was the most critical aspect of MQTT security?

Two things. First, in the IoT Policy, `iot:Subscribe` and `iot:Receive` require different ARN prefixes — Subscribe uses `topicfilter/`, while Receive requires `topic/`. Mixing them causes AUTHORIZATION_FAILURE. I actually encountered this during development and diagnosed it using CloudWatch IoT V2 logs at DEBUG level. Second, since browsers cannot directly access MQTT, I separated the device control interface into a REST API + API Key approach.

### Q3. How did you secure the OTA update process?

I applied three layers of security. First, firmware files are stored in a private S3 bucket and are only accessible via pre-signed URLs valid for one hour. Second, the OTA Job Document includes a SHA-256 hash; the device verifies integrity after downloading. Third, on hash mismatch, installation is immediately aborted and the IoT Jobs status is reported as FAILED, enabling a full audit trail. I verified this by creating a job with an intentionally wrong hash and confirming the FAILED response.

### Q4. How did you manage AWS infrastructure?

I managed 50+ AWS resources as code using Terraform. The tfstate is stored in an S3 bucket for shared state across environments. GitHub Actions CI/CD is configured to automatically run `terraform plan` on PRs and `terraform apply` + Lambda deployment on main branch merges. Sensitive values (certificate ARNs, email) are injected via GitHub Secrets → Terraform variables, keeping all credentials out of source code.

### Q5. Describe a security issue you diagnosed and fixed.

Lock/Unlock commands were not reaching the device. API calls returned 200 but MQTT messages were never received by the simulator. I enabled AWS IoT Core V2 CloudWatch logging at DEBUG level and found `eventType: Publish-Out, reason: AUTHORIZATION_FAILURE`. The root cause was using `topicfilter/` prefix instead of `topic/` prefix for `iot:Receive` resources in the IoT Policy. The fix was a one-line change in Terraform and resolved immediately after `terraform apply`.

### Q6. How did you resolve the CORS issue?

After migrating the dashboard from direct S3 hosting to `dashboard.iviewio.com` via CloudFront, the lock/unlock buttons stopped working. The browser's CORS preflight (OPTIONS request) was returning 403 from API Gateway because no OPTIONS method was defined. I added OPTIONS methods with MOCK integrations to both the telemetry and command endpoints, returning `Access-Control-Allow-Origin: *` and `Access-Control-Allow-Headers: Content-Type,X-Api-Key` headers, which resolved the issue.
