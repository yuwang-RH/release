#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

# save the exit code for junit xml file generated in step gather-must-gather
# pre configuration steps before running installation, exit code 100 if failed,
# save to install-pre-config-status.txt
# post check steps after cluster installation, exit code 101 if failed,
# save to install-post-check-status.txt
EXIT_CODE=101
trap 'if [[ "$?" == 0 ]]; then EXIT_CODE=0; fi; echo "${EXIT_CODE}" > "${SHARED_DIR}/install-post-check-status.txt"' EXIT TERM

# set the parameters we'll need as env vars
AZURE_AUTH_LOCATION="${CLUSTER_PROFILE_DIR}/osServicePrincipal.json"
AZURE_AUTH_CLIENT_ID="$(<"${AZURE_AUTH_LOCATION}" jq -r .clientId)"
AZURE_AUTH_CLIENT_SECRET="$(<"${AZURE_AUTH_LOCATION}" jq -r .clientSecret)"
AZURE_AUTH_TENANT_ID="$(<"${AZURE_AUTH_LOCATION}" jq -r .tenantId)"
AZURE_AUTH_SUBSCRIPTION_ID="$(<"${AZURE_AUTH_LOCATION}" jq -r .subscriptionId)"

# log in with az
if [[ "${CLUSTER_TYPE}" == "azuremag" ]]; then
    az cloud set --name AzureUSGovernment
elif [[ "${CLUSTER_TYPE}" == "azurestack" ]]; then
    if [ ! -f "${CLUSTER_PROFILE_DIR}/cloud_name" ]; then
        echo "Unable to get specific ASH cloud name!"
        exit 1
    fi
    cloud_name=$(< "${CLUSTER_PROFILE_DIR}/cloud_name")

    AZURESTACK_ENDPOINT=$(cat "${SHARED_DIR}"/AZURESTACK_ENDPOINT)
    SUFFIX_ENDPOINT=$(cat "${SHARED_DIR}"/SUFFIX_ENDPOINT)

    if [[ -f "${CLUSTER_PROFILE_DIR}/ca.pem" ]]; then
        cp "${CLUSTER_PROFILE_DIR}/ca.pem" /tmp/ca.pem
        cat /usr/lib64/az/lib/python*/site-packages/certifi/cacert.pem >> /tmp/ca.pem
        export REQUESTS_CA_BUNDLE=/tmp/ca.pem
    fi
    az cloud register \
        -n ${cloud_name} \
        --endpoint-resource-manager "${AZURESTACK_ENDPOINT}" \
        --suffix-storage-endpoint "${SUFFIX_ENDPOINT}"
    az cloud set --name ${cloud_name}
    az cloud update --profile 2019-03-01-hybrid
else
    az cloud set --name AzureCloud
fi
az login --service-principal -u "${AZURE_AUTH_CLIENT_ID}" -p "${AZURE_AUTH_CLIENT_SECRET}" --tenant "${AZURE_AUTH_TENANT_ID}" --output none
az account set --subscription ${AZURE_AUTH_SUBSCRIPTION_ID}

function property_check() {
    local node_name=$1
    local property=$2
    local expected_value=$3
    local profile=$4

    [[ -z "${expected_value}" ]] && { echo "${property} is not configured on ${node_name}, skip!"; return 0; }
    actual_value=$(cat ${profile} | jq -r ".${property}")
    [[ "${expected_value}" == "Disabled" ]] && [[ "${actual_value}" == "false" ]] && { echo "property ${property} check - expected value ${expected_value} - passed!"; return 0; }
    [[ "${expected_value}" == "Enabled" ]] && [[ "${actual_value}" == "true" ]] && { echo "property ${property} check - expected value ${expected_value} - passed!"; return 0; }
    [[ "${expected_value}" == "${actual_value}" ]] && [[ "${actual_value}" != "null" ]] && { echo "property ${property} check - expected value ${expected_value} - passed!"; return 0; }
    [[ "${expected_value}" == "false" ]] && ([[ "${actual_value}" == "null" ]] || [[ "${actual_value}" == "false" ]]) && { echo "property ${property} check - expected value ${expected_value} - passed!"; return 0; }

    echo "ERROR: property ${property} on node ${node_name} compared failed, expected value: ${expected_value}, actual value: ${actual_value}"
    return 1
}

function vm_confidential_check() {

    local node=$1 encryptionathost=$2 security_type=$3 secure_boot=$4 vtpm=$5 osdisk_set=$6
    local check_result=0

    echo "--- check node ${node} ---"
    security_profile_output=$(mktemp)
    az vm show -n "${node}" -g "${RESOURCE_GROUP}" -ojson | jq -r '.securityProfile' 1>"${security_profile_output}"

    echo "DEBUG: node ${node} security profile"
    cat "${security_profile_output}"

    if [[ -n "${osdisk_set}" ]]; then
        osdisk_security_profile_output=$(mktemp)
        az vm show -n "${node}" -g "${RESOURCE_GROUP}" -ojson | jq -r '.storageProfile.osDisk.managedDisk.securityProfile' 1>"${osdisk_security_profile_output}"
        echo "DEBUG: node ${node} osdisk security profile"
        cat "${osdisk_security_profile_output}"
        property_check "${node}" "securityEncryptionType" "${osdisk_set}" "${osdisk_security_profile_output}" || check_result=1
        rm -rf "${osdisk_security_profile_output}"
    fi

    property_check "${node}" "encryptionAtHost" "${encryptionathost}" "${security_profile_output}" || check_result=1
    property_check "${node}" "securityType" "${security_type}" "${security_profile_output}" || check_result=1
    property_check "${node}" "uefiSettings.secureBootEnabled" "${secure_boot}" "${security_profile_output}" || check_result=1
    property_check "${node}" "uefiSettings.vTpmEnabled" "${vtpm}" "${security_profile_output}" || check_result=1

    rm -f "${security_profile_output}"
    return ${check_result}
}

if test -f "${SHARED_DIR}/proxy-conf.sh"
then
    # shellcheck disable=SC1090
    source "${SHARED_DIR}/proxy-conf.sh"
fi

INSTALL_CONFIG="${SHARED_DIR}/install-config.yaml"
INFRA_ID=$(jq -r .infraID ${SHARED_DIR}/metadata.json)
RESOURCE_GROUP=$(yq-go r "${INSTALL_CONFIG}" 'platform.azure.resourceGroupName')
if [[ -z "${RESOURCE_GROUP}" ]]; then
    RESOURCE_GROUP="${INFRA_ID}-rg"
fi

critical_check_result=0

# machine check
# expected values are from step `ipi-conf-azure-confidential-trustedlaunch`
master_encryptionathost=""
master_security_type=""
master_secure_boot=""
master_vtpm=""
master_osdisk_securityencryptiontype=""
worker_encryptionathost=""
worker_security_type=""
worker_secure_boot=""
worker_vtpm=""
worker_osdisk_securityencryptiontype=""
if [[ "${ENABLE_CONFIDENTIAL_DEFAULT_MACHINE}" == "true" ]]; then
    master_encryptionathost=$(yq-go r "${INSTALL_CONFIG}" 'platform.azure.defaultMachinePlatform.encryptionAtHost')
    master_security_type=$(yq-go r "${INSTALL_CONFIG}" 'platform.azure.defaultMachinePlatform.settings.securityType')
    master_secure_boot=$(yq-go r "${INSTALL_CONFIG}" "platform.azure.defaultMachinePlatform.settings.${master_security_type,}.uefiSettings.secureBoot")
    master_vtpm=$(yq-go r "${INSTALL_CONFIG}" "platform.azure.defaultMachinePlatform.settings.${master_security_type,}.uefiSettings.virtualizedTrustedPlatformModule")
    worker_encryptionathost="${master_encryptionathost}"
    worker_security_type="${master_security_type}"
    worker_secure_boot="${master_secure_boot}"
    worker_vtpm="${master_vtpm}"
    master_osdisk_securityencryptiontype=$(yq-go r "${INSTALL_CONFIG}" 'platform.azure.defaultMachinePlatform.osDisk.securityProfile.securityEncryptionType')
    worker_osdisk_securityencryptiontype="${master_osdisk_securityencryptiontype}"
fi

if [[ "${ENABLE_CONFIDENTIAL_CONTROL_PLANE}" == "true" ]]; then
    master_encryptionathost=$(yq-go r "${INSTALL_CONFIG}" 'controlPlane.platform.azure.encryptionAtHost')
    master_security_type=$(yq-go r "${INSTALL_CONFIG}" 'controlPlane.platform.azure.settings.securityType')
    master_secure_boot=$(yq-go r "${INSTALL_CONFIG}" "controlPlane.platform.azure.settings.${master_security_type,}.uefiSettings.secureBoot")
    master_vtpm=$(yq-go r "${INSTALL_CONFIG}" "controlPlane.platform.azure.settings.${master_security_type,}.uefiSettings.virtualizedTrustedPlatformModule")
    master_osdisk_securityencryptiontype=$(yq-go r "${INSTALL_CONFIG}" 'controlPlane.platform.azure.osDisk.securityProfile.securityEncryptionType')
fi

if [[ "${ENABLE_CONFIDENTIAL_COMPUTE}" == "true" ]]; then
    worker_encryptionathost=$(yq-go r "${INSTALL_CONFIG}" 'compute[0].platform.azure.encryptionAtHost')
    worker_security_type=$(yq-go r "${INSTALL_CONFIG}" 'compute[0].platform.azure.settings.securityType')
    worker_secure_boot=$(yq-go r "${INSTALL_CONFIG}" "compute[0].platform.azure.settings.${worker_security_type,}.uefiSettings.secureBoot")
    worker_vtpm=$(yq-go r "${INSTALL_CONFIG}" "compute[0].platform.azure.settings.${worker_security_type,}.uefiSettings.virtualizedTrustedPlatformModule")
    worker_osdisk_securityencryptiontype=$(yq-go r "${INSTALL_CONFIG}" 'compute[0].platform.azure.osDisk.securityProfile.securityEncryptionType')
fi

master_nodes_list=$(oc get nodes --selector='node-role.kubernetes.io/master' --no-headers | awk '{print $1}')
for node in ${master_nodes_list}; do
    if vm_confidential_check "${node}" "${master_encryptionathost}" "${master_security_type}" "${master_secure_boot}" "${master_vtpm}" "${master_osdisk_securityencryptiontype}"; then
        echo -e "INFO: confidentail check on node ${node} passed!\n"
    else
        echo -e "ERROR: confidentail check on node ${node} failed!\n"
        critical_check_result=1
    fi   
done

worker_nodes_list=$(oc get nodes --selector='node-role.kubernetes.io/worker' --no-headers | awk '{print $1}')
for node in ${worker_nodes_list}; do
    if vm_confidential_check "${node}" "${worker_encryptionathost}" "${worker_security_type}" "${worker_secure_boot}" "${worker_vtpm}" "${worker_osdisk_securityencryptiontype}"; then
        echo -e "INFO: confidentail check on node ${node} passed!\n"
    else
        echo -e "ERROR: confidentail check on node ${node} failed!\n"
        critical_check_result=1
    fi
done

# gen2 image definition check
echo -e "\nGen2 image definition check..."
ocp_minor_version=$(oc version -o json | jq -r '.openshiftVersion' | cut -d '.' -f2)
expected_image_security_type="${master_security_type:-$worker_security_type}"
expected_image_security_type="${expected_image_security_type/VM/Vm}"
if (( ${ocp_minor_version} > 16 )); then
    expected_image_security_type="${expected_image_security_type}Supported"
fi
image_def_security_type=$(az sig image-definition show --gallery-image-definition ${INFRA_ID}-gen2 --gallery-name gallery_${INFRA_ID//-/_} -g ${RESOURCE_GROUP} --query "features[?name=='SecurityType'].value" -otsv)
if [[ "${image_def_security_type}" == "${expected_image_security_type}" ]]; then
    echo "INFO: Gen2 image defintion has expected feature setting!"
else
    echo "ERROR: Gen2 image definition has unexpected feature setting, expected feature: ${expected_image_security_type}, actual vaule: ${image_def_security_type}."
    critical_check_result=1
fi

exit ${critical_check_result}
