#! /bin/bash
################################################################################
# Title           : terraform and ansible script to capture the users argument and
#                 : for deployment scripts
# Author          : Doug Ortiz and Co-authored by Vibhor Kumar
# Date            : Sept 7, 2020
# Version         : 1.0
################################################################################

################################################################################
# quit on any error
set -e
# verify any  undefined shell variables
#set -u

################################################################################
# source common_fucs
################################################################################
DIRECTORY=$(dirname $0)
source ${DIRECTORY}/lib/common_funcs.sh

################################################################################
# function build server
################################################################################
function aws_build_server()
{
    local F_OSNAME="$1"
    local F_REGION="$2"
    local F_INSTANCES="$3"
    local F_KEYPATH="$4"
    local F_PEMINSTANCE="$5"
    local F_PROJECTNAME="$6"
    local F_AMI_ID=""
    local F_INSTANCE_TYPE="c5.2xlarge"
    local F_PRIV_FILE_KEYPATH="$7"
    local F_PUB_KEYNAMEANDEXTENSION=""
    local F_PRIV_KEYNAMEANDEXTENSION=""
    
    process_log "Building AWS Servers"
    cd ${DIRECTORY}/terraform/aws || exit 1
    process_log "including project names in the variables and tags"
    sed "s/PROJECT_NAME/${F_PROJECTNAME}/g" tags.tf.template > tags.tf
    sed "s/PROJECT_NAME/${F_PROJECTNAME}/g" variables.tf.template \
                                        > variables.tf 
   
    case $F_OSNAME in
        "CentOS7")
            shift; 
            F_AMI_ID="ami-0bc06212a56393ee1"
            export F_AMI_ID
            ;;
        "CentOS8")
            shift; 
            F_AMI_ID="ami-0157b1e4eefd91fd7"
            export F_AMI_ID
            ;;
        "RHEL7")
            shift; 
            F_AMI_ID="ami-0039be094106a495e"
            export F_AMI_ID
            ;;            
        "RHEL8")
            shift; 
            F_AMI_ID="ami-0a5eb017b84430da9"
            export F_AMI_ID
            ;;                       
    esac    

    process_log "Checking availability of Instance Type in target region"
    instancetypeExists=$(aws ec2 describe-instance-type-offerings --location-type availability-zone  --filters Name=instance-type,Values=${F_INSTANCE_TYPE} --region ${REGION} --output text)
    if [ ! -z "$instancetypeExists" ]
    then
        process_log "Instance Type: '${F_INSTANCE_TYPE}' is available in region: '${REGION}'"
    else
        exit_on_error "Instance Type: '${F_INSTANCE_TYPE}' is not available in region: '${REGION}'"
    fi
       
    process_log "Checking availability of Instance Image in target region"
    amiExists=$(aws ec2 describe-images --query 'sort_by(Images, &CreationDate)[*].[CreationDate,Name,ImageId]' --image-ids ${F_AMI_ID} --region ${REGION} --output text)
    if [ ! -z "$amiExists" ]
    then
        process_log "Instance Image: '${F_AMI_ID}' is available in region: '${REGION}'"
    else
        exit_on_error "Instance Image: '${F_AMI_ID}' is not available in region: '${REGION}'"
    fi

    F_PUB_KEYNAMEANDEXTENSION=$(get_string_after_lastslash "${F_KEYPATH}")
    F_PRIV_KEYNAMEANDEXTENSION=$(get_string_after_lastslash "${F_PRIV_FILE_KEYPATH}")
    F_NEW_PUB_KEYNAME=$(join_strings_with_underscore "${F_PROJECTNAME}" "${F_PUB_KEYNAMEANDEXTENSION}")
    F_NEW_PRIV_KEYNAME=$(join_strings_with_underscore "${F_PROJECTNAME}" "${F_PRIV_KEYNAMEANDEXTENSION}")    
    cp -f "${F_KEYPATH}" "${F_NEW_PUB_KEYNAME}"
    cp -f "${F_PRIV_FILE_KEYPATH}" "${F_NEW_PRIV_KEYNAME}"

    if output=$(terraform workspace show | grep "${F_PROJECTNAME}")  &&  [ ! -z "$output" ]
    then
        terraform workspace select "${F_PROJECTNAME}"
    else
        terraform workspace new "${F_PROJECTNAME}"
    fi
        
    terraform init
    
    terraform apply -auto-approve \
        -var="os=${F_OSNAME}" \
        -var="ami_id=${F_AMI_ID}" \
        -var="aws_region=${REGION}" \
        -var="instance_count=${F_INSTANCES}" \
        -var="ssh_key_path=./${F_NEW_PUB_KEYNAME}" \
        -var="pem_instance_count=${F_PEMINSTANCE}"

    if [[ $? -eq 0 ]]
    then
        process_log "Waiting for Instances to be available"
        aws ec2 wait instance-status-ok --region "${F_REGION}"
        process_log "instances are ready"
    else
        exit_on_error "Failed to build the servers."
    fi
    sed -i "/^ */d" inventory.yml
    sed -i "/^ *$/d" pem-inventory.yml
    
    if [[ ${F_PEMINSTANCE} -gt 0 ]]
    then
        cp -f pem-inventory.yml hosts.yml
    else
        cp -f inventory.yml hosts.yml
    fi
}


function azure_build_server()
{
    local F_PUBLISHER="$1"
    local F_OFFER="$2"
    local F_SKU="$3"
    local F_LOCATION="$4"
    local F_INSTANCE_COUNT="$5"
    local F_PUB_FILE_PATH="$6"
    local F_PROJECTNAME="$7"
    local F_EDB_PREREQ_GROUP="${7}_EDB-PREREQS-RESOURCEGROUP"
    local F_PEM_INSTANCE_COUNT="$8"
    local F_PRIV_FILE_KEYPATH="$9"
    #local F_AZURE_INSTANCE_SIZE="Standard_A1"
    local F_AZURE_INSTANCE_SIZE="Standard_A8_v2"
    
    process_log "Building Azure Servers"
    cd ${DIRECTORY}/terraform/azure || exit 1
    process_log "including project names in the variables and tags"
    sed "s/PROJECT_NAME/${F_PROJECTNAME}/g" tags.tf.template > tags.tf
    sed "s/PROJECT_NAME/${F_PROJECTNAME}/g" variables.tf.template \
                                        > variables.tf

    process_log "Checking availability of Instance Size in target region"
#az vm list-sizes --location westus2 --output table| grep "Standard_A1"    
    instancesizeExists=$(az vm list-sizes --location westus2 --output table| grep "${F_AZURE_INSTANCE_SIZE}")
    if [ ! -z "$instancesizeExists" ]
    then
        process_log "Instance Size: '${F_AZURE_INSTANCE_SIZE}' is available in region: '${F_LOCATION}'"
    else
        exit_on_error "Instance Size: '${F_AZURE_INSTANCE_SIZE}' is not available in region: '${F_LOCATION}'"
    fi
       
    process_log "Checking availability of Instance Image in target region"
#az vm image list --all -p OpenLogic -f Centos -s 7.7 -l westus2    
    amiExists=$(az vm image list --all -p ${F_PUBLISHER} -f ${F_OFFER} -s ${F_SKU} -l ${F_LOCATION} --output table)
    if [ ! -z "$amiExists" ]
    then
        process_log "Instance Image for: Publisher: '${F_PUBLISHER}' Offer: '${F_OFFER}' SKU: '${F_SKU}' is available in location: '${F_LOCATION}'"
    else
        exit_on_error "Instance Image for: Publisher: '${F_PUBLISHER}' Offer: '${F_OFFER}' SKU: '${F_SKU}' is not available in location: '${F_LOCATION}'"
    fi

    F_PUB_KEYNAMEANDEXTENSION=$(get_string_after_lastslash "${F_PUB_FILE_PATH}")
    F_PRIV_KEYNAMEANDEXTENSION=$(get_string_after_lastslash "${F_PRIV_FILE_KEYPATH}")
    F_NEW_PUB_KEYNAME=$(join_strings_with_underscore "${F_PROJECTNAME}" "${F_PUB_KEYNAMEANDEXTENSION}")
    F_NEW_PRIV_KEYNAME=$(join_strings_with_underscore "${F_PROJECTNAME}" "${F_PRIV_KEYNAMEANDEXTENSION}")
    cp -f "${F_PUB_FILE_PATH}" "${F_NEW_PUB_KEYNAME}"
    cp -f "${F_PRIV_FILE_KEYPATH}" "${F_NEW_PRIV_KEYNAME}"

    if output=$(terraform workspace show | grep "${F_PROJECTNAME}")  &&  [ ! -z "$output" ]
    then
        terraform workspace select "${F_PROJECTNAME}"
    else
        terraform workspace new "${F_PROJECTNAME}"
    fi
                                                
    terraform init

    terraform apply -auto-approve \
         -var="publisher=$F_PUBLISHER" \
         -var="offer=$F_OFFER" \
         -var="sku=$F_SKU" \
         -var="azure_location=$F_LOCATION" \
         -var="instance_count=1" \
         -var="ssh_key_path=./${F_NEW_PUB_KEYNAME}"
 
    if [ "$?" = "0" ]; then
      # Wait for VMs to be fully available
      az vm wait --ids $(az vm list -g "$F_EDB_PREREQ_GROUP" --query "[].id" -o tsv) --created
    fi

    # Execute with the correct instance count
    terraform apply -auto-approve \
         -var="publisher=$F_PUBLISHER" \
         -var="offer=$F_OFFER" \
         -var="sku=$F_SKU" \
         -var="azure_location=$F_LOCATION" \
         -var="instance_count=$F_INSTANCE_COUNT" \
         -var="ssh_key_path=./${F_NEW_PUB_KEYNAME}"         

    if [[ $? -eq 0 ]]
    then
        process_log "Waiting for Instances to be available"
        az vm wait --ids $(az vm list -g "$F_EDB_PREREQ_GROUP" --query "[].id" -o tsv) --created
        process_log "instances are ready"
    else
        exit_on_error "Failed to build the servers."
    fi
    sed -i "/^ */d" inventory.yml
    sed -i "/^ *$/d" pem-inventory.yml
    
    if [[ ${F_PEM_INSTANCE_COUNT} -gt 0 ]]
    then
        cp -f pem-inventory.yml hosts.yml
    else
        cp -f inventory.yml hosts.yml
    fi
}

function gcloud_build_server()
{
    local F_OSVERSION=""
    local F_OS="$1"
    local F_SUBNETWORK_REGION="$2"
    local F_INSTANCE_COUNT="$3"
    local F_PUB_FILE_PATH="$4"
    local F_PROJECTID="$5"    
    local F_PROJECTNAME="$6"
    local F_PEM_INSTANCE_COUNT="$7"
    local F_CREDENTIALS_FILE_LOCATION="$8"
    local F_PRIV_FILE_KEYPATH="$9"
    local F_IMAGE_FAMILY=""

    process_log "Building Google Cloud Servers"
    cd ${DIRECTORY}/terraform/gcloud || exit 1
    process_log "including project names in the variables and tags"
    sed "s/PROJECT_NAME/${F_PROJECTNAME}/g" variables.tf.template \
                                        > variables.tf

    case $F_OS in
        "CentOS7")
            shift;
            #OSVERSION="centos-7-v20170816"
            F_OSVERSION="centos-7-v20200403"
            F_IMAGE_FAMILY="centos-7"
            ANSIBLE_USER="centos"
            export F_OSVERSION
            export F_IMAGE_FAMILY
            export ANSIBLE_USER
            ;;
        "CentOS8")
            shift;
            F_OSVERSION="centos-8-v20200910"
            F_IMAGE_FAMILY="centos-8"
            ANSIBLE_USER="centos"
            export F_OSVERSION
            export F_IMAGE_FAMILY
            export ANSIBLE_USER            
            ;;
        "RHEL7")
            shift;
            F_OSVERSION="rhel-7-v20200403"
            F_IMAGE_FAMILY="rhel-7"
            ANSIBLE_USER="ec2-user"
            export F_OSVERSION
            export F_IMAGE_FAMILY
            export ANSIBLE_USER            
            ;;
        "RHEL8")
            shift; 
            F_OSVERSION="rhel-8-v20200910"
            F_IMAGE_FAMILY="rhel-7"
            ANSIBLE_USER="ec2-user"
            export F_OSVERSION
            export F_IMAGE_FAMILY
            export ANSIBLE_USER            
            ;;
    esac 

    process_log "Checking availability of Image in target region"
    imageExists=$(gcloud compute images list --filter="family=${F_IMAGE_FAMILY}")
    if [ ! -z "$imageExists" ]
    then
        process_log "Instance Image for: Family: '${F_IMAGE_FAMILY}' is available in region: '${F_SUBNETWORK_REGION}'"
    else
        exit_on_error "Instance Image for: Family: '${F_IMAGE_FAMILY}' is not available in location: '${F_SUBNETWORK_REGION}'"
    fi
        
    F_PUB_KEYNAMEANDEXTENSION=$(get_string_after_lastslash "${F_PUB_FILE_PATH}")
    F_PRIV_KEYNAMEANDEXTENSION=$(get_string_after_lastslash "${F_PRIV_FILE_KEYPATH}")
    F_NEW_PUB_KEYNAME=$(join_strings_with_underscore "${F_PROJECTNAME}" "${F_PUB_KEYNAMEANDEXTENSION}")
    F_NEW_PRIV_KEYNAME=$(join_strings_with_underscore "${F_PROJECTNAME}" "${F_PRIV_KEYNAMEANDEXTENSION}")
    cp -f "${F_PUB_FILE_PATH}" "${F_NEW_PUB_KEYNAME}"
    cp -f "${F_PRIV_FILE_KEYPATH}" "${F_NEW_PRIV_KEYNAME}"

    if output=$(terraform workspace show | grep "${F_PROJECTNAME}")  &&  [ ! -z "$output" ]
    then
        terraform workspace select "${F_PROJECTNAME}"
    else
        terraform workspace new "${F_PROJECTNAME}"
    fi
 
    terraform init

    terraform apply -auto-approve \
         -var="os=$F_OSVERSION" \
         -var="project_name=$F_PROJECTID" \
         -var="subnetwork_region=$F_SUBNETWORK_REGION" \
         -var="instance_count=$F_INSTANCE_COUNT" \
         -var="credentials=$F_CREDENTIALS_FILE_LOCATION" \
         -var="ssh_user=$ANSIBLE_USER" \
         -var="ssh_key_location=./${F_NEW_PUB_KEYNAME}"
 
    if [[ $? -eq 0 ]]
    then
        process_log "Waiting for Instances to be available"
        sleep 20s
        process_log "instances are ready"
    else
        exit_on_error "Failed to build the servers."
    fi
    sed -i "/^ */d" inventory.yml
    sed -i "/^ *$/d" pem-inventory.yml
    
    if [[ ${F_PEM_INSTANCE_COUNT} -gt 0 ]]
    then
        cp -f pem-inventory.yml hosts.yml
    else
        cp -f inventory.yml hosts.yml
    fi
    mv -f ${DIRECTORY}/terraform/gcloud/${F_NEW_PUB_KEYNAME} ${PROJECTS_DIRECTORY}/gcloud/${F_PROJECTNAME}/${F_NEW_PUB_KEYNAME}
    mv -f ${DIRECTORY}/terraform/gcloud/${F_NEW_PRIV_KEYNAME} ${PROJECTS_DIRECTORY}/gcloud/${F_PROJECTNAME}/${F_NEW_PRIV_KEYNAME}
}

