#!/bin/sh

# Return current date and time with passed log message
log() {
  echo "$(date '+%Y-%m-%d %H:%M:%S'): $1" | tee -a log
}
error() {
  echo "$(date '+%Y-%m-%d %H:%M:%S'): $1" | tee -a log
  exit 1
}

cleanup() {
  if [ $is_failed -ne 0 ]; then
    log "Deployment failed. Please check log file."
  else
    log "Clean up temporary files"
    \rm -f *_id
    \rm -f workbook.json
  fi
}

deploy_workbook() {
  deployment_name=$1
  filename=$2
  log "Start to deploy $filename"
  az deployment group create --name $deployment_name -g $resource_group_name --template-uri $deployment_template_for_workbook --parameters serializedData=@$filename --parameters name=$deployment_name -o table
  if [ $? -ne 0 ]; then
    is_failed=1
    log "Failed to deploy $filename"
  else
    log "Succeeded to deploy $filename"
  fi
}

trap cleanup EXIT

is_failed=0 # Flag to check whether deployment is failed or not and use it to determine cleanup

# Get option from script argument, which is used to specify Subscription ID, Resource Group name and Tenant name
help() {
  echo "Usage: $0 -s <Subscription ID> -g <Resource Group> [-t <Tenant ID>] [-c Create Resource Group if not exist] [-l <location>] [-b <Base URL of Workbook>] [-d]" 1>&2
  # Write command example with explanation
  echo "Example 1: When you want to deploy workbook to resource group myResourceGroup in subscription" 1>&2
  echo "         $0 -s 00000000-0000-0000-0000-000000000000 -g myResourceGroup -t 00000000-0000-0000-0000-000000000000" 1>&2
  echo "Example 2: When you want to deploy workbook to resource group myResourceGroup in subscription and create resource group if not exist" 1>&2
  echo "         $0 -s 00000000-0000-0000-0000-000000000000 -g myResourceGroup -t 00000000-0000-0000-0000-000000000000 -c -l japaneast" 1>&2
   
  exit 1
}

while getopts :s:g:t:cl:b:d OPT
do
  case $OPT in
    s) subscription_id=$OPTARG
       ;;
    g) resource_group_name=$OPTARG
       ;;
    t) tenant=$OPTARG
       ;;
    c) create_rg=1
       ;;
    l) location=$OPTARG
       ;;
    b) base_url=$OPTARG
       ;;
    d) developer_mode=1
       ;;
    *) help
       ;;
  esac
done

# Check subscription_id, resource_group_name and tenant. tenant is optional.
if [ x$subscription_id = x"" -o x$resource_group_name = x"" ]; then
    help
fi

# Check create_rg option, if specific it, location is required.
if [ x$create_rg != x"" -a x$location = x"" ]; then
    help
fi

public_repo_url="https://raw.githubusercontent.com/Azure/reliability-workbook/main"
deployment_template_for_workbook="$public_repo_url/workbooks/azuredeploy.json"
case $base_url in
    "") # If not set base_url, use default value
      ;;
    ".") # If set base_url with current directory, use default value
      ;;
    *) # If set base_url with other value, use it
      public_repo_url=$base_url
      deployment_template_for_workbook="$base_url/workbooks/azuredeploy.json"
      ;;
esac

[ x$tenant != x"" ] && tenant="-t $tenant"

# az login
log "Check token whether need to login or not"
az account get-access-token --subscription $subscription_id > /dev/null 2>&1
if [ $? -ne 0 ]; then
  log "Please login to Azure"
  az login $tenant --use-device-code
  [ $? -ne 0 ] && error "Please input correct SubscriptionID and Tenant ID"
fi

log "Set subscription: $subscription_id"
az account set --subscription $subscription_id -o table

log "Check existance of target resource group"
az group show --name $resource_group_name --subscription $subscription_id > /dev/null 2>&1
if [ $? -ne 0 ]; then
    if [ x$create_rg = x"" ]; then
        log "Resource group $resource_group_name does not exist. Please create it or specify -c and -l option to create it automatically"
        exit 1
    else
        log "Create resource group $resource_group_name"
        az group create --name $resource_group_name --subscription $subscription_id --location $location
        [ $? -ne 0 ] && error "Please input correct SubscriptionID and Resource Group name"
    fi
fi

if [ x$developer_mode != x"" ]; then
    log "Developer mode is enabled. Deploy Advisor version."
    wget $public_repo_url/workbooks/ReliabilityWorkbookPublic.workbook
    az deployment group create -g $resource_group_name --template-uri $deployment_template_for_workbook --parameters name="FTA - Reliability Workbook - Advisor version" serializedData=@ReliabilityWorkbookPublic.workbook
    exit 0
fi

# Download file list
# - If set base_url with current directory, doen't download file list to use local file
if [ x$base_url != x"." ]; then
  [ ! -f workbook_filelist ] && wget $public_repo_url/workbooks/workbook_filelist
  cat workbook_filelist | while read f
  do
      log "Download workbook file: $f"
      if [ -f $f ]; then
          log "Skip download because the file already exists"
      else
          wget $public_repo_url/workbooks/$f
          if [ $? -ne 0 ]; then
              is_failed=1
              error "Failed to download $f"
          fi
      fi
  done
fi

# Deploy Workbook
deployed_workbook_list=""
for f in `find . -maxdepth 1 -type f -name "*.workbook"`
do
  filename_base=`basename $f .workbook`
  filename=`basename $f`
  # Capture deployment name to use replacing placeholder with resource ID in workbook.tpl.json
  deployed_workbook_list="$deployed_workbook_list $filename_base"
  # Deploy workbook on background
  deploy_workbook $filename_base $filename &
done

# Wait for all deployment processes
wait


# Get resource ID from deployed workbook by using deployment name
for f in $deployed_workbook_list
do
  resource_id=`az deployment group show -g $resource_group_name -n $f --query 'properties.outputs.resource_id.value' -o tsv`
  if [ $? -ne 0 ]; then
      is_failed=1
      error "Failed to get resource ID of $f"
  fi
  log "Get resource ID of deployed workbook: $f -> $resource_id"
  echo $resource_id > ${f}_id
done

workbook_template_file="workbook.tpl.json"
[ ! -e $workbook_template_file ] && wget $public_repo_url/build/templates/workbook.tpl.json
# Copy workbook template file to workbook.json to keep workbook.tpl.json to use again
cp -f $workbook_template_file workbook.json
for f in `find . -maxdepth 1 -type f -name "*_id"`
do
    resource_id=`cat $f | tr -d '\"'`
    # Get resource type from filename (e.g.: ReliabilityWorkbookExport.workbook -> export)
    resource_type=`echo $f | sed -e 's/.*Workbook\([^.]*\).*_id/\L\1/g'`
    # Replace placeholder in the file
    sed -i "s#\\\${${resource_type}_workbook_resource_id}#$resource_id#g" workbook.json
    log "Replace $resource_type workbook resource ID: $resource_id"
done

overview_information=$(cat <<EOS
          ,{
            "type": 1,
            "content": {
              "json": "* This workbook source is maintained publicly as OpenSource in [GitHub Repository](https://github.com/Azure/reliability-workbook). There is no Service Level guarantees or warranties associated with the usage of this workbook. Refer [license](https://github.com/Azure/reliability-workbook/blob/main/LICENSE) for more details.\r\n\r\n> If there are any bugs or suggestions for improvements, feel free to raise an issue in the above GitHub repository. In case you want to reach out to maintainers, please email to [FTA Reliability vTeam](mailto:fta-reliability-team@microsoft.com)",
              "style": "info"
            },
            "name": "text - 3"
          }
EOS
)

escaped_replacement_text=$(printf '%s\n' "$overview_information" | sed 's:[\/&]:\\&:g;$!s/$/\\/')
sed -i "s/\${overview_information}/$escaped_replacement_text/g" workbook.json

link_of_Summary=$(cat <<EOS
          ,{
            "id": "d6656d8e-acfc-4d7d-853d-a8c628907ba6",
            "cellValue": "selectedTab",
            "linkTarget": "parameter",
            "linkLabel": "Summary",
            "subTarget": "Summary2",
            "style": "link"
          }
EOS
)
escaped_replacement_text=$(printf '%s\n' "$link_of_Summary" | sed 's:[\/&]:\\&:g;$!s/$/\\/')
sed -i "s/\${link_of_Summary}/$escaped_replacement_text/g" workbook.json

summary_id=$([ -f ReliabilityWorkbookSummary_id ] && cat ReliabilityWorkbookSummary_id | tr -d '\"')
tab_of_Summary=$(cat <<EOS
    ,{
      "type": 12,
      "content": {
        "version": "NotebookGroup/1.0",
        "groupType": "template",
        "loadFromTemplateId": "${summary_id}",
        "items": []
      },
      "conditionalVisibility": {
        "parameterName": "selectedTab",
        "comparison": "isEqualTo",
        "value": "Summary2"
      },
      "name": "summary group"
    }
EOS
)
escaped_replacement_text=$(printf '%s\n' "$tab_of_Summary" | sed 's:[\/&]:\\&:g;$!s/$/\\/')
sed -i "s/\${tab_of_Summary}/$escaped_replacement_text/g" workbook.json


link_of_Advisor=$(cat <<EOS
         ,{
            "id": "d983c7c7-b5a0-4245-86fa-52ac1266fb13",
            "cellValue": "selectedTab",
            "linkTarget": "parameter",
            "linkLabel": "Azure Advisor",
            "subTarget": "Advisor",
            "style": "link"
          }
EOS
)
escaped_replacement_text=$(printf '%s\n' "$link_of_Advisor" | sed 's:[\/&]:\\&:g;$!s/$/\\/')
sed -i "s/\${link_of_Advisor}/$escaped_replacement_text/g" workbook.json

advisor_id=$([ -f ReliabilityWorkbookAdvisor_id ] && cat ReliabilityWorkbookAdvisor_id | tr -d '\"')
tab_of_Advisor=$(cat <<EOS
    ,{
      "type": 12,
      "content": {
        "version": "NotebookGroup/1.0",
        "groupType": "template",
        "loadFromTemplateId": "${advisor_id}",
        "items": []
      },
      "conditionalVisibility": {
        "parameterName": "selectedTab",
        "comparison": "isEqualTo",
        "value": "Advisor"
      },
      "name": "Advisor"
    }
EOS
)
escaped_replacement_text=$(printf '%s\n' "$tab_of_Advisor" | sed 's:[\/&]:\\&:g;$!s/$/\\/')
sed -i "s/\${tab_of_Advisor}/$escaped_replacement_text/g" workbook.json

link_of_Export=$(cat <<EOS
          ,{
            "id": "0f548bfa-f959-4a25-a9ac-7c986be6d33b",
            "cellValue": "selectedTab",
            "linkTarget": "parameter",
            "linkLabel": "Export",
            "subTarget": "Export",
            "style": "link"
          }
EOS
)
escaped_replacement_text=$(printf '%s\n' "$link_of_Export" | sed 's:[\/&]:\\&:g;$!s/$/\\/')
sed -i "s/\${link_of_Export}/$escaped_replacement_text/g" workbook.json

export_id=$([ -f ReliabilityWorkbookExport_id ] && cat ReliabilityWorkbookExport_id | tr -d '\"')
tab_of_Export=$(cat <<EOS
    ,{
      "type": 12,
      "content": {
        "version": "NotebookGroup/1.0",
        "groupType": "template",
        "loadFromTemplateId": "${export_id}",
        "items": []
      },
      "conditionalVisibility": {
        "parameterName": "selectedTab",
        "comparison": "isEqualTo",
        "value": "Export"
      },
      "name": "ExportStep"
    }
EOS
)
escaped_replacement_text=$(printf '%s\n' "$tab_of_Export" | sed 's:[\/&]:\\&:g;$!s/$/\\/')
sed -i "s/\${tab_of_Export}/$escaped_replacement_text/g" workbook.json

log "Deploy FTA - Reliability Workbook"
az deployment group create -g $resource_group_name --template-uri $deployment_template_for_workbook --parameters name="FTA - Reliability Workbook" serializedData=@workbook.json -o table
# If failed deployment command, mark the deployment as failed
if [ $? -ne 0 ]; then
  is_failed=1
  log "Failed to deploy workbook"
  exit 1
fi
