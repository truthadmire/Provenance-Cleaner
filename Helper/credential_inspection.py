"""Structured, offline C2PA inspection; presence never implies trust."""
from __future__ import annotations

import json
import os
import re
import shutil
import subprocess
from pathlib import Path


def _run(args, timeout=30, **kwargs):
    return subprocess.run(args, capture_output=True, text=True, timeout=timeout, check=False, **kwargs)


def summarize(payload: dict) -> dict:
    manifests = payload.get("manifests")
    if not isinstance(manifests, dict) or not manifests:
        raise ValueError("No structured manifest store returned")
    active = payload.get("active_manifest")
    manifest = manifests.get(active)
    if not isinstance(manifest, dict):
        raise ValueError("Active manifest is missing from the manifest store")
    signature = manifest.get("signature_info") or {}
    results = payload.get("validation_results") or {}
    active_results = results.get("activeManifest") or {}
    statuses = []
    for category in ("success", "informational", "failure"):
        for item in active_results.get(category, []):
            if isinstance(item, dict):
                statuses.append({"code": str(item.get("code", "")), "message": str(item.get("explanation", "")), "category": category})
    # Older SDKs expose only the failure list. Do not infer a valid signature
    # from an empty list: require an explicit validation success code.
    known = {s["code"] for s in statuses}
    for item in payload.get("validation_status") or []:
        if isinstance(item, dict) and item.get("code") not in known:
            statuses.append({"code": str(item.get("code", "")), "message": str(item.get("explanation", "")), "category": "failure"})
    success = {s["code"] for s in statuses if s["category"] == "success"}
    failure = {s["code"] for s in statuses if s["category"] == "failure"}
    signature_state = "invalid" if any(c.startswith("claimSignature.") for c in failure) else "valid" if "claimSignature.validated" in success else "unknown"
    binding_state = "invalid" if any("mismatch" in c.lower() and (c.startswith("assertion.") or c.startswith("claim.")) for c in failure) else "valid" if success & {"assertion.dataHash.match", "assertion.bmffHash.match", "assertion.boxesHash.match", "assertion.collectionHash.match"} else "unknown"
    trust = "untrusted" if "signingCredential.untrusted" in failure else "trusted" if "signingCredential.trusted" in success else "unknown"
    return {
        "state": "present", "manifestCount": len(manifests), "activeManifest": active,
        "validationState": str(payload.get("validation_state", "Unknown")),
        "signature": signature_state, "contentBinding": binding_state, "trust": trust,
        "validationFailed": bool(failure - {"signingCredential.untrusted"}),
        "signer": str(signature.get("common_name", "")), "issuer": str(signature.get("issuer", "")),
        "algorithm": str(signature.get("alg", "")), "signedAt": str(signature.get("time", "")),
        "serialNumber": str(signature.get("cert_serial_number", "")),
        "generator": str(manifest.get("claim_generator", "")),
        "statuses": statuses[:150], "certificates": [],
        "scope": "Offline validation. Remote manifests, live revocation and CAWG identity are not checked. Trust is relative to the bundled verifier's local trust configuration.",
    }


def certificates(pem: str) -> list[dict]:
    chain = re.findall(r"-----BEGIN CERTIFICATE-----.*?-----END CERTIFICATE-----", pem, re.S)
    result = []
    if len(chain) > 16:
        raise ValueError("Certificate chain exceeds the 16-certificate limit")
    for cert in chain:
        r = _run(["/usr/bin/openssl", "x509", "-noout", "-subject", "-issuer", "-serial", "-dates", "-fingerprint", "-sha256"], input=cert)
        if r.returncode != 0:
            raise ValueError("Certificate could not be decoded")
        fields = {}
        for line in r.stdout.splitlines():
            if "=" in line:
                key, value = line.split("=", 1)
                fields[key.strip()] = value.strip()
        result.append({"subject": fields.get("subject", ""), "issuer": fields.get("issuer", ""),
                       "serial": fields.get("serial", ""), "notBefore": fields.get("notBefore", ""),
                       "notAfter": fields.get("notAfter", ""),
                       "sha256": next((v for k, v in fields.items() if "fingerprint" in k.lower()), "")})
    if not result:
        raise ValueError("No certificate chain returned")
    return result


def inspect(path) -> dict:
    if Path(path).suffix.lower() in {".docx", ".xlsx", ".pptx"}:
        from office_credentials import inspect_office
        return inspect_office(Path(path), inspect_asset)
    return inspect_asset(path)


def inspect_asset(path, *, timeout=30) -> dict:
    tool = shutil.which("c2patool")
    settings = os.environ.get("C2PATOOL_SETTINGS")
    result = {"available": bool(tool and settings), "ok": False, "has_manifest": False}
    details = {"state": "unavailable", "signature": "unknown", "trust": "unknown", "contentBinding": "unknown", "certificates": []}
    result["details"] = details
    if not tool or not settings:
        result["error"] = "Offline C2PA verifier unavailable"
        details.update(error=result["error"], inspectionIncomplete=True)
        return result
    try:
        r = _run([tool, str(path), "--settings", settings], timeout=timeout)
        result["returncode"] = r.returncode
        try:
            payload = json.loads(r.stdout)
        except (ValueError, TypeError):
            payload = None
        if isinstance(payload, dict) and payload.get("manifests"):
            result["details"] = details = summarize(payload)
            result.update(ok=True, has_manifest=True)
            try:
                cert_result = _run([tool, str(path), "--settings", settings, "--certs"], timeout=timeout)
                if cert_result.returncode != 0:
                    raise ValueError("Verifier could not extract the certificate chain")
                details["certificates"] = certificates(cert_result.stdout)
            except (OSError, ValueError, subprocess.TimeoutExpired) as exc:
                details["certificateError"] = str(exc)
        else:
            message = (r.stderr + "\n" + r.stdout).strip()[:2000]
            # Match explicit absence, not arbitrary mentions of 'claim/C2PA'.
            if re.fullmatch(r"(?:Error: )?(?:No claim found|No JUMBF (?:data|manifest)(?: found)?|No manifest found)", message, re.I):
                details["state"] = "absent"
                result["ok"] = True
            elif "unsupported" in message.lower():
                details["state"] = "unsupported"
                result["error"] = message
            else:
                details["state"] = "inconclusive"
                result["error"] = message or "Verifier returned no structured result"
    except (OSError, ValueError, subprocess.TimeoutExpired) as exc:
        details["state"] = "inconclusive"
        result["error"] = str(exc)
    if result.get("error"):
        details["error"] = result["error"]
    details["inspectionIncomplete"] = not result["ok"] or bool(details.get("certificateError")) or (
        details["state"] == "present" and not details.get("validationFailed") and
        (details["signature"] == "unknown" or details["contentBinding"] == "unknown"))
    return result


def run_optional_tools(path, *, include_exiftool=True):
    """Adapter for the pinned upstream contract; avoids its substring verdict."""
    result = {"c2patool": inspect(path)}
    if include_exiftool:
        tool = shutil.which("exiftool")
        if not tool:
            result["exiftool"] = {"available": False}
        else:
            try:
                r = _run([tool, "-G1", "-a", "-s", str(path)], timeout=5)
                result["exiftool"] = {"available": True, "returncode": r.returncode,
                    "interesting_lines": [line for line in r.stdout.splitlines() if re.search(r"c2pa|content.?credential|AIGC|digitalSource|XMP|EXIF|IPTC|jumb", line, re.I)][:50]}
            except (OSError, subprocess.TimeoutExpired) as exc:
                result["exiftool"] = {"available": True, "error": str(exc)}
    return result
