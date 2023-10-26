# Deployment

The following guide assumes you already have the Terraform setup completed. If you have not completed the Terraform setup, please see the [Terraform Setup](./terraform-setup.md) guide.

### Setting up the environment

The Terraform setup will create a set of Secrets Manager secrets that will be used by the AVM CI/CD to deploy the application.

The majority of secrets will be pre-filled by Terraform, but information such as Single Sign-On (SSO) credentials and the Google Drive token will need to be manually updated. 

> Secrets Manager entries marked as <REPLACE_ME> will need to be manually updated before deploying the application.

![](assets/secrets-manager.png)

### Deploying the AVM application

The Terraform setup will create a set of CodePipeline pipelines that will be used to deploy the application in the AWS account.

The pipelines are configured to pull the latest Docker images from Elastic Container Registry (ECR). The Docker images are built and pushed to ECR by the AVM CI/CD.

> Pipelines will also need to be manually started after the initial setup. And whenever a new version of the application is released. 

![](assets/code-pipeline.png)