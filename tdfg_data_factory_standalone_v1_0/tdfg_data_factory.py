from __future__ import annotations

import json
import os
import random
import re
import subprocess
import sys
import threading
import time
import traceback
from datetime import datetime, date, timedelta
from pathlib import Path
from typing import Any, Dict, List, Optional

import tkinter as tk
from tkinter import ttk, filedialog, messagebox

try:
    import requests
    import urllib3
    urllib3.disable_warnings(urllib3.exceptions.InsecureRequestWarning)
except Exception:  # pragma: no cover
    requests = None

try:
    import yaml
except Exception:  # pragma: no cover
    yaml = None

APP_VERSION = "1.2.2"
APP_TITLE = f"TDFG Data Factory v{APP_VERSION}"
DEFAULT_SCENARIO = "tdfg_create_client.yaml"

PACKAGE_CHOICES = {
    "none": {"title": "Без ПУ", "code": "", "name": ""},
    "prime": {"title": "Прайм+", "code": "PRIME2", "name": "Прайм+"},
    "privilege": {"title": "ПривилегияМК", "code": "PRIVILEGE2", "name": "ПривилегияМК"},
    "multi": {"title": "Мультикарта", "code": "MULTICARTA", "name": "Мультикарта"},
}

LAST_NAMES = [
    "Иванов", "Петров", "Сидоров", "Смирнов", "Кузнецов", "Попов", "Соколов", "Лебедев",
    "Козлов", "Новиков", "Морозов", "Ершов", "Федоров", "Волков", "Алексеев", "Орлов",
    "Макаров", "Захаров", "Андреев", "Сергеев", "Григорьев", "Романов", "Яковлев", "Павлов",
]
FIRST_NAMES = [
    "Александр", "Михаил", "Дмитрий", "Сергей", "Андрей", "Алексей", "Иван", "Максим",
    "Егор", "Кирилл", "Матвей", "Ярослав", "Никита", "Роман", "Тимофей", "Владимир",
    "Павел", "Виктор", "Олег", "Илья", "Артём", "Константин", "Евгений", "Виталий",
]
MIDDLE_NAMES = [
    "Александрович", "Михайлович", "Дмитриевич", "Сергеевич", "Алексеевич", "Иванович",
    "Андреевич", "Егорович", "Кириллович", "Максимович", "Романович", "Тимофеевич",
    "Павлович", "Владимирович", "Олегович", "Юрьевич", "Ильич", "Федорович",
]


def resource_path(name: str) -> Path:
    if getattr(sys, "frozen", False):
        return Path(sys.executable).resolve().parent / name
    return Path(__file__).resolve().parent / name


def load_yaml_file(path: Path) -> Dict[str, Any]:
    if yaml is None:
        raise RuntimeError("Не установлен PyYAML. Выполни: pip install PyYAML")
    if not path.exists():
        raise FileNotFoundError(f"Файл сценария не найден: {path}")
    with path.open("r", encoding="utf-8") as f:
        data = yaml.safe_load(f)
    if not isinstance(data, dict):
        raise RuntimeError("YAML должен быть объектом верхнего уровня")
    return data


def pretty_json(value: Any) -> str:
    return json.dumps(value, ensure_ascii=False, indent=2)


def short_text(value: str, limit: int = 2500) -> str:
    value = value or ""
    return value if len(value) <= limit else value[:limit] + "\n...<обрезано>"


def random_digits(length: int) -> str:
    return "".join(str(random.randint(0, 9)) for _ in range(length))


def random_birthday(start_s: str, end_s: str) -> str:
    start = date.fromisoformat(start_s)
    end = date.fromisoformat(end_s)
    delta = (end - start).days
    return (start + timedelta(days=random.randint(0, max(delta, 0)))).isoformat()


def generate_value(rule: str) -> str:
    rule = str(rule or "")
    if rule == "random_first_name":
        return random.choice(FIRST_NAMES)
    if rule == "random_last_name":
        return random.choice(LAST_NAMES)
    if rule == "random_middle_name":
        return random.choice(MIDDLE_NAMES)
    if rule.startswith("digits:"):
        return random_digits(int(rule.split(":", 1)[1]))
    if rule == "passport_code":
        return f"{random_digits(3)}-{random_digits(3)}"
    if rule == "mobile_phone":
        return "89" + random_digits(9)
    if rule == "job_phone":
        return "8495" + random_digits(7)
    if rule == "home_phone":
        return "8495" + random_digits(7)
    if rule.startswith("birthday:"):
        _, start_s, end_s = rule.split(":", 2)
        return random_birthday(start_s, end_s)
    return rule


class TemplateError(RuntimeError):
    pass


def render_template(value: Any, context: Dict[str, Any], strict: bool = True) -> Any:
    if isinstance(value, dict):
        return {k: render_template(v, context, strict=strict) for k, v in value.items()}
    if isinstance(value, list):
        return [render_template(v, context, strict=strict) for v in value]
    if not isinstance(value, str):
        return value

    def replace(match: re.Match) -> str:
        key = match.group(1).strip()
        if key not in context:
            if strict:
                raise TemplateError(f"Переменная {{{{{key}}}}} не найдена")
            return match.group(0)
        return str(context.get(key, ""))

    return re.sub(r"\{\{\s*([^}]+?)\s*\}\}", replace, value)


def simple_json_path(data: Any, path: str) -> Any:
    if not path or path == "$":
        return data
    value = data
    expr = path.strip()
    if expr.startswith("$."):
        expr = expr[2:]
    elif expr.startswith("$"):
        expr = expr[1:].lstrip(".")

    tokens: List[Any] = []
    for part in expr.split("."):
        if not part:
            continue
        m = re.match(r"^([^\[]+)(.*)$", part)
        if not m:
            tokens.append(part)
            continue
        name, rest = m.group(1), m.group(2)
        tokens.append(name)
        for idx in re.findall(r"\[(\d+)\]", rest):
            tokens.append(int(idx))

    for token in tokens:
        if isinstance(token, int):
            if not isinstance(value, list) or token >= len(value):
                return None
            value = value[token]
        else:
            if not isinstance(value, dict) or token not in value:
                return None
            value = value[token]
    return value


class WorkflowRunner:
    def __init__(self, scenario: Dict[str, Any], log_callback=None, request_overrides: Optional[Dict[str, Dict[str, Any]]] = None, request_timeout: int = 15):
        if requests is None:
            raise RuntimeError("Не установлен requests. Выполни: pip install requests")
        self.scenario = scenario
        self.log_callback = log_callback or (lambda text: None)
        self.request_overrides = request_overrides or {}
        self.request_timeout = max(1, int(request_timeout or 15))
        self.session = requests.Session()
        self.context: Dict[str, Any] = dict(scenario.get("variables") or {})
        self.default_headers = dict(scenario.get("default_headers") or {})
        self.last_log_dir: Optional[Path] = None

    def log(self, text: str) -> None:
        self.log_callback(text)

    def _log_jsonl(self, payload: Dict[str, Any]) -> None:
        if not self.last_log_dir:
            return
        with (self.last_log_dir / "run_log.jsonl").open("a", encoding="utf-8") as f:
            f.write(json.dumps(payload, ensure_ascii=False) + "\n")

    def start_log_dir(self) -> Path:
        root = resource_path("tdfg_logs")
        root.mkdir(parents=True, exist_ok=True)
        run_dir = root / datetime.now().strftime("run_%Y%m%d_%H%M%S")
        run_dir.mkdir(parents=True, exist_ok=True)
        self.last_log_dir = run_dir
        return run_dir

    def get_step(self, step_id: str) -> Dict[str, Any]:
        for step in self.scenario.get("steps") or []:
            if step.get("id") == step_id:
                return step
        raise RuntimeError(f"Шаг не найден: {step_id}")

    def render_step_preview(self, step_id: str, extra_context: Dict[str, Any]) -> str:
        prepared = self.render_step_request_for_editor(step_id, extra_context, apply_override=True)
        parts = [f"{prepared['method']} {prepared['url']}"]
        if prepared.get("headers"):
            parts.append("Headers:\n" + pretty_json(prepared["headers"]))
        body = prepared.get("body") or ""
        if body:
            try:
                parts.append("Body:\n" + pretty_json(json.loads(body)))
            except Exception:
                parts.append("Body:\n" + body)
        return "\n\n".join(parts)

    def render_step_request_for_editor(self, step_id: str, extra_context: Dict[str, Any], apply_override: bool = True) -> Dict[str, Any]:
        old_context = dict(self.context)
        try:
            self.context.update(extra_context)
            step = self.get_step(step_id)
            for key, rule in (step.get("generate") or {}).items():
                self.context.setdefault(str(key), generate_value(str(rule)))
            return self._prepare_request(step, apply_override=apply_override, for_preview=True)
        finally:
            self.context = old_context

    def run_steps(self, step_ids: List[str], extra_context: Dict[str, Any], use_cookie_step: bool = True) -> Dict[str, Any]:
        self.context.update(extra_context)
        self.start_log_dir()
        self.log(f"Папка логов: {self.last_log_dir}")

        actual_ids = list(step_ids)
        if use_cookie_step and "get_cookie" not in actual_ids:
            actual_ids.insert(0, "get_cookie")

        for step_id in actual_ids:
            step = self.get_step(step_id)
            if not self._condition_ok(step):
                self.log(f"SKIP: {step.get('name')} — условие не выполнено")
                continue
            self._run_step(step)

        if self.last_log_dir:
            (self.last_log_dir / "final_context.json").write_text(pretty_json(self.context), encoding="utf-8")
        return self.context

    def _condition_ok(self, step: Dict[str, Any]) -> bool:
        cond = step.get("condition")
        if not isinstance(cond, dict):
            return True
        var = str(cond.get("variable") or "")
        value = str(self.context.get(var, ""))
        if cond.get("not_empty") is True:
            return bool(value.strip())
        if "equals" in cond:
            return value == str(cond.get("equals"))
        return True

    def _headers(self, step: Optional[Dict[str, Any]] = None) -> Dict[str, str]:
        headers = render_template(self.default_headers, self.context, strict=False)
        if isinstance(step, dict) and isinstance(step.get("headers"), dict):
            step_headers = render_template(step.get("headers") or {}, self.context, strict=False)
            headers.update(step_headers)
        headers = {str(k): str(v) for k, v in headers.items() if str(v).strip()}
        jsid = self.context.get("JSESSIONID")
        if jsid:
            old_cookie = headers.get("Cookie", "")
            if "JSESSIONID=" not in old_cookie:
                headers["Cookie"] = (old_cookie + "; " if old_cookie else "") + f"JSESSIONID={jsid}"
        return headers

    def _parse_headers_override(self, raw: Any) -> Dict[str, str]:
        if raw is None:
            return {}
        if isinstance(raw, dict):
            return {str(k): str(v) for k, v in raw.items() if str(v).strip()}
        if isinstance(raw, str):
            text = raw.strip()
            if not text:
                return {}
            try:
                parsed = json.loads(text)
                if isinstance(parsed, dict):
                    return {str(k): str(v) for k, v in parsed.items() if str(v).strip()}
            except Exception:
                result: Dict[str, str] = {}
                for line in text.splitlines():
                    if ":" in line:
                        key, value = line.split(":", 1)
                        if key.strip():
                            result[key.strip()] = value.strip()
                return result
        return {}

    def _prepare_request(self, step: Dict[str, Any], apply_override: bool = True, for_preview: bool = False) -> Dict[str, Any]:
        step_id = str(step.get("id") or "")
        url = render_template(step.get("url", ""), self.context)
        method = str(step.get("method", "GET")).upper()
        body_text = render_template(step.get("body", ""), self.context) if step.get("body") else None
        headers = self._headers(step)

        override = self.request_overrides.get(step_id) if apply_override else None
        if isinstance(override, dict) and override:
            method = str(override.get("method") or method).upper()
            if str(override.get("url") or "").strip():
                url = render_template(str(override.get("url")), self.context, strict=not for_preview)
            if "headers" in override:
                headers_raw = render_template(override.get("headers") or {}, self.context, strict=False)
                headers = self._parse_headers_override(headers_raw)
            if "body" in override:
                raw_body = override.get("body")
                if raw_body is None or str(raw_body) == "":
                    body_text = None
                else:
                    body_text = render_template(str(raw_body), self.context, strict=not for_preview)
        return {"method": method, "url": url, "headers": headers, "body": body_text, "overridden": bool(override)}

    def _save_request_file(self, step: Dict[str, Any], prepared: Dict[str, Any]) -> None:
        if not self.last_log_dir:
            return
        safe_name = re.sub(r"[^a-zA-Z0-9а-яА-Я_-]+", "_", str(step.get("id") or step.get("name") or "step")).strip("_")
        path = self.last_log_dir / f"request_{safe_name}.json"
        body = prepared.get("body")
        body_value: Any = body
        if isinstance(body, str) and body.strip():
            try:
                body_value = json.loads(body)
            except Exception:
                body_value = body
        payload = {
            "step": step.get("name"),
            "method": prepared.get("method"),
            "url": prepared.get("url"),
            "headers": prepared.get("headers") or {},
            "body": body_value,
            "overridden_from_ui": prepared.get("overridden", False),
        }
        path.write_text(pretty_json(payload), encoding="utf-8")
        self.log(f"Request file: {path.name}")

    def _run_step(self, step: Dict[str, Any]) -> None:
        name = str(step.get("name") or step.get("id") or "step")
        self.log(f"\n=== {name} ===")

        for key, rule in (step.get("generate") or {}).items():
            # Если мастер UI уже подготовил значение, не перезатираем его при отправке.
            # Это позволяет проверить и поправить ФИО/паспорт/телефон до запуска.
            if str(self.context.get(str(key), "")).strip():
                continue
            self.context[str(key)] = generate_value(str(rule))

        prepared = self._prepare_request(step, apply_override=True)
        url = str(prepared["url"])
        method = str(prepared["method"]).upper()
        body_text = prepared.get("body")
        headers = prepared.get("headers") or {}

        self.log(f"→ REQUEST: {method} {url}")
        if prepared.get("overridden"):
            self.log("Запрос изменён через редактор подкапотных запросов")
        if headers:
            self.log("Request headers:")
            self.log(pretty_json(headers))
        if body_text:
            self.log("Request body:")
            try:
                self.log(pretty_json(json.loads(str(body_text))))
            except Exception:
                self.log(str(body_text))
        self._save_request_file(step, prepared)

        started = time.time()
        try:
            response = self.session.request(
                method=method,
                url=url,
                headers=headers,
                data=body_text.encode("utf-8") if body_text is not None else None,
                timeout=self.request_timeout,
                verify=False,
            )
        except Exception as exc:
            error_text = f"{type(exc).__name__}: {exc}"
            self.log(f"ОШИБКА ЗАПРОСА: {error_text}")
            self._log_jsonl({
                "step": name,
                "method": method,
                "url": url,
                "error": error_text,
                "context_keys": sorted(self.context.keys()),
            })
            if step.get("continue_on_error"):
                self.log("Шаг помечен continue_on_error=true — переходим к следующему шагу.")
                return
            raise

        elapsed_ms = int((time.time() - started) * 1000)
        self.log(f"← RESPONSE: Status {response.status_code} | Time: {elapsed_ms} ms")
        self.log("Response headers:")
        self.log(pretty_json(dict(response.headers)))

        expected = step.get("expected_status") or []
        if expected and response.status_code not in expected:
            msg = f"Ожидался статус {expected}, пришёл {response.status_code}"
            self.log(msg)
            if not step.get("continue_on_error"):
                # сохраняем ответ до исключения
                self._save_response_file(step, response)
                raise RuntimeError(msg)

        cookie_rule = step.get("extract_cookie")
        if isinstance(cookie_rule, dict):
            cookie_name = str(cookie_rule.get("name") or "")
            save_as = str(cookie_rule.get("save_as") or cookie_name)
            if cookie_name:
                cookie_value = self.session.cookies.get(cookie_name)
                if cookie_value:
                    self.context[save_as] = cookie_value
                    self.log(f"Cookie extract: {save_as} = {cookie_value}")
                else:
                    self.log(f"Cookie {cookie_name} не найдена в ответе/session")

        response_data = self._parse_response(response)
        self._save_response_file(step, response, response_data=response_data)

        preview = response.text or ""
        if isinstance(response_data, (dict, list)):
            preview = pretty_json(response_data)
        if preview.strip():
            self.log("Response preview:")
            self.log(short_text(preview, 2500))

        extracts = step.get("extract") or {}
        if isinstance(extracts, dict) and isinstance(response_data, (dict, list)):
            for var, path in extracts.items():
                extracted = simple_json_path(response_data, str(path))
                if extracted is not None:
                    self.context[str(var)] = extracted
                    self.log(f"Extract: {path} -> {var} = {extracted}")
                else:
                    self.log(f"Extract: {path} -> {var} НЕ НАЙДЕНО")

        set_if_empty = step.get("set_context_if_empty") or {}
        if isinstance(set_if_empty, dict):
            for key, tmpl in set_if_empty.items():
                if not str(self.context.get(key, "")).strip():
                    self.context[str(key)] = render_template(str(tmpl), self.context, strict=False)

        self._log_jsonl({
            "step": name,
            "method": method,
            "url": url,
            "status": response.status_code,
            "elapsed_ms": elapsed_ms,
            "context_keys": sorted(self.context.keys()),
        })

    def _parse_response(self, response) -> Any:
        try:
            return response.json()
        except Exception:
            return response.text

    def _save_response_file(self, step: Dict[str, Any], response, response_data: Any = None) -> None:
        if not self.last_log_dir:
            return
        safe_name = re.sub(r"[^a-zA-Z0-9а-яА-Я_-]+", "_", str(step.get("id") or step.get("name") or "step")).strip("_")
        path = self.last_log_dir / f"response_{safe_name}.json"
        payload = {
            "step": step.get("name"),
            "status_code": response.status_code,
            "headers": dict(response.headers),
            "body": response_data if response_data is not None else self._parse_response(response),
        }
        path.write_text(pretty_json(payload), encoding="utf-8")
        self.log(f"Response file: {path.name}")


