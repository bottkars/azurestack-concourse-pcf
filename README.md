# azurestack-concourse-pcf
Concourse PCF Pipeline for Azure Stack


this is a modified version of https://github.com/Azure/azure-quickstart-templates/tree/master/concourse-ci  to run on AzureStack
pipelines will be added from pivnet

## getting started

once Concourse is deployed, open the webpage [concourse](http://jumphost-comcourse:8080)

download the fly executable into you path
login fly cli

```bash
fly -t ci login -c http://10.244.15.2:8080
```

clone into https://github.com/pivotal-cf/pcf-pipelines/tree/master/install-pcf/azure

```bash
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