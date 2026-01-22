#!/bin/bash
  ROLE_ARN=$(terraform output -raw clickhouse_s3_role_arn)
  kubectl apply -f - <<EOF
  apiVersion: v1
  kind: ServiceAccount
  metadata:
    name: clickhouse-s3
    namespace: clickhouse
    annotations:
      eks.amazonaws.com/role-arn: ${ROLE_ARN}
  EOF
