#!/usr/bin/env python3
"""Offline JSON-lines bridge to the vendored watermarks-remover engine.

The macOS app owns file selection and passes absolute paths.  This process is
deliberately synchronous: it reads one request, writes one response, flushes,
and only then reads the next request.  Closing stdin exits normally; cancelling
work is done by terminating this process.

stdout is protocol-only.  Diagnostics, including unexpected exceptions, go to
stderr so they can never corrupt a JSONL response stream.
"""

from __future__ import annotations

import base64
import binascii
import json
import math
import os
import platform
import ssl
import stat
import sys
from pathlib import Path
from typing import Any, NoReturn


PROTOCOL_VERSION = 1
ENGINE_NAME = "guillaumemeyer/watermarks-remover"
ENGINE_COMMIT = "3f84d3e3964368b82172112b09ef3e7c02b25749"
MAX_INPUT_BYTES = 256 << 20
MAX_OUTPUT_BYTES = 256 << 20
MAX_REQUEST_LINE_BYTES = 1 << 20
MAX_REQUEST_ID_CHARS = 256

_REQUEST_FIELDS = frozenset({"requestID", "operation", "inputPath", "outputPath", "options"})
_OPERATIONS = frozenset({"capabilities", "inspect", "clean"})
_OPTION_TYPES: dict[str, type] = {
    "normalizeSpaces": bool,
    "keepNonAIMetadata": bool,
    "stripAllMetadata": bool,
    "alsoLayerAText": bool,
    "deepImages": str,
}
_OPTION_MAP = {
    "normalizeSpaces": "normalize_spaces",
    "keepNonAIMetadata": "keep_non_ai_metadata",
    "stripAllMetadata": "strip_all_metadata",
    "alsoLayerAText": "also_layer_a_text",
    "deepImages": "deep_images",
}
_DEEP_IMAGE_MODES = frozenset({"auto", "always", "lossless", "never"})
_OPTION_DEFAULTS: dict[str, Any] = {
    "normalizeSpaces": False,
    "keepNonAIMetadata": True,
    "stripAllMetadata": False,
    "alsoLayerAText": True,
    "deepImages": "auto",
}

# These opt in to model checkouts, detector services, HTTP scorers, or rewrite
# services in the upstream project.  The bundled engine never inherits them.
_REMOTE_OR_HEAVY_ENV = frozenset(
    {
        "NOAI_WATERMARK_DIR",
        "MARKDIFFUSION_DIR",
        "REVERSE_SYNTHID_DIR",
        "MARKLLM_DIR",
        "MARKLLM_MODEL",
        "HF_TOKEN",
        "HUGGING_FACE_HUB_TOKEN",
        "CLAUDE_API_KEY",
        "ANTHROPIC_API_KEY",
        "OPENAI_API_KEY",
        "C2PATOOL_SETTINGS",
        "HTTP_PROXY",
        "HTTPS_PROXY",
        "ALL_PROXY",
        "http_proxy",
        "https_proxy",
        "all_proxy",
    }
)


class ProtocolError(Exception):
    """A caller-visible failure with a stable machine-readable code."""

    def __init__(
        self,
        code: str,
        message: str,
        *,
        details: dict[str, Any] | None = None,
    ) -> None:
        super().__init__(message)
        self.code = code
        self.message = message
        self.details = details


class _DuplicateJSONKey(ValueError):
    pass


def _sanitize_environment() -> None:
    """Disable every upstream environment-controlled remote/heavy backend."""

    for key in tuple(os.environ):
        if key.startswith("WATERMARKS_") or key in _REMOTE_OR_HEAVY_ENV:
            os.environ.pop(key, None)

    # Pin the cap before importing upstream.common, which reads it at import.
    os.environ["WATERMARKS_MAX_INPUT_BYTES"] = str(MAX_INPUT_BYTES)
    os.environ["WATERMARKS_SERVER_VERSION"] = ENGINE_COMMIT

    # Do not discover Homebrew/user-installed model wrappers or media tools.
    # Only release-staged local metadata tools and Apple's system paths are
    # visible.  Each tool has its own directory so ExifTool keeps its adjacent
    # lib/ tree intact in the packaged onedir bundle.
    helper_dir = Path(__file__).resolve().parent
    executable_contents = Path(sys.executable).resolve().parent.parent
    tool_roots = [
        Path(sys.executable).resolve().parent / "tools",
        executable_contents / "Frameworks" / "tools",
        executable_contents / "Resources" / "tools",
        helper_dir / "tools",
        helper_dir.parent / "Vendor" / "Artifacts" / "staged",
    ]
    tool_paths: list[str] = []
    c2patool_settings: Path | None = None
    for root in tool_roots:
        for name in ("c2patool", "exiftool", "qpdf"):
            candidate = root / name
            if not candidate.is_dir():
                continue
            if name == "c2patool":
                settings = candidate / "offline.toml"
                if not settings.is_file():
                    # c2patool fetches remote manifests by default.  A missing
                    # deny-all settings file therefore disables the tool.
                    continue
                if c2patool_settings is None:
                    c2patool_settings = settings.resolve()
            candidate_text = str(candidate.resolve())
            if candidate_text not in tool_paths:
                tool_paths.append(candidate_text)
    os.environ["PATH"] = os.pathsep.join(
        [*tool_paths, "/usr/bin", "/bin", "/usr/sbin", "/sbin"]
    )
    if c2patool_settings is not None:
        os.environ["C2PATOOL_SETTINGS"] = str(c2patool_settings)


def _upstream_directory() -> Path:
    """Find upstream modules in source, embedded-dev, or PyInstaller layouts."""

    candidates: list[Path] = []
    frozen_root = getattr(sys, "_MEIPASS", None)
    if frozen_root:
        # PyInstaller's importer resolves bundled modules from this root even
        # when no physical server.py is present next to the executable.
        candidates.append(Path(frozen_root))

    helper_dir = Path(__file__).resolve().parent
    candidates.extend(
        [
            helper_dir / "upstream",
            helper_dir.parent / "Vendor" / "watermarks-remover" / "service" / "scripts",
        ]
    )
    for candidate in candidates:
        if candidate.is_dir():
            return candidate
    raise RuntimeError("vendored watermarks-remover engine was not found")


_sanitize_environment()
_UPSTREAM_DIRECTORY = _upstream_directory()
sys.path.insert(0, str(_UPSTREAM_DIRECTORY))

# Import only after sanitizing the environment.  These are internal upstream
# entry points pinned by ENGINE_COMMIT and covered by our integration tests.
from common import safe_write_bytes as _safe_write_bytes  # noqa: E402
from server import (  # noqa: E402
    _clean_payload as _upstream_clean_payload,
    _inspect_payload as _upstream_inspect_payload,
    capabilities as _upstream_capabilities,
)


def _json_object(pairs: list[tuple[str, Any]]) -> dict[str, Any]:
    result: dict[str, Any] = {}
    for key, value in pairs:
        if key in result:
            raise _DuplicateJSONKey(f"duplicate JSON key: {key}")
        result[key] = value
    return result


def _reject_json_constant(value: str) -> NoReturn:
    raise ValueError(f"non-finite JSON number: {value}")


def _parse_request(raw: bytes) -> dict[str, Any]:
    try:
        text = raw.decode("utf-8")
    except UnicodeDecodeError as exc:
        raise ProtocolError("invalid_json", "request must be UTF-8 JSON") from exc
    try:
        request = json.loads(
            text,
            object_pairs_hook=_json_object,
            parse_constant=_reject_json_constant,
        )
    except (_DuplicateJSONKey, json.JSONDecodeError, ValueError) as exc:
        raise ProtocolError("invalid_json", f"invalid JSON request: {exc}") from exc
    if not isinstance(request, dict):
        raise ProtocolError("invalid_request", "request must be a JSON object")
    return request


def _request_id(request: dict[str, Any]) -> str:
    request_id = request.get("requestID")
    if not isinstance(request_id, str) or not request_id:
        raise ProtocolError("invalid_request", "requestID must be a non-empty string")
    if len(request_id) > MAX_REQUEST_ID_CHARS:
        raise ProtocolError(
            "invalid_request",
            f"requestID must not exceed {MAX_REQUEST_ID_CHARS} characters",
        )
    return request_id


def _unexpected_fields(request: dict[str, Any], allowed: frozenset[str]) -> None:
    unexpected = sorted(set(request) - allowed)
    if unexpected:
        raise ProtocolError(
            "invalid_request",
            f"unexpected request field(s): {', '.join(unexpected)}",
            details={"unexpectedFields": unexpected},
        )


def _path_field(request: dict[str, Any], field: str) -> Path:
    value = request.get(field)
    if not isinstance(value, str) or not value:
        raise ProtocolError("invalid_request", f"{field} must be a non-empty string")
    if "\x00" in value:
        raise ProtocolError("invalid_request", f"{field} must not contain NUL bytes")
    path = Path(value)
    if not path.is_absolute():
        raise ProtocolError("invalid_request", f"{field} must be an absolute path")
    return path


def _read_input(path: Path) -> bytes:
    try:
        before = path.lstat()
    except FileNotFoundError as exc:
        raise ProtocolError("input_not_found", f"input file does not exist: {path}") from exc
    except OSError as exc:
        raise ProtocolError("input_io_error", f"cannot inspect input file: {exc}") from exc

    if stat.S_ISLNK(before.st_mode):
        raise ProtocolError("invalid_input", "inputPath must not be a symbolic link")
    if not stat.S_ISREG(before.st_mode):
        raise ProtocolError("invalid_input", "inputPath must name a regular file")
    if before.st_size > MAX_INPUT_BYTES:
        raise ProtocolError(
            "input_too_large",
            f"input exceeds the {MAX_INPUT_BYTES}-byte limit",
            details={"actualBytes": before.st_size, "maxBytes": MAX_INPUT_BYTES},
        )

    flags = os.O_RDONLY
    flags |= getattr(os, "O_CLOEXEC", 0)
    flags |= getattr(os, "O_NOFOLLOW", 0)
    try:
        descriptor = os.open(path, flags)
        with os.fdopen(descriptor, "rb") as stream:
            opened = os.fstat(stream.fileno())
            if not stat.S_ISREG(opened.st_mode):
                raise ProtocolError("invalid_input", "inputPath must name a regular file")
            if opened.st_size > MAX_INPUT_BYTES:
                raise ProtocolError(
                    "input_too_large",
                    f"input exceeds the {MAX_INPUT_BYTES}-byte limit",
                    details={"actualBytes": opened.st_size, "maxBytes": MAX_INPUT_BYTES},
                )
            data = stream.read(MAX_INPUT_BYTES + 1)
    except ProtocolError:
        raise
    except FileNotFoundError as exc:
        raise ProtocolError("input_not_found", f"input file does not exist: {path}") from exc
    except PermissionError as exc:
        raise ProtocolError("input_permission_denied", f"cannot read input file: {path}") from exc
    except OSError as exc:
        raise ProtocolError("input_io_error", f"cannot read input file: {exc}") from exc

    if len(data) > MAX_INPUT_BYTES:
        raise ProtocolError(
            "input_too_large",
            f"input exceeds the {MAX_INPUT_BYTES}-byte limit",
            details={"maxBytes": MAX_INPUT_BYTES},
        )
    return data


def _validate_output(input_path: Path, output_path: Path) -> None:
    # samefile also catches hard links.  Fall back to canonical path comparison
    # when the destination has not been created yet.
    try:
        if output_path.exists() and os.path.samefile(input_path, output_path):
            raise ProtocolError(
                "invalid_output",
                "outputPath must be different from inputPath",
            )
    except OSError:
        pass
    if os.path.realpath(input_path) == os.path.realpath(output_path):
        raise ProtocolError("invalid_output", "outputPath must be different from inputPath")

    parent = output_path.parent
    try:
        parent_status = parent.stat()
    except FileNotFoundError as exc:
        raise ProtocolError("invalid_output", "outputPath parent directory does not exist") from exc
    except OSError as exc:
        raise ProtocolError("output_io_error", f"cannot inspect output directory: {exc}") from exc
    if not stat.S_ISDIR(parent_status.st_mode):
        raise ProtocolError("invalid_output", "outputPath parent must be a directory")

    try:
        status = output_path.lstat()
    except FileNotFoundError:
        return
    except OSError as exc:
        raise ProtocolError("output_io_error", f"cannot inspect outputPath: {exc}") from exc
    if stat.S_ISLNK(status.st_mode):
        raise ProtocolError("invalid_output", "outputPath must not be a symbolic link")
    if not stat.S_ISREG(status.st_mode):
        raise ProtocolError("invalid_output", "existing outputPath must be a regular file")


def _clean_options(request: dict[str, Any]) -> dict[str, Any]:
    options = request.get("options", {})
    if not isinstance(options, dict):
        raise ProtocolError("invalid_options", "options must be a JSON object")

    unknown = sorted(set(options) - set(_OPTION_TYPES))
    if unknown:
        raise ProtocolError(
            "invalid_options",
            f"unsupported cleaning option(s): {', '.join(unknown)}",
            details={"unsupportedOptions": unknown},
        )

    normalized = dict(_OPTION_DEFAULTS)
    for key, value in options.items():
        expected = _OPTION_TYPES[key]
        # bool is a subclass of int, so use exact types for a strict envelope.
        if type(value) is not expected:  # noqa: E721
            expected_name = "boolean" if expected is bool else "string"
            raise ProtocolError(
                "invalid_options",
                f"option {key} must be a {expected_name}",
                details={"option": key, "expectedType": expected_name},
            )
        normalized[key] = value

    deep_images = options.get("deepImages")
    if deep_images is not None and deep_images not in _DEEP_IMAGE_MODES:
        raise ProtocolError(
            "invalid_options",
            "option deepImages must be one of: auto, always, lossless, never",
            details={"option": "deepImages", "allowedValues": sorted(_DEEP_IMAGE_MODES)},
        )
    return {_OPTION_MAP[key]: value for key, value in normalized.items()}


def _report_object(value: Any) -> dict[str, Any]:
    """Keep arbitrary upstream report fields without assuming their schema."""

    if isinstance(value, dict):
        return value
    return {"upstreamReport": value}


def _safe_upstream_capabilities() -> dict[str, Any]:
    report = _upstream_capabilities()
    if not isinstance(report, dict):
        return {"upstreamReport": report}

    # Defence in depth: never advertise backends that this wrapper forbids,
    # even if a future upstream capability probe changes its env lookup.
    report["pixel_backends"] = {"ctrlregen": False, "diffusion": False}
    scorers = report.get("scorers")
    if isinstance(scorers, dict):
        scorers["synthid"] = False
        scorers["synthid_http"] = False
    report["harnesses"] = {"markllm": False}
    detectors = report.get("text_detectors")
    if isinstance(detectors, dict):
        for value in detectors.values():
            if isinstance(value, dict):
                value["available"] = False
    return report


def _capabilities_response(request_id: str) -> dict[str, Any]:
    report: dict[str, Any] = {
        "protocolVersion": PROTOCOL_VERSION,
        "engine": {"name": ENGINE_NAME, "commit": ENGINE_COMMIT},
        "runtime": {
            "pythonVersion": platform.python_version(),
            "opensslVersion": ssl.OPENSSL_VERSION,
            "packaged": bool(getattr(sys, "frozen", False)),
        },
        "operations": sorted(_OPERATIONS),
        "limits": {
            "maxInputBytes": MAX_INPUT_BYTES,
            "maxOutputBytes": MAX_OUTPUT_BYTES,
            "maxRequestLineBytes": MAX_REQUEST_LINE_BYTES,
            "concurrentRequests": 1,
        },
        "execution": {
            "offline": True,
            "networkBackends": False,
            "heavyModelBackends": False,
            "c2patoolNetworkPolicy": (
                "deny-all" if os.environ.get("C2PATOOL_SETTINGS") else "disabled"
            ),
            "cancellation": "terminate-process",
        },
        "cleanOptions": {
            "normalizeSpaces": {"type": "boolean", "default": False},
            "keepNonAIMetadata": {"type": "boolean", "default": True},
            "stripAllMetadata": {"type": "boolean", "default": False},
            "alsoLayerAText": {"type": "boolean", "default": True},
            "deepImages": {
                "type": "string",
                "default": "auto",
                "allowedValues": sorted(_DEEP_IMAGE_MODES),
            },
        },
        "upstream": _safe_upstream_capabilities(),
    }
    return {"requestID": request_id, "ok": True, "kind": "capabilities", "report": report}


def _inspect_response(request_id: str, input_path: Path) -> dict[str, Any]:
    data = _read_input(input_path)
    try:
        result = _upstream_inspect_payload(data, input_path.name, False)
    except ValueError as exc:
        raise ProtocolError("processing_error", str(exc)) from exc
    except OSError as exc:
        raise ProtocolError("processing_io_error", f"inspection failed: {exc}") from exc

    if not isinstance(result, dict):
        raise RuntimeError("upstream inspection returned a non-object result")
    kind = result.get("kind")
    if not isinstance(kind, str):
        kind = "unknown"
    report = dict(_report_object(result.get("report")))
    report.setdefault("suspicious", bool(result.get("suspicious")))
    return {"requestID": request_id, "ok": True, "kind": kind, "report": report}


def _clean_response(
    request_id: str,
    input_path: Path,
    output_path: Path,
    options: dict[str, Any],
) -> dict[str, Any]:
    _validate_output(input_path, output_path)
    data = _read_input(input_path)
    try:
        result = _upstream_clean_payload(data, input_path.name, options)
    except ValueError as exc:
        raise ProtocolError("processing_error", str(exc)) from exc
    except OSError as exc:
        raise ProtocolError("processing_io_error", f"cleaning failed: {exc}") from exc

    if not isinstance(result, dict):
        raise RuntimeError("upstream cleaning returned a non-object result")
    encoded = result.get("cleaned")
    if not isinstance(encoded, str):
        raise RuntimeError("upstream cleaning omitted cleaned bytes")
    try:
        cleaned = base64.b64decode(encoded, validate=True)
    except (binascii.Error, ValueError) as exc:
        raise RuntimeError("upstream cleaning returned invalid encoded bytes") from exc
    if len(cleaned) > MAX_OUTPUT_BYTES:
        raise ProtocolError(
            "output_too_large",
            f"cleaned output exceeds the {MAX_OUTPUT_BYTES}-byte limit",
            details={"actualBytes": len(cleaned), "maxBytes": MAX_OUTPUT_BYTES},
        )

    # The upstream helper uses a sibling temp file, fsync, and os.replace.  It
    # refuses symlink destinations and leaves an existing output untouched if
    # processing or writing fails before the final atomic replacement.
    try:
        _safe_write_bytes(output_path, cleaned)
    except PermissionError as exc:
        raise ProtocolError(
            "output_permission_denied",
            f"cannot write outputPath: {output_path}",
        ) from exc
    except OSError as exc:
        raise ProtocolError("output_io_error", f"cannot write outputPath: {exc}") from exc

    kind = result.get("kind")
    if not isinstance(kind, str):
        kind = "unknown"
    report = _report_object(result.get("report"))
    return {
        "requestID": request_id,
        "ok": True,
        "kind": kind,
        "report": report,
        "outputPath": str(output_path),
    }


def _handle_request(request: dict[str, Any]) -> dict[str, Any]:
    _unexpected_fields(request, _REQUEST_FIELDS)
    request_id = _request_id(request)

    operation = request.get("operation")
    if not isinstance(operation, str):
        raise ProtocolError("invalid_request", "operation must be a string")
    if operation not in _OPERATIONS:
        raise ProtocolError(
            "unsupported_operation",
            f"unsupported operation: {operation}",
            details={"operation": operation, "supportedOperations": sorted(_OPERATIONS)},
        )

    if operation == "capabilities":
        _unexpected_fields(request, frozenset({"requestID", "operation"}))
        return _capabilities_response(request_id)

    if operation == "inspect":
        _unexpected_fields(request, frozenset({"requestID", "operation", "inputPath"}))
        return _inspect_response(request_id, _path_field(request, "inputPath"))

    _unexpected_fields(
        request,
        frozenset({"requestID", "operation", "inputPath", "outputPath", "options"}),
    )
    input_path = _path_field(request, "inputPath")
    output_path = _path_field(request, "outputPath")
    return _clean_response(request_id, input_path, output_path, _clean_options(request))


def _json_safe(value: Any) -> Any:
    """Convert a future/upstream report into strict JSON without rejecting it."""

    if value is None or isinstance(value, (str, bool, int)):
        return value
    if isinstance(value, float):
        return value if math.isfinite(value) else None
    if isinstance(value, dict):
        return {str(key): _json_safe(item) for key, item in value.items()}
    if isinstance(value, (list, tuple)):
        return [_json_safe(item) for item in value]
    if isinstance(value, (set, frozenset)):
        return [_json_safe(item) for item in sorted(value, key=repr)]
    if isinstance(value, Path):
        return str(value)
    return str(value)


def _emit(response: dict[str, Any]) -> None:
    data = json.dumps(
        _json_safe(response),
        ensure_ascii=False,
        allow_nan=False,
        sort_keys=True,
        separators=(",", ":"),
    ).encode("utf-8")
    sys.stdout.buffer.write(data + b"\n")
    sys.stdout.buffer.flush()


def _error_response(request_id: str, error: ProtocolError) -> dict[str, Any]:
    response: dict[str, Any] = {
        "requestID": request_id,
        "ok": False,
        "kind": error.code,
        "report": {},
        "error": error.message,
    }
    if error.details:
        response["report"] = {"details": error.details}
    return response


def _drain_oversized_line(first_chunk: bytes) -> None:
    if first_chunk.endswith(b"\n"):
        return
    while True:
        chunk = sys.stdin.buffer.readline(MAX_REQUEST_LINE_BYTES + 1)
        if not chunk or chunk.endswith(b"\n"):
            return


def main() -> int:
    while True:
        raw = sys.stdin.buffer.readline(MAX_REQUEST_LINE_BYTES + 1)
        if not raw:
            return 0
        if len(raw) > MAX_REQUEST_LINE_BYTES:
            _drain_oversized_line(raw)
            _emit(
                _error_response(
                    "",
                    ProtocolError(
                        "request_too_large",
                        f"request line exceeds the {MAX_REQUEST_LINE_BYTES}-byte limit",
                        details={"maxBytes": MAX_REQUEST_LINE_BYTES},
                    ),
                )
            )
            continue

        request_id = ""
        try:
            request = _parse_request(raw)
            candidate_id = request.get("requestID")
            if isinstance(candidate_id, str) and len(candidate_id) <= MAX_REQUEST_ID_CHARS:
                request_id = candidate_id
            response = _handle_request(request)
        except ProtocolError as exc:
            response = _error_response(request_id, exc)
        except Exception as exc:  # keep one malformed file from killing the long-lived helper
            print(f"provenance helper internal error: {type(exc).__name__}: {exc}", file=sys.stderr)
            response = _error_response(
                request_id,
                ProtocolError("internal_error", "the provenance engine failed unexpectedly"),
            )
        _emit(response)


if __name__ == "__main__":
    raise SystemExit(main())
