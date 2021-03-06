#!/usr/bin/env bash

function retryop()
{
  retry=0
  max_retries=10
  interval=30
  while [ ${retry} -lt ${max_retries} ]; do
    echo "Operation: $1, Retry #${retry}"
    eval $1
    if [ $? -eq 0 ]; then
      echo "Successful"
      break
    else
      let retry=retry+1
      echo "Sleep $interval seconds, then retry..."
      sleep $interval
    fi
  done
  if [ ${retry} -eq ${max_retries} ]; then
    echo "Operation failed: $1"
    exit 1
  fi
}

function escape_password() {
  password=$1
  result=""
  for char in $(echo $password | sed -e 's/\(.\)/\1\n/g'); do
    if [ $char == "'" ]; then
      result="${result}'\\''"
    else
      result="${result}${char}"
    fi
  done
  echo $result
}

echo "Installing jq"
retryop "apt-get update && apt-get install -y jq"

function get_setting() {
  key=$1
  local value=$(echo $settings | jq ".$key" -r)
  echo $value
}

custom_data_file="/var/lib/cloud/instance/user-data.txt"
settings=$(cat ${custom_data_file})
tenant_id=$1
client_id=$2
client_secret=$3
environment=$(get_setting ENVIRONMENT)
username=$(get_setting ADMIN_USER_NAME)
home_dir="/home/$username"

# https://bosh.io/docs/cli-v2-install/#additional-dependencies
echo "Installing OS specified dependencies for bosh create-env command"
retryop "apt-get update && apt-get install -y build-essential zlibc zlib1g-dev ruby ruby-dev openssl libxslt-dev libxml2-dev libssl-dev  libreadline-dev libyaml-dev libsqlite3-dev sqlite3"
#libreadline6
echo "Installing BOSH CLI"
bosh_cli_url=$(get_setting BOSH_CLI_URL)
wget $bosh_cli_url
chmod +x ./bosh-cli-*
mv ./bosh-cli-* /usr/local/bin/bosh

echo "Installing Azure CLI"
AZ_REPO=$(lsb_release -cs)
echo "deb [arch=amd64] https://packages.microsoft.com/repos/azure-cli/ $AZ_REPO main" | tee /etc/apt/sources.list.d/azure-cli.list
curl -L https://packages.microsoft.com/keys/microsoft.asc | sudo apt-key add -
retryop "apt-get install apt-transport-https"
retryop "apt-get update && apt-get install azure-cli"


echo "Prepare manifests"
manifests_dir="$home_dir/example_manifests"
mkdir -p $manifests_dir
cp *.yml $manifests_dir
pushd $manifests_dir > /dev/null
  # Enable availability zones if needed
  use_availability_zones=$(get_setting USE_AVAILABILITY_ZONES)
  if [ "$use_availability_zones" == "enabled" ]; then
    sed -i '1,5d' cloud-config.yml
    cat - cloud-config.yml > cloud-config-azs-enabled.yml << EOF
---
azs:
- name: z1
  cloud_properties:
    availability_zone: '1'
- name: z2
  cloud_properties:
    availability_zone: '2'
- name: z3
  cloud_properties:
    availability_zone: '3'
EOF
    mv cloud-config-azs-enabled.yml cloud-config.yml
  fi
  if [ "${service_principal_type}" == "Certificate" ]; then
    cat > service-principal-certificate.yml << EOF
certificate: |-
$(client_secret_or_certificate | sed 's/^/  /')
EOF
  fi
  if [ "$environment" = "AzureStack" ]; then
    if [ "$(get_setting AZURE_STACK_CA_ROOT_CERTIFICATE | base64 --decode)" = "" ]; then
      cat > azure-stack-ca-cert.yml << EOF
ca_cert: |-
$(cat /var/lib/waagent/Certificates.pem | sed 's/^/  /')
EOF
    else
      cat > azure-stack-ca-cert.yml << EOF
ca_cert: |-
$(get_setting AZURE_STACK_CA_ROOT_CERTIFICATE | base64 --decode | sed 's/^/  /')
EOF
    fi
  fi
popd  > /dev/null
chmod 775 $manifests_dir
chmod 644 $manifests_dir/*

echo "Creating the containers (bosh and stemcell) and the table (stemcells) in the default storage account"
default_storage_account=$(get_setting DEFAULT_STORAGE_ACCOUNT_NAME)
default_storage_access_key=$(get_setting STORAGE_ACCESS_KEY)
endpoint_suffix=$(get_setting SERVICE_HOST_BASE)
connection_string="DefaultEndpointsProtocol=https;AccountName=${default_storage_account};AccountKey=${default_storage_access_key};EndpointSuffix=${endpoint_suffix}"
if [ "$environment" = "AzureStack" ]; then
  cat /var/lib/waagent/Certificates.pem >> /etc/ssl/certs/ca-certificates.crt
  export REQUESTS_CA_BUNDLE=/etc/ssl/certs/ca-certificates.crt
  az cloud update --profile 2018-03-01-hybrid
fi
az cloud update --profile 2018-03-01-hybrid
az storage container create --name bosh --connection-string ${connection_string}
az storage container create --name stemcell --public-access blob --connection-string ${connection_string}
az storage table create --name stemcells --connection-string ${connection_string}

echo "Prepare Bosh deployment script"
cat > "deploy_bosh.sh" << EOF
#!/usr/bin/env bash
set -e
export BOSH_LOG_LEVEL="$(get_setting LOG_LEVEL_FOR_BOSH)"
export BOSH_LOG_PATH="./run.log"
bosh create-env ~/example_manifests/bosh.yml \\
  --state=state.json \\
  --vars-store=~/bosh-deployment-vars.yml \\
  -o ~/example_manifests/cpi.yml \\
  -o ~/example_manifests/custom-cpi-release.yml \\
  -o ~/example_manifests/custom-environment.yml \\
  -o ~/example_manifests/use-azure-dns.yml \\
  -o ~/example_manifests/jumpbox-user.yml \\
  -v director_name=azure \\
  -v internal_cidr=$(get_setting SUBNET_ADDRESS_RANGE_FOR_BOSH) \\
  -v internal_gw=$(get_setting SUBNET_GATEWAY_FOR_BOSH) \\
  -v internal_ip=$(get_setting INTERNAL_IP_FOR_BOSH) \\
  -v cpi_release_url=$(get_setting BOSH_AZURE_CPI_RELEASE_URL) \\
  -v cpi_release_sha1=$(get_setting BOSH_AZURE_CPI_RELEASE_SHA1) \\
  -v director_vm_instance_type=$(get_setting BOSH_VM_SIZE) \\
  -v resource_group_name=$(get_setting RESOURCE_GROUP_NAME) \\
  -v vnet_name=$(get_setting VNET_NAME) \\
  -v subnet_name=$(get_setting SUBNET_NAME_FOR_BOSH) \\
  -v default_security_group=$(get_setting NSG_NAME_FOR_BOSH) \\
  -v environment=$(get_setting ENVIRONMENT) \\
  -v subscription_id=$(get_setting SUBSCRIPTION_ID) \\
  -v tenant_id=${tenant_id} \\
  -v client_id=${client_id} \\
  -v client_secret=${client_secret} \\
  -v stemcell_sha1=$(get_setting STEMCELL_SHA1) \\
  -v stemcell_url=$(get_setting STEMCELL_URL) \\
  -v stemcell_release=$(get_setting STEMCELL_RELEASE) \\
EOF

if [ $(get_setting KEEP_UNREACHABLE_VMS) = "true" ]; then
  cat >> "deploy_bosh.sh" <<EOF
  -o ~/example_manifests/keep-failed-or-unreachable-vms.yml \\
EOF
fi

if [ "$environment" = "AzureStack" ]; then
  cat >> "deploy_bosh.sh" << EOF
  -v storage_account_name=$(get_setting DEFAULT_STORAGE_ACCOUNT_NAME) \\
  -o ~/example_manifests/azure-stack-properties.yml \\
  -v azure_stack_domain=$(get_setting AZURE_STACK_DOMAIN) \\
  -v azure_stack_resource=$(get_setting AZURE_STACK_RESOURCE) \\
  -v azure_stack_authentication=$(get_setting AZURE_STACK_AUTHENTICATION) \\
  -l ~/example_manifests/azure-stack-ca-cert.yml
EOF
fi

chmod +x deploy_bosh.sh
cp deploy_bosh.sh $home_dir

echo "Prepare Concourse deployment script"
concourse_worker_disk_size_in_mb=$(($(get_setting CONCOURSE_WORKER_DISK_SIZE)*1024))
cat > "deploy_concourse.sh" <<EOF
export BOSH_ENVIRONMENT=$(get_setting INTERNAL_IP_FOR_BOSH)
export BOSH_CLIENT=admin
export BOSH_CLIENT_SECRET="\$(bosh int ~/bosh-deployment-vars.yml --path /admin_password)"
export BOSH_CA_CERT="\$(bosh int ~/bosh-deployment-vars.yml --path /director_ssl/ca)"


bosh alias-env azure
bosh -e azure login

bosh -n update-cloud-config ~/example_manifests/cloud.yml \\
  -v internal_cidr=$(get_setting SUBNET_ADDRESS_RANGE_FOR_CONCOURSE) \\
  -v internal_gw=$(get_setting SUBNET_GATEWAY_FOR_CONCOURSE) \\
  -v vnet_name=$(get_setting VNET_NAME) \\
  -v subnet_name=$(get_setting SUBNET_NAME_FOR_CONCOURSE) \\
  -v security_group=$(get_setting NSG_NAME_FOR_CONCOURSE) \\
  -v ephemeral_disk_size=${concourse_worker_disk_size_in_mb} 

bosh upload-stemcell --sha1=$(get_setting STEMCELL_SHA1) $(get_setting STEMCELL_URL)
bosh -e azure -n deploy -d concourse ~/example_manifests/concourse.yml \\
  -l ~/example_manifests/versions.yml \\
  --vars-store=~/concourse-deployment-vars.yml \\
  -v deployment_name=concourse \\
  -v network_name=concourse \\
  -v web_vm_type=concourse_web_or_db \\
  -v db_vm_type=concourse_web_or_db \\
  -v db_persistent_disk_type=default \\
  -v worker_vm_type=concourse_worker \\
  -v basic_auth_username=$(get_setting CONCOURSE_USERNAME) \\
  -v basic_auth_password='$(escape_password $(get_setting CONCOURSE_PASSWORD))' \\
  -v web_ip=$(get_setting CONCOURSE_PUBLIC_IP) \\
  -v external_url="http://$(get_setting CONCOURSE_FQDN):8080"\\
  -v stemcell_sha1=$(get_setting STEMCELL_SHA1) \\
  -v stemcell_url=$(get_setting STEMCELL_URL) \\
  -v stemcell_release=$(get_setting STEMCELL_RELEASE) \\
EOF

stemcell_os_version=$(get_setting STEMCELL_OS_VERSION)
if [ "${stemcell_os_version}" = "Trusty" ]; then
    cat >> "deploy_concourse.sh" << EOF
  -o ~/example_manifests/use-compiled-releases.yml \\
EOF
  else
 cp  "${manifests_dir}/concourse-xenial.yml"  "${manifests_dir}/concourse.yml"
# cat >> "deploy_concourse.sh" << EOF
#  -o ~/example_manifests/use-compiled-releases-xenial-stemcell.yml \\
#EOF
fi


chmod +x deploy_concourse.sh
cp deploy_concourse.sh $home_dir

echo "Prepare logging in bosh script"
cat > "login_bosh.sh" <<EOF
#!/usr/bin/env bash
export BOSH_ENVIRONMENT=10.20.0.4
export BOSH_CLIENT=admin
export BOSH_CLIENT_SECRET="\$(bosh int ~/bosh-deployment-vars.yml --path /admin_password)"
export BOSH_CA_CERT="\$(bosh int ~/bosh-deployment-vars.yml --path /director_ssl/ca)"
bosh alias-env azure
bosh -e azure login
EOF

chmod +x login_bosh.sh
cp login_bosh.sh $home_dir

chown -R $username $home_dir

auto_deploy_bosh=$(get_setting AUTO_DEPLOY_BOSH)
if [ "$auto_deploy_bosh" != "enabled" ]; then
  echo "Finish"
  exit 0
fi

echo "Start to run deploy_bosh.sh..."
su -c "./deploy_bosh.sh" - $username
echo "Finish"

auto_deploy_concourse=$(get_setting AUTO_DEPLOY_CONCOURSE)
if [ "$auto_deploy_concourse" != "enabled" ]; then
  echo "Finish"
  exit 0
fi

echo "Start to run deploy_concourse.sh..."
su -c "./deploy_concourse.sh" - $username
echo "Finish"
