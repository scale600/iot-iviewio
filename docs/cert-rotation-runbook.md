# Device Certificate Rotation Runbook

> **ISO 24241 Reference**: Section 6.2.2 — Credential Expiry and Renewal  
> **Automated script**: [`scripts/rotate-cert.sh`](../scripts/rotate-cert.sh)

## When to Rotate

- Annual rotation (recommended)
- Immediately if private key is suspected compromised
- Before certificate expiry (check with `aws iot describe-certificate`)

## Automated Rotation (Recommended)

```bash
cd /path/to/iot-iviewio
./scripts/rotate-cert.sh Trailer_Sim_01 ./device-simulator/certs
```

The script handles steps 1–5 automatically. See below for manual procedure.

## Steps

### 1. Generate new certificate

```bash
aws iot create-keys-and-certificate \
  --set-as-active \
  --certificate-pem-outfile device-simulator/certs/device_new.pem.crt \
  --public-key-outfile device-simulator/certs/public_new.pem.key \
  --private-key-outfile device-simulator/certs/private_new.pem.key
```

Save the returned `certificateArn` as `NEW_CERT_ARN`.

### 2. Attach new certificate to the Thing and Policy

```bash
aws iot attach-thing-principal \
  --thing-name Trailer_Sim_01 \
  --principal "$NEW_CERT_ARN"

aws iot attach-policy \
  --policy-name TrailerSim01Policy \
  --target "$NEW_CERT_ARN"
```

### 3. Update Terraform to reference new cert

Update `terraform.tfvars`:
```hcl
device_cert_arn = "<NEW_CERT_ARN>"
```

Run `terraform apply` to update the `aws_iot_thing_principal_attachment` and `aws_iot_policy_attachment` resources.

### 4. Swap certs on device and verify connectivity

Rename new cert files to the standard names and restart the simulator:
```bash
mv device-simulator/certs/device_new.pem.crt device-simulator/certs/device.pem.crt
mv device-simulator/certs/private_new.pem.key device-simulator/certs/private.pem.key
python device-simulator/simulator.py --endpoint <IOT_ENDPOINT>
```

Confirm the simulator connects and telemetry flows to DynamoDB.

### 5. Revoke old certificate

```bash
OLD_CERT_ARN="arn:aws:iot:us-east-1:ACCOUNT_ID:cert/OLD_CERT_ID"

aws iot update-certificate \
  --certificate-id "$(basename $OLD_CERT_ARN)" \
  --new-status REVOKED

aws iot detach-thing-principal \
  --thing-name Trailer_Sim_01 \
  --principal "$OLD_CERT_ARN"

aws iot detach-policy \
  --policy-name TrailerSim01Policy \
  --target "$OLD_CERT_ARN"

aws iot delete-certificate \
  --certificate-id "$(basename $OLD_CERT_ARN)"
```

### 6. Securely delete old key files

```bash
rm -P device-simulator/certs/device.pem.crt.bak
rm -P device-simulator/certs/private.pem.key.bak
```
