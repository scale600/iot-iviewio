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
| **Security standards (ISO/IEC)** | ISO 24241 compliance checklist with evidence per control | `docs/ISO24241-Checklist.md` |
| **REST API design** | API Gateway REST API with API Key auth, throttling, CORS, Lambda proxy integration | `infra/main.tf` → API Gateway resources |
| **CI/CD pipeline** | GitHub Actions: lint (flake8, black, terraform fmt/validate) + deploy (terraform apply + Lambda zip deploy) | `.github/workflows/` |

---

## 2. Interview Answer Drafts

### Q1. IoT 디바이스 인증은 어떻게 구현하셨나요?

AWS IoT Core의 X.509 mTLS를 사용했습니다. 각 디바이스는 고유한 클라이언트 인증서를 가지며, 연결 시 서버와 클라이언트가 서로 인증서를 검증합니다. IoT Policy로 디바이스가 접근할 수 있는 topic을 자신의 ID에 한정시켜 cross-device 접근을 구조적으로 차단했습니다. 인증서 교체는 `scripts/rotate-cert.sh`를 통해 자동화했으며, ISO 24241 §6.2 요구사항에 매핑됩니다.

### Q2. MQTT 보안에서 가장 주의한 점은?

두 가지입니다. 첫째, IoT Policy에서 `iot:Subscribe`와 `iot:Receive`에 적용되는 ARN prefix가 다릅니다 — Subscribe는 `topicfilter/`, Receive는 `topic/` prefix를 사용합니다. 이를 혼용하면 AUTHORIZATION_FAILURE가 발생하는데, 실제로 디버깅 과정에서 CloudWatch V2 로그로 원인을 파악하고 수정했습니다. 둘째, 브라우저에서 MQTT 직접 접근이 불가하므로 REST API + API Key 방식으로 디바이스 제어 인터페이스를 분리했습니다.

### Q3. OTA 업데이트 보안은 어떻게 처리했나요?

세 단계로 보안을 적용했습니다. 첫째, 펌웨어 파일은 private S3 버킷에 저장하고 1시간 유효한 pre-signed URL로만 접근 가능하게 했습니다. 둘째, OTA Job Document에 SHA-256 해시를 포함시켜 디바이스가 다운로드 후 무결성을 검증합니다. 셋째, 해시 불일치 시 즉시 설치를 중단하고 IoT Jobs 상태를 FAILED로 보고해 감사 추적이 가능하게 했습니다. 실제로 잘못된 해시로 Job을 생성해 FAILED 반환을 확인했습니다.

### Q4. AWS 인프라를 어떻게 관리하셨나요?

Terraform으로 50여 개의 AWS 리소스를 코드로 관리합니다. tfstate는 S3 버킷에 저장해 팀 공유 상태를 유지합니다. GitHub Actions CI/CD를 구성해 PR 시 `terraform plan`을 자동 실행하고, main 브랜치 머지 시 `terraform apply` + Lambda 배포가 자동화됩니다. 민감한 값(인증서 ARN, 이메일)은 GitHub Secrets → Terraform 변수로 주입해 코드에 하드코딩을 방지했습니다.

### Q5. 보안 이슈를 디버깅한 경험을 말씀해 주세요.

Lock/Unlock 명령이 디바이스에 전달되지 않는 문제가 발생했습니다. API 호출은 성공(200)하지만 MQTT 수신이 안 되는 상황이었습니다. AWS IoT Core V2 CloudWatch 로그를 DEBUG 레벨로 활성화해 `eventType: Publish-Out, reason: AUTHORIZATION_FAILURE`를 확인했습니다. 원인은 IoT Policy에서 `iot:Receive` 리소스에 `topicfilter/` prefix를 잘못 사용한 것이었습니다. `topic/` prefix로 수정 후 즉시 해결됐습니다.

### Q6. CORS 이슈를 어떻게 해결하셨나요?

대시보드를 S3 직접 호스팅에서 `dashboard.iviewio.com` (CloudFront) 으로 이전한 후 lock/unlock 버튼이 동작하지 않았습니다. 브라우저 CORS preflight (OPTIONS 요청)에 API Gateway가 403을 반환했기 때문입니다. API Gateway에 MOCK 통합 방식의 OPTIONS 메서드를 추가하고 `Access-Control-Allow-Origin: *`, `Access-Control-Allow-Headers: Content-Type,X-Api-Key` 응답 헤더를 설정해 해결했습니다.
