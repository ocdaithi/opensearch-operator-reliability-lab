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

## Bootstrap runbook

Complete the following manual prerequisites before creating either AWS role or running OIDC verification:

1. Create the GitHub Environment `aws-bootstrap`.
2. Restrict its deployment branches and tags to the selected branch `main`.
3. Store the bootstrap role ARN only in that Environment.
4. Confirm that fork and other untrusted pull request code cannot receive AWS credentials.

An environment-scoped GitHub OIDC subject does not contain a branch. The Environment deployment-branch rule is therefore the authoritative branch boundary. The workflow's tokenless `main` guard is an additional repository control and does not replace that rule.

Before the initial apply, root must confirm that the exact state bucket and both exact role names do not already exist. Generate the temporary policy immediately before use, attach it only to the exact MFA-protected bootstrap user, which must have no access keys, and apply immediately. Export `BUDGET_NOTIFICATION_EMAIL` with the exact private recipient, then run the independent verifier immediately after apply. Stop if a resource already exists or any result differs from the reviewed contract. Detach and delete the temporary policy immediately after successful verification.

Two bounded first-write risks remain accepted during this initial operation. Temporary `s3:PutBucketPolicy` access to the exact bucket can write its policy before Terraform establishes the reviewed TLS-only policy. Temporary `iam:CreateRole` access to the exact roles accepts each initial trust document before the verifier confirms it. The required permissions boundaries cap what a newly created role can do, but they cannot constrain the initial trust-policy contents. The controls above reduce the exposure window; they do not eliminate either race.

### Cost and resource lifecycle

The account, Terraform state, diagnostic evidence and ephemeral resources must be reviewed well before the Free Plan ends or its credits are exhausted. This provides time to decide whether to upgrade, retain durable data and remove temporary resources.

Cost visibility and alerts will be configured before EKS or other material billable resources are created. Durable account bootstrap resources will be kept separate from ephemeral reliability-test resources. These controls are planned, not yet implemented.

## Next checkpoint

Apply and verify the reviewed bootstrap only after the manual prerequisites above are complete.
