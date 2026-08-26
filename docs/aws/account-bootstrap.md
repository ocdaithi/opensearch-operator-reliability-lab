# AWS account bootstrap

This page records the verified account baseline and separates it from planned project controls.

## Secure Free Plan baseline

The lab uses a standalone personal AWS account on the [Free Plan](https://docs.aws.amazon.com/awsaccountbilling/latest/aboutv2/free-tier-plans.html) with AWS Free Tier credits. [ADR 0001](../adr/0001-use-a-standalone-aws-account.md) is the canonical explanation of this account boundary. Staying outside AWS Organizations and AWS Control Tower avoids their documented immediate-expiry path; it does not extend the credits or prevent their consumption.

No AWS infrastructure has been provisioned.

### Root identity

The root user has a dedicated private mailbox so root, billing and security messages remain separate from public project contact channels. It is reserved for root-only and recovery tasks, in line with [AWS root-user best practices](https://docs.aws.amazon.com/IAM/latest/UserGuide/root-user-best-practices.html).

The root password is unique and securely stored to avoid credential reuse. Two independently stored MFA methods were registered and tested so one unavailable method does not remove the second sign-in path. Recovery details are current. No root access keys exist, avoiding permanent programmatic credentials with unrestricted access. Root was signed out after verification to end the privileged session.

### Free Plan lifecycle

The Free Plan ends after six months or when the AWS Free Tier credits are exhausted, whichever occurs first. The actual credit balance and plan dates remain private.

Account identifiers, account-specific ARNs, private contact and recovery information, MFA products and device names, credentials, and screenshots or other account-specific evidence are also deliberately excluded from this public record.

## Project-specific configuration

No project-specific AWS resource has been configured.

### Human and automation access

Daily human access and automated trust have not been configured.

The initial Terraform bootstrap will run locally with temporary human credentials. GitHub Actions cannot assume an AWS role until the bootstrap has created the OIDC provider and trusted role. The same bootstrap will create the Terraform backend required for routine runs. Temporary human credentials avoid creating a long-lived access key solely to establish automation.

Routine provisioning will then move to GitHub Actions OIDC. Provisioning workflows will obtain short-lived credentials instead of storing AWS credentials in GitHub. The human access model, OIDC provider and role, Terraform backend and EKS infrastructure do not yet exist.

### Cost and resource lifecycle

The account, Terraform state, diagnostic evidence and ephemeral resources must be reviewed well before the Free Plan ends or its credits are exhausted. This provides time to decide whether to upgrade, retain durable data and remove temporary resources.

Cost visibility and alerts will be configured before EKS or other material billable resources are created. Durable account bootstrap resources will be kept separate from ephemeral reliability-test resources. These controls are planned, not yet implemented.

## Next checkpoint

The next checkpoint is cost and billing safeguards. Temporary human access and the Terraform and OIDC bootstrap will be reviewed afterwards.
