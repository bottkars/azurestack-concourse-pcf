# azurestack-concourse-pcf
Concourse PCF Pipeline for Azure Stack

this is a modified version of  
https://github.com/Azure/azure-quickstart-templates/tree/master/concourse-ci  to run on AzureStack
pipelines can be added from pivnet

## getting started  

### parameters required  



## after deployment  
once Concourse is deployed, open the webpage [concourse](http://vmjump-concourse.local.cloudapp.azurestack.external:8080)  

download the fly executable into you path
login fly cli

```bash
fly -t ci login -c http://vmjump-concourse.local.cloudapp.azurestack.external:8080
```

default user ise ciuser / Password123!  
clone into https://github.com/pivotal-cf/pcf-pipelines/tree/master/install-pcf/azure  

```powershell
git clone https://github.com/pivotal-cf/pcf-pipelines  
```

adjust the manifest to your needs

```powershell
fly -t ci set-pipeline -p install-pcf-azure `
  -c pcf-pipelines/install-pcf/azure/pipeline.yml `
  -l pcf-pipelines/install-pcf/azure/params.yml
```

destroy pipeline
```powershell
fly -t ci destroy-pipeline -p install-pcf-azure
```