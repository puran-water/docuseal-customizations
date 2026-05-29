#!/usr/bin/env bash
set -euo pipefail

if [[ -z "${DOCUSEAL_TOKEN:-}" ]]; then
  echo "DOCUSEAL_TOKEN is required" >&2
  exit 2
fi

base_url="${DOCUSEAL_URL:-http://127.0.0.1:3050}"
base_url="${base_url%/}"

case "$base_url" in
  */api) api_url="$base_url" ;;
  *) api_url="$base_url/api" ;;
esac

tmp_dir="$(mktemp -d)"
cleanup() {
  rm -rf "$tmp_dir"
}
trap cleanup EXIT

pdf_payload="$(
  python3 - <<'PY'
import base64
import json

stream = b"BT /F1 18 Tf 72 720 Td (Docuseal PDF probe) Tj ET\n"
objects = [
    "1 0 obj\n<< /Type /Catalog /Pages 2 0 R >>\nendobj\n",
    "2 0 obj\n<< /Type /Pages /Kids [3 0 R] /Count 1 >>\nendobj\n",
    "3 0 obj\n<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] "
    "/Contents 4 0 R /Resources << /Font << /F1 5 0 R >> >> >>\nendobj\n",
    f"4 0 obj\n<< /Length {len(stream)} >>\nstream\n{stream.decode('ascii')}endstream\nendobj\n",
    "5 0 obj\n<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>\nendobj\n",
]

pdf = b"%PDF-1.4\n"
offsets = [0]
for obj in objects:
    offsets.append(len(pdf))
    pdf += obj.encode("ascii")

xref_offset = len(pdf)
pdf += f"xref\n0 {len(objects) + 1}\n0000000000 65535 f \n".encode("ascii")
for offset in offsets[1:]:
    pdf += f"{offset:010d} 00000 n \n".encode("ascii")
pdf += f"trailer\n<< /Size {len(objects) + 1} /Root 1 0 R >>\nstartxref\n{xref_offset}\n%%EOF\n".encode("ascii")

print(json.dumps({
    "name": "Docuseal PDF API probe",
    "documents": [{
        "name": "probe.pdf",
        "file": base64.b64encode(pdf).decode("ascii"),
        "fields": [{
            "name": "Probe Signature",
            "type": "signature",
            "role": "Client",
            "required": True,
            "areas": [{"x": 0.16, "y": 0.42, "w": 0.30, "h": 0.04, "page": 0}]
        }]
    }]
}))
PY
)"

docx_payload="$(
  python3 - <<'PY'
import base64
import json
from io import BytesIO
from zipfile import ZIP_DEFLATED, ZipFile

document_xml = """<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">
  <w:body>
    <w:p>
      <w:r><w:t>Docuseal DOCX probe </w:t></w:r>
      <w:r><w:t>{{Probe Signature;type=signature;role=Client}}</w:t></w:r>
    </w:p>
    <w:sectPr>
      <w:pgSz w:w="12240" w:h="15840"/>
      <w:pgMar w:top="1440" w:right="1440" w:bottom="1440" w:left="1440"/>
    </w:sectPr>
  </w:body>
</w:document>
"""

content_types = """<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">
  <Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>
  <Default Extension="xml" ContentType="application/xml"/>
  <Override PartName="/word/document.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/>
</Types>
"""

rels = """<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
  <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="word/document.xml"/>
</Relationships>
"""

doc_rels = """<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"/>
"""

buffer = BytesIO()
with ZipFile(buffer, "w", ZIP_DEFLATED) as docx:
    docx.writestr("[Content_Types].xml", content_types)
    docx.writestr("_rels/.rels", rels)
    docx.writestr("word/document.xml", document_xml)
    docx.writestr("word/_rels/document.xml.rels", doc_rels)

print(json.dumps({
    "name": "Docuseal DOCX API probe",
    "documents": [{
        "name": "probe.docx",
        "file": base64.b64encode(buffer.getvalue()).decode("ascii")
    }]
}))
PY
)"

post_template_probe() {
  local format="$1"
  local payload="$2"
  local body_file="$tmp_dir/${format}.json"
  local status

  status="$(
    curl -sS \
      -o "$body_file" \
      -w "%{http_code}" \
      -X POST "$api_url/templates/$format" \
      -H "Accept: application/json" \
      -H "Content-Type: application/json" \
      -H "X-Auth-Token: $DOCUSEAL_TOKEN" \
      --data "$payload"
  )"

  if [[ "$status" != "200" ]]; then
    # DOCX/DOC conversion needs libreoffice/soffice in the container. When that
    # binary is intentionally absent the route returns a clean 422 — treat that
    # as a SKIP rather than a failure (the route registered; only the optional
    # converter is missing).
    if [[ "$format" != "pdf" ]] && [[ "$status" == "422" ]] \
       && jq -e '.error? | strings | test("libreoffice|soffice"; "i")' "$body_file" >/dev/null 2>&1; then
      echo "Docuseal ${format^^} API route reachable but converter SKIPPED: $(jq -r '.error' "$body_file")"
      return 0
    fi
    echo "POST $api_url/templates/$format returned HTTP $status" >&2
    cat "$body_file" >&2
    exit 1
  fi

  if jq -e '.message? | strings | test("Pro Edition")' "$body_file" >/dev/null; then
    echo "$format API route not registered by initializer (still returns upstream 404)" >&2
    cat "$body_file" >&2
    exit 1
  fi

  local template_id
  template_id="$(jq -r '.id // empty' "$body_file")"

  if [[ -z "$template_id" || "$template_id" == "null" ]]; then
    echo "$format API response did not include a template id" >&2
    cat "$body_file" >&2
    exit 1
  fi

  if [[ "$format" == "docx" ]]; then
    if ! jq -e '(.fields // []) | any(.type == "signature" and ((.name // "") | test("Probe Signature")))' "$body_file" >/dev/null; then
      echo "DOCX API response did not include the detected Probe Signature field" >&2
      cat "$body_file" >&2
      exit 1
    fi
  fi

  curl -fsS \
    -X DELETE "$api_url/templates/$template_id?permanently=true" \
    -H "Accept: application/json" \
    -H "X-Auth-Token: $DOCUSEAL_TOKEN" \
    >/dev/null

  echo "Docuseal ${format^^} API route OK: created and deleted probe template $template_id"
}

post_template_probe "pdf" "$pdf_payload"
post_template_probe "docx" "$docx_payload"
