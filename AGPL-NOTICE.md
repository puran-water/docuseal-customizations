# AGPL-3.0 §13 Corresponding Source Offer

[Docuseal Community](https://github.com/docusealco/docuseal) is licensed under
the GNU Affero General Public License version 3 (AGPL-3.0). Puran Water LLC
operates a self-hosted instance of Docuseal Community for the signing of
agreements between Puran Water LLC and its counterparties. The instance runs a
**modified version** of Docuseal Community: the original image plus the Ruby
initializer in this directory (`initializers/zzz_puranos_customizations.rb`).

Under AGPL-3.0 §13, users that interact with the modified version over a
computer network must be offered access to the Corresponding Source for the
modification.

## Corresponding Source

The Corresponding Source for the modification is published as a public Git
repository at:

> **<https://github.com/puran-water/docuseal-customizations>**

It contains:

- `initializers/zzz_puranos_customizations.rb` — the runtime initializer.
- `docker-compose.yml` — the mount wiring.
- `scripts/verify-document-api.sh` — smoke test.
- `README.md` — implementation notes.
- `AGPL-NOTICE.md` — this notice.

## In-Product Offer

The same initializer registers a Rack middleware
(`PuranWaterDocusealCustomizations::SourceOfferMiddleware`) that injects a
discreet footer link into every HTML response from the modified Rails app.
The footer text is `Modified Docuseal Community — source` and the link
target is the Corresponding-Source URL above. This satisfies the §13
requirement to "prominently offer" interacting users an opportunity to
receive the source.

## Contact

For questions about the modification or to request the source via an
alternative channel, contact `hersh@puranwater.com`.

## Upstream

This notice does not modify or supersede the upstream Docuseal Community
license. The upstream `LICENSE` is unchanged inside the container; refer to
the upstream repository for the canonical AGPL-3.0 text and the original
copyright notices.
