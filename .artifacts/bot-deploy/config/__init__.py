import json
import os
from pathlib import Path


CONFIG_DIR = Path(__file__).resolve().parent
PROJECT_ROOT = str(CONFIG_DIR.parent)
DEFAULT_USE_CASE = "tax_pdf_forms"
VALID_USE_CASES = ("tax_pdf_forms", "eng_design_ppt")

_cache: dict[str, dict] = {}


def _load(filename: str) -> dict:
    path = CONFIG_DIR / filename
    return json.loads(path.read_text(encoding="utf-8"))


def _get(filename: str) -> dict:
    if filename not in _cache:
        _cache[filename] = _load(filename)
    return _cache[filename]


def get_use_case() -> str:
    use_case = os.environ.get("USE_CASE", DEFAULT_USE_CASE)
    if use_case not in VALID_USE_CASES:
        raise ValueError(f"Invalid USE_CASE '{use_case}'. Must be one of {VALID_USE_CASES}")
    return use_case


def azure_resources() -> dict:
    return _get("azure_resources.json")


def agent_config() -> dict:
    return _get("agent_config.json")


def prompts_config() -> dict:
    return _get("prompts_config.json")


def document_config() -> dict:
    return _get("document_config.json")


def search_config() -> dict:
    return _get("search_config.json")


def storage_config() -> dict:
    return _get("storage_config.json")


def use_case_settings(use_case: str | None = None) -> dict:
    key = use_case or get_use_case()
    return azure_resources()["use_cases"][key]


def uc_agent_config(use_case: str | None = None) -> dict:
    key = use_case or get_use_case()
    return agent_config()["use_cases"][key]


def project_endpoint() -> str:
    return azure_resources()["foundry"]["project_endpoint"]


def apim_gateway_url() -> str:
    return azure_resources()["apim"]["gateway_url"]


def apim_api_base_url() -> str:
    apim = azure_resources()["apim"]
    return f"{apim['gateway_url']}/{apim['api_path']}/api"


def app_service_urls() -> dict:
    return azure_resources()["app_services"]


def default_allowed_origins() -> str:
    apps = azure_resources()["app_services"]
    return f"{apps['ui_url']},http://localhost:4200"