class ScrollableFrame(ttk.Frame):
    def __init__(self, parent):
        super().__init__(parent)
        self.canvas = tk.Canvas(self, highlightthickness=0)
        self.scrollbar = ttk.Scrollbar(self, orient="vertical", command=self.canvas.yview)
        self.inner = ttk.Frame(self.canvas)
        self.window = self.canvas.create_window((0, 0), window=self.inner, anchor="nw")
        self.canvas.configure(yscrollcommand=self.scrollbar.set)
        self.canvas.pack(side="left", fill="both", expand=True)
        self.scrollbar.pack(side="right", fill="y")
        self.inner.bind("<Configure>", self._on_inner_configure)
        self.canvas.bind("<Configure>", self._on_canvas_configure)
        self.canvas.bind_all("<MouseWheel>", self._on_mousewheel)

    def _on_inner_configure(self, _event=None):
        self.canvas.configure(scrollregion=self.canvas.bbox("all"))

    def _on_canvas_configure(self, event):
        self.canvas.itemconfigure(self.window, width=event.width)

    def _on_mousewheel(self, event):
        try:
            if self.winfo_containing(event.x_root, event.y_root) is not None:
                self.canvas.yview_scroll(int(-1 * (event.delta / 120)), "units")
        except Exception:
            pass


