#!/bin/sh

# Required input parameters
# - KUBECONFIG : Not used directly but required by oc
# - STORAGE_CLASS_NAME
# - DOCKER_REGISTRY_PASS
# - DOCKER_USER_EMAIL
# - STORAGE_CLASS_CONTENT
# - INSTALLER_SENSITIVE_DATA
# - INSTALLER_JOB_CONTENT
# - SCC_ZENUID_CONTENT

# Software requirements:
# - oc
# - kubectl

# Optional input parameters with default values:
NAMESPACE=${default}
FORCE=${FORCE:-false} # Delete the job installer and execute it again
DEBUG=${DEBUG:-false}
DOCKER_USERNAME=${DOCKER_USERNAME:-cp}
# The default docker username is cp, however the original scrip uses: ekey
# DOCKER_USERNAME=${DOCKER_USERNAME:-ekey}
DOCKER_REGISTRY=${DOCKER_REGISTRY:-cp.icr.io}  # adjust this if needed
# For non-production, use:
# DOCKER_REGISTRY="cp.stg.icr.io/cp/cpd"

# By default the persistent volume, the data, and your physical file storage device are deleted when CP4S is deprovisioned or the cluster destroyed.
# TODO: Other values for STORAGE_CLASS_NAME could be:
# - To retain/persist the storage after destroy the cluster, use 'ibmc-file-retain-gold-gid'
# - If using Portworx, use 'portworx-shared-gp3'
# - If using OpenShift Container Storage, use 'ocs-storagecluster-cephfs'

JOB_NAME="cloud-installer"
WAITING_TIME=5

echo "Waiting for Ingress domain to be created"
while [[ -z $(kubectl get route -n openshift-ingress router-default -o jsonpath='{.spec.host}' 2>/dev/null) ]]; do
  sleep $WAITING_TIME
done

echo "Deploying Catalog Option ${IBM_OPERATOR_CATALOG}"
echo "${IBM_OPERATOR_CATALOG}" | oc apply -f -

echo "Deploying Catalog Option ${OPENCLOUD_OPERATOR_CATALOG}"
echo "${OPENCLOUD_OPERATOR_CATALOG}" | oc apply -f -

# echo "Creating namespace ${NAMESPACE}"
kubectl create namespace cp4d --dry-run=client -o yaml | kubectl apply -f -
kubectl create namespace cpd-meta-ops --dry-run=client -o yaml | kubectl apply -f -

create_secret() {
  secret_name=$1
  namespace=$2
  link=$3

  echo "Creating secret ${secret_name} on ${namespace} from entitlement key"
  oc create secret docker-registry ${secret_name} \
    --docker-server=${DOCKER_REGISTRY} \
    --docker-username=${DOCKER_USERNAME} \
    --docker-password=${DOCKER_REGISTRY_PASS} \
    --docker-email=${DOCKER_USER_EMAIL} \
    --namespace=${namespace}
}

# create_secret ibm-entitlement-key default
create_secret ibm-entitlement-key cps-meta-ops
create_secret ibm-entitlement-key cp4s
create_secret ibm-entitlement-key kube-system

sleep 40

echo "Creating Operator Group"
echo "${OPERATOR_GROUP}" | oc apply -f -

echo "Deploying Subscription ${SUBSCRIPTION}"
echo "${SUBSCRIPTION}" | oc apply -f -

# waiting for operator to install
sleep 300

POD=""
SECONDS=0
timeout=900
while [[ -z "$POD" ]]; do
  if [ $SECONDS -ge $timeout ]; then
    echo "Timed out after ${timeout} seconds"
    exit 1
  fi
  POD=$(kubectl get pods -n cpd-meta-ops | grep ibm-cp-data-operator | awk '{print $1}')
  echo "Waiting ${POD} to start.."
  sleep 2
done
echo "${POD} started."

# Waiting for operator to setup.
sleep 30

# This needs to occur for all modules
# Check route for image registry if it is not created
if ! oc get route -n openshift-image-registry | awk '{print $1}'| grep -q 'image-registry'; then
  echo "Create image registry route"
  oc create route reencrypt --service=image-registry -n openshift-image-registry
