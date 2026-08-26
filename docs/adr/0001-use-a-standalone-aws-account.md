# ADR 0001: Use a standalone AWS account

## Context

This public reliability lab uses a standalone personal AWS account on the Free Plan with AWS Free Tier credits. The [AWS Free Tier FAQ](https://docs.aws.amazon.com/awsaccountbilling/latest/aboutv2/free-tier-FAQ.html) states that creating or joining an AWS Organization, or setting up an AWS Control Tower landing zone, automatically upgrades the account and causes its remaining credits to expire immediately. The lab needs Terraform, Amazon EKS and GitHub Actions federation, but does not need multi-account governance at this stage.

## Decision

Keep the lab account standalone and do not create or join an AWS Organization or set up AWS Control Tower while its AWS Free Tier credits remain active.

## Consequences

This avoids the documented immediate-expiry path through AWS Organizations or AWS Control Tower. It does not extend the credit lifetime or prevent usage from exhausting the credits. Organisation-level controls remain unavailable, so identity, cost and audit controls must work within one account.

A single account provides less isolation than a multi-account design. Project roles, Terraform state boundaries and teardown controls therefore carry more responsibility, and durable bootstrap resources must remain separate from ephemeral lab resources.

## Revisit when

Review this decision well before the Free Plan ends or its credits are exhausted, and before intentionally upgrading the account or moving to multi-account governance. Review it earlier if a required feature depends on AWS Organizations or AWS Control Tower.
