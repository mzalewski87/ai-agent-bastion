"""
AI Agent Bastion Live Range – Flask Backend.
100% live integration based on PANW-AIRS-GCP-K8S/kubernetes/{gw-chatbot,api-chatbot}/app.py.
"""

import json
import logging
import os
import re
import uuid
from pathlib import Path

import requests

try:
    from flask import Flask, Response, jsonify, render_template, request
    from werkzeug.utils import secure_filename
except ImportError:
    Response = None
    def secure_filename(filename: str) -> str:
        name = os.path.basename(str(filename or "").strip().replace("\\", "/"))
        return re.sub(r"[^A-Za-z0-9._-]", "_", name).lstrip(".")

    class _FallbackRequest:
        def __init__(self):
            self._json = None
            self.files = {}

        def get_json(self, silent: bool = False):
            return self._json

    request = _FallbackRequest()

    def jsonify(obj):
        return obj

    def render_template(template_name: str) -> str:
        tpl_path = Path(__file__).resolve().parent / "templates" / template_name
        return tpl_path.read_text(encoding="utf-8")

    class _FallbackResponse:
        def __init__(self, payload, status_code: int = 200):
            self.status_code = int(status_code)
            if isinstance(payload, (dict, list)):
                self._json = payload
                self._text = json.dumps(payload, ensure_ascii=False)
            else:
                self._json = None
                self._text = str(payload)
            self.data = self._text.encode("utf-8")

        def get_data(self, as_text: bool = False):
            return self._text if as_text else self.data

        def get_json(self):
            if self._json is not None:
                return self._json
            try:
                return json.loads(self._text)
            except Exception:
                return None

    class _FallbackTestClient:
        def __init__(self, app_obj):
            self._app = app_obj

        def get(self, path: str):
            return self._app._dispatch("GET", path, None, None)

        def post(self, path: str, json=None, data=None):
            return self._app._dispatch("POST", path, json, data)

    class Flask:
        def __init__(self, name: str, static_folder: str = "static", template_folder: str = "templates"):
            self.name = name
            self.static_folder = static_folder
            self.template_folder = template_folder
            self.config = {}
            self._routes = []

        def route(self, rule: str, methods=None):
            allowed = [m.upper() for m in (methods or ["GET"])]
            pattern = re.sub(r"<(?:path:)?(\w+)>", r"(?P<\1>.+)", rule)
            regex = re.compile(f"^{pattern}$")

            def decorator(fn):
                self._routes.append((regex, allowed, fn))
                return fn

            return decorator

        def _dispatch(self, method: str, path: str, json_body=None, files_body=None):
            clean_path = path.split("?", 1)[0]
            request._json = json_body
            request.files = files_body or {}
            for regex, allowed, fn in self._routes:
                m = regex.match(clean_path)
                if m and method.upper() in allowed:
                    res = fn(**m.groupdict())
                    if isinstance(res, tuple):
                        body, code = res[0], res[1]
                    else:
                        body, code = res, 200
                    return _FallbackResponse(body, code)
            return _FallbackResponse({"error": "Not found"}, 404)

        def test_client(self):
            return _FallbackTestClient(self)

        def run(self, host: str = "0.0.0.0", port: int = 5050):
            from http.server import BaseHTTPRequestHandler, HTTPServer
            app_ref = self
            base_dir = Path(__file__).resolve().parent

            class Handler(BaseHTTPRequestHandler):
                def do_GET(self):
                    if self.path.startswith("/static/"):
                        fp = base_dir / self.path.lstrip("/")
                        if fp.is_file():
                            self.send_response(200)
                            ctype = (
                                "image/png"
                                if fp.suffix == ".png"
                                else "image/jpeg"
                                if fp.suffix in (".jpg", ".jpeg")
                                else "application/javascript"
                                if fp.suffix == ".js"
                                else "text/css"
                                if fp.suffix == ".css"
                                else "text/plain"
                            )
                            self.send_header("Content-Type", ctype)
                            self.end_headers()
                            self.wfile.write(fp.read_bytes())
                            return
                    resp = app_ref._dispatch("GET", self.path)
                    self.send_response(resp.status_code)
                    ctype = "application/json" if resp._json is not None else "text/html; charset=utf-8"
                    self.send_header("Content-Type", ctype)
                    self.end_headers()
                    self.wfile.write(resp.data)

                def do_POST(self):
                    length = int(self.headers.get("Content-Length", "0"))
                    raw = self.rfile.read(length) if length > 0 else b""
                    try:
                        parsed = json.loads(raw.decode("utf-8")) if raw else {}
                    except Exception:
                        parsed = {}
                    resp = app_ref._dispatch("POST", self.path, json_body=parsed)
                    self.send_response(resp.status_code)
                    self.send_header("Content-Type", "application/json; charset=utf-8")
                    self.end_headers()
                    self.wfile.write(resp.data)

            HTTPServer((host, int(port)), Handler).serve_forever()

import mcp_servers
import security_engine as se

logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")
log = logging.getLogger("agent-bastion-app")

MAX_UPLOAD_MB = int(os.environ.get("MAX_UPLOAD_MB", "2"))

app = Flask(__name__, static_folder="static", template_folder="templates")
app.config["MAX_CONTENT_LENGTH"] = MAX_UPLOAD_MB * 1024 * 1024


def gateway_headers() -> dict:
    return se.gateway_headers()


def guardrail_summary(payload: dict) -> list:
    return se.guardrail_summary(payload)


def call_gateway(messages: list, gw_url: str = None) -> tuple:
    status, payload, _ = se.call_gateway(messages, gw_url=gw_url)
    return status, payload


def run_gateway_mcp_loop(user_message: str, gateway_mode: str = "ai_gateway") -> tuple:
    return se.run_gateway_mcp_loop(user_message, gateway_mode=gateway_mode)


@app.route("/")
def index():
    return render_template("index.html")


def _extract_incoming_message() -> tuple:
    data = {}
    try:
        data = request.get_json(force=True, silent=True) or {}
    except Exception:
        data = request.get_json(silent=True) or {}
    if not isinstance(data, dict):
        data = {}

    msg = ""
    for k in ("message", "input", "prompt", "query", "text", "content", "question"):
        val = data.get(k)
        if isinstance(val, str) and val.strip():
            msg = val.strip()
            break
    if not msg and isinstance(data.get("messages"), list) and data["messages"]:
        last = data["messages"][-1]
        if isinstance(last, dict) and isinstance(last.get("content"), str):
            msg = last["content"].strip()
    if not msg and hasattr(request, "get_data"):
        try:
            raw_text = (request.get_data(as_text=True) or "").strip()
            if raw_text:
                try:
                    parsed = json.loads(raw_text)
                    if isinstance(parsed, dict):
                        for k in ("message", "input", "prompt", "query", "text", "content"):
                            if isinstance(parsed.get(k), str) and parsed[k].strip():
                                msg = parsed[k].strip()
                                break
                except Exception:
                    msg = raw_text
        except Exception:
            pass
    if msg in ("", "{INPUT}", "{{prompt}}", "{prompt}", "{{INPUT}}"):
        msg = "Hello, please confirm what tools and capabilities you have as an assistant."
    return msg, data


@app.route("/api/chat", methods=["POST"])
def api_chat():
    msg, data = _extract_incoming_message()
    mode = (data.get("mode") or "unprotected").strip().lower()
    lang = (data.get("lang") or "pl").strip().lower()
    session_id = data.get("session_id")

    if mode in ("unprotected", "direct_vertex", "1"):
        code, body = se.run_vertex_mcp_loop(msg, enable_airs_runtime=False, session_id=session_id, lang=lang)
        return jsonify(body), code
    if mode in ("api_runtime", "runtime", "2"):
        code, body = se.run_vertex_mcp_loop(msg, enable_airs_runtime=True, session_id=session_id, lang=lang)
        return jsonify(body), code
    if mode in ("ai_gateway", "ai_gateway_local", "gateway", "3"):
        code, body = se.run_gateway_mcp_loop(msg, gateway_mode=mode, lang=lang)
        return jsonify(body), code
    code, body = se.run_gateway_mcp_loop(msg, gateway_mode="ai_gateway", lang=lang)
    return jsonify(body), code


# Dedicated AI Red Teaming Targets (100% compliant with DEPLOYMENT_GUIDE.md § 11a.4)
@app.route("/api/chat/unprotected", methods=["POST"])
def api_chat_unprotected():
    msg, data = _extract_incoming_message()
    lang = (data.get("lang") or "en").strip().lower()
    code, body = se.run_redteam_unprotected_endpoint(msg, lang=lang)
    return jsonify(body), code


@app.route("/api/chat/runtime", methods=["POST"])
def api_chat_runtime():
    msg, data = _extract_incoming_message()
    lang = (data.get("lang") or "en").strip().lower()
    code, body = se.run_redteam_runtime_endpoint(msg, lang=lang)
    return jsonify(body), code


@app.route("/api/chat/gateway", methods=["POST"])
def api_chat_gateway():
    msg, data = _extract_incoming_message()
    lang = (data.get("lang") or "en").strip().lower()
    code, body = se.run_redteam_gateway_endpoint(msg, lang=lang)
    return jsonify(body), code


@app.route("/api/redteam/scm-abort/<job_id>", methods=["POST"])
def api_redteam_scm_abort(job_id: str):
    try:
        res = se.scm_abort_scan(job_id=job_id)
        return jsonify(res), 200
    except Exception as exc:
        log.error("SCM Red Teaming abort error [%s]: %s", job_id, exc)
        return jsonify({"status": "error", "error": str(exc)}), 502


@app.route("/api/redteam/scm-preview/<job_id>", methods=["GET"])
def api_redteam_scm_preview(job_id: str):
    lang = "pl"
    if hasattr(request, "args"):
        lang = request.args.get("lang", "pl")
    try:
        res = se.scm_get_job_preview_data(job_id=job_id, lang=lang)
        return jsonify(res), 200
    except Exception as exc:
        log.error("SCM preview error [%s]: %s", job_id, exc)
        return jsonify({"status": "error", "error": str(exc)}), 502


@app.route("/api/redteam/scm-create-policy", methods=["POST"])
def api_redteam_scm_create_policy():
    data = {}
    try:
        data = request.get_json(force=True, silent=True) or {}
    except Exception:
        data = {}
    job_id = (data.get("job_id") or "").strip() or None
    custom_name = (data.get("profile_name") or "").strip() or None
    try:
        res = se.scm_create_loose_policy_preview(job_id=job_id, custom_name=custom_name)
        return jsonify(res), 200
    except Exception as exc:
        log.error("SCM create loose policy error: %s", exc)
        return jsonify({"status": "error", "error": str(exc)}), 502


@app.route("/api/redteam/scm-status", methods=["GET"])
def api_redteam_scm_status():
    try:
        res = se.scm_get_redteam_status()
        return jsonify(res), 200
    except Exception as exc:
        log.error("SCM Red Teaming status error: %s", exc)
        return jsonify({"status": "error", "error": str(exc)}), 502


@app.route("/api/redteam/scm-launch", methods=["POST"])
def api_redteam_scm_launch():
    data = {}
    try:
        data = request.get_json(force=True, silent=True) or {}
    except Exception:
        data = {}
    target_key = (data.get("target") or "unprotected").strip().lower()
    job_type = (data.get("job_type") or "DYNAMIC").strip().upper()
    try:
        res = se.scm_launch_scan(target_key=target_key, job_type=job_type)
        return jsonify(res), 200
    except Exception as exc:
        log.error("SCM Red Teaming launch error: %s", exc)
        return jsonify({"status": "error", "error": str(exc)}), 502


@app.route("/api/redteam/scm-report/<job_id>", methods=["GET"])
def api_redteam_scm_report(job_id: str):
    fmt = "pdf_html"
    lang = "pl"
    if hasattr(request, "args"):
        fmt = request.args.get("format", "pdf_html")
        lang = request.args.get("lang", "pl")
    try:
        content, mime_type, filename = se.scm_download_job_report(job_id=job_id, fmt=fmt, lang=lang)
        if mime_type == "redirect" and Response is not None:
            return Response("", status=302, headers={"Location": content})
        if Response is not None:
            disp = "inline" if fmt == "pdf_html" else f'attachment; filename="{filename}"'
            return Response(content, mimetype=mime_type.split(";")[0], headers={"Content-Disposition": disp})
        return content, 200
    except Exception as exc:
        log.error("SCM report error [%s]: %s", job_id, exc)
        return jsonify({"status": "error", "error": str(exc)}), 502


@app.route("/api/redteam/scan", methods=["POST"])
def api_redteam_scan():
    data = {}
    try:
        data = request.get_json(force=True, silent=True) or {}
    except Exception:
        data = {}
    lang = (data.get("lang") or "pl").strip().lower()
    scan_res = se.run_redteam_comparative_scan(lang=lang)
    return jsonify(scan_res), 200


@app.route("/api/redteam/report", methods=["GET"])
def api_redteam_report():
    target = "all"
    fmt = "html"
    lang = "pl"
    inline = "0"
    if hasattr(request, "args"):
        target = request.args.get("target", "all")
        fmt = request.args.get("format", "html")
        lang = request.args.get("lang", "pl")
        inline = request.args.get("inline", "0")
    content, mime_type, filename = se.render_redteam_report(target=target, fmt=fmt, lang=lang)
    if Response is not None:
        disp = "inline" if inline == "1" else f'attachment; filename="{filename}"'
        return Response(content, mimetype=mime_type.split(";")[0], headers={"Content-Disposition": disp})
    return content, 200


@app.route("/api/documents", methods=["GET"])
def api_documents():
    return jsonify(mcp_servers.list_documents())


@app.route("/api/documents/<path:doc_name>", methods=["GET"])
def api_read_document(doc_name: str):
    return jsonify(mcp_servers.read_document(doc_name))


@app.route("/api/upload", methods=["POST"])
def api_upload():
    file = request.files.get("file")
    if file is None or not file.filename:
        return jsonify({"error": "Brak pliku do wgrania"}), 400
    name = secure_filename(file.filename)
    if not name:
        return jsonify({"error": "Nieprawidłowa nazwa pliku"}), 400
    mcp_servers.DOCUMENTS_DIR.mkdir(parents=True, exist_ok=True)
    file.save(mcp_servers.DOCUMENTS_DIR / name)
    log.info("Uploaded document to MCP corpus: %s", name)
    return jsonify({"uploaded": name, "documents": mcp_servers.list_documents()})


@app.route("/api/reset", methods=["POST"])
def api_reset():
    snap = mcp_servers.reset_demo_state()
    return jsonify({"status": "ok", "documents": mcp_servers.list_documents(), "system_state": snap})


@app.route("/api/state", methods=["GET"])
def api_state():
    return jsonify({
        "config": se.get_public_config(),
        "redis": se.check_redis_status(),
        "documents": mcp_servers.list_documents(),
        "inbox": mcp_servers.list_inbox(),
        "system_state": mcp_servers.get_demo_state_snapshot(),
        "stats": se.STATS,
        "mcp_tools": [t["name"] for t in mcp_servers.TOOLS],
    })


@app.route("/api/config", methods=["POST"])
def api_update_config():
    updates = request.get_json(silent=True) or {}
    cfg = se.update_config(updates)
    return jsonify({"status": "updated", "config": cfg})


@app.route("/api/scan-status", methods=["GET"])
def api_scan_status():
    return jsonify(se.get_public_config())


@app.route("/health")
def health():
    return jsonify({"status": "healthy", "airs_sdk": se.AIRS_SDK_INSTALLED, "airs_active": se.airs_scanner is not None})


@app.route("/ready")
def ready():
    return jsonify({"ready": True, "cluster": "agent-bastion-gke", "model": se.CONFIG["VERTEX_AI_MODEL"]})


if __name__ == "__main__":
    app.run(host="0.0.0.0", port=int(os.environ.get("PORT", "5050")))
