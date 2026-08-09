#!/bin/bash

set -Eeuo pipefail

REGION="us-east-1"
CLUSTER="mern-eks"
NODEGROUP="mern-workers"
NAMESPACE="mern"
ADDON="amazon-cloudwatch-observability"
ALARM_NAME="mern-eks-worker-high-cpu"

PROJECT_ROOT="$(pwd)"
REPORT="${PROJECT_ROOT}/phase4a-cloudwatch-report.txt"

echo
echo "=============================================================="
echo " PHASE 4A - CLOUDWATCH MONITORING & LOGGING"
echo "=============================================================="

# ==============================================================
# 1. AWS IDENTITY
# ==============================================================

ACCOUNT_ID="$(aws sts get-caller-identity \
    --query Account \
    --output text)"

CALLER_ARN="$(aws sts get-caller-identity \
    --query Arn \
    --output text)"

if [[ -z "${ACCOUNT_ID}" || "${ACCOUNT_ID}" == "None" ]]; then
    echo "ERROR: AWS credentials are not working."
    exit 1
fi

echo
echo "AWS Account : ${ACCOUNT_ID}"
echo "AWS Region  : ${REGION}"
echo "Cluster     : ${CLUSTER}"
echo "Nodegroup   : ${NODEGROUP}"
echo

# ==============================================================
# 2. EKS VALIDATION
# ==============================================================

echo "=============================================================="
echo "1. EKS VALIDATION"
echo "=============================================================="

CLUSTER_STATUS="$(aws eks describe-cluster \
    --name "${CLUSTER}" \
    --region "${REGION}" \
    --query 'cluster.status' \
    --output text)"

if [[ "${CLUSTER_STATUS}" != "ACTIVE" ]]; then
    echo "ERROR: EKS cluster is not ACTIVE."
    echo "Status: ${CLUSTER_STATUS}"
    exit 1
fi

kubectl get nodes -o wide

echo
echo "EKS status: ACTIVE"

# ==============================================================
# 3. NODEGROUP VALIDATION
# ==============================================================

echo
echo "=============================================================="
echo "2. NODEGROUP VALIDATION"
echo "=============================================================="

NODEGROUP_STATUS="$(aws eks describe-nodegroup \
    --cluster-name "${CLUSTER}" \
    --nodegroup-name "${NODEGROUP}" \
    --region "${REGION}" \
    --query 'nodegroup.status' \
    --output text)"

NODE_ROLE_ARN="$(aws eks describe-nodegroup \
    --cluster-name "${CLUSTER}" \
    --nodegroup-name "${NODEGROUP}" \
    --region "${REGION}" \
    --query 'nodegroup.nodeRole' \
    --output text)"

if [[ "${NODEGROUP_STATUS}" != "ACTIVE" ]]; then
    echo "ERROR: Nodegroup is not ACTIVE."
    echo "Status: ${NODEGROUP_STATUS}"
    exit 1
fi

if [[ -z "${NODE_ROLE_ARN}" || "${NODE_ROLE_ARN}" == "None" ]]; then
    echo "ERROR: Could not determine node IAM role."
    exit 1
fi

NODE_ROLE_NAME="${NODE_ROLE_ARN##*/}"

echo "Nodegroup Status : ${NODEGROUP_STATUS}"
echo "Node Role ARN    : ${NODE_ROLE_ARN}"
echo "Node Role Name   : ${NODE_ROLE_NAME}"

# ==============================================================
# 4. CLOUDWATCH IAM POLICY
# ==============================================================

echo
echo "=============================================================="
echo "3. CLOUDWATCH IAM PERMISSIONS"
echo "=============================================================="

CW_POLICY_ARN="arn:aws:iam::aws:policy/CloudWatchAgentServerPolicy"

POLICY_ATTACHED="$(aws iam list-attached-role-policies \
    --role-name "${NODE_ROLE_NAME}" \
    --query "AttachedPolicies[?PolicyArn=='${CW_POLICY_ARN}'].PolicyArn" \
    --output text)"

if [[ -z "${POLICY_ATTACHED}" ]]; then

    echo "CloudWatchAgentServerPolicy is not attached."
    echo "Attaching policy..."

    aws iam attach-role-policy \
        --role-name "${NODE_ROLE_NAME}" \
        --policy-arn "${CW_POLICY_ARN}"

    echo "CloudWatchAgentServerPolicy attached."

else

    echo "CloudWatchAgentServerPolicy already attached."

fi

# ==============================================================
# 5. CHECK CLOUDWATCH ADDON
# ==============================================================

echo
echo "=============================================================="
echo "4. CHECK CLOUDWATCH OBSERVABILITY ADD-ON"
echo "=============================================================="

ADDON_EXISTS="false"

if aws eks describe-addon \
    --cluster-name "${CLUSTER}" \
    --addon-name "${ADDON}" \
    --region "${REGION}" >/tmp/cloudwatch-addon.json 2>/dev/null; then

    ADDON_EXISTS="true"

    ADDON_STATUS="$(jq -r '.addon.status' /tmp/cloudwatch-addon.json)"
    ADDON_VERSION="$(jq -r '.addon.addonVersion' /tmp/cloudwatch-addon.json)"

    echo "Add-on already exists."
    echo "Status : ${ADDON_STATUS}"
    echo "Version: ${ADDON_VERSION}"

else

    echo "CloudWatch Observability add-on is not installed."

fi

# ==============================================================
# 6. INSTALL CLOUDWATCH ADDON
# ==============================================================

echo
echo "=============================================================="
echo "5. INSTALL / UPDATE CLOUDWATCH OBSERVABILITY"
echo "=============================================================="

if [[ "${ADDON_EXISTS}" == "false" ]]; then

    echo "Installing ${ADDON}..."

    aws eks create-addon \
        --cluster-name "${CLUSTER}" \
        --addon-name "${ADDON}" \
        --region "${REGION}" \
        --resolve-conflicts OVERWRITE

else

    echo "CloudWatch add-on already exists."
    echo "No new installation required."

fi

# ==============================================================
# 7. WAIT FOR ADDON
# ==============================================================

echo
echo "=============================================================="
echo "6. WAIT FOR CLOUDWATCH ADD-ON"
echo "=============================================================="

for i in $(seq 1 30); do

    STATUS="$(aws eks describe-addon \
        --cluster-name "${CLUSTER}" \
        --addon-name "${ADDON}" \
        --region "${REGION}" \
        --query 'addon.status' \
        --output text 2>/dev/null || true)"

    echo "Attempt ${i}/30 : ${STATUS}"

    if [[ "${STATUS}" == "ACTIVE" ]]; then
        break
    fi

    if [[ "${STATUS}" == "CREATE_FAILED" ||
          "${STATUS}" == "UPDATE_FAILED" ]]; then

        echo
        echo "ERROR: CloudWatch add-on failed."

        aws eks describe-addon \
            --cluster-name "${CLUSTER}" \
            --addon-name "${ADDON}" \
            --region "${REGION}" \
            --output json

        exit 1
    fi

    sleep 10

done

FINAL_ADDON_STATUS="$(aws eks describe-addon \
    --cluster-name "${CLUSTER}" \
    --addon-name "${ADDON}" \
    --region "${REGION}" \
    --query 'addon.status' \
    --output text)"

if [[ "${FINAL_ADDON_STATUS}" != "ACTIVE" ]]; then
    echo "ERROR: CloudWatch add-on did not become ACTIVE."
    exit 1
fi

ADDON_VERSION="$(aws eks describe-addon \
    --cluster-name "${CLUSTER}" \
    --addon-name "${ADDON}" \
    --region "${REGION}" \
    --query 'addon.addonVersion' \
    --output text)"

echo
echo "CloudWatch Add-on:"
echo "Status : ${FINAL_ADDON_STATUS}"
echo "Version: ${ADDON_VERSION}"

# ==============================================================
# 8. CLOUDWATCH NAMESPACE
# ==============================================================

echo
echo "=============================================================="
echo "7. CLOUDWATCH KUBERNETES RESOURCES"
echo "=============================================================="

kubectl get namespace amazon-cloudwatch \
    --ignore-not-found

echo
kubectl get pods \
    -n amazon-cloudwatch \
    -o wide

echo
kubectl get daemonsets \
    -n amazon-cloudwatch

echo
kubectl get deployments \
    -n amazon-cloudwatch

# ==============================================================
# 9. CHECK CLOUDWATCH AGENT
# ==============================================================

echo
echo "=============================================================="
echo "8. CLOUDWATCH AGENT"
echo "=============================================================="

CW_AGENT_COUNT="$(kubectl get pods \
    -n amazon-cloudwatch \
    -l app.kubernetes.io/name=cloudwatch-agent \
    --no-headers 2>/dev/null | wc -l)"

echo "CloudWatch Agent pod count: ${CW_AGENT_COUNT}"

if [[ "${CW_AGENT_COUNT}" -eq 0 ]]; then

    echo
    echo "CloudWatch agent label not detected."
    echo "Listing all CloudWatch namespace pods:"

    kubectl get pods \
        -n amazon-cloudwatch \
        -o wide

fi

# ==============================================================
# 10. CHECK FLUENT BIT
# ==============================================================

echo
echo "=============================================================="
echo "9. LOG COLLECTION AGENT"
echo "=============================================================="

kubectl get pods \
    -n amazon-cloudwatch \
    -o wide

echo
echo "DaemonSets:"
kubectl get daemonsets \
    -n amazon-cloudwatch

# ==============================================================
# 11. APPLICATION POD STATUS
# ==============================================================

echo
echo "=============================================================="
echo "10. APPLICATION STATUS"
echo "=============================================================="

kubectl get deployments \
    -n "${NAMESPACE}"

echo
kubectl get pods \
    -n "${NAMESPACE}" \
    -o wide

echo
kubectl get services \
    -n "${NAMESPACE}"

# ==============================================================
# 12. FIND WORKER EC2 INSTANCE
# ==============================================================

echo
echo "=============================================================="
echo "11. FIND EKS WORKER EC2 INSTANCE"
echo "=============================================================="

NODE_NAME="$(kubectl get nodes \
    -o jsonpath='{.items[0].metadata.name}')"

echo "Kubernetes Node:"
echo "${NODE_NAME}"

PROVIDER_ID="$(kubectl get node "${NODE_NAME}" \
    -o jsonpath='{.spec.providerID}')"

echo
echo "Provider ID:"
echo "${PROVIDER_ID}"

INSTANCE_ID="$(echo "${PROVIDER_ID}" | awk -F/ '{print $NF}')"

if [[ -z "${INSTANCE_ID}" ]]; then
    echo "ERROR: Could not determine EC2 instance ID."
    exit 1
fi

echo
echo "EC2 Instance:"
echo "${INSTANCE_ID}"

# ==============================================================
# 13. EC2 INSTANCE DETAILS
# ==============================================================

echo
echo "=============================================================="
echo "12. EC2 INSTANCE DETAILS"
echo "=============================================================="

aws ec2 describe-instances \
    --instance-ids "${INSTANCE_ID}" \
    --region "${REGION}" \
    --query 'Reservations[0].Instances[0].{InstanceId:InstanceId,InstanceType:InstanceType,State:State.Name,PrivateIP:PrivateIpAddress,PublicIP:PublicIpAddress}' \
    --output table

# ==============================================================
# 14. CREATE CLOUDWATCH ALARM
# ==============================================================

echo
echo "=============================================================="
echo "13. CREATE CLOUDWATCH CPU ALARM"
echo "=============================================================="

aws cloudwatch put-metric-alarm \
    --alarm-name "${ALARM_NAME}" \
    --alarm-description "Alarm when the EKS worker node CPU exceeds 80 percent" \
    --namespace AWS/EC2 \
    --metric-name CPUUtilization \
    --dimensions Name=InstanceId,Value="${INSTANCE_ID}" \
    --statistic Average \
    --period 300 \
    --evaluation-periods 2 \
    --threshold 80 \
    --comparison-operator GreaterThanThreshold \
    --treat-missing-data notBreaching \
    --region "${REGION}"

echo
echo "CloudWatch alarm created:"
echo "${ALARM_NAME}"

# ==============================================================
# 15. VERIFY ALARM
# ==============================================================

echo
echo "=============================================================="
echo "14. VERIFY CLOUDWATCH ALARM"
echo "=============================================================="

aws cloudwatch describe-alarms \
    --alarm-names "${ALARM_NAME}" \
    --region "${REGION}" \
    --query 'MetricAlarms[].{Name:AlarmName,State:StateValue,Metric:MetricName,Threshold:Threshold}' \
    --output table

# ==============================================================
# 16. WAIT FOR LOG GROUPS
# ==============================================================

echo
echo "=============================================================="
echo "15. CHECK CLOUDWATCH LOG GROUPS"
echo "=============================================================="

echo "Waiting for telemetry ingestion..."

for i in $(seq 1 12); do

    LOG_GROUPS="$(aws logs describe-log-groups \
        --region "${REGION}" \
        --log-group-name-prefix "/aws/containerinsights/${CLUSTER}" \
        --query 'logGroups[].logGroupName' \
        --output text 2>/dev/null || true)"

    if [[ -n "${LOG_GROUPS}" ]]; then
        break
    fi

    echo "Attempt ${i}/12 - no Container Insights log groups yet."
    sleep 15

done

echo
echo "CloudWatch Container Insights log groups:"
aws logs describe-log-groups \
    --region "${REGION}" \
    --log-group-name-prefix "/aws/containerinsights/${CLUSTER}" \
    --query 'logGroups[].{LogGroup:logGroupName,StoredBytes:storedBytes}' \
    --output table || true

# ==============================================================
# 17. CHECK APPLICATION LOGS IN KUBERNETES
# ==============================================================

echo
echo "=============================================================="
echo "16. APPLICATION LOG SAMPLE"
echo "=============================================================="

kubectl logs \
    deployment/hello-service \
    -n "${NAMESPACE}" \
    --tail=20 || true

echo

kubectl logs \
    deployment/profile-service \
    -n "${NAMESPACE}" \
    --tail=20 || true

# ==============================================================
# 18. GENERATE REPORT
# ==============================================================

echo
echo "=============================================================="
echo "17. GENERATE CLOUDWATCH REPORT"
echo "=============================================================="

{
    echo "=============================================================="
    echo "PHASE 4A - CLOUDWATCH REPORT"
    echo "=============================================================="
    echo
    echo "Date          : $(date)"
    echo "AWS Account   : ${ACCOUNT_ID}"
    echo "Region        : ${REGION}"
    echo "Cluster       : ${CLUSTER}"
    echo "Nodegroup     : ${NODEGROUP}"
    echo "Node          : ${NODE_NAME}"
    echo "Instance ID   : ${INSTANCE_ID}"
    echo
    echo "=============================================================="
    echo "CLOUDWATCH ADD-ON"
    echo "=============================================================="
    echo "Status        : ${FINAL_ADDON_STATUS}"
    echo "Version       : ${ADDON_VERSION}"
    echo
    echo "=============================================================="
    echo "KUBERNETES NODES"
    echo "=============================================================="
    kubectl get nodes -o wide
    echo
    echo "=============================================================="
    echo "CLOUDWATCH PODS"
    echo "=============================================================="
    kubectl get pods -n amazon-cloudwatch -o wide
    echo
    echo "=============================================================="
    echo "APPLICATION PODS"
    echo "=============================================================="
    kubectl get pods -n "${NAMESPACE}" -o wide
    echo
    echo "=============================================================="
    echo "APPLICATION SERVICES"
    echo "=============================================================="
    kubectl get services -n "${NAMESPACE}"
    echo
    echo "=============================================================="
    echo "CLOUDWATCH LOG GROUPS"
    echo "=============================================================="
    aws logs describe-log-groups \
        --region "${REGION}" \
        --log-group-name-prefix "/aws/containerinsights/${CLUSTER}" \
        --query 'logGroups[].logGroupName' \
        --output table || true
    echo
    echo "=============================================================="
    echo "CLOUDWATCH ALARM"
    echo "=============================================================="
    aws cloudwatch describe-alarms \
        --alarm-names "${ALARM_NAME}" \
        --region "${REGION}" \
        --output table || true
    echo
    echo "=============================================================="
    echo "PHASE 4A COMPLETE"
    echo "=============================================================="
} | tee "${REPORT}"

echo
echo "=============================================================="
echo " PHASE 4A COMPLETE"
echo "=============================================================="
echo
echo "CloudWatch Add-on : ${FINAL_ADDON_STATUS}"
echo "CloudWatch Version: ${ADDON_VERSION}"
echo "Alarm             : ${ALARM_NAME}"
echo
echo "Report:"
echo "${REPORT}"
echo
echo "NOTE:"
echo "CloudWatch telemetry may take several minutes to appear."
echo
