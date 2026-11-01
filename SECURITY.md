# Security Policy

Commonroom is a public, anonymous chat application. Please review the privacy and abuse limitations in the [README](README.md) before using it.

## Supported versions

Security fixes are made against the latest code on the default branch. The hosted application is deployed from that branch through GitHub Actions.

## Reporting a vulnerability

Please report suspected vulnerabilities privately and include:

- A clear description of the issue and its potential impact.
- The affected page, file, endpoint, or component.
- Reproduction steps or a minimal proof of concept.
- Any relevant screenshots, logs, or request details with secrets and personal data removed.

Use GitHub's **Private vulnerability reporting / Report a vulnerability** feature for this repository when it is enabled. If that option is unavailable, contact the repository maintainers privately through GitHub rather than creating a public issue.

Please do not publicly disclose an unpatched vulnerability or publish exploit details before maintainers have had a reasonable opportunity to investigate.

## What to expect

The maintainers will acknowledge reports when reasonably possible, investigate reproducible findings, and coordinate a fix or mitigation. Response and remediation times depend on severity, available information, and maintainer availability; no fixed service-level agreement is offered.

## Scope and important limitations

- The application is intentionally public and anonymous. Display names and browser-local sender keys are not verified identities.
- Client-side validation and sender keys must not be treated as security boundaries.
- Never include real credentials, service-role keys, database passwords, or private user information in a report.
- Do not perform destructive testing, denial-of-service testing, or access data belonging to other people.
- Only test systems and Supabase projects you own or are explicitly authorized to assess.

Thank you for helping keep Commonroom and its community safer.
