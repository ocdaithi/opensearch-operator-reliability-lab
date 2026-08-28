# opensearch-operator-reliability-lab

A public, independently developed open-source lab for validating the OpenSearch Kubernetes Operator on short-lived Amazon EKS environments.

The planned platform combines Terraform, GitHub Actions OIDC, repeatable reliability tests and curated diagnostic evidence. Human and automated project access will use temporary AWS credentials; long-lived AWS access keys will not be used.

The Terraform account foundation, policy renderers and security tests are implemented in source. Foundation changes remain a local, human-reviewed exact-plan operation; this public repository does not assert the live state of an installation. EKS infrastructure and reliability workloads are later work. Curated documentation and results will be published through GitHub Pages from a generated site artefact containing only selected public material.

- [AWS account bootstrap runbook](docs/aws/account-bootstrap.md)
- [Verify the Terraform-managed AWS foundation](docs/aws/verify-state.md)
- [Bootstrap security and design](docs/aws/bootstrap-security.md)
- [Account bootstrap recovery](docs/aws/account-bootstrap-recovery.md)
- [Bootstrapping a Secure AWS Account with Terraform and GitHub Actions](docs/articles/aws-account-bootstrap-with-terraform.md)
- [Architecture decisions](docs/adr/)

## Licence

This project is licensed under the Apache License 2.0. See [LICENSE](LICENSE).