################################################################################
# function destroy server
################################################################################
function aws_destroy_server()
{
    local F_REGION="$1"
    local F_PROJECTNAME="$2"

    process_log "Removing AWS Servers"
    cd ${DIRECTORY}/terraform/aws || exit 1

    terraform workspace select "${F_PROJECTNAME}"
        
    terraform destroy -auto-approve \
        -var="aws_region=${REGION}"

    terraform workspace select default
    terraform workspace delete "${F_PROJECTNAME}"
}

function azure_destroy_server()
{
    local F_LOCATION="$1"
    local F_PROJECTNAME="$2"    

    process_log "Removing Azure Servers"
    cd ${DIRECTORY}/terraform/azure || exit 1

    terraform workspace select "${F_PROJECTNAME}"
        
    terraform destroy -auto-approve \
        -var="azure_location=${F_LOCATION}"
        
    terraform workspace select default
    terraform workspace delete "${F_PROJECTNAME}"
}

function gcloud_destroy_server()
{
    local F_SUBNETWORK_REGION="$1"
    local F_PROJECT_ID="$2"
    local F_PUB_FILE_PATH="$3"
    local F_PROJECTNAME="$4"

    process_log "Removing Google Cloud Servers"
    cd ${DIRECTORY}/terraform/gcloud || exit 1    

    terraform workspace select "${F_PROJECTNAME}"
    
    terraform destroy -auto-approve \
        -var="subnetwork_region=${F_SUBNETWORK_REGION}" \
        -var="project_name=${F_PROJECT_ID}" \
        -var="ssh_key_location=${F_PUB_FILE_PATH}"

    terraform workspace select default
    terraform workspace delete "${F_PROJECTNAME}"
}
