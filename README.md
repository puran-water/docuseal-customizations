# PuranOS Docuseal Customizations

## Role in the current PuranOS system

This repository publishes the Docuseal-specific modifications and their source-offer material. It is separate from the [public engineering MCP packages](https://github.com/puran-water/PuranOS-public/blob/main/docs/public-tools.md) and is not a distribution of the complete PuranOS workflow.

Engineering proposals and BEPs originate in the [retained sizing-and-balance workflow](https://github.com/puran-water/PuranOS-public/blob/main/docs/workflows.md). Signature preparation and document conversion are downstream operations; they do not supply the engineering approval itself. Follow the version assumptions and AGPL source obligations documented here when running the customization.

Built by [Puran Water](https://puranwater.com/).


This service runs self-hosted [Docuseal](https://www.docuseal.com/) Community
(AGPL-3.0) with a single read-only Ruby initializer mounted into the container.
The initializer extends the Rails app with two PuranOS-specific behaviors,
without altering the upstream image, schema, or assets:

1. **Document-ingestion API routes** for PDF, DOCX, DOC, and HTML inputs:

   ```text
   POST /api/templates/pdf
   POST /api/submissions/pdf
   POST /api/templates/docx
   POST /api/templates/doc
   POST /api/submissions/docx
   POST /api/templates/html
   POST /api/submissions/html
   ```

   Final document persistence delegates to Docuseal's shipped open-source
   services (`Templates::CreateAttachments`, `Templates::ProcessDocument`,
   `Submissions.create_from_submitters`). The initializer prepares a PDF for
   DOCX / DOC / HTML inputs and feeds it through the same attachment path.

2. **AGPL §13 source-offer middleware.** A small Rack middleware injects a
   discreet footer link into rendered HTML responses pointing network-
   interacting users at the public source for this modification. See
   `AGPL-NOTICE.md`.

The initializer is a runtime mount, not an image rebuild. It can be removed by
deleting the volume mount and recreating the service.

## Implementation Notes

DOCX / DOC support decodes the upload, extracts `{{…}}` field text-tags from
`word/document.xml`, converts the source document with `libreoffice` /
`soffice`, then positions detected fields from the converted PDF text using
`Pdfium::Page#text_nodes`. If exact text positioning is unavailable, fields are
created with deterministic fallback areas so the template remains usable.

HTML support accepts top-level `html`, `documents[].html`, or base64
`documents[].file`, extracts the same field text-tags, renders a simple PDF via
HexaPDF, and passes that PDF through the same attachment path.

### Internal Mapping

The initializer maps the documented API JSON into Docuseal v3.0.1's community
schema:

- `Template.schema`: one entry per created PDF attachment,
  `{ "attachment_uuid" => <ActiveStorage::Attachment#uuid>, "name" => <document name without extension> }`.
- `Template.submitters`: distinct role names from explicit fields, detected
  text-tags, and submission submitters, each as
  `{ "uuid" => SecureRandom.uuid, "name" => <role> }`.
- `Template.fields`: Docuseal field hashes with `uuid`, `submitter_uuid`,
  `name`, `type`, `required`, `preferences`, optional `validation` /
  `options`, and `areas`.
- `field.areas`: incoming explicit coordinates are kept as `x`, `y`, `w`, `h`;
  `page` is zero-based and `attachment_uuid` is set to the created PDF
  attachment. Detected text-tags use the same area structure.
- Submission endpoints create the API template first, then call
  `Submissions.create_from_submitters` with `source: :api`,
  `submitters_order` from `order` or `submitters_order` (default `preserved`),
  and the same `send_email` semantics as the standard `/api/submissions`
  endpoint.

## Wiring

`docker-compose.yml` mounts the initializer read-only into the Docuseal
container:

```yaml
./initializers/zzz_puranos_customizations.rb:/app/config/initializers/zzz_puranos_customizations.rb:ro
```

The `zzz_` prefix keeps it late in Rails' initializer load order. The
initializer is guarded: if a future Docuseal upgrade renames the internal
controllers, models, or services it depends on, it logs a warning and does not
crash Rails boot. The smoke test should then fail loudly.

DOCX / DOC conversion requires `libreoffice` or `soffice` inside the
container. Set `DOCUSEAL_OFFICE_CONVERT_BIN=/path/to/soffice` if it is not on
the normal `PATH`.

## Smoke Test

From `services/docuseal/` with `DOCUSEAL_TOKEN` set:

```bash
DOCUSEAL_URL=http://127.0.0.1:3050 ./scripts/verify-document-api.sh
```

The script generates:

- a one-page PDF with an explicit signature field and probes
  `/api/templates/pdf`;
- a tiny `.docx` containing
  `{{Probe Signature;type=signature;role=Client}}` and probes
  `/api/templates/docx`.

The PDF probe requires HTTP 200 + a JSON `id`. The DOCX probe requires the
same when `libreoffice` / `soffice` is present; when the converter is
intentionally absent, the route is still reachable but returns a clean 422 and
the probe reports SKIP rather than failing.

## OCI Deploy

```bash
cd /home/ubuntu/services/docuseal
docker compose up -d --force-recreate docuseal
DOCUSEAL_URL=http://127.0.0.1:3050 DOCUSEAL_TOKEN=<token> ./scripts/verify-document-api.sh
```

To confirm the mount is visible inside the running container:

```bash
docker exec docuseal test -r /app/config/initializers/zzz_puranos_customizations.rb
docker exec docuseal sh -lc 'command -v libreoffice || command -v soffice'
```

## Rollback

Remove the initializer volume mount from `docker-compose.yml`, then recreate:

```bash
docker compose up -d --force-recreate docuseal
```

The customizations are a read-only runtime mount. They do not alter the
database schema or the Docuseal image.

## License

Docuseal Community is AGPL-3.0. This directory is a server-side modification of
that software used over the network by counterparties signing documents. Under
AGPL-3.0 §13 the modified Corresponding Source — this initializer, the compose
mount, and the verify script — must be offered to network-interacting users.
See `AGPL-NOTICE.md` for the corresponding-source URL and the in-product
offer mechanism (the Rack middleware in `initializers/zzz_puranos_customizations.rb`).

## Maintenance

Re-test after every Docuseal upgrade. This initializer was derived against
Docuseal tag `3.0.1` (`9c700a3fb6fb4f16628da3d69e073ad57ca80e52`). Re-check at
least these internals before upgrading:

- `app/controllers/api/api_base_controller.rb`
- `app/controllers/errors_controller.rb`
- `lib/templates/create_attachments.rb`
- `lib/templates/process_document.rb`
- `lib/pdfium.rb`
- `Submissions.create_from_submitters`