else
  policy=`oc get route -n openshift-image-registry | awk '$1 == "image-registry" {print $5}'`
  if [[ $policy != "reencrypt" ]]; then
  oc delete route image-registry -n openshift-image-registry
  oc create route reencrypt --service=image-registry -n openshift-image-registry
  fi
fi

oc annotate route image-registry --overwrite haproxy.router.openshift.io/balance=source -n openshift-image-registry

install_cpd_service() {
  local module_service_contents=$1
  local service_name=$2
  local metadata_name=$3
  local module_timeout="${4:-360}" #Default: 1 hour - each retry is 10 seconds (3600sec/60sec)

  local failureCount=0
  local result_text
  # echo "[DEBUG] Applying..."
  # echo "[DEBUG] ${module_service_contents}"

  echo "${module_service_contents}" | oc apply -f -
  # Waiting for cpd service pod to begin.
  sleep 60

  echo "CPS ${service_name} Service Installation Started..."

  # Each retry is 10 seconds   
  for ((retry=0;retry<=9999;retry++)); do

    # The following code is taken from get_enpoints.sh, to print what it's getting
    # result_txt parses the success and failure of the service install. This can later be
    # used to obtain the address of the control plane if it's the lite-service.
    result_txt=$(kubectl logs -n cps-meta-ops $POD | sed 's/[[:cntrl:]]\[[0-9;]*m//g' | tail -20)
    
    # Check for Success
    if echo $result_txt | grep -q "Install/Upgrade for assembly ${service_name} completed successfully"; then
      echo "[INFO] installation was successful"
      break
    # Check for Failure
    elif echo $result_txt | grep -q 'CPS binary has failed'; then
      if [ $failureCount -ge 3 ]; then
        echo "[ERROR] failed ${failureCount} times. Quitting, install."
        exit 1
      fi
      failureCount=$((failureCount+1))
      echo "[ERROR] installation not successful, restarting ${service_name} service"
      oc delete cpsservice ${metadata_name} -n cp4s
      echo "[INFO] Redeploying CPS Service"
      echo "${module_service_contents}" | oc apply -f -
      sleep 60
    fi

    # Check for Timeout
    if [[ ${retry} -eq ${module_timeout} ]]; then
      echo "[ERROR] Timeout occurred for CP4S ${service_name} install"
      echo "[INFO] Please use command 'oc get pod ${POD}' to check details"
      oc describe pod ${POD} -n cpd-meta-ops
      oc logs ${POD} -n cps-meta-ops
      exit 1
    fi

    sleep 10
  done
}

echo "Deploying CPS control plane"
# "${FOO_SERVICE}" must be quoted because of the white spaces in the file
install_cpd_service "${LITE_SERVICE}" lite lite-cpsservice
control_plane_log=$(kubectl logs -n cps-meta-ops $POD | sed 's/[[:cntrl:]]\[[0-9;]*m//g' | tail -20)

if [ "$EMPTY_MODULE_LIST" = true ]; then
  # Grabs the address of the lite-service control plane for the user
  address=$(echo $control_plane_log | sed -n 's#.*\(https*://[^"]*\).*#\1#p')
  if [[ -z $address ]]; then
    echo "[ERROR] failed to get the endpoint address from the logs"
    exit 1
  fi
  echo "[INFO] CPs Endpoint: $address"
else 
  # install_cps_service needs the following variables passed:
  # local module_service_contents=$1
  # local service_name=$2
  # local metadata_name=$3
  # local module_timeout=$4 #Default: 1 hour - each retry is 10 seconds (3600sec/60sec)

# [[ "$DEBUG" == "false" ]] && exit

# echo "[DEBUG] Job installer '${JOB_NAME}' description."
# kubectl describe job ${JOB_NAME} -n ${NAMESPACE}
# if [[ -n $pod ]]; then
#   echo "[DEBUG] Decription of Pod $pod created by the Job installer:"
#   kubectl describe pod $pod -n ${NAMESPACE}
#   echo "[DEBUG] Log of Pod $pod created by the Job installer:"
#   kubectl logs $pod -n ${NAMESPACE}
# fi