class TdfgApp(tk.Tk):
    def __init__(self):
        super().__init__()
        self.title(APP_TITLE)
        self.geometry("1280x820")
        self.minsize(1000, 680)
        self.scenario_path = tk.StringVar(value=str(resource_path(DEFAULT_SCENARIO)))
        self.base_tdfg_url = tk.StringVar()
        self.sofk_mock_url = tk.StringVar()
        self.tdfg_authorization = tk.StringVar()
        self.use_cookie = tk.BooleanVar(value=True)
        self.full_package = tk.StringVar(value="privilege")
        self.bind_in_full = tk.BooleanVar(value=False)
        self.full_ko_login = tk.StringVar(value="VTB4090196@test.vtb.ru")
        self.full_ko_package_name = tk.StringVar(value="ПривилегияМК")
        self.full_ko_mdm_override = tk.StringVar()
        self.full_ko_point = tk.StringVar()
        self.only_package_mdm = tk.StringVar()
        self.only_package_choice = tk.StringVar(value="privilege")
        self.ko_mdm = tk.StringVar()
        self.ko_login = tk.StringVar(value="VTB4090196@test.vtb.ru")
        self.ko_package_name = tk.StringVar(value="ПривилегияМК")
        self.ko_point = tk.StringVar()
        self.status = tk.StringVar(value="Готово")
        self.last_log_dir: Optional[Path] = None
        self.scenario: Dict[str, Any] = {}

        # Мастер создания клиента: данные генерируются заранее, их можно проверить и поправить до отправки.
        self.client_fields: Dict[str, tk.StringVar] = {
            "lastName": tk.StringVar(),
            "firstName": tk.StringVar(),
            "middleName": tk.StringVar(),
            "dateBirthday": tk.StringVar(),
            "passportSeries": tk.StringVar(),
            "passportNumber": tk.StringVar(),
            "passportCode": tk.StringVar(),
            "inn": tk.StringVar(),
            "registrationIndex": tk.StringVar(),
            "mobilePhone": tk.StringVar(),
            "jobPhone": tk.StringVar(),
            "homePhone": tk.StringVar(),
        }
        self.client_data_ready = tk.BooleanVar(value=False)
        self.generated_client_status = tk.StringVar(value="Данные ещё не сгенерированы")

        # Редактор подкапотных запросов: временные override-правки поверх YAML.
        self.request_overrides: Dict[str, Dict[str, Any]] = {}
        self.request_step_var = tk.StringVar(value="")
        self.request_method_var = tk.StringVar(value="GET")
        self.request_url_var = tk.StringVar(value="")
        self.auto_scroll_log = tk.BooleanVar(value=True)
        self.request_timeout = tk.StringVar(value="15")
        self.is_running = False

        self._build_ui()
        self.load_scenario_from_path(show_message=False)

    def _build_ui(self):
        self._configure_theme()
        root = ttk.Frame(self, padding=10, style="App.TFrame")
        root.pack(fill="both", expand=True)

        top = ttk.Frame(root, style="App.TFrame")
        top.pack(fill="x", pady=(0, 8))
        ttk.Label(top, text="TDFG Data Factory", style="Title.TLabel").pack(side="left")
        ttk.Label(top, textvariable=self.status, style="Status.TLabel").pack(side="right")

        paned = ttk.PanedWindow(root, orient="horizontal")
        paned.pack(fill="both", expand=True)
        left_wrap = ScrollableFrame(paned)
        right = ttk.Frame(paned, style="App.TFrame")
        paned.add(left_wrap, weight=4)
        paned.add(right, weight=6)
        left = left_wrap.inner

        # Левая зона — рабочие сценарии. Она прокручивается и нормально живёт на маленьких экранах.
        self._build_full_cycle_block(left)
        self._build_package_only_block(left)
        self._build_ko_only_block(left)
        self._build_settings_block(left)
        self._build_service_buttons(left)

        # Правая зона — лог, подкапотные запросы и история. Она растягивается сильнее.
        self._build_log_block(right)

    def _configure_theme(self):
        style = ttk.Style(self)
        try:
            style.theme_use("clam")
        except tk.TclError:
            pass

        # Более мягкая палитра: светлый фон, белые карточки, спокойные границы.
        self.configure(background="#f4f1ea")
        style.configure("App.TFrame", background="#f4f1ea")
        style.configure("Card.TFrame", background="#ffffff", relief="flat")
        style.configure(
            "Card.TLabelframe",
            background="#ffffff",
            borderwidth=1,
            relief="solid",
            padding=(10, 8),
        )
        style.configure(
            "Card.TLabelframe.Label",
            font=("Segoe UI", 10, "bold"),
            foreground="#2f3b48",
            background="#f4f1ea",
        )
        style.configure("Soft.TLabelframe", background="#ffffff", borderwidth=1, relief="solid", padding=(10, 8))
        style.configure("Soft.TLabelframe.Label", font=("Segoe UI", 10, "bold"), foreground="#2f3b48", background="#f4f1ea")
        style.configure("Title.TLabel", font=("Segoe UI", 18, "bold"), foreground="#263238", background="#f4f1ea")
        style.configure("Hint.TLabel", foreground="#6c757d", background="#ffffff")
        style.configure("Status.TLabel", foreground="#2e7d32", background="#f4f1ea", font=("Segoe UI", 10, "bold"))
        style.configure("TLabel", background="#ffffff", foreground="#24313d")
        style.configure("TFrame", background="#ffffff")
        style.configure("TCheckbutton", background="#ffffff", foreground="#24313d")
        style.configure("TRadiobutton", background="#ffffff", foreground="#24313d")
        style.configure("TEntry", fieldbackground="#fffdf8", borderwidth=1, padding=4)
        style.configure("TButton", padding=(9, 5))
        style.configure("Accent.TButton", padding=(12, 7), font=("Segoe UI", 9, "bold"))
        style.map("Accent.TButton", background=[("active", "#dceeff")])

    def _build_settings_block(self, parent):
        box = ttk.LabelFrame(parent, text="Настройки", style="Card.TLabelframe")
        box.pack(fill="x", padx=6, pady=6)
        self._row_entry(box, "YAML сценарий:", self.scenario_path, button_text="Выбрать", button_cmd=self.choose_scenario)
        self._row_entry(box, "TDFG Base URL:", self.base_tdfg_url)
        self._row_entry(box, "SOFK Mock URL:", self.sofk_mock_url)
        self._row_entry(box, "Authorization:", self.tdfg_authorization)
        self._row_entry(box, "Timeout запроса, сек:", self.request_timeout)
        ttk.Checkbutton(box, text="Перед запросом получать Cookie / JSESSIONID", variable=self.use_cookie).pack(anchor="w", padx=8, pady=4)
        ttk.Button(box, text="Перезагрузить YAML", command=self.load_scenario_from_path).pack(anchor="w", padx=8, pady=(0, 6))

    def _build_full_cycle_block(self, parent):
        box = ttk.LabelFrame(parent, text="1. Мастер создания клиента", style="Card.TLabelframe")
        box.pack(fill="x", padx=6, pady=6)

        hint = ttk.Label(
            box,
            text="Сначала сгенерируй данные клиента, проверь и при необходимости поправь поля. После этого запускай полный цикл.",
            style="Hint.TLabel",
            wraplength=540,
            justify="left",
        )
        hint.pack(fill="x", padx=10, pady=(8, 4))

        actions = ttk.Frame(box)
        actions.pack(fill="x", padx=10, pady=(4, 6))
        action_buttons = [
            ("Сгенерировать данные", self.generate_client_data, "Accent.TButton"),
            ("Перегенерировать всё", self.generate_client_data, None),
            ("ФИО", self.regenerate_fio, None),
            ("Паспорт", self.regenerate_passport, None),
            ("Телефоны", self.regenerate_phones, None),
        ]
        for idx, (text, command, style_name) in enumerate(action_buttons):
            btn = ttk.Button(actions, text=text, command=command, style=style_name) if style_name else ttk.Button(actions, text=text, command=command)
            btn.grid(row=idx // 3, column=idx % 3, sticky="ew", padx=3, pady=3)
        for col in range(3):
            actions.columnconfigure(col, weight=1)

        ttk.Label(box, textvariable=self.generated_client_status, style="Hint.TLabel").pack(anchor="w", padx=10, pady=(0, 6))

        data_box = ttk.LabelFrame(box, text="Сгенерированные данные клиента", style="Soft.TLabelframe")
        data_box.pack(fill="x", padx=10, pady=(4, 8))
        data_box.columnconfigure(1, weight=1)

        rows = [
            ("Фамилия", "lastName"),
            ("Имя", "firstName"),
            ("Отчество", "middleName"),
            ("Дата рождения", "dateBirthday"),
            ("Серия паспорта", "passportSeries"),
            ("Номер паспорта", "passportNumber"),
            ("Код подразделения", "passportCode"),
            ("ИНН", "inn"),
            ("Индекс", "registrationIndex"),
            ("Мобильный", "mobilePhone"),
            ("Рабочий телефон", "jobPhone"),
            ("Домашний телефон", "homePhone"),
        ]
        for row_idx, (label, key) in enumerate(rows):
            ttk.Label(data_box, text=label + ":", width=22).grid(row=row_idx, column=0, sticky="w", padx=(8, 8), pady=3)
            ttk.Entry(data_box, textvariable=self.client_fields[key]).grid(row=row_idx, column=1, sticky="ew", padx=(0, 8), pady=3)

        settings = ttk.LabelFrame(box, text="Пакет услуг и закрепление в КО", style="Soft.TLabelframe")
        settings.pack(fill="x", padx=10, pady=(0, 8))
        ttk.Label(settings, text="Пакет услуг:").pack(anchor="w", padx=8, pady=(6, 2))
        self._package_radios(settings, self.full_package, include_none=True, horizontal=True)
        ttk.Checkbutton(settings, text="Дополнительно закрепить клиента в КО", variable=self.bind_in_full, command=self._toggle_full_ko).pack(anchor="w", padx=8, pady=(6, 2))
        self.full_ko_frame = ttk.Frame(settings)
        self._row_entry(self.full_ko_frame, "Логин сотрудника:", self.full_ko_login)
        self._row_entry(self.full_ko_frame, "Пакет услуг / newPackageName:", self.full_ko_package_name)
        self._row_entry(self.full_ko_frame, "MDM для КО, пусто = авто-MDM:", self.full_ko_mdm_override)
        self._row_entry(self.full_ko_frame, "Точка продаж / pointOfSale:", self.full_ko_point)
        self._toggle_full_ko()

        btns = ttk.Frame(box)
        btns.pack(fill="x", padx=10, pady=(0, 10))
        ttk.Button(btns, text="Показать весь сценарий", command=self.show_full_scenario_preview).grid(row=0, column=0, sticky="ew", padx=3, pady=3)
        ttk.Button(btns, text="Скопировать карточку", command=self.copy_generated_client_card).grid(row=0, column=1, sticky="ew", padx=3, pady=3)
        ttk.Button(btns, text="Запустить полный цикл", command=self.run_full_cycle, style="Accent.TButton").grid(row=0, column=2, sticky="ew", padx=3, pady=3)
        for col in range(3):
            btns.columnconfigure(col, weight=1)

    def _build_package_only_block(self, parent):
        box = ttk.LabelFrame(parent, text="2. Подключить только пакет услуг", style="Card.TLabelframe")
        box.pack(fill="x", padx=6, pady=6)
        self._row_entry(box, "MDM ID клиента:", self.only_package_mdm)
        ttk.Label(box, text="Пакет услуг:").pack(anchor="w", padx=8, pady=(4, 2))
        self._package_radios(box, self.only_package_choice, include_none=False, horizontal=True)
        btns = ttk.Frame(box)
        btns.pack(fill="x", padx=8, pady=8)
        ttk.Button(btns, text="Показать тело", command=self.show_package_body).grid(row=0, column=0, sticky="ew", padx=3, pady=3)
        ttk.Button(btns, text="Подключить ПУ", command=self.run_package_only).grid(row=0, column=1, sticky="ew", padx=3, pady=3)
        btns.columnconfigure(0, weight=1)
        btns.columnconfigure(1, weight=1)

    def _build_ko_only_block(self, parent):
        box = ttk.LabelFrame(parent, text="3. Подключить клиента в КО", style="Card.TLabelframe")
        box.pack(fill="x", padx=6, pady=6)
        self._row_entry(box, "MDM ID клиента:", self.ko_mdm)
        self._row_entry(box, "Логин сотрудника:", self.ko_login)
        self._row_entry(box, "Пакет услуг / newPackageName:", self.ko_package_name)
        self._row_entry(box, "Точка продаж / pointOfSale, пусто = null:", self.ko_point)
        btns = ttk.Frame(box)
        btns.pack(fill="x", padx=8, pady=8)
        ttk.Button(btns, text="Показать тело", command=self.show_ko_body).grid(row=0, column=0, sticky="ew", padx=3, pady=3)
        ttk.Button(btns, text="Подключить в КО", command=self.run_ko_only).grid(row=0, column=1, sticky="ew", padx=3, pady=3)
        btns.columnconfigure(0, weight=1)
        btns.columnconfigure(1, weight=1)

    def _build_service_buttons(self, parent):
        box = ttk.Frame(parent)
        box.pack(fill="x", padx=6, pady=6)
        buttons = [
            ("Показать переменные", self.show_variables),
            ("Открыть папку логов", self.open_logs),
            ("Загрузить запросы в редактор", self.load_request_editor_from_step),
        ]
        for idx, (text, command) in enumerate(buttons):
            ttk.Button(box, text=text, command=command).grid(row=0, column=idx, sticky="ew", padx=3, pady=3)
            box.columnconfigure(idx, weight=1)

    def _build_log_block(self, parent):
        notebook = ttk.Notebook(parent)
        notebook.pack(fill="both", expand=True)

        log_tab = ttk.Frame(notebook)
        request_tab = ttk.Frame(notebook)
        history_tab = ttk.Frame(notebook)
        notebook.add(log_tab, text="Живой лог")
        notebook.add(request_tab, text="Подкапотные запросы")
        notebook.add(history_tab, text="История клиентов")

        top = ttk.Frame(log_tab)
        top.pack(fill="x", pady=(0, 4))
        ttk.Label(top, text="Живой лог выполнения и итоговая карточка:").pack(side="left")
        ttk.Checkbutton(top, text="Автоскролл", variable=self.auto_scroll_log).pack(side="right", padx=(6, 0))
        ttk.Button(top, text="Очистить лог", command=self.clear_log).pack(side="right")
        ttk.Button(top, text="Копировать лог", command=self.copy_log_to_clipboard).pack(side="right", padx=(0, 6))
        ttk.Button(top, text="Выделить всё", command=self.select_all_log).pack(side="right", padx=(0, 6))

        text_frame = ttk.Frame(log_tab)
        text_frame.pack(fill="both", expand=True)
        self.log_text = tk.Text(text_frame, wrap="none", font=("Consolas", 10), background="#fffdf8", foreground="#24313d", insertbackground="#24313d", selectbackground="#cfe8ff", relief="flat", padx=8, pady=6)
        self.log_text.pack(side="left", fill="both", expand=True)
        y = ttk.Scrollbar(text_frame, orient="vertical", command=self.log_text.yview)
        y.pack(side="right", fill="y")
        x = ttk.Scrollbar(log_tab, orient="horizontal", command=self.log_text.xview)
        x.pack(fill="x")
        self.log_text.configure(yscrollcommand=y.set, xscrollcommand=x.set)
        self.log_text.tag_configure("error", foreground="#b00020")
        self.log_text.tag_configure("request", foreground="#003399")
        self.log_text.tag_configure("response", foreground="#006400")
        self._bind_log_copy_keys()

        self._build_request_editor_block(request_tab)
        self._build_history_block(history_tab)

    def _build_history_block(self, parent):
        top = ttk.Frame(parent)
        top.pack(fill="x", padx=8, pady=(8, 4))
        ttk.Label(top, text="История созданных клиентов за текущий запуск").pack(side="left")
        ttk.Button(top, text="Скопировать выбранного", command=self.copy_selected_history_client).pack(side="right")
        ttk.Button(top, text="Очистить историю", command=self.clear_history).pack(side="right", padx=(0, 6))

        columns = ("time", "fio", "mdm", "phone", "package")
        self.history_tree = ttk.Treeview(parent, columns=columns, show="headings", height=8)
        headers = {
            "time": "Время",
            "fio": "ФИО",
            "mdm": "MDM",
            "phone": "Телефон",
            "package": "Пакет услуг",
        }
        widths = {"time": 110, "fio": 260, "mdm": 140, "phone": 130, "package": 140}
        for col in columns:
            self.history_tree.heading(col, text=headers[col])
            self.history_tree.column(col, width=widths[col], minwidth=80, stretch=True)
        self.history_tree.pack(side="left", fill="both", expand=True, padx=(8, 0), pady=(0, 8))
        y = ttk.Scrollbar(parent, orient="vertical", command=self.history_tree.yview)
        y.pack(side="right", fill="y", pady=(0, 8))
        self.history_tree.configure(yscrollcommand=y.set)

    def _build_request_editor_block(self, parent):
        info = ttk.Label(
            parent,
            text=(
                "Здесь можно посмотреть и изменить реальный запрос перед отправкой. "
                "Правки сохраняются как override поверх YAML и используются в сценариях до перезагрузки приложения. "
                "При необходимости можно сохранить текущий шаг обратно в YAML."
            ),
            wraplength=780,
            foreground="#555555",
            justify="left",
        )
        info.pack(fill="x", padx=8, pady=(8, 6))

        row = ttk.Frame(parent)
        row.pack(fill="x", padx=8, pady=4)
        ttk.Label(row, text="Шаг:", width=8).pack(side="left")
        self.request_step_combo = ttk.Combobox(row, textvariable=self.request_step_var, state="readonly")
        self.request_step_combo.pack(side="left", fill="x", expand=True, padx=(0, 6))
        self.request_step_combo.bind("<<ComboboxSelected>>", lambda _e: self.load_request_editor_from_step())
        ttk.Button(row, text="Загрузить", command=self.load_request_editor_from_step).pack(side="left", padx=(0, 4))
        ttk.Button(row, text="Выполнить", command=self.run_current_request_from_editor).pack(side="left")

        row = ttk.Frame(parent)
        row.pack(fill="x", padx=8, pady=4)
        ttk.Label(row, text="Method:", width=8).pack(side="left")
        ttk.Entry(row, textvariable=self.request_method_var, width=12).pack(side="left", padx=(0, 8))
        ttk.Label(row, text="URL:").pack(side="left")
        ttk.Entry(row, textvariable=self.request_url_var).pack(side="left", fill="x", expand=True, padx=(6, 0))

        panes = ttk.PanedWindow(parent, orient="vertical")
        panes.pack(fill="both", expand=True, padx=8, pady=6)

        headers_box = ttk.LabelFrame(panes, text="Headers JSON или формат Header: value")
        self.request_headers_text = tk.Text(headers_box, height=9, wrap="none", font=("Consolas", 10))
        self.request_headers_text.pack(fill="both", expand=True, padx=4, pady=4)
        panes.add(headers_box, weight=1)

        body_box = ttk.LabelFrame(panes, text="Body / raw JSON")
        self.request_body_text = tk.Text(body_box, height=15, wrap="none", font=("Consolas", 10))
        self.request_body_text.pack(fill="both", expand=True, padx=4, pady=4)
        panes.add(body_box, weight=2)

        btns = ttk.Frame(parent)
        btns.pack(fill="x", padx=8, pady=(0, 8))
        ttk.Button(btns, text="Сохранить override", command=self.save_request_override).pack(side="left")
        ttk.Button(btns, text="Сбросить override", command=self.clear_request_override).pack(side="left", padx=6)
        ttk.Button(btns, text="Сохранить шаг в YAML", command=self.save_current_step_to_yaml).pack(side="left", padx=6)
        ttk.Button(btns, text="Скопировать cURL", command=self.copy_current_request_as_curl).pack(side="left", padx=6)

        self.refresh_request_step_choices()

    def _row_entry(self, parent, label, variable, button_text=None, button_cmd=None):
        row = ttk.Frame(parent)
        row.pack(fill="x", padx=8, pady=3)
        ttk.Label(row, text=label, width=25).pack(side="left")
        ttk.Entry(row, textvariable=variable).pack(side="left", fill="x", expand=True, padx=(0, 6))
        if button_text:
            ttk.Button(row, text=button_text, command=button_cmd).pack(side="left")

    def _package_radios(self, parent, variable, include_none: bool, horizontal: bool = False):
        frame = ttk.Frame(parent)
        frame.pack(fill="x", padx=8)
        keys = ["prime", "privilege", "multi"]
        if include_none:
            keys.append("none")
        for idx, key in enumerate(keys):
            info = PACKAGE_CHOICES[key]
            text = info["title"] if key == "none" else f"{info['title']} = {info['code']}"
            rb = ttk.Radiobutton(frame, text=text, variable=variable, value=key)
            if horizontal:
                # Не кладем все варианты в одну линию: на небольших экранах они начинают наезжать.
                rb.grid(row=idx // 2, column=idx % 2, sticky="w", padx=(0, 14), pady=2)
            else:
                rb.grid(row=idx, column=0, sticky="w", pady=2)
        if horizontal:
            frame.columnconfigure(0, weight=1)
            frame.columnconfigure(1, weight=1)

    def _toggle_full_ko(self):
        if self.bind_in_full.get():
            self.full_ko_frame.pack(fill="x", padx=0, pady=(2, 4))
        else:
            self.full_ko_frame.pack_forget()

    def choose_scenario(self):
        path = filedialog.askopenfilename(title="Выбери YAML сценарий", filetypes=[("YAML", "*.yaml *.yml"), ("All", "*.*")])
        if path:
            self.scenario_path.set(path)
            self.load_scenario_from_path()

    def load_scenario_from_path(self, show_message: bool = True):
        try:
            self.scenario = load_yaml_file(Path(self.scenario_path.get()))
            variables = self.scenario.get("variables") or {}
            self.base_tdfg_url.set(str(variables.get("base_tdfg_url", "")))
            self.sofk_mock_url.set(str(variables.get("sofk_mock_url", "")))
            self.tdfg_authorization.set(str(variables.get("tdfg_authorization", "")))
            self.status.set("YAML загружен")
            if hasattr(self, "request_step_combo"):
                self.refresh_request_step_choices()
            if show_message:
                messagebox.showinfo("Готово", "YAML сценарий загружен")
        except Exception as exc:
            self.status.set("Ошибка YAML")
            messagebox.showerror("Ошибка", str(exc))

    def base_context(self) -> Dict[str, Any]:
        return {
            "base_tdfg_url": self.base_tdfg_url.get().strip().rstrip("/"),
            "sofk_mock_url": self.sofk_mock_url.get().strip().rstrip("/"),
            "tdfg_authorization": self.tdfg_authorization.get().strip(),
        }

    def package_context(self, key: str) -> Dict[str, str]:
        info = PACKAGE_CHOICES.get(key, PACKAGE_CHOICES["privilege"])
        return {"package_code": info["code"], "package_name": info["name"]}

    def point_context(self, value: str) -> Dict[str, str]:
        value = value.strip()
        return {"point_of_sale": value, "point_of_sale_json": "null" if not value else json.dumps(value, ensure_ascii=False)}

    def _request_timeout_value(self) -> int:
        raw = self.request_timeout.get().strip().replace(",", ".")
        try:
            value = int(float(raw))
        except Exception:
            value = 15
            self.request_timeout.set("15")
        return max(1, min(value, 300))

    def make_runner(self) -> WorkflowRunner:
        self.load_scenario_from_path(show_message=False)
        timeout = self._request_timeout_value()
        return WorkflowRunner(self.scenario, log_callback=self.append_log, request_overrides=self.request_overrides, request_timeout=timeout)

    def step_display_name(self, step: Dict[str, Any]) -> str:
        return f"{step.get('id', '')} — {step.get('name', '')}"

    def step_id_from_display(self, value: str) -> str:
        return str(value).split(" — ", 1)[0].strip()

    def refresh_request_step_choices(self):
        steps = self.scenario.get("steps") or []
        values = [self.step_display_name(step) for step in steps if isinstance(step, dict) and step.get("id")]
        if hasattr(self, "request_step_combo"):
            self.request_step_combo["values"] = values
        if values and not self.request_step_var.get():
            self.request_step_var.set(values[0])

    def current_step_id(self) -> str:
        value = self.request_step_var.get().strip()
        if not value:
            raise RuntimeError("Выбери шаг запроса")
        return self.step_id_from_display(value)

    def editor_context_for_step(self, step_id: str) -> Dict[str, Any]:
        ctx = self.base_context()
        ctx.update(self.package_context(self.only_package_choice.get() or self.full_package.get()))
        ctx.update({
            "mdm_client": self.only_package_mdm.get().strip() or self.ko_mdm.get().strip() or "<MDM_ID>",
            "service_team_client_id": self.ko_mdm.get().strip() or self.only_package_mdm.get().strip() or "<MDM_ID>",
            "service_team_user_login": self.ko_login.get().strip() or self.full_ko_login.get().strip() or "<LOGIN>",
            "package_name": self.ko_package_name.get().strip() or self.full_ko_package_name.get().strip() or "<PACKAGE_NAME>",
            "bind_service_team": "true",
            "created_client_id": "<ORDER_ID>",
        })
        ctx.update(self.point_context(self.ko_point.get() or self.full_ko_point.get()))
        return ctx

    def load_request_editor_from_step(self):
        try:
            step_id = self.current_step_id()
            runner = self.make_runner()
            prepared = runner.render_step_request_for_editor(step_id, self.editor_context_for_step(step_id), apply_override=True)
            self.request_method_var.set(str(prepared.get("method") or "GET"))
            self.request_url_var.set(str(prepared.get("url") or ""))
            self.request_headers_text.delete("1.0", "end")
            self.request_headers_text.insert("1.0", pretty_json(prepared.get("headers") or {}))
            self.request_body_text.delete("1.0", "end")
            body = prepared.get("body") or ""
            if body:
                try:
                    body = pretty_json(json.loads(body))
                except Exception:
                    body = str(body)
            self.request_body_text.insert("1.0", body)
            self.append_log(f"Редактор: загружен запрос шага {step_id}")
        except Exception as exc:
            messagebox.showerror("Ошибка", str(exc))

    def read_request_editor(self) -> Dict[str, Any]:
        step_id = self.current_step_id()
        headers_raw = self.request_headers_text.get("1.0", "end-1c").strip()
        body_raw = self.request_body_text.get("1.0", "end-1c")
        # Валидируем headers заранее, чтобы не ловить ошибку в потоке.
        if headers_raw:
            try:
                parsed = json.loads(headers_raw)
                if not isinstance(parsed, dict):
                    raise ValueError("Headers JSON должен быть объектом")
            except Exception:
                # Разрешаем простой формат Header: value.
                if not any(":" in line for line in headers_raw.splitlines() if line.strip()):
                    raise RuntimeError("Headers должны быть JSON-объектом или строками Header: value")
        return {
            "method": self.request_method_var.get().strip().upper() or "GET",
            "url": self.request_url_var.get().strip(),
            "headers": headers_raw,
            "body": body_raw,
        }

    def save_request_override(self, show_message: bool = True):
        try:
            step_id = self.current_step_id()
            self.request_overrides[step_id] = self.read_request_editor()
            self.append_log(f"Override сохранён для шага {step_id}. Теперь сценарии будут использовать этот вариант запроса.")
            if show_message:
                messagebox.showinfo("Готово", f"Override сохранён для шага {step_id}")
        except Exception as exc:
            messagebox.showerror("Ошибка", str(exc))

    def clear_request_override(self):
        try:
            step_id = self.current_step_id()
            self.request_overrides.pop(step_id, None)
            self.append_log(f"Override сброшен для шага {step_id}")
            self.load_request_editor_from_step()
        except Exception as exc:
            messagebox.showerror("Ошибка", str(exc))

    def run_current_request_from_editor(self):
        try:
            step_id = self.current_step_id()
            self.save_request_override(show_message=False)
            ctx = self.editor_context_for_step(step_id)
            self.run_async(lambda: self._run_and_card([step_id], ctx, full_cycle=False), f"Выполнение запроса из редактора: {step_id}...")
        except Exception as exc:
            messagebox.showerror("Ошибка", str(exc))

    def save_current_step_to_yaml(self):
        if yaml is None:
            messagebox.showerror("Ошибка", "Не установлен PyYAML")
            return
        try:
            step_id = self.current_step_id()
            edited = self.read_request_editor()
            self.load_scenario_from_path(show_message=False)
            found = None
            for step in self.scenario.get("steps") or []:
                if isinstance(step, dict) and step.get("id") == step_id:
                    found = step
                    break
            if not found:
                raise RuntimeError(f"Шаг не найден: {step_id}")
            found["method"] = edited["method"]
            found["url"] = edited["url"]
            body = str(edited.get("body") or "")
            if body.strip():
                found["body"] = body
            else:
                found.pop("body", None)
            headers_raw = str(edited.get("headers") or "").strip()
            if headers_raw:
                try:
                    parsed_headers = json.loads(headers_raw)
                    if isinstance(parsed_headers, dict):
                        found["headers"] = parsed_headers
                    else:
                        raise ValueError
                except Exception:
                    parsed_headers = {}
                    for line in headers_raw.splitlines():
                        if ":" in line:
                            k, v = line.split(":", 1)
                            parsed_headers[k.strip()] = v.strip()
                    found["headers"] = parsed_headers
            path = Path(self.scenario_path.get())
            path.write_text(yaml.safe_dump(self.scenario, allow_unicode=True, sort_keys=False), encoding="utf-8")
            self.request_overrides.pop(step_id, None)
            self.append_log(f"Шаг {step_id} сохранён в YAML: {path}")
            messagebox.showinfo("Готово", "Шаг сохранён в YAML")
        except Exception as exc:
            messagebox.showerror("Ошибка", str(exc))

    def copy_current_request_as_curl(self):
        try:
            edited = self.read_request_editor()
            curl = ["curl", "-X", edited["method"], repr(edited["url"])]
            headers_text = edited.get("headers") or ""
            headers = WorkflowRunner(self.scenario)._parse_headers_override(headers_text)
            for k, v in headers.items():
                curl.extend(["-H", repr(f"{k}: {v}")])
            body = str(edited.get("body") or "")
            if body.strip():
                curl.extend(["--data-raw", repr(body)])
            text = " \\n  ".join(curl)
            self.clipboard_clear()
            self.clipboard_append(text)
            self.append_log("cURL скопирован в буфер:\n" + text)
        except Exception as exc:
            messagebox.showerror("Ошибка", str(exc))

    def _create_step_generate_rules(self) -> Dict[str, str]:
        try:
            self.load_scenario_from_path(show_message=False)
            for step in self.scenario.get("steps") or []:
                if step.get("id") == "create_client":
                    rules = step.get("generate") or {}
                    if isinstance(rules, dict):
                        return {str(k): str(v) for k, v in rules.items()}
        except Exception:
            pass
        return {
            "firstName": "random_first_name",
            "lastName": "random_last_name",
            "middleName": "random_middle_name",
            "passportNumber": "digits:6",
            "passportSeries": "digits:4",
            "passportCode": "passport_code",
            "inn": "digits:12",
            "registrationIndex": "digits:6",
            "mobilePhone": "mobile_phone",
            "jobPhone": "job_phone",
            "homePhone": "home_phone",
            "dateBirthday": "birthday:1940-01-01:2004-12-31",
        }

    def generate_client_data(self):
        rules = self._create_step_generate_rules()
        for key, variable in self.client_fields.items():
            rule = rules.get(key)
            if rule:
                variable.set(generate_value(rule))
        self.client_data_ready.set(True)
        self.generated_client_status.set("Данные сгенерированы. Можно проверить, поправить поля и запускать цикл.")
        self.append_log("\n=== СГЕНЕРИРОВАНЫ ДАННЫЕ КЛИЕНТА ===\n" + self.generated_client_card_text())

    def regenerate_fio(self):
        rules = self._create_step_generate_rules()
        for key in ["lastName", "firstName", "middleName"]:
            self.client_fields[key].set(generate_value(rules.get(key, "")))
        self.client_data_ready.set(True)
        self.generated_client_status.set("ФИО перегенерировано")

    def regenerate_passport(self):
        rules = self._create_step_generate_rules()
        for key in ["passportSeries", "passportNumber", "passportCode", "inn", "dateBirthday"]:
            self.client_fields[key].set(generate_value(rules.get(key, "")))
        self.client_data_ready.set(True)
        self.generated_client_status.set("Паспортные данные / ИНН / дата рождения перегенерированы")

    def regenerate_phones(self):
        rules = self._create_step_generate_rules()
        for key in ["mobilePhone", "jobPhone", "homePhone"]:
            self.client_fields[key].set(generate_value(rules.get(key, "")))
        self.client_data_ready.set(True)
        self.generated_client_status.set("Телефоны перегенерированы")

    def generated_client_context(self) -> Dict[str, str]:
        return {key: var.get().strip() for key, var in self.client_fields.items()}

    def ensure_client_data(self) -> None:
        ctx = self.generated_client_context()
        required = ["lastName", "firstName", "middleName", "dateBirthday", "passportSeries", "passportNumber", "mobilePhone"]
        if not self.client_data_ready.get() or any(not ctx.get(key) for key in required):
            self.generate_client_data()

    def generated_client_card_text(self) -> str:
        ctx = self.generated_client_context()
        fio = " ".join([ctx.get("lastName", ""), ctx.get("firstName", ""), ctx.get("middleName", "")]).strip()
        return "\n".join([
            f"ФИО: {fio}",
            f"Дата рождения: {ctx.get('dateBirthday', '')}",
            f"Паспорт: {ctx.get('passportSeries', '')} {ctx.get('passportNumber', '')}",
            f"Код подразделения: {ctx.get('passportCode', '')}",
            f"ИНН: {ctx.get('inn', '')}",
            f"Мобильный: {ctx.get('mobilePhone', '')}",
            f"Рабочий телефон: {ctx.get('jobPhone', '')}",
            f"Домашний телефон: {ctx.get('homePhone', '')}",
        ])

    def copy_generated_client_card(self):
        if not self.client_data_ready.get():
            self.generate_client_data()
        text = self.generated_client_card_text()
        self.clipboard_clear()
        self.clipboard_append(text)
        self.generated_client_status.set("Карточка клиента скопирована в буфер")

    def show_full_scenario_preview(self):
        try:
            self.ensure_client_data()
            ctx = self.base_context()
            ctx.update(self.generated_client_context())
            ctx.update(self.package_context(self.full_package.get()))
            ctx["bind_service_team"] = "true" if self.bind_in_full.get() else "false"
            if self.bind_in_full.get():
                ctx["service_team_user_login"] = self.full_ko_login.get().strip()
                ctx["package_name"] = self.full_ko_package_name.get().strip() or ctx.get("package_name", "")
                ctx["service_team_client_id"] = self.full_ko_mdm_override.get().strip() or "<AUTO_MDM_AFTER_GET_MDM>"
                ctx.update(self.point_context(self.full_ko_point.get()))
            steps = ["create_client", "get_mdm"]
            if ctx.get("package_code"):
                steps.append("set_package")
            if self.bind_in_full.get():
                steps.append("bind_service_team")
            runner = self.make_runner()
            lines = ["\n=== ПРЕДПРОСМОТР ПОЛНОГО СЦЕНАРИЯ ===", "Будут выполнены шаги:"]
            for index, step_id in enumerate((["get_cookie"] if self.use_cookie.get() else []) + steps, start=1):
                try:
                    step = runner.get_step(step_id)
                    lines.append(f"{index}. {step.get('name') or step_id}")
                except Exception:
                    lines.append(f"{index}. {step_id}")
            lines.append("\nДанные клиента:\n" + self.generated_client_card_text())
            self.append_log("\n".join(lines) + "\n")
        except Exception as exc:
            messagebox.showerror("Ошибка предпросмотра", str(exc))

    def run_full_cycle(self):
        self.ensure_client_data()
        ctx = self.base_context()
        ctx.update(self.generated_client_context())
        ctx.update(self.package_context(self.full_package.get()))
        ctx["bind_service_team"] = "true" if self.bind_in_full.get() else "false"
        if self.bind_in_full.get():
            ctx["service_team_user_login"] = self.full_ko_login.get().strip()
            ctx["package_name"] = self.full_ko_package_name.get().strip() or ctx.get("package_name", "")
            ctx["service_team_client_id"] = self.full_ko_mdm_override.get().strip()
            ctx.update(self.point_context(self.full_ko_point.get()))
        steps = ["create_client", "get_mdm"]
        if ctx.get("package_code"):
            steps.append("set_package")
        if self.bind_in_full.get():
            steps.append("bind_service_team")
        self.run_async(lambda: self._run_and_card(steps, ctx, full_cycle=True), "Запуск полного цикла создания клиента...")

    def run_package_only(self):
        mdm = self.only_package_mdm.get().strip()
        if not mdm:
            messagebox.showerror("Ошибка", "Введи MDM ID клиента")
            return
        ctx = self.base_context()
        ctx.update(self.package_context(self.only_package_choice.get()))
        ctx["mdm_client"] = mdm
        self.run_async(lambda: self._run_and_card(["set_package"], ctx, full_cycle=False), "Подключение ПУ...")

    def run_ko_only(self):
        mdm = self.ko_mdm.get().strip()
        login = self.ko_login.get().strip()
        package_name = self.ko_package_name.get().strip()
        if not mdm or not login or not package_name:
            messagebox.showerror("Ошибка", "Заполни MDM ID, логин сотрудника и пакет услуг")
            return
        ctx = self.base_context()
        ctx.update({
            "bind_service_team": "true",
            "service_team_client_id": mdm,
            "service_team_user_login": login,
            "package_name": package_name,
        })
        ctx.update(self.point_context(self.ko_point.get()))
        self.run_async(lambda: self._run_and_card(["bind_service_team"], ctx, full_cycle=False), "Подключение клиента в КО...")

    def _run_and_card(self, steps: List[str], ctx: Dict[str, Any], full_cycle: bool):
        runner = self.make_runner()
        context = runner.run_steps(steps, ctx, use_cookie_step=self.use_cookie.get())
        self.last_log_dir = runner.last_log_dir
        if full_cycle:
            fio = " ".join(str(context.get(k, "")) for k in ["lastName", "firstName", "middleName"]).strip()
            card = [
                "\n" + "=" * 70,
                "ИТОГОВАЯ КАРТОЧКА КЛИЕНТА",
                "=" * 70,
                f"ФИО клиента: {fio}",
                f"MDM ID: {context.get('mdm_client', '')}",
                f"Телефон: {context.get('mobilePhone', '')}",
                f"Пакет услуг: {context.get('package_name', '') or 'Без ПУ'}",
                "=" * 70,
            ]
            self.append_log("\n".join(card))
            self.add_client_to_history(
                fio=fio,
                mdm=str(context.get("mdm_client", "")),
                phone=str(context.get("mobilePhone", "")),
                package=str(context.get("package_name", "") or "Без ПУ"),
            )
        self.status.set("Готово")

    def add_client_to_history(self, fio: str, mdm: str, phone: str, package: str):
        if not hasattr(self, "history_tree"):
            return
        self.history_tree.insert("", "end", values=(datetime.now().strftime("%H:%M:%S"), fio, mdm, phone, package))

    def copy_selected_history_client(self):
        if not hasattr(self, "history_tree"):
            return
        selected = self.history_tree.selection()
        if not selected:
            messagebox.showinfo("История", "Выбери строку в истории")
            return
        values = self.history_tree.item(selected[0], "values")
        text = "\n".join([
            f"Время: {values[0]}",
            f"ФИО: {values[1]}",
            f"MDM: {values[2]}",
            f"Телефон: {values[3]}",
            f"Пакет услуг: {values[4]}",
        ])
        self.clipboard_clear()
        self.clipboard_append(text)
        self.append_log("Карточка из истории скопирована в буфер")

    def clear_history(self):
        if hasattr(self, "history_tree"):
            for item in self.history_tree.get_children():
                self.history_tree.delete(item)

    def show_package_body(self):
        mdm = self.only_package_mdm.get().strip() or "<MDM_ID>"
        ctx = self.base_context()
        ctx.update(self.package_context(self.only_package_choice.get()))
        ctx["mdm_client"] = mdm
        self.show_preview("set_package", ctx)

    def show_ko_body(self):
        ctx = self.base_context()
        ctx.update({
            "bind_service_team": "true",
            "service_team_client_id": self.ko_mdm.get().strip() or "<MDM_ID>",
            "service_team_user_login": self.ko_login.get().strip() or "<LOGIN>",
            "package_name": self.ko_package_name.get().strip() or "<PACKAGE_NAME>",
        })
        ctx.update(self.point_context(self.ko_point.get()))
        self.show_preview("bind_service_team", ctx)

    def show_preview(self, step_id: str, ctx: Dict[str, Any]):
        try:
            runner = self.make_runner()
            text = runner.render_step_preview(step_id, ctx)
            self.append_log("\n=== PREVIEW ===\n" + text + "\n")
        except Exception as exc:
            messagebox.showerror("Ошибка предпросмотра", str(exc))

    def show_variables(self):
        ctx = self.base_context()
        ctx.update(self.package_context(self.full_package.get()))
        self.append_log("\n=== ТЕКУЩИЕ ПЕРЕМЕННЫЕ UI ===\n" + pretty_json(ctx) + "\n")

    def run_async(self, func, start_message: str):
        if self.is_running:
            messagebox.showinfo("Выполнение", "Сейчас уже выполняется запрос/сценарий. Дождись окончания или таймаута.")
            return
        self.is_running = True
        self.status.set("Выполнение...")
        self.append_log("\n" + start_message)

        def finish_success():
            self.is_running = False
            if self.status.get() == "Выполнение...":
                self.status.set("Готово")

        def worker():
            try:
                func()
                self.after(0, finish_success)
            except Exception as exc:
                err = traceback.format_exc()
                message = str(exc)
                self.after(0, lambda message=message, err=err: self.show_error(message, err))
                self.after(0, finish_success)
        threading.Thread(target=worker, daemon=True).start()

    def show_error(self, message: str, details: str):
        self.is_running = False
        self.status.set("Ошибка")
        self.append_log("\nОШИБКА: " + message + "\n" + details)
        messagebox.showerror("Ошибка", f"{message}\n\n{details[:3000]}")

    def append_log(self, text: str):
        raw = str(text)
        def inner():
            tag = None
            if "ОШИБКА" in raw or "Traceback" in raw:
                tag = "error"
            elif "→ REQUEST" in raw or "Request " in raw:
                tag = "request"
            elif "← RESPONSE" in raw or "Status" in raw:
                tag = "response"
            prefix = datetime.now().strftime("[%H:%M:%S] ")
            for line in raw.splitlines() or [""]:
                self.log_text.insert("end", prefix + line + "\n", tag if tag else ())
            if self.auto_scroll_log.get():
                self.log_text.see("end")
            self.log_text.update_idletasks()
        try:
            self.after(0, inner)
        except RuntimeError:
            pass

    def _bind_log_copy_keys(self):
        """Горячие клавиши и меню для копирования живого лога.

        В Windows/Tk Ctrl+A для Text не всегда работает из коробки,
        особенно при русской раскладке. Поэтому вешаем явные биндинги:
        Ctrl+A / Ctrl+C и физические клавиши на русской раскладке.
        """
        self.log_text.bind("<Control-a>", lambda event: self.select_all_log())
        self.log_text.bind("<Control-A>", lambda event: self.select_all_log())
        self.log_text.bind("<Control-c>", lambda event: self.copy_selected_log())
        self.log_text.bind("<Control-C>", lambda event: self.copy_selected_log())
        self.log_text.bind("<Double-Button-1>", self.select_log_token_at_event)
        self.log_text.bind("<KeyPress>", self._handle_log_hotkey, add="+")

        self.log_context_menu = tk.Menu(self.log_text, tearoff=False)
        self.log_context_menu.add_command(label="Копировать выделенное", command=self.copy_selected_log)
        self.log_context_menu.add_command(label="Копировать весь лог", command=self.copy_log_to_clipboard)
        self.log_context_menu.add_command(label="Выделить всё", command=self.select_all_log)
        self.log_context_menu.add_separator()
        self.log_context_menu.add_command(label="Очистить лог", command=self.clear_log)
        self.log_text.bind("<Button-3>", self._show_log_context_menu)

    def _show_log_context_menu(self, event):
        try:
            self.log_context_menu.tk_popup(event.x_root, event.y_root)
        finally:
            self.log_context_menu.grab_release()
        return "break"

    def _handle_log_hotkey(self, event):
        # Ctrl обычно имеет бит 0x0004. Обрабатываем русскую раскладку:
        # A -> ф, C -> с. Английские Ctrl+A/C уже обработаны выше.
        if not (event.state & 0x0004):
            return None
        keysym = str(getattr(event, "keysym", "") or "").lower()
        char = str(getattr(event, "char", "") or "").lower()
        keycode = int(getattr(event, "keycode", 0) or 0)
        if keycode == 65 or keysym in {"ф", "cyrillic_ef"} or char == "ф":
            return self.select_all_log()
        if keycode == 67 or keysym in {"с", "cyrillic_es"} or char == "с":
            return self.copy_selected_log()
        return None

    def select_log_token_at_event(self, event):
        """Выделяет только слово/значение под курсором в строке лога.

        Стандартное поведение Text иногда выделяет не то, что нужно для лога.
        Здесь двойной клик выбирает ближайший токен: ФИО, MDM, телефон, email,
        код пакета, URL-фрагмент и т.п.
        """
        try:
            index = self.log_text.index(f"@{event.x},{event.y}")
            line_start = self.log_text.index(f"{index} linestart")
            line_end = self.log_text.index(f"{index} lineend")
            line = self.log_text.get(line_start, line_end)
            col = int(index.split(".")[1])
        except Exception:
            return "break"

        # Токены для удобного копирования: русские/латинские слова, числа,
        # email/login, package-code, mdm, phone, URL-части.
        token_re = re.compile(r"[A-Za-zА-Яа-яЁё0-9_@./:+\-]+")
        selected = None
        for match in token_re.finditer(line):
            if match.start() <= col <= match.end():
                selected = match
                break
        if selected is None:
            for match in token_re.finditer(line):
                if abs(match.start() - col) <= 1 or abs(match.end() - col) <= 1:
                    selected = match
                    break
        if selected is None:
            return "break"

        start = f"{line_start}+{selected.start()}c"
        end = f"{line_start}+{selected.end()}c"
        self.log_text.tag_remove("sel", "1.0", "end")
        self.log_text.tag_add("sel", start, end)
        self.log_text.mark_set("insert", end)
        self.log_text.focus_set()
        return "break"

    def select_all_log(self):
        self.log_text.focus_set()
        self.log_text.tag_add("sel", "1.0", "end-1c")
        self.log_text.mark_set("insert", "1.0")
        self.log_text.see("insert")
        return "break"

    def copy_selected_log(self):
        try:
            value = self.log_text.get("sel.first", "sel.last")
        except tk.TclError:
            value = self.log_text.get("1.0", "end-1c")
        self.clipboard_clear()
        self.clipboard_append(value)
        self.status.set("Лог скопирован")
        return "break"

    def copy_log_to_clipboard(self):
        value = self.log_text.get("1.0", "end-1c")
        if not value.strip():
            messagebox.showinfo("Лог", "Лог пока пустой")
            return "break"
        self.clipboard_clear()
        self.clipboard_append(value)
        self.status.set("Весь лог скопирован")
        return "break"

    def clear_log(self):
        self.log_text.delete("1.0", "end")

    def open_logs(self):
        path = self.last_log_dir or resource_path("tdfg_logs")
        if not path.exists():
            messagebox.showinfo("Логи", "Папка логов пока не создана")
            return
        try:
            if sys.platform.startswith("win"):
                os.startfile(str(path))
            elif sys.platform == "darwin":
                subprocess.run(["open", str(path)], check=False)
            else:
                subprocess.run(["xdg-open", str(path)], check=False)
        except Exception as exc:
            messagebox.showerror("Ошибка", str(exc))


if __name__ == "__main__":
    app = TdfgApp()
    app.mainloop()
