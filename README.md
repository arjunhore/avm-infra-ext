# avm-infra

Terraform modules for the Add Value Machine platform.

## Architecture

Architecture Diagram:

![](docs/diagrams/architecture-diagram-v1.3.png)

## Docs
- [Running the Terraform setup](docs/setup.md)

### Prerequisites:

To get started you will need the following:

- [Terraform v1.5.3](https://developer.hashicorp.com/terraform/downloads)
- [AWS CLI 2.0](https://aws.amazon.com/cli/)
- A set of valid AWS Administrator or PowerUser Credentials

> Type `aws configure` and input the AWS credentials, including the region where you want to deploy the infrastructure
> stack into.

## Installation

Follow these instructions after installing both Terraform and AWS CLI.

1. Initialize Terraform modules. 

```terraform
$ terraform init
```

2. Create a workspace. Corresponding workspace keys need to be updated in `workspace_iam_roles` in [variables.tf](variables.tf)

> Due to the `assume_role` setting in the AWS provider configuration, any management operations for AWS resources will be performed via the configured role in the appropriate environment AWS account. The backend operations, such as reading and writing the state from S3, will be performed directly as the administrator's own user within the administrative account.

```
$ terraform workspace new <NAMESPACE>
```

To select an existing workspace use `terraform workspace select <NAMESPACE>`

3. Create an execution plan, preview the changes that Terraform plans to make to your infrastructure.

```
$ terraform plan
```

> The plan command alone does not actually carry out the proposed changes. You can use this command to check whether the proposed changes match what you expected before you apply the changes or share your changes with your team for broader review.

4. Execute the actions proposed in the Terraform plan.

```
$ terraform apply
```

> When you run terraform apply without passing a saved plan file, Terraform automatically creates a new execution plan as if you had run terraform plan

5. Inspect the output.

At the end of a successful apply, a set of variables and their values shall be output, to be used in further provisioning application environments.
