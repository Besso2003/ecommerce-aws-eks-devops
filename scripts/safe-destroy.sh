#!/usr/bin/env bash
#
# safe-destroy.sh
#
# Runs "terraform destroy" for an environment, watches its output
# live, and automatically detects and cleans up leftover Kubernetes-
# created classic ELBs and their security groups the moment destroy
# gets stuck on the Internet Gateway / VPC deletion step - the same
# manual intervention this project has needed repeatedly, now done
# automatically while destroy is still running in the background.
#
# Usage:
#   ./safe-destroy.sh dev
#   ./safe-destroy.sh prod
#
# How it works:
#   1. Deletes Kubernetes-managed resources for the environment
#   2. Starts "terraform destroy" in the BACKGROUND, streaming its
#      output to both the screen and a log file
#   3. Watches the log file for the specific line that indicates a
#      stuck Internet Gateway or VPC deletion
#   4. The moment that pattern is seen repeating, looks up the
#      environment's VPC, finds and deletes any leftover classic
#      ELB and its "k8s-elb-*" security group
#   5. terraform destroy's own internal retry logic picks up the
#      now-cleared dependency and finishes normally - this script
#      never needs to restart or re-run terraform itself
#
# Safe to run even if nothing gets stuck - if destroy finishes
# cleanly, the watcher just exits without ever needing to intervene.

set -uo pipefail

ENVIRONMENT="${1:-}"
REGION="eu-north-1"

if [[ -z "$ENVIRONMENT" ]]; then
  echo "Usage: $0 <dev|prod|platform>"
  exit 1
fi

if [[ "$ENVIRONMENT" != "dev" && "$ENVIRONMENT" != "prod" && "$ENVIRONMENT" != "platform" ]]; then
  echo "Error: environment must be one of: dev, prod, platform"
  exit 1
fi

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TF_DIR="$REPO_ROOT/Terraform/environments/$ENVIRONMENT"
VPC_NAME="ecommerce-${ENVIRONMENT}-vpc"
LOG_FILE="/tmp/safe-destroy-${ENVIRONMENT}-$(date +%s).log"

echo "=============================================="
echo " Safe destroy: $ENVIRONMENT"
echo " Log file: $LOG_FILE"
echo "=============================================="

# ---------------------------------------------------------------
# Step 1: Delete Kubernetes-managed resources (if a k8s overlay
# exists for this environment - platform has no app overlay)
# ---------------------------------------------------------------
K8S_OVERLAY="$REPO_ROOT/k8s/overlays/$ENVIRONMENT"
if [[ -d "$K8S_OVERLAY" ]]; then
  echo ""
  echo "--- Step 1: Deleting Kubernetes resources for $ENVIRONMENT ---"
  kubectl delete -k "$K8S_OVERLAY" --ignore-not-found=true --timeout=120s || true
  echo "Giving the cluster a moment before starting terraform destroy..."
  sleep 20
else
  echo ""
  echo "--- No k8s overlay found for '$ENVIRONMENT' - skipping Kubernetes cleanup ---"
fi

# ---------------------------------------------------------------
# Step 2: Start terraform destroy in the background, logging to
# a file we can watch live
# ---------------------------------------------------------------
echo ""
echo "--- Step 2: Starting terraform destroy in the background ---"
cd "$TF_DIR"

terraform destroy -auto-approve 2>&1 | tee "$LOG_FILE" &
DESTROY_PID=$!

echo "terraform destroy started (PID $DESTROY_PID). Watching for stuck IGW/VPC..."

# ---------------------------------------------------------------
# Step 3: Watch the log for the stuck pattern while destroy runs.
# A genuinely stuck IGW/VPC repeats the SAME "Still destroying..."
# line every ~10s for minutes. We treat 7+ checks of an IGW or
# VPC line appearing (i.e. ~70+ seconds of sitting on that resource)
# as the signal to intervene.
# ---------------------------------------------------------------
CLEANED_UP=false
IGW_REPEAT_COUNT=0

while kill -0 "$DESTROY_PID" 2>/dev/null; do
  sleep 10

  CURRENT_IGW_LINE=$(grep -E "aws_internet_gateway.*Still destroying|aws_vpc\.main: Still destroying" "$LOG_FILE" 2>/dev/null | tail -1)

  if [[ -n "$CURRENT_IGW_LINE" ]]; then
    IGW_REPEAT_COUNT=$((IGW_REPEAT_COUNT + 1))
  else
    IGW_REPEAT_COUNT=0
  fi

  if [[ "$CLEANED_UP" == false && $IGW_REPEAT_COUNT -ge 7 ]]; then
    echo ""
    echo ">>> Detected a stuck Internet Gateway / VPC deletion."
    echo ">>> Checking for leftover ELBs and security groups in the background..."
    CLEANED_UP=true

    VPC_ID=$(aws ec2 describe-vpcs \
      --region "$REGION" \
      --filters "Name=tag:Name,Values=$VPC_NAME" \
      --query 'Vpcs[0].VpcId' \
      --output text 2>/dev/null)

    if [[ -z "$VPC_ID" || "$VPC_ID" == "None" ]]; then
      echo ">>> Could not find VPC '$VPC_NAME' - nothing to clean up."
    else
      echo ">>> Found VPC: $VPC_ID"

      ELB_NAMES=$(aws elb describe-load-balancers \
        --region "$REGION" \
        --query "LoadBalancerDescriptions[?VPCId=='$VPC_ID'].LoadBalancerName" \
        --output text 2>/dev/null)

      if [[ -n "$ELB_NAMES" ]]; then
        for ELB_NAME in $ELB_NAMES; do
          echo ">>> Deleting leftover ELB: $ELB_NAME"
          aws elb delete-load-balancer \
            --load-balancer-name "$ELB_NAME" \
            --region "$REGION" 2>/dev/null
        done
        echo ">>> Waiting 30s for network interfaces to release..."
        sleep 30
      else
        echo ">>> No leftover classic ELB found."
      fi

      SG_IDS=$(aws ec2 describe-security-groups \
        --region "$REGION" \
        --filters "Name=vpc-id,Values=$VPC_ID" "Name=group-name,Values=k8s-elb-*" \
        --query 'SecurityGroups[*].GroupId' \
        --output text 2>/dev/null)

      if [[ -n "$SG_IDS" ]]; then
        for SG_ID in $SG_IDS; do
          for attempt in 1 2 3 4 5; do
            echo ">>> Deleting leftover security group: $SG_ID (attempt $attempt)"
            if aws ec2 delete-security-group --group-id "$SG_ID" --region "$REGION" 2>/dev/null; then
              echo ">>> Deleted."
              break
            fi
            sleep 10
          done
        done
      else
        echo ">>> No leftover k8s-elb-* security group found."
      fi

      echo ">>> Cleanup pass complete. terraform destroy's own retries should now proceed."
    fi
    echo ""
  fi
done

wait "$DESTROY_PID"
DESTROY_EXIT_CODE=$?

echo ""
echo "=============================================="
if [[ $DESTROY_EXIT_CODE -eq 0 ]]; then
  echo " Safe destroy complete: $ENVIRONMENT"
else
  echo " terraform destroy exited with code $DESTROY_EXIT_CODE"
  echo " Check the log for details: $LOG_FILE"
fi
echo "=============================================="

exit $DESTROY_EXIT_CODE