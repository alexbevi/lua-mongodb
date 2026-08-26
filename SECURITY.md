# Security policy

## Supported versions

Only the latest published patch in the current `0.10.x` release line receives security updates.
Older release lines and superseded patch releases are unsupported. Upgrade to the latest release
before reporting a problem that may already have been corrected.

## Reporting a vulnerability

Submit a confidential report through
[GitHub private vulnerability reporting](https://github.com/alexbevi/lua-mongodb/security/advisories/new).
Do not open a public issue, discussion, or pull request for an unpatched vulnerability.

A useful report includes:

- the affected driver release or commit and Lua version;
- the MongoDB server version, topology, and relevant runtime provider versions;
- a concise impact assessment and the conditions required to reproduce the issue;
- minimal reproduction steps or a proof of concept; and
- possible mitigations or fixes, if known.

Remove live credentials, tokens, certificates, connection strings, customer data, and other
secrets from reports and attachments. If a sensitive value is essential to reproduce the issue,
describe how to create a disposable equivalent instead of submitting the live value.

Security-sensitive areas include credential exposure, authentication and authorization behavior,
TLS verification, error redaction, BSON or wire protocol parsing, protocol state transitions,
and defects that permit unintended access or practical denial of service. Ordinary correctness or
documentation bugs that do not require confidentiality can use the public issue tracker.

## Coordinated disclosure

Keep the report and unpatched details private while the vulnerability is investigated. The
maintainer and reporter should coordinate disclosure through the private advisory, including the
fix, release, advisory text, and publication timing. Public disclosure should follow a corrected
release or an agreed mitigation unless earlier disclosure is necessary to protect users.
