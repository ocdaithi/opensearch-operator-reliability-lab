# Repository guidance

This is a public, independently developed open-source AWS and OpenSearch reliability lab.

- Do not include confidential, proprietary or client-specific code, data, documentation or operational details. All project material must be independently created using public sources or synthetic data.
- Never include AWS account IDs, credit balances or plan dates, private email addresses associated with AWS root access, billing, recovery or the account, account-specific ARNs, credentials, recovery information, MFA product or device details, Terraform state or plan files, kubeconfigs or screenshots containing identifiers. Public professional contact details are permitted.
- Use concise technical British English and distinguish completed work from planned work.
- Verify time-sensitive AWS claims against current official AWS documentation.
- Do not create or join an AWS Organization or set up AWS Control Tower while the AWS Free Tier credits remain active.
- Do not create AWS resources or make external changes unless the task explicitly authorises them. Stop and discuss the impact before changing the account plan, consuming substantial credits or exposing a public endpoint.
- Record a control as complete only after its outcome has been confirmed.
- Do not commit or push unless explicitly requested.
- Future GitHub Pages workflows must publish only explicitly selected documentation or generated site artefacts, never the repository root wholesale.

## Code Review Rules

Reviewers should flag:

- committed secrets, identifiers, state files, long-lived AWS access keys or other sensitive artefacts;
- AWS resources that can remain running or incur uncontrolled cost without explicit lifecycle and teardown controls;
- over-broad IAM permissions or GitHub Actions OIDC trust, especially trust available to forks, pull requests or arbitrary branches.

Mechanical formatting checks belong in CI, not the review rules.
