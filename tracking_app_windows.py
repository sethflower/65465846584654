"""Modern PySide6 desktop adaptation of TrackingApp."""
from __future__ import annotations

import csv
import json
import threading
from collections import defaultdict
from dataclasses import dataclass, asdict, fields
from datetime import date, datetime, time as dtime, timezone
from pathlib import Path
from typing import Any, Callable, Dict, Iterable, List, Optional, Tuple

from enum import Enum

import requests

from PySide6.QtCore import (
    QDate,
    QObject,
    QRunnable,
    Qt,
    QThreadPool,
    QTime,
    QTimer,
    Signal,
)
from PySide6.QtGui import QColor, QPalette
from PySide6.QtWidgets import (
    QApplication,
    QComboBox,
    QDateEdit,
    QDialog,
    QDialogButtonBox,
    QFileDialog,
    QFrame,
    QHBoxLayout,
    QLabel,
    QLineEdit,
    QMainWindow,
    QMessageBox,
    QPushButton,
    QScrollArea,
    QSizePolicy,
    QStackedWidget,
    QTableWidget,
    QTableWidgetItem,
    QTimeEdit,
    QVBoxLayout,
    QWidget,
)

API_BASE = "https://tracking-api-b4jb.onrender.com"
STATE_PATH = Path(__file__).with_name("tracking_app_state.json")
QUEUE_PATH = Path(__file__).with_name("offline_queue.json")

PRIMARY_BG = "#0b1220"
SURFACE_BG = "#111c3a"
CARD_BG = "#1c2640"
ACCENT_COLOR = "#3b82f6"
ACCENT_COLOR_SOFT = "#60a5fa"
ACCENT_HOVER = "#2563eb"
SUCCESS_COLOR = "#22c55e"
WARNING_COLOR = "#facc15"
ERROR_COLOR = "#ef4444"
TEXT_PRIMARY = "#f8fafc"
TEXT_SECONDARY = "#cbd5f5"
BORDER_COLOR = "#334155"


class TaskSignals(QObject):
    success = Signal(object)
    error = Signal(Exception)
    finished = Signal()


class TaskRunnable(QRunnable):
    def __init__(self, fn: Callable[[], Any]) -> None:
        super().__init__()
        self.fn = fn
        self.signals = TaskSignals()

    def run(self) -> None:  # pragma: no cover
        try:
            result = self.fn()
        except Exception as exc:  # noqa: BLE001 - propagate all errors
            self.signals.error.emit(exc)
        else:
            self.signals.success.emit(result)
        finally:
            self.signals.finished.emit()


class TaskRunner(QObject):
    def __init__(self) -> None:
        super().__init__()
        self.pool = QThreadPool.globalInstance()
        self._tasks: List[TaskRunnable] = []

    def submit(
        self,
        fn: Callable[[], Any],
        *,
        on_success: Optional[Callable[[Any], None]] = None,
        on_error: Optional[Callable[[Exception], None]] = None,
        on_finish: Optional[Callable[[], None]] = None,
    ) -> None:
        runnable = TaskRunnable(fn)
        self._tasks.append(runnable)

        def _cleanup() -> None:
            try:
                self._tasks.remove(runnable)
            except ValueError:
                pass

        if on_success:
            runnable.signals.success.connect(on_success)
        if on_error:
            runnable.signals.error.connect(on_error)
        if on_finish:
            runnable.signals.finished.connect(on_finish)
        runnable.signals.finished.connect(_cleanup)
        self.pool.start(runnable)


class ApiException(Exception):
    def __init__(self, message: str, status_code: int) -> None:
        super().__init__(message)
        self.message = message
        self.status_code = status_code


class UserRole(str, Enum):
    ADMIN = "admin"
    OPERATOR = "operator"
    VIEWER = "viewer"

    @property
    def label(self) -> str:
        return {
            UserRole.ADMIN: "🔑 Адмін",
            UserRole.OPERATOR: "🧰 Оператор",
            UserRole.VIEWER: "👁 Перегляд",
        }[self]

    @property
    def description(self) -> str:
        return {
            UserRole.ADMIN: "Повний доступ до функцій та керування користувачами",
            UserRole.OPERATOR: "Додавання записів та базовий функціонал",
            UserRole.VIEWER: "Перегляд інформації без змін",
        }[self]

    @property
    def level(self) -> int:
        return {
            UserRole.ADMIN: 1,
            UserRole.OPERATOR: 0,
            UserRole.VIEWER: 2,
        }[self]

    @staticmethod
    def from_value(value: Optional[str], access_level: Optional[int] = None) -> "UserRole":
        if value:
            normalized = value.lower()
            if normalized == "admin":
                return UserRole.ADMIN
            if normalized == "operator":
                return UserRole.OPERATOR
            if normalized == "viewer":
                return UserRole.VIEWER
        if access_level == 1:
            return UserRole.ADMIN
        if access_level == 0:
            return UserRole.OPERATOR
        return UserRole.VIEWER


@dataclass
class PendingUser:
    id: int
    surname: str
    created_at: Optional[datetime]


@dataclass
class ManagedUser:
    id: int
    surname: str
    role: UserRole
    is_active: bool
    created_at: Optional[datetime]
    updated_at: Optional[datetime]


class UserApi:
    @staticmethod
    def _url(path: str) -> str:
        if not path.startswith("/"):
            path = f"/{path}"
        return f"{API_BASE}{path}"

    @staticmethod
    def _headers(token: Optional[str] = None) -> Dict[str, str]:
        headers = {
            "Accept": "application/json",
            "Content-Type": "application/json",
        }
        if token:
            headers["Authorization"] = f"Bearer {token}"
        return headers

    @staticmethod
    def _extract_message(payload: Any, status: int) -> str:
        if isinstance(payload, dict):
            detail = payload.get("detail") or payload.get("message")
            if isinstance(detail, str) and detail:
                return detail
        return f"Помилка сервера ({status})"

    @staticmethod
    def _request(
        method: str,
        path: str,
        *,
        token: Optional[str] = None,
        json_data: Optional[Dict[str, Any]] = None,
    ) -> Any:
        response = requests.request(
            method,
            UserApi._url(path),
            headers=UserApi._headers(token),
            json=json_data,
            timeout=15,
        )
        if 200 <= response.status_code < 300:
            if response.content:
                try:
                    return response.json()
                except ValueError:
                    return None
            return None
        try:
            payload = response.json()
        except ValueError:
            payload = None
        raise ApiException(
            UserApi._extract_message(payload, response.status_code),
            response.status_code,
        )

    @staticmethod
    def register_user(surname: str, password: str) -> None:
        UserApi._request(
            "POST",
            "/register",
            json_data={"surname": surname, "password": password},
        )

    @staticmethod
    def admin_login(password: str) -> str:
        data = UserApi._request(
            "POST",
            "/admin_login",
            json_data={"password": password},
        )
        if not isinstance(data, dict):
            raise ApiException("Некоректна відповідь сервера", 500)
        token = str(data.get("token", ""))
        if not token:
            raise ApiException("Сервер не повернув токен доступу", 500)
        return token

    @staticmethod
    def fetch_pending_users(token: str) -> List[PendingUser]:
        data = UserApi._request("GET", "/admin/registration_requests", token=token)
        results: List[PendingUser] = []
        if isinstance(data, list):
            for item in data:
                if isinstance(item, dict):
                    created = parse_api_datetime(item.get("created_at"))
                    results.append(
                        PendingUser(
                            id=int(float(item.get("id", 0) or 0)),
                            surname=str(item.get("surname", "Невідомий користувач")),
                            created_at=created,
                        )
                    )
        return results

    @staticmethod
    def approve_pending_user(token: str, request_id: int, role: UserRole) -> None:
        UserApi._request(
            "POST",
            f"/admin/registration_requests/{request_id}/approve",
            token=token,
            json_data={"role": role.value},
        )

    @staticmethod
    def reject_pending_user(token: str, request_id: int) -> None:
        UserApi._request(
            "POST",
            f"/admin/registration_requests/{request_id}/reject",
            token=token,
        )

    @staticmethod
    def fetch_users(token: str) -> List[ManagedUser]:
        data = UserApi._request("GET", "/admin/users", token=token)
        results: List[ManagedUser] = []
        if isinstance(data, list):
            for item in data:
                if isinstance(item, dict):
                    role = UserRole.from_value(item.get("role"))
                    created = parse_api_datetime(item.get("created_at"))
                    updated = parse_api_datetime(item.get("updated_at"))
                    results.append(
                        ManagedUser(
                            id=int(float(item.get("id", 0) or 0)),
                            surname=str(item.get("surname", "Невідомий користувач")),
                            role=role,
                            is_active=bool(item.get("is_active", False)),
                            created_at=created,
                            updated_at=updated,
                        )
                    )
        return results

    @staticmethod
    def update_user(
        token: str,
        user_id: int,
        *,
        role: Optional[UserRole] = None,
        is_active: Optional[bool] = None,
    ) -> ManagedUser:
        payload: Dict[str, Any] = {}
        if role is not None:
            payload["role"] = role.value
        if is_active is not None:
            payload["is_active"] = is_active
        if not payload:
            raise ApiException("Немає даних для оновлення", 400)
        data = UserApi._request(
            "PATCH",
            f"/admin/users/{user_id}",
            token=token,
            json_data=payload,
        )
        if not isinstance(data, dict):
            raise ApiException("Некоректна відповідь сервера", 500)
        role_value = UserRole.from_value(data.get("role"))
        return ManagedUser(
            id=int(float(data.get("id", user_id) or user_id)),
            surname=str(data.get("surname", "Невідомий користувач")),
            role=role_value,
            is_active=bool(data.get("is_active", False)),
            created_at=parse_api_datetime(data.get("created_at")),
            updated_at=parse_api_datetime(data.get("updated_at")),
        )

    @staticmethod
    def delete_user(token: str, user_id: int) -> None:
        UserApi._request("DELETE", f"/admin/users/{user_id}", token=token)

    @staticmethod
    def fetch_role_passwords(token: str) -> Dict[UserRole, str]:
        data = UserApi._request("GET", "/admin/role-passwords", token=token)
        results: Dict[UserRole, str] = {}
        if isinstance(data, dict):
            for key, value in data.items():
                role = UserRole.from_value(str(key))
                results[role] = "" if value is None else str(value)
        return results

    @staticmethod
    def update_role_password(token: str, role: UserRole, password: str) -> None:
        UserApi._request(
            "POST",
            f"/admin/role-passwords/{role.value}",
            token=token,
            json_data={"password": password},
        )


@dataclass
class AppState:
    token: Optional[str] = None
    access_level: Optional[int] = None
    user_name: str = ""
    user_role: str = "viewer"

    @classmethod
    def load(cls) -> "AppState":
        if STATE_PATH.exists():
            try:
                data = json.loads(STATE_PATH.read_text(encoding="utf-8"))
                allowed = {field.name for field in fields(cls)}
                filtered = {
                    key: value
                    for key, value in data.items()
                    if key in allowed
                }
                return cls(**filtered)
            except Exception:
                STATE_PATH.unlink(missing_ok=True)
        return cls()

    def save(self) -> None:
        STATE_PATH.write_text(json.dumps(asdict(self), indent=2), encoding="utf-8")


class OfflineQueue:
    _lock = threading.Lock()

    @staticmethod
    def _load() -> List[Dict[str, Any]]:
        if QUEUE_PATH.exists():
            try:
                return json.loads(QUEUE_PATH.read_text(encoding="utf-8"))
            except Exception:
                QUEUE_PATH.unlink(missing_ok=True)
        return []

    @classmethod
    def add_record(cls, record: Dict[str, Any]) -> None:
        with cls._lock:
            pending = cls._load()
            pending.append(record)
            QUEUE_PATH.write_text(json.dumps(pending, indent=2), encoding="utf-8")

    @classmethod
    def sync_pending(
        cls, token: str, callback: Optional[Callable[[int], None]] = None
    ) -> None:
        def worker() -> None:
            with cls._lock:
                pending = cls._load()
            if not pending or not token:
                return
            synced: List[Dict[str, Any]] = []
            for record in pending:
                try:
                    response = requests.post(
                        f"{API_BASE}/add_record",
                        json=record,
                        headers={
                            "Authorization": f"Bearer {token}",
                            "Content-Type": "application/json",
                        },
                        timeout=10,
                    )
                    if response.status_code == 200:
                        synced.append(record)
                except requests.RequestException:
                    break
            if synced:
                with cls._lock:
                    remaining = [r for r in cls._load() if r not in synced]
                    QUEUE_PATH.write_text(
                        json.dumps(remaining, indent=2), encoding="utf-8"
                    )
            if callback:
                callback(len(synced))

        threading.Thread(target=worker, daemon=True).start()


def parse_api_datetime(value: Optional[str]) -> Optional[datetime]:
    if not value:
        return None
    cleaned = value.replace("Z", "+00:00")
    try:
        dt = datetime.fromisoformat(cleaned)
        if dt.tzinfo is None:
            dt = dt.replace(tzinfo=timezone.utc)
        return dt.astimezone()
    except ValueError:
        try:
            return datetime.strptime(value, "%Y-%m-%d %H:%M:%S").replace(tzinfo=timezone.utc)
        except ValueError:
            return None


class TrackingAppController(QObject):
    offline_synced = Signal(int)
    connectivity_changed = Signal(bool)

    def __init__(self, state: AppState) -> None:
        super().__init__()
        self.state = state
        self._connectivity_timer = QTimer(self)
        self._connectivity_timer.setInterval(15000)
        self._connectivity_timer.timeout.connect(self.check_connectivity)
        self._online = False

    @property
    def is_online(self) -> bool:
        return self._online

    def start_connectivity_checks(self) -> None:
        self.check_connectivity()
        self._connectivity_timer.start()

    def stop_connectivity_checks(self) -> None:
        self._connectivity_timer.stop()

    def check_connectivity(self) -> None:
        def worker() -> bool:
            try:
                response = requests.head(API_BASE, timeout=5)
                return response.status_code < 500
            except requests.RequestException:
                return False

        def on_success(result: bool) -> None:
            if self._online != result:
                self._online = result
                self.connectivity_changed.emit(result)

        TaskRunner().submit(worker, on_success=on_success)

    def login(self, surname: str, password: str) -> Dict[str, Any]:
        response = requests.post(
            f"{API_BASE}/login",
            json={"surname": surname, "password": password},
            headers={
                "Accept": "application/json",
                "Content-Type": "application/json",
            },
            timeout=15,
        )
        if response.status_code != 200:
            try:
                payload = response.json()
            except ValueError:
                payload = None
            raise ApiException(
                UserApi._extract_message(payload, response.status_code),
                response.status_code,
            )
        data = response.json()
        if not isinstance(data, dict):
            raise ApiException("Некоректна відповідь сервера", 500)
        token = str(data.get("token", ""))
        if not token:
            raise ApiException("Сервер не повернув коректний токен", 500)
        access_level = self._to_int(data.get("access_level"))
        role_name = data.get("role")
        resolved_name = str(data.get("surname", surname))

        self.state.token = token
        self.state.access_level = access_level
        self.state.user_name = resolved_name
        self.state.user_role = str(role_name or "viewer").lower()
        self.state.save()
        OfflineQueue.sync_pending(token, self.offline_synced.emit)
        return data

    def logout(self) -> None:
        self.state.token = None
        self.state.access_level = None
        self.state.user_role = "viewer"
        self.state.save()

    def register(self, surname: str, password: str) -> None:
        UserApi.register_user(surname, password)

    def set_user_name(self, name: str) -> None:
        self.state.user_name = name
        self.state.save()

    def submit_record(self, boxid: str, ttn: str) -> Dict[str, Any]:
        record = {
            "user_name": self.state.user_name,
            "boxid": boxid,
            "ttn": ttn,
        }
        token = self.state.token or ""
        if not token:
            OfflineQueue.add_record(record)
            return {"status": "offline", "message": "📦 Збережено локально. Увійдіть для синхронізації."}
        try:
            response = requests.post(
                f"{API_BASE}/add_record",
                json=record,
                headers={
                    "Authorization": f"Bearer {token}",
                    "Content-Type": "application/json",
                },
                timeout=10,
            )
            if response.status_code == 200:
                payload = response.json() if response.content else {}
                note = ""
                if isinstance(payload, dict):
                    note = str(payload.get("note", ""))
                if note:
                    message = f"⚠️ Дублікат: {note}"
                else:
                    message = "✅ Успішно додано"
                OfflineQueue.sync_pending(token, self.offline_synced.emit)
                return {"status": "ok", "message": message}
            raise requests.RequestException(f"status {response.status_code}")
        except requests.RequestException:
            OfflineQueue.add_record(record)
            return {"status": "offline", "message": "📦 Збережено локально (офлайн)."}

    def fetch_history(self) -> List[Dict[str, Any]]:
        token = self._require_token()
        response = requests.get(
            f"{API_BASE}/get_history",
            headers={"Authorization": f"Bearer {token}"},
            timeout=10,
        )
        if response.status_code != 200:
            raise requests.RequestException(f"status {response.status_code}")
        data = response.json()
        fallback = datetime.min.replace(tzinfo=timezone.utc)
        data.sort(
            key=lambda r: parse_api_datetime(r.get("datetime")) or fallback,
            reverse=True,
        )
        return data

    def clear_history(self) -> None:
        token = self._require_token()
        response = requests.delete(
            f"{API_BASE}/clear_tracking",
            headers={"Authorization": f"Bearer {token}"},
            timeout=10,
        )
        if response.status_code != 200:
            raise requests.RequestException(f"status {response.status_code}")

    def fetch_errors(self) -> List[Dict[str, Any]]:
        token = self._require_token()
        response = requests.get(
            f"{API_BASE}/get_errors",
            headers={"Authorization": f"Bearer {token}"},
            timeout=10,
        )
        if response.status_code != 200:
            raise requests.RequestException(f"status {response.status_code}")
        data = response.json()
        fallback = datetime.min.replace(tzinfo=timezone.utc)
        data.sort(
            key=lambda r: parse_api_datetime(r.get("datetime")) or fallback,
            reverse=True,
        )
        return data

    def clear_errors(self) -> None:
        token = self._require_token()
        response = requests.delete(
            f"{API_BASE}/clear_errors",
            headers={"Authorization": f"Bearer {token}"},
            timeout=10,
        )
        if response.status_code != 200:
            raise requests.RequestException(f"status {response.status_code}")

    def delete_error(self, record_id: int) -> None:
        token = self._require_token()
        response = requests.delete(
            f"{API_BASE}/delete_error/{record_id}",
            headers={"Authorization": f"Bearer {token}"},
            timeout=10,
        )
        if response.status_code != 200:
            raise requests.RequestException(f"status {response.status_code}")

    def fetch_statistics_payload(self) -> Tuple[List[Dict[str, Any]], List[Dict[str, Any]]]:
        token = self._require_token()
        headers = {"Authorization": f"Bearer {token}"}
        history_resp = requests.get(
            f"{API_BASE}/get_history",
            headers=headers,
            timeout=10,
        )
        errors_resp = requests.get(
            f"{API_BASE}/get_errors",
            headers=headers,
            timeout=10,
        )
        if history_resp.status_code != 200 or errors_resp.status_code != 200:
            raise requests.RequestException(
                f"history {history_resp.status_code}, errors {errors_resp.status_code}"
            )
        history = history_resp.json()
        errors = errors_resp.json()
        fallback = datetime.min.replace(tzinfo=timezone.utc)
        history.sort(key=lambda r: parse_api_datetime(r.get("datetime")) or fallback, reverse=True)
        errors.sort(key=lambda r: parse_api_datetime(r.get("datetime")) or fallback, reverse=True)
        return history, errors

    def export_statistics(
        self,
        *,
        file_path: str,
        period_text: str,
        updated_text: str,
        totals: Dict[str, str],
        scan_counts: Dict[str, int],
        error_counts: Dict[str, int],
        daily_rows: List[Tuple[str, int, int, str, str]],
    ) -> None:
        with open(file_path, "w", newline="", encoding="utf-8") as handle:
            writer = csv.writer(handle, delimiter=";")
            writer.writerow(["Аналітичний звіт TrackingApp"])
            writer.writerow([period_text])
            writer.writerow([f"Оновлено: {updated_text}"])
            writer.writerow([])
            writer.writerow(["Підсумки"])
            writer.writerow(["Усього сканувань", totals.get("scans", "0")])
            writer.writerow(["Унікальних операторів", totals.get("unique", "0")])
            writer.writerow(["Усього помилок", totals.get("errors", "0")])
            writer.writerow(["Користувачів з помилками", totals.get("error_users", "0")])
            writer.writerow(["Найактивніший оператор", totals.get("top_operator", "—"), totals.get("top_operator_count", "0")])
            writer.writerow(["Найбільше помилок", totals.get("top_error", "—"), totals.get("top_error_count", "0")])
            writer.writerow([])
            writer.writerow(["Сканування за користувачами"])
            writer.writerow(["Користувач", "Кількість"])
            if scan_counts:
                for name, count in sorted(scan_counts.items(), key=lambda item: item[1], reverse=True):
                    writer.writerow([name, count])
            else:
                writer.writerow(["Немає даних", "—"])
            writer.writerow([])
            writer.writerow(["Помилки за користувачами"])
            writer.writerow(["Користувач", "Кількість"])
            if error_counts:
                for name, count in sorted(error_counts.items(), key=lambda item: item[1], reverse=True):
                    writer.writerow([name, count])
            else:
                writer.writerow(["Немає даних", "—"])
            writer.writerow([])
            writer.writerow(["Щоденна активність"])
            writer.writerow(["Дата", "Сканування", "Помилки", "Лідер", "Найбільше помилок"])
            if daily_rows:
                for row in daily_rows:
                    writer.writerow(row)
            else:
                writer.writerow(["Немає даних", "—", "—", "—", "—"])

    def admin_token(self, password: str) -> str:
        return UserApi.admin_login(password)

    def fetch_pending(self, token: str) -> List[PendingUser]:
        return UserApi.fetch_pending_users(token)

    def approve_pending(self, token: str, request_id: int, role: UserRole) -> None:
        UserApi.approve_pending_user(token, request_id, role)

    def reject_pending(self, token: str, request_id: int) -> None:
        UserApi.reject_pending_user(token, request_id)

    def fetch_users_admin(self, token: str) -> List[ManagedUser]:
        return UserApi.fetch_users(token)

    def update_user_admin(
        self,
        token: str,
        user_id: int,
        *,
        role: Optional[UserRole] = None,
        is_active: Optional[bool] = None,
    ) -> ManagedUser:
        return UserApi.update_user(token, user_id, role=role, is_active=is_active)

    def delete_user_admin(self, token: str, user_id: int) -> None:
        UserApi.delete_user(token, user_id)

    def fetch_role_passwords_admin(self, token: str) -> Dict[UserRole, str]:
        return UserApi.fetch_role_passwords(token)

    def update_role_password_admin(self, token: str, role: UserRole, password: str) -> None:
        UserApi.update_role_password(token, role, password)

    @staticmethod
    def _to_int(value: Any) -> Optional[int]:
        if isinstance(value, int):
            return value
        if isinstance(value, float):
            return int(value)
        if isinstance(value, str):
            try:
                return int(value)
            except ValueError:
                return None
        return None

    def _require_token(self) -> str:
        if not self.state.token:
            raise ApiException("Необхідна авторизація", 401)
        return self.state.token

def apply_modern_palette(app: QApplication) -> None:
    palette = QPalette()
    palette.setColor(QPalette.Window, QColor(PRIMARY_BG))
    palette.setColor(QPalette.WindowText, QColor(TEXT_PRIMARY))
    palette.setColor(QPalette.Base, QColor(CARD_BG))
    palette.setColor(QPalette.AlternateBase, QColor(SURFACE_BG))
    palette.setColor(QPalette.ToolTipBase, QColor(TEXT_PRIMARY))
    palette.setColor(QPalette.ToolTipText, QColor(PRIMARY_BG))
    palette.setColor(QPalette.Text, QColor(TEXT_PRIMARY))
    palette.setColor(QPalette.Button, QColor(SURFACE_BG))
    palette.setColor(QPalette.ButtonText, QColor(TEXT_PRIMARY))
    palette.setColor(QPalette.Highlight, QColor(ACCENT_COLOR))
    palette.setColor(QPalette.HighlightedText, QColor("#0f172a"))
    app.setPalette(palette)
    app.setStyleSheet(
        f"""
        QWidget {{
            color: {TEXT_PRIMARY};
            font-family: 'Segoe UI', 'Inter', sans-serif;
            font-size: 15px;
        }}
        QFrame#Card {{
            background-color: {CARD_BG};
            border-radius: 18px;
            border: 1px solid {BORDER_COLOR};
        }}
        QPushButton {{
            border-radius: 12px;
            padding: 12px 18px;
            background-color: transparent;
            border: 1px solid transparent;
        }}
        QPushButton.primary {{
            background-color: {ACCENT_COLOR};
            border: 1px solid {ACCENT_COLOR};
            color: white;
            font-weight: 600;
        }}
        QPushButton.primary:hover {{
            background-color: {ACCENT_HOVER};
            border-color: {ACCENT_HOVER};
        }}
        QPushButton.outline {{
            border: 1px solid {ACCENT_COLOR_SOFT};
            color: {ACCENT_COLOR_SOFT};
        }}
        QPushButton.outline:hover {{
            background-color: rgba(96,165,250,0.1);
        }}
        QPushButton.text {{
            border: none;
            color: {TEXT_SECONDARY};
        }}
        QLineEdit {{
            border-radius: 12px;
            padding: 12px 16px;
            background: {SURFACE_BG};
            border: 1px solid {BORDER_COLOR};
            font-size: 16px;
        }}
        QLineEdit:focus {{
            border-color: {ACCENT_COLOR};
        }}
        QScrollArea {{
            border: none;
        }}
        QTableWidget {{
            border: 1px solid {BORDER_COLOR};
            border-radius: 16px;
            gridline-color: {BORDER_COLOR};
            background: {SURFACE_BG};
        }}
        QHeaderView::section {{
            background: {CARD_BG};
            color: {TEXT_PRIMARY};
            border: none;
            padding: 12px;
            font-weight: 600;
        }}
        QListWidget {{
            background: transparent;
            border: none;
        }}
        QListWidget::item {{
            padding: 18px 16px;
            border-radius: 12px;
        }}
        QListWidget::item:selected {{
            background: {ACCENT_COLOR};
        }}
        QTabWidget::pane {{
            border: 1px solid {BORDER_COLOR};
            border-radius: 14px;
            padding: 16px;
        }}
        QTabBar::tab {{
            background: transparent;
            padding: 12px 20px;
            border-radius: 10px;
            margin: 0 6px;
            border: 1px solid transparent;
        }}
        QTabBar::tab:selected {{
            background: {ACCENT_COLOR};
            border-color: {ACCENT_COLOR};
        }}
        """
    )


class HeroCard(QFrame):
    def __init__(self, *, title: str, subtitle: str, parent: Optional[QWidget] = None) -> None:
        super().__init__(parent)
        self.setObjectName("Card")
        layout = QVBoxLayout(self)
        layout.setSpacing(12)
        layout.setContentsMargins(28, 28, 28, 28)

        title_label = QLabel(title)
        title_label.setWordWrap(True)
        title_label.setStyleSheet("font-size: 28px; font-weight: 700;")
        layout.addWidget(title_label)

        subtitle_label = QLabel(subtitle)
        subtitle_label.setWordWrap(True)
        subtitle_label.setStyleSheet(f"color: {TEXT_SECONDARY}; font-size: 16px; line-height: 1.4em;")
        layout.addWidget(subtitle_label)


class NavigationButton(QPushButton):
    def __init__(self, text: str, *, key: str, icon: Optional[str] = None, parent: Optional[QWidget] = None) -> None:
        super().__init__(parent)
        self.key = key
        self.setText(f"{icon or ''}  {text}".strip())
        self.setCursor(Qt.PointingHandCursor)
        self.setSizePolicy(QSizePolicy.Expanding, QSizePolicy.Fixed)
        self.setCheckable(True)
        self.setStyleSheet(
            f"""
            QPushButton {{
                text-align: left;
                padding: 14px 18px;
                border-radius: 14px;
                background: transparent;
                border: 1px solid transparent;
                color: {TEXT_SECONDARY};
            }}
            QPushButton:checked {{
                background: {ACCENT_COLOR};
                color: white;
            }}
            QPushButton:hover {{
                background: rgba(96,165,250,0.15);
                color: white;
            }}
            """
        )


class NavigationPanel(QFrame):
    page_selected = Signal(str)

    def __init__(self, parent: Optional[QWidget] = None) -> None:
        super().__init__(parent)
        self.setObjectName("Card")
        self.setMinimumWidth(260)
        layout = QVBoxLayout(self)
        layout.setContentsMargins(20, 24, 20, 24)
        layout.setSpacing(12)

        logo = QLabel("TrackingApp")
        logo.setStyleSheet("font-size: 22px; font-weight: 700;")
        layout.addWidget(logo)

        tagline = QLabel("Панель логістики")
        tagline.setStyleSheet(f"color: {TEXT_SECONDARY}; font-size: 14px;")
        layout.addWidget(tagline)

        self.button_container = QVBoxLayout()
        self.button_container.setSpacing(4)
        layout.addLayout(self.button_container)
        layout.addStretch(1)

        self.logout_button = QPushButton("Вийти")
        self.logout_button.setStyleSheet(
            f"color: {ERROR_COLOR}; border: 1px solid {ERROR_COLOR}; border-radius: 12px; padding: 12px 16px;"
        )
        layout.addWidget(self.logout_button)

        self._buttons: Dict[str, NavigationButton] = {}

    def add_page(self, *, key: str, text: str, icon: Optional[str] = None) -> None:
        button = NavigationButton(text, key=key, icon=icon)
        button.toggled.connect(lambda checked, k=key: checked and self.page_selected.emit(k))
        self.button_container.addWidget(button)
        self._buttons[key] = button

    def set_current(self, key: str) -> None:
        for btn_key, button in self._buttons.items():
            button.setChecked(btn_key == key)

    def buttons(self) -> Iterable[NavigationButton]:
        return self._buttons.values()


class SectionTitle(QLabel):
    def __init__(self, text: str, *, large: bool = False, parent: Optional[QWidget] = None) -> None:
        super().__init__(text, parent)
        self.setWordWrap(True)
        self.setStyleSheet(
            "font-weight: 700; "
            + ("font-size: 24px;" if large else "font-size: 20px;")
        )


class PillLabel(QLabel):
    def __init__(self, text: str, *, color: str = ACCENT_COLOR, parent: Optional[QWidget] = None) -> None:
        super().__init__(text, parent)
        self.setStyleSheet(
            f"background-color: {color}; color: white; padding: 6px 14px; border-radius: 999px; font-weight: 600;"
        )


class FlowRow(QWidget):
    def __init__(self, parent: Optional[QWidget] = None) -> None:
        super().__init__(parent)
        layout = QHBoxLayout(self)
        layout.setContentsMargins(0, 0, 0, 0)
        layout.setSpacing(12)


class MetricCard(QFrame):
    def __init__(self, title: str, value_label: QLabel, *, accent: Optional[str] = None, parent: Optional[QWidget] = None) -> None:
        super().__init__(parent)
        self.setObjectName("Card")
        layout = QVBoxLayout(self)
        layout.setContentsMargins(22, 22, 22, 22)
        layout.setSpacing(8)

        title_label = QLabel(title)
        title_label.setStyleSheet(f"color: {TEXT_SECONDARY}; font-size: 14px;")
        layout.addWidget(title_label)

        value_label.setStyleSheet(
            f"font-size: 28px; font-weight: 700; color: {accent or TEXT_PRIMARY};"
        )
        layout.addWidget(value_label)
        layout.addStretch(1)


class InfoCard(QFrame):
    def __init__(self, title: str, description: str, *, icon: str = "", parent: Optional[QWidget] = None) -> None:
        super().__init__(parent)
        self.setObjectName("Card")
        layout = QVBoxLayout(self)
        layout.setContentsMargins(22, 22, 22, 22)
        layout.setSpacing(8)

        header = QLabel(f"{icon} {title}" if icon else title)
        header.setWordWrap(True)
        header.setStyleSheet("font-weight: 600; font-size: 18px;")
        layout.addWidget(header)

        body = QLabel(description)
        body.setWordWrap(True)
        body.setStyleSheet(f"color: {TEXT_SECONDARY}; line-height: 1.4em; font-size: 14px;")
        layout.addWidget(body)


class DatePickerDialog(QDialog):
    def __init__(self, parent: Optional[QWidget] = None, initial: Optional[date] = None) -> None:
        super().__init__(parent)
        self.setWindowTitle("Оберіть дату")
        self.setModal(True)
        layout = QVBoxLayout(self)
        layout.setContentsMargins(24, 24, 24, 24)
        self.date_edit = QDateEdit(self)
        self.date_edit.setCalendarPopup(True)
        self.date_edit.setDisplayFormat("dd.MM.yyyy")
        self.date_edit.setDate(initial and QDate(initial.year, initial.month, initial.day) or QDate.currentDate())
        layout.addWidget(self.date_edit)

        buttons = QDialogButtonBox(QDialogButtonBox.Ok | QDialogButtonBox.Cancel)
        buttons.accepted.connect(self.accept)
        buttons.rejected.connect(self.reject)
        layout.addWidget(buttons)

    def show_dialog(self) -> Optional[date]:
        if self.exec() == QDialog.Accepted:
            qdate = self.date_edit.date()
            return date(qdate.year(), qdate.month(), qdate.day())
        return None


class TimePickerDialog(QDialog):
    def __init__(self, parent: Optional[QWidget] = None, *, title: str = "Оберіть час", initial: Optional[dtime] = None) -> None:
        super().__init__(parent)
        self.setWindowTitle(title)
        self.setModal(True)
        layout = QVBoxLayout(self)
        layout.setContentsMargins(24, 24, 24, 24)
        self.time_edit = QTimeEdit(self)
        self.time_edit.setDisplayFormat("HH:mm")
        initial_time = initial or dtime(hour=0, minute=0)
        self.time_edit.setTime(QTime(initial_time.hour, initial_time.minute))
        layout.addWidget(self.time_edit)

        buttons = QDialogButtonBox(QDialogButtonBox.Ok | QDialogButtonBox.Cancel)
        buttons.accepted.connect(self.accept)
        buttons.rejected.connect(self.reject)
        layout.addWidget(buttons)

    def show_dialog(self) -> Optional[dtime]:
        if self.exec() == QDialog.Accepted:
            qtime = self.time_edit.time()
            return dtime(hour=qtime.hour(), minute=qtime.minute())
        return None


class NameDialog(QDialog):
    def __init__(self, controller: TrackingAppController, parent: Optional[QWidget] = None) -> None:
        super().__init__(parent)
        self.controller = controller
        self.setWindowTitle("Ім’я користувача")
        self.setModal(True)
        layout = QVBoxLayout(self)
        layout.setContentsMargins(32, 32, 32, 32)
        layout.setSpacing(18)

        layout.addWidget(SectionTitle("Як ми можемо звертатись до вас?", large=True))
        help_label = QLabel("Ім’я відображається у звітах та історії сканувань.")
        help_label.setWordWrap(True)
        help_label.setStyleSheet(f"color: {TEXT_SECONDARY};")
        layout.addWidget(help_label)

        self.edit = QLineEdit(self)
        self.edit.setPlaceholderText("Введіть ім’я та ініціали")
        layout.addWidget(self.edit)

        buttons = QDialogButtonBox()
        ok_button = buttons.addButton("Зберегти", QDialogButtonBox.AcceptRole)
        ok_button.setProperty("class", "primary")
        cancel_button = buttons.addButton("Скасувати", QDialogButtonBox.RejectRole)
        cancel_button.setProperty("class", "outline")
        buttons.accepted.connect(self.accept)
        buttons.rejected.connect(self.reject)
        layout.addWidget(buttons)

    def accept(self) -> None:  # noqa: D401 - Qt override
        text = self.edit.text().strip()
        if not text:
            QMessageBox.warning(self, "Увага", "Введіть ім’я користувача")
            return
        self.controller.set_user_name(text)
        super().accept()


class AdminPasswordDialog(QDialog):
    def __init__(self, parent: Optional[QWidget] = None) -> None:
        super().__init__(parent)
        self.setWindowTitle("Панель адміністратора")
        self.setModal(True)
        layout = QVBoxLayout(self)
        layout.setContentsMargins(24, 24, 24, 24)
        layout.addWidget(SectionTitle("Введіть пароль адміністратора"))

        self.edit = QLineEdit(self)
        self.edit.setEchoMode(QLineEdit.Password)
        layout.addWidget(self.edit)

        buttons = QDialogButtonBox()
        ok = buttons.addButton("Увійти", QDialogButtonBox.AcceptRole)
        ok.setProperty("class", "primary")
        cancel = buttons.addButton("Скасувати", QDialogButtonBox.RejectRole)
        cancel.setProperty("class", "outline")
        buttons.accepted.connect(self.accept)
        buttons.rejected.connect(self.reject)
        layout.addWidget(buttons)

    def password(self) -> Optional[str]:
        if self.exec() == QDialog.Accepted:
            return self.edit.text().strip()
        return None


class AdminPanelDialog(QDialog):
    def __init__(self, controller: TrackingAppController, admin_token: str, parent: Optional[QWidget] = None) -> None:
        super().__init__(parent)
        self.controller = controller
        self.admin_token = admin_token
        self.setWindowTitle("Адмін-панель")
        self.resize(1100, 720)

        from PySide6.QtWidgets import QTabWidget  # local import keeps header tidy

        layout = QVBoxLayout(self)
        layout.setContentsMargins(28, 28, 28, 28)
        layout.setSpacing(18)

        layout.addWidget(SectionTitle("Управління доступом", large=True))
        description = QLabel(
            "Керуйте заявками на реєстрацію, ролями користувачів та паролями доступу."
        )
        description.setWordWrap(True)
        description.setStyleSheet(f"color: {TEXT_SECONDARY};")
        layout.addWidget(description)

        self.tabs = QTabWidget(self)
        layout.addWidget(self.tabs, 1)

        # Pending requests tab
        self.pending_table = QTableWidget(0, 3, self)
        self.pending_table.setHorizontalHeaderLabels(["ID", "Прізвище", "Створено"])
        self.pending_table.horizontalHeader().setStretchLastSection(True)
        pending_widget = QWidget()
        pending_layout = QVBoxLayout(pending_widget)
        pending_layout.setContentsMargins(0, 0, 0, 0)
        pending_layout.addWidget(self.pending_table)

        pending_actions = FlowRow()
        self.approve_button = QPushButton("Схвалити")
        self.approve_button.setProperty("class", "primary")
        self.reject_button = QPushButton("Відхилити")
        self.reject_button.setProperty("class", "outline")
        pending_actions.layout().addWidget(self.approve_button)
        pending_actions.layout().addWidget(self.reject_button)
        pending_actions.layout().addStretch(1)
        pending_layout.addWidget(pending_actions)
        self.tabs.addTab(pending_widget, "Заявки")

        # Users tab
        self.users_table = QTableWidget(0, 6, self)
        self.users_table.setHorizontalHeaderLabels(["ID", "Прізвище", "Роль", "Активний", "Створено", "Оновлено"])
        self.users_table.horizontalHeader().setStretchLastSection(True)
        users_widget = QWidget()
        users_layout = QVBoxLayout(users_widget)
        users_layout.setContentsMargins(0, 0, 0, 0)
        users_layout.addWidget(self.users_table)
        users_actions = FlowRow()
        self.role_combo = QComboBox()
        for role in UserRole:
            self.role_combo.addItem(role.label, role)
        users_actions.layout().addWidget(self.role_combo)
        self.toggle_button = QPushButton("Перемкнути активність")
        self.toggle_button.setProperty("class", "outline")
        users_actions.layout().addWidget(self.toggle_button)
        self.update_role_button = QPushButton("Оновити роль")
        self.update_role_button.setProperty("class", "primary")
        users_actions.layout().addWidget(self.update_role_button)
        self.delete_button = QPushButton("Видалити")
        self.delete_button.setStyleSheet(f"color: {ERROR_COLOR}; border: 1px solid {ERROR_COLOR}; border-radius: 12px; padding: 12px 18px;")
        users_actions.layout().addWidget(self.delete_button)
        users_actions.layout().addStretch(1)
        users_layout.addWidget(users_actions)
        self.tabs.addTab(users_widget, "Користувачі")

        # Password tab
        self.password_table = QTableWidget(0, 2, self)
        self.password_table.setHorizontalHeaderLabels(["Роль", "Пароль"])
        self.password_table.horizontalHeader().setStretchLastSection(True)
        password_widget = QWidget()
        password_layout = QVBoxLayout(password_widget)
        password_layout.setContentsMargins(0, 0, 0, 0)
        password_layout.addWidget(self.password_table)
        self.password_update_button = QPushButton("Зберегти пароль")
        self.password_update_button.setProperty("class", "primary")
        password_layout.addWidget(self.password_update_button, alignment=Qt.AlignLeft)
        self.tabs.addTab(password_widget, "Паролі доступу")

        close_button = QPushButton("Закрити")
        close_button.setProperty("class", "outline")
        close_button.clicked.connect(self.close)
        layout.addWidget(close_button, alignment=Qt.AlignRight)

        self.runner = TaskRunner()
        self._refresh_all()

        self.approve_button.clicked.connect(self._approve_selected)
        self.reject_button.clicked.connect(self._reject_selected)
        self.update_role_button.clicked.connect(self._update_role)
        self.toggle_button.clicked.connect(self._toggle_active)
        self.delete_button.clicked.connect(self._delete_user)
        self.password_update_button.clicked.connect(self._update_password)

    def _refresh_all(self) -> None:
        self._load_pending()
        self._load_users()
        self._load_passwords()

    def _load_pending(self) -> None:
        def work() -> List[PendingUser]:
            return self.controller.fetch_pending(self.admin_token)

        def on_success(items: List[PendingUser]) -> None:
            self.pending_table.setRowCount(0)
            for item in items:
                row = self.pending_table.rowCount()
                self.pending_table.insertRow(row)
                self.pending_table.setItem(row, 0, QTableWidgetItem(str(item.id)))
                self.pending_table.setItem(row, 1, QTableWidgetItem(item.surname))
                created = item.created_at.strftime("%d.%m.%Y %H:%M") if item.created_at else "—"
                self.pending_table.setItem(row, 2, QTableWidgetItem(created))

        self.runner.submit(work, on_success=on_success, on_error=self._show_error)

    def _load_users(self) -> None:
        def work() -> List[ManagedUser]:
            return self.controller.fetch_users_admin(self.admin_token)

        def on_success(items: List[ManagedUser]) -> None:
            self.users_table.setRowCount(0)
            for item in items:
                row = self.users_table.rowCount()
                self.users_table.insertRow(row)
                self.users_table.setItem(row, 0, QTableWidgetItem(str(item.id)))
                self.users_table.setItem(row, 1, QTableWidgetItem(item.surname))
                self.users_table.setItem(row, 2, QTableWidgetItem(item.role.label))
                self.users_table.setItem(row, 3, QTableWidgetItem("Так" if item.is_active else "Ні"))
                created = item.created_at.strftime("%d.%m.%Y %H:%M") if item.created_at else "—"
                updated = item.updated_at.strftime("%d.%m.%Y %H:%M") if item.updated_at else "—"
                self.users_table.setItem(row, 4, QTableWidgetItem(created))
                self.users_table.setItem(row, 5, QTableWidgetItem(updated))

        self.runner.submit(work, on_success=on_success, on_error=self._show_error)

    def _load_passwords(self) -> None:
        def work() -> Dict[UserRole, str]:
            return self.controller.fetch_role_passwords_admin(self.admin_token)

        def on_success(data: Dict[UserRole, str]) -> None:
            self.password_table.setRowCount(0)
            for role, password in data.items():
                row = self.password_table.rowCount()
                self.password_table.insertRow(row)
                self.password_table.setItem(row, 0, QTableWidgetItem(role.label))
                self.password_table.setItem(row, 1, QTableWidgetItem(password))

        self.runner.submit(work, on_success=on_success, on_error=self._show_error)

    def _selected_pending_id(self) -> Optional[int]:
        row = self.pending_table.currentRow()
        if row < 0:
            return None
        item = self.pending_table.item(row, 0)
        if not item:
            return None
        try:
            return int(item.text())
        except ValueError:
            return None

    def _selected_user_id(self) -> Optional[int]:
        row = self.users_table.currentRow()
        if row < 0:
            return None
        item = self.users_table.item(row, 0)
        if not item:
            return None
        try:
            return int(item.text())
        except ValueError:
            return None

    def _approve_selected(self) -> None:
        request_id = self._selected_pending_id()
        if request_id is None:
            QMessageBox.information(self, "Заявки", "Оберіть заявку для схвалення.")
            return
        role = self.role_combo.currentData() or UserRole.OPERATOR

        def work() -> None:
            self.controller.approve_pending(self.admin_token, request_id, role)

        self.runner.submit(
            work,
            on_success=lambda _: self._refresh_all(),
            on_error=self._show_error,
        )

    def _reject_selected(self) -> None:
        request_id = self._selected_pending_id()
        if request_id is None:
            QMessageBox.information(self, "Заявки", "Оберіть заявку для відхилення.")
            return

        def work() -> None:
            self.controller.reject_pending(self.admin_token, request_id)

        self.runner.submit(
            work,
            on_success=lambda _: self._refresh_all(),
            on_error=self._show_error,
        )

    def _update_role(self) -> None:
        user_id = self._selected_user_id()
        if user_id is None:
            QMessageBox.information(self, "Користувачі", "Оберіть користувача для оновлення ролі.")
            return
        role = self.role_combo.currentData() or UserRole.OPERATOR

        def work() -> ManagedUser:
            return self.controller.update_user_admin(self.admin_token, user_id, role=role)

        self.runner.submit(
            work,
            on_success=lambda _: self._load_users(),
            on_error=self._show_error,
        )

    def _toggle_active(self) -> None:
        user_id = self._selected_user_id()
        if user_id is None:
            QMessageBox.information(self, "Користувачі", "Оберіть користувача.")
            return
        row = self.users_table.currentRow()
        current = self.users_table.item(row, 3)
        is_active = current and current.text().lower() == "так"

        def work() -> ManagedUser:
            return self.controller.update_user_admin(self.admin_token, user_id, is_active=not is_active)

        self.runner.submit(
            work,
            on_success=lambda _: self._load_users(),
            on_error=self._show_error,
        )

    def _delete_user(self) -> None:
        user_id = self._selected_user_id()
        if user_id is None:
            QMessageBox.information(self, "Користувачі", "Оберіть користувача для видалення.")
            return
        if QMessageBox.question(self, "Підтвердження", f"Видалити користувача #{user_id}?") != QMessageBox.Yes:
            return

        def work() -> None:
            self.controller.delete_user_admin(self.admin_token, user_id)

        self.runner.submit(
            work,
            on_success=lambda _: self._load_users(),
            on_error=self._show_error,
        )

    def _update_password(self) -> None:
        row = self.password_table.currentRow()
        if row < 0:
            QMessageBox.information(self, "Паролі", "Оберіть запис для оновлення.")
            return
        role_item = self.password_table.item(row, 0)
        value_item = self.password_table.item(row, 1)
        if not role_item or not value_item:
            return
        role = next((r for r in UserRole if r.label == role_item.text()), None)
        if role is None:
            QMessageBox.warning(self, "Паролі", "Невідома роль")
            return
        password = value_item.text()

        def work() -> None:
            self.controller.update_role_password_admin(self.admin_token, role, password)

        self.runner.submit(
            work,
            on_success=lambda _: QMessageBox.information(self, "Паролі", "Пароль збережено."),
            on_error=self._show_error,
        )

    def _show_error(self, exc: Exception) -> None:
        QMessageBox.warning(self, "Помилка", str(exc))


class LoginDialog(QDialog):
    authenticated = Signal()

    def __init__(self, controller: TrackingAppController, parent: Optional[QWidget] = None) -> None:
        super().__init__(parent)
        self.controller = controller
        self.setWindowTitle("TrackingApp • Вхід")
        self.resize(960, 640)
        self.runner = TaskRunner()

        layout = QHBoxLayout(self)
        layout.setContentsMargins(0, 0, 0, 0)

        hero_container = QFrame(self)
        hero_container.setStyleSheet(
            "background: qlineargradient(x1:0, y1:0, x2:1, y2:1, stop:0 #1d253f, stop:1 #0f172a);"
        )
        hero_layout = QVBoxLayout(hero_container)
        hero_layout.setContentsMargins(48, 48, 48, 48)
        hero_layout.setSpacing(24)
        hero_layout.addWidget(SectionTitle("TrackingApp", large=True))
        hero_text = QLabel(
            "Професійний десктопний клієнт для сканування відправлень. Сучасний дизайн, адаптивні макети та миттєва синхронізація."
        )
        hero_text.setWordWrap(True)
        hero_text.setStyleSheet(f"color: {TEXT_SECONDARY}; font-size: 16px;")
        hero_layout.addWidget(hero_text)
        hero_layout.addStretch(1)
        for feature in [
            "🔐 Захищена авторизація",
            "⚡ Швидке сканування BoxID та ТТН",
            "📊 Адміністративна аналітика",
        ]:
            label = QLabel(feature)
            label.setStyleSheet("font-size: 16px; font-weight: 600;")
            hero_layout.addWidget(label)
        hero_layout.addStretch(2)
        layout.addWidget(hero_container, 2)

        form_container = QFrame(self)
        form_container.setObjectName("Card")
        form_layout = QVBoxLayout(form_container)
        form_layout.setContentsMargins(48, 48, 48, 48)
        form_layout.setSpacing(18)

        form_layout.addWidget(PillLabel("Windows версія"), alignment=Qt.AlignLeft)
        form_layout.addWidget(SectionTitle("Увійдіть у робочий простір", large=True))
        intro = QLabel("Обирайте режим роботи: авторизація або заявка на доступ.")
        intro.setWordWrap(True)
        intro.setStyleSheet(f"color: {TEXT_SECONDARY};")
        form_layout.addWidget(intro)

        toggle_layout = FlowRow()
        self.login_button = QPushButton("Вхід")
        self.login_button.setProperty("class", "primary")
        self.register_button = QPushButton("Реєстрація")
        self.register_button.setProperty("class", "outline")
        toggle_layout.layout().addWidget(self.login_button)
        toggle_layout.layout().addWidget(self.register_button)
        toggle_layout.layout().addStretch(1)
        form_layout.addWidget(toggle_layout)

        self.stack = QStackedWidget(self)
        form_layout.addWidget(self.stack, 1)

        login_widget = QWidget()
        login_layout = QVBoxLayout(login_widget)
        login_layout.setSpacing(16)
        self.login_surname = QLineEdit()
        self.login_surname.setPlaceholderText("Прізвище")
        self.login_password = QLineEdit()
        self.login_password.setPlaceholderText("Пароль")
        self.login_password.setEchoMode(QLineEdit.Password)
        login_layout.addWidget(self.login_surname)
        login_layout.addWidget(self.login_password)
        self.login_error = QLabel()
        self.login_error.setStyleSheet(f"color: {ERROR_COLOR};")
        login_layout.addWidget(self.login_error)
        self.login_submit = QPushButton("Увійти")
        self.login_submit.setProperty("class", "primary")
        login_layout.addWidget(self.login_submit)
        self.stack.addWidget(login_widget)

        register_widget = QWidget()
        register_layout = QVBoxLayout(register_widget)
        register_layout.setSpacing(16)
        self.register_surname = QLineEdit()
        self.register_surname.setPlaceholderText("Прізвище")
        self.register_password = QLineEdit()
        self.register_password.setPlaceholderText("Пароль")
        self.register_password.setEchoMode(QLineEdit.Password)
        self.register_confirm = QLineEdit()
        self.register_confirm.setPlaceholderText("Підтвердження пароля")
        self.register_confirm.setEchoMode(QLineEdit.Password)
        register_layout.addWidget(self.register_surname)
        register_layout.addWidget(self.register_password)
        register_layout.addWidget(self.register_confirm)
        self.register_feedback = QLabel()
        self.register_feedback.setWordWrap(True)
        register_layout.addWidget(self.register_feedback)
        self.register_submit = QPushButton("Надіслати заявку")
        self.register_submit.setProperty("class", "primary")
        register_layout.addWidget(self.register_submit)
        self.stack.addWidget(register_widget)

        admin_button = QPushButton("Панель адміністратора")
        admin_button.setProperty("class", "text")
        form_layout.addWidget(admin_button, alignment=Qt.AlignRight)

        layout.addWidget(form_container, 3)

        self.login_button.clicked.connect(lambda: self._set_mode(True))
        self.register_button.clicked.connect(lambda: self._set_mode(False))
        self.login_submit.clicked.connect(self._login)
        self.register_submit.clicked.connect(self._register)
        admin_button.clicked.connect(self._open_admin_panel)
        self._set_mode(True)

    def _set_mode(self, login_mode: bool) -> None:
        if login_mode:
            self.stack.setCurrentIndex(0)
            self.login_button.setProperty("class", "primary")
            self.register_button.setProperty("class", "outline")
        else:
            self.stack.setCurrentIndex(1)
            self.register_button.setProperty("class", "primary")
            self.login_button.setProperty("class", "outline")
        for button in (self.login_button, self.register_button):
            button.style().unpolish(button)
            button.style().polish(button)

    def _login(self) -> None:
        surname = self.login_surname.text().strip()
        password = self.login_password.text().strip()
        if not surname or not password:
            self.login_error.setText("Введіть прізвище та пароль")
            return

        self.login_submit.setEnabled(False)
        self.login_error.clear()

        def work() -> Dict[str, Any]:
            return self.controller.login(surname, password)

        def on_success(_: Any) -> None:
            self.login_submit.setEnabled(True)
            self.accept()
            self.authenticated.emit()

        def on_error(exc: Exception) -> None:
            self.login_submit.setEnabled(True)
            self.login_error.setText(str(exc))

        self.runner.submit(work, on_success=on_success, on_error=on_error)

    def _register(self) -> None:
        surname = self.register_surname.text().strip()
        password = self.register_password.text().strip()
        confirm = self.register_confirm.text().strip()
        if not surname or not password or not confirm:
            self.register_feedback.setStyleSheet(f"color: {ERROR_COLOR};")
            self.register_feedback.setText("Заповніть усі поля")
            return
        if len(password) < 6:
            self.register_feedback.setStyleSheet(f"color: {ERROR_COLOR};")
            self.register_feedback.setText("Пароль має містити щонайменше 6 символів")
            return
        if password != confirm:
            self.register_feedback.setStyleSheet(f"color: {ERROR_COLOR};")
            self.register_feedback.setText("Паролі не співпадають")
            return

        self.register_submit.setEnabled(False)
        self.register_feedback.clear()

        def work() -> None:
            self.controller.register(surname, password)

        def on_success(_: Any) -> None:
            self.register_submit.setEnabled(True)
            self.register_feedback.setStyleSheet(f"color: {SUCCESS_COLOR};")
            self.register_feedback.setText(
                "Заявку на реєстрацію надіслано. Дочекайтесь підтвердження адміністратора."
            )
            self.register_surname.clear()
            self.register_password.clear()
            self.register_confirm.clear()

        def on_error(exc: Exception) -> None:
            self.register_submit.setEnabled(True)
            self.register_feedback.setStyleSheet(f"color: {ERROR_COLOR};")
            self.register_feedback.setText(str(exc))

        self.runner.submit(work, on_success=on_success, on_error=on_error)

    def _open_admin_panel(self) -> None:
        dialog = AdminPasswordDialog(self)
        password = dialog.password()
        if not password:
            return

        self.setEnabled(False)

        def work() -> str:
            return self.controller.admin_token(password)

        def on_success(token: str) -> None:
            self.setEnabled(True)
            AdminPanelDialog(self.controller, token, self).exec()

        def on_error(exc: Exception) -> None:
            self.setEnabled(True)
            QMessageBox.warning(self, "Помилка", str(exc))

        self.runner.submit(work, on_success=on_success, on_error=on_error)


class BasePage(QWidget):
    def __init__(self, controller: TrackingAppController, parent: Optional[QWidget] = None) -> None:
        super().__init__(parent)
        self.controller = controller
        self.runner = TaskRunner()

    def on_enter(self) -> None:
        """Hook executed whenever the page becomes visible."""


class ScannerPage(BasePage):
    def __init__(self, controller: TrackingAppController, parent: Optional[QWidget] = None) -> None:
        super().__init__(controller, parent)
        self.stage = "box"
        self.status_label = QLabel("Готово до введення BoxID")
        self.status_label.setWordWrap(True)
        self.status_label.setStyleSheet("font-size: 16px;")
        self.online_chip = QLabel("Перевірка зв’язку...")
        self.online_chip.setStyleSheet(
            f"background: {WARNING_COLOR}; color: #0f172a; padding: 6px 12px; border-radius: 999px; font-weight: 600;"
        )
        self.sync_status = QLabel("")
        self.sync_status.setStyleSheet(f"color: {TEXT_SECONDARY}; font-size: 13px;")

        layout = QVBoxLayout(self)
        layout.setContentsMargins(32, 32, 32, 32)
        layout.setSpacing(24)

        header = QHBoxLayout()
        title = SectionTitle("Сканування відправлень", large=True)
        header.addWidget(title)
        header.addStretch(1)
        header.addWidget(self.online_chip)
        layout.addLayout(header)

        self.user_label = QLabel("Оператор")
        self.user_label.setStyleSheet(f"color: {TEXT_SECONDARY};")
        layout.addWidget(self.user_label)

        form_card = QFrame()
        form_card.setObjectName("Card")
        form_layout = QVBoxLayout(form_card)
        form_layout.setContentsMargins(32, 32, 32, 32)
        form_layout.setSpacing(18)
        form_layout.addWidget(self.status_label)

        self.box_input = QLineEdit()
        self.box_input.setPlaceholderText("BoxID")
        form_layout.addWidget(self.box_input)

        self.ttn_input = QLineEdit()
        self.ttn_input.setPlaceholderText("Номер ТТН")
        self.ttn_input.setEnabled(False)
        form_layout.addWidget(self.ttn_input)

        button_row = FlowRow()
        self.primary_button = QPushButton("Перейти до ТТН")
        self.primary_button.setProperty("class", "primary")
        self.reset_button = QPushButton("Скинути")
        self.reset_button.setProperty("class", "outline")
        button_row.layout().addWidget(self.primary_button)
        button_row.layout().addWidget(self.reset_button)
        button_row.layout().addStretch(1)
        form_layout.addWidget(button_row)
        form_layout.addWidget(self.sync_status)

        layout.addWidget(form_card)

        helper_card = InfoCard(
            "Поради для швидкої роботи",
            "Використовуйте сканер для вводу BoxID. Після підтвердження система автоматично переходить до ТТН.",
            icon="💡",
        )
        layout.addWidget(helper_card)

        self.primary_button.clicked.connect(self._on_primary)
        self.reset_button.clicked.connect(self.reset_fields)
        self.box_input.returnPressed.connect(self._on_primary)
        self.ttn_input.returnPressed.connect(self._submit)
        controller.offline_synced.connect(self._on_offline_synced)
        self._update_online_state(controller.is_online)

    def refresh_user_info(self) -> None:
        name = self.controller.state.user_name or "Оператор"
        role = UserRole.from_value(
            self.controller.state.user_role,
            self.controller.state.access_level,
        )
        self.user_label.setText(f"Поточний користувач: {name} • {role.label}")

    def on_enter(self) -> None:
        self.refresh_user_info()
        self.box_input.setFocus()

    def _on_primary(self) -> None:
        if self.stage == "box":
            value = self.box_input.text().strip()
            if not value:
                QMessageBox.warning(self, "Увага", "Введіть BoxID")
                return
            self.stage = "ttn"
            self.status_label.setText("Введіть номер ТТН та підтвердіть запис")
            self.ttn_input.setEnabled(True)
            self.ttn_input.setFocus()
            self.primary_button.setText("Зберегти запис")
        else:
            self._submit()

    def _submit(self) -> None:
        if self.stage != "ttn":
            return
        boxid = self.box_input.text().strip()
        ttn = self.ttn_input.text().strip()
        if not boxid or not ttn:
            QMessageBox.warning(self, "Увага", "Заповніть обидва поля")
            return

        self.primary_button.setEnabled(False)
        self.status_label.setText("Відправлення даних...")

        def work() -> Dict[str, Any]:
            return self.controller.submit_record(boxid, ttn)

        def on_success(result: Dict[str, Any]) -> None:
            self.status_label.setText(result.get("message", ""))
            self.reset_fields()

        def on_error(exc: Exception) -> None:
            self.status_label.setText(str(exc))

        def on_finish() -> None:
            self.primary_button.setEnabled(True)

        self.runner.submit(work, on_success=on_success, on_error=on_error, on_finish=on_finish)

    def reset_fields(self) -> None:
        self.stage = "box"
        self.box_input.clear()
        self.ttn_input.clear()
        self.ttn_input.setEnabled(False)
        self.status_label.setText("Готово до введення BoxID")
        self.primary_button.setText("Перейти до ТТН")
        self.box_input.setFocus()

    def _on_offline_synced(self, count: int) -> None:
        if count:
            self.sync_status.setText(f"Синхронізовано {count} записів з офлайн-черги")
        else:
            self.sync_status.setText("")

    def _update_online_state(self, online: bool) -> None:
        if online:
            self.online_chip.setText("🟢 Підключення активне")
            self.online_chip.setStyleSheet(
                f"background: {SUCCESS_COLOR}; color: #0f172a; padding: 6px 12px; border-radius: 999px; font-weight: 600;"
            )
        else:
            self.online_chip.setText("🔴 Немає зв’язку")
            self.online_chip.setStyleSheet(
                f"background: {ERROR_COLOR}; color: white; padding: 6px 12px; border-radius: 999px; font-weight: 600;"
            )

    def set_online_state(self, online: bool) -> None:
        self._update_online_state(online)


class HistoryPage(BasePage):
    def __init__(self, controller: TrackingAppController, parent: Optional[QWidget] = None) -> None:
        super().__init__(controller, parent)
        self.records: List[Dict[str, Any]] = []
        self.filtered: List[Dict[str, Any]] = []
        self.date_filter: Optional[date] = None
        self.start_time: Optional[dtime] = None
        self.end_time: Optional[dtime] = None

        layout = QVBoxLayout(self)
        layout.setContentsMargins(32, 32, 32, 32)
        layout.setSpacing(18)

        layout.addWidget(SectionTitle("Історія операцій", large=True))
        layout.addWidget(QLabel("Швидкий пошук за BoxID, ТТН, користувачем або датою."))

        filters = QFrame()
        filters.setObjectName("Card")
        filters_layout = QVBoxLayout(filters)
        filters_layout.setContentsMargins(24, 24, 24, 24)
        filters_layout.setSpacing(12)

        input_row = FlowRow()
        self.box_filter = QLineEdit()
        self.box_filter.setPlaceholderText("BoxID")
        self.ttn_filter = QLineEdit()
        self.ttn_filter.setPlaceholderText("TTN")
        self.user_filter = QLineEdit()
        self.user_filter.setPlaceholderText("Користувач")
        for widget in (self.box_filter, self.ttn_filter, self.user_filter):
            widget.setMaximumWidth(240)
            widget.textChanged.connect(self.apply_filters)
            input_row.layout().addWidget(widget)
        input_row.layout().addStretch(1)
        filters_layout.addWidget(input_row)

        button_row = FlowRow()
        self.date_button = QPushButton("Дата")
        self.date_button.setProperty("class", "outline")
        self.start_button = QPushButton("Початок")
        self.start_button.setProperty("class", "outline")
        self.end_button = QPushButton("Кінець")
        self.end_button.setProperty("class", "outline")
        self.clear_button = QPushButton("Скинути")
        self.clear_button.setProperty("class", "outline")
        self.refresh_button = QPushButton("Оновити")
        self.refresh_button.setProperty("class", "primary")
        self.purge_button = QPushButton("Очистити історію")
        self.purge_button.setStyleSheet(f"color: {ERROR_COLOR}; border: 1px solid {ERROR_COLOR}; border-radius: 12px; padding: 12px 16px;")
        for button in (
            self.date_button,
            self.start_button,
            self.end_button,
            self.clear_button,
            self.refresh_button,
            self.purge_button,
        ):
            button_row.layout().addWidget(button)
        button_row.layout().addStretch(1)
        filters_layout.addWidget(button_row)

        self.date_display = QLabel("Дата: —")
        self.time_display = QLabel("Проміжок: —")
        filters_layout.addWidget(self.date_display)
        filters_layout.addWidget(self.time_display)

        layout.addWidget(filters)

        self.table = QTableWidget(0, 5, self)
        self.table.setHorizontalHeaderLabels(["Дата", "BoxID", "TTN", "Користувач", "Примітка"])
        self.table.horizontalHeader().setStretchLastSection(True)
        layout.addWidget(self.table, 1)

        self.date_button.clicked.connect(self._pick_date)
        self.start_button.clicked.connect(lambda: self._pick_time(True))
        self.end_button.clicked.connect(lambda: self._pick_time(False))
        self.clear_button.clicked.connect(self._reset_filters)
        self.refresh_button.clicked.connect(self.fetch_history)
        self.purge_button.clicked.connect(self._clear_history)

    def on_enter(self) -> None:
        self.fetch_history()

    def fetch_history(self) -> None:
        def work() -> List[Dict[str, Any]]:
            return self.controller.fetch_history()

        def on_success(records: List[Dict[str, Any]]) -> None:
            self.records = records
            self.apply_filters()

        self.runner.submit(work, on_success=on_success, on_error=self._show_error)

    def _show_error(self, exc: Exception) -> None:
        QMessageBox.warning(self, "Помилка", str(exc))

    def _pick_date(self) -> None:
        dialog = DatePickerDialog(self, self.date_filter)
        result = dialog.show_dialog()
        self.date_filter = result
        self.date_display.setText(
            f"Дата: {result.strftime('%d.%m.%Y')}" if result else "Дата: —"
        )
        self.apply_filters()

    def _pick_time(self, is_start: bool) -> None:
        initial = self.start_time if is_start else self.end_time
        dialog = TimePickerDialog(self, title="Час початку" if is_start else "Час завершення", initial=initial)
        result = dialog.show_dialog()
        if is_start:
            self.start_time = result
        else:
            self.end_time = result
        if self.start_time or self.end_time:
            start_txt = self.start_time.strftime("%H:%M") if self.start_time else "—"
            end_txt = self.end_time.strftime("%H:%M") if self.end_time else "—"
            self.time_display.setText(f"Проміжок: {start_txt} – {end_txt}")
        else:
            self.time_display.setText("Проміжок: —")
        self.apply_filters()

    def _reset_filters(self) -> None:
        self.box_filter.clear()
        self.ttn_filter.clear()
        self.user_filter.clear()
        self.date_filter = None
        self.start_time = None
        self.end_time = None
        self.date_display.setText("Дата: —")
        self.time_display.setText("Проміжок: —")
        self.apply_filters()

    def _clear_history(self) -> None:
        if QMessageBox.question(self, "Підтвердження", "Очистити історію? Це незворотньо.") != QMessageBox.Yes:
            return

        def work() -> None:
            self.controller.clear_history()

        def on_success(_: Any) -> None:
            self.records.clear()
            self.apply_filters()

        self.runner.submit(work, on_success=on_success, on_error=self._show_error)

    def apply_filters(self) -> None:
        filtered = list(self.records)
        if self.box_filter.text():
            needle = self.box_filter.text().strip().lower()
            filtered = [r for r in filtered if needle in str(r.get("boxid", "")).lower()]
        if self.ttn_filter.text():
            needle = self.ttn_filter.text().strip().lower()
            filtered = [r for r in filtered if needle in str(r.get("ttn", "")).lower()]
        if self.user_filter.text():
            needle = self.user_filter.text().strip().lower()
            filtered = [r for r in filtered if needle in str(r.get("user_name", "")).lower()]
        if self.date_filter or self.start_time or self.end_time:
            timed: List[Dict[str, Any]] = []
            for record in filtered:
                dt = parse_api_datetime(record.get("datetime"))
                if not dt:
                    continue
                if self.date_filter and dt.date() != self.date_filter:
                    continue
                tm = dt.time()
                if self.start_time and tm < self.start_time:
                    continue
                if self.end_time and tm > self.end_time:
                    continue
                timed.append(record)
            filtered = timed
        self.filtered = filtered
        self._render_table(filtered)

    def _render_table(self, records: List[Dict[str, Any]]) -> None:
        self.table.setRowCount(0)
        for record in records:
            row = self.table.rowCount()
            self.table.insertRow(row)
            dt = parse_api_datetime(record.get("datetime"))
            dt_txt = dt.strftime("%d.%m.%Y %H:%M:%S") if dt else record.get("datetime", "")
            self.table.setItem(row, 0, QTableWidgetItem(dt_txt))
            self.table.setItem(row, 1, QTableWidgetItem(str(record.get("boxid", ""))))
            self.table.setItem(row, 2, QTableWidgetItem(str(record.get("ttn", ""))))
            self.table.setItem(row, 3, QTableWidgetItem(str(record.get("user_name", ""))))
            self.table.setItem(row, 4, QTableWidgetItem(str(record.get("note", ""))))


class ErrorsPage(BasePage):
    def __init__(self, controller: TrackingAppController, parent: Optional[QWidget] = None) -> None:
        super().__init__(controller, parent)
        self.records: List[Dict[str, Any]] = []

        layout = QVBoxLayout(self)
        layout.setContentsMargins(32, 32, 32, 32)
        layout.setSpacing(18)

        layout.addWidget(SectionTitle("Журнал помилок", large=True))
        layout.addWidget(QLabel("Аналізуйте проблеми синхронізації та очищайте журнал."))

        toolbar = FlowRow()
        self.refresh_button = QPushButton("Оновити")
        self.refresh_button.setProperty("class", "primary")
        self.clear_button = QPushButton("Очистити журнал")
        self.clear_button.setStyleSheet(f"color: {ERROR_COLOR}; border: 1px solid {ERROR_COLOR}; border-radius: 12px; padding: 12px 18px;")
        toolbar.layout().addWidget(self.refresh_button)
        toolbar.layout().addWidget(self.clear_button)
        toolbar.layout().addStretch(1)
        layout.addWidget(toolbar)

        self.table = QTableWidget(0, 5, self)
        self.table.setHorizontalHeaderLabels(["Дата", "BoxID", "TTN", "Користувач", "Причина"])
        self.table.horizontalHeader().setStretchLastSection(True)
        layout.addWidget(self.table, 1)

        self.refresh_button.clicked.connect(self.fetch_errors)
        self.clear_button.clicked.connect(self._clear_errors)
        self.table.cellDoubleClicked.connect(self._delete_error)

    def on_enter(self) -> None:
        self.fetch_errors()

    def fetch_errors(self) -> None:
        def work() -> List[Dict[str, Any]]:
            return self.controller.fetch_errors()

        def on_success(records: List[Dict[str, Any]]) -> None:
            self.records = records
            self._render_table(records)

        self.runner.submit(work, on_success=on_success, on_error=self._show_error)

    def _clear_errors(self) -> None:
        if QMessageBox.question(self, "Підтвердження", "Очистити журнал помилок?") != QMessageBox.Yes:
            return

        def work() -> None:
            self.controller.clear_errors()

        def on_success(_: Any) -> None:
            self.records.clear()
            self._render_table([])

        self.runner.submit(work, on_success=on_success, on_error=self._show_error)

    def _delete_error(self, row: int, column: int) -> None:  # noqa: ARG002 - required by Qt
        if row < 0:
            return
        try:
            record_id = int(float(self.records[row].get("id", 0)))
        except (ValueError, IndexError):
            return
        if QMessageBox.question(self, "Видалити", f"Видалити помилку #{record_id}?") != QMessageBox.Yes:
            return

        def work() -> None:
            self.controller.delete_error(record_id)

        def on_success(_: Any) -> None:
            self.records = [r for r in self.records if int(float(r.get("id", 0) or 0)) != record_id]
            self._render_table(self.records)

        self.runner.submit(work, on_success=on_success, on_error=self._show_error)

    def _render_table(self, records: List[Dict[str, Any]]) -> None:
        self.table.setRowCount(0)
        for record in records:
            row = self.table.rowCount()
            self.table.insertRow(row)
            dt = parse_api_datetime(record.get("datetime"))
            dt_txt = dt.strftime("%d.%m.%Y %H:%M:%S") if dt else record.get("datetime", "")
            reason = (
                record.get("error_message")
                or record.get("reason")
                or record.get("note")
                or record.get("message")
                or record.get("error")
                or "Причина не вказана"
            )
            self.table.setItem(row, 0, QTableWidgetItem(dt_txt))
            self.table.setItem(row, 1, QTableWidgetItem(str(record.get("boxid", ""))))
            self.table.setItem(row, 2, QTableWidgetItem(str(record.get("ttn", ""))))
            self.table.setItem(row, 3, QTableWidgetItem(str(record.get("user_name", ""))))
            self.table.setItem(row, 4, QTableWidgetItem(str(reason)))

    def _show_error(self, exc: Exception) -> None:
        QMessageBox.warning(self, "Помилка", str(exc))


class StatisticsPage(BasePage):
    def __init__(self, controller: TrackingAppController, parent: Optional[QWidget] = None) -> None:
        super().__init__(controller, parent)
        self.history_records: List[Dict[str, Any]] = []
        self.error_records: List[Dict[str, Any]] = []
        today = date.today()
        self.start_date: Optional[date] = today.replace(day=1)
        self.end_date: Optional[date] = today
        self.start_time: Optional[dtime] = dtime.min
        self.end_time: Optional[dtime] = dtime(hour=23, minute=59, second=59)
        self.last_updated: Optional[str] = None

        layout = QVBoxLayout(self)
        layout.setContentsMargins(32, 32, 32, 32)
        layout.setSpacing(18)

        layout.addWidget(SectionTitle("Адміністративна статистика", large=True))
        layout.addWidget(QLabel("Переглядайте продуктивність команди та помилки за обраний період."))

        filters = FlowRow()
        self.period_label = QLabel("")
        filters.layout().addWidget(self.period_label)
        self.start_date_button = QPushButton("Дата початку")
        self.start_date_button.setProperty("class", "outline")
        self.start_time_button = QPushButton("Час початку")
        self.start_time_button.setProperty("class", "outline")
        self.end_date_button = QPushButton("Дата завершення")
        self.end_date_button.setProperty("class", "outline")
        self.end_time_button = QPushButton("Час завершення")
        self.end_time_button.setProperty("class", "outline")
        self.reset_button = QPushButton("Скинути період")
        self.reset_button.setProperty("class", "outline")
        self.refresh_button = QPushButton("Оновити")
        self.refresh_button.setProperty("class", "primary")
        self.export_button = QPushButton("Зберегти звіт")
        self.export_button.setProperty("class", "primary")
        for button in (
            self.start_date_button,
            self.start_time_button,
            self.end_date_button,
            self.end_time_button,
            self.reset_button,
            self.refresh_button,
            self.export_button,
        ):
            filters.layout().addWidget(button)
        filters.layout().addStretch(1)
        layout.addWidget(filters)

        metrics_row = FlowRow()
        self.total_scans_label = QLabel("0")
        self.unique_users_label = QLabel("0")
        self.total_errors_label = QLabel("0")
        self.error_users_label = QLabel("0")
        metrics_row.layout().addWidget(MetricCard("Сканувань", self.total_scans_label, accent=ACCENT_COLOR))
        metrics_row.layout().addWidget(MetricCard("Операторів", self.unique_users_label))
        metrics_row.layout().addWidget(MetricCard("Помилок", self.total_errors_label, accent=ERROR_COLOR))
        metrics_row.layout().addWidget(MetricCard("Користувачів з помилками", self.error_users_label))
        metrics_row.layout().addStretch(1)
        layout.addWidget(metrics_row)

        self.top_operator_label = QLabel("—")
        self.top_operator_count = QLabel("0")
        self.top_error_label = QLabel("—")
        self.top_error_count = QLabel("0")
        insights_row = FlowRow()
        insights_row.layout().addWidget(self._build_insight_card("🏆 Найактивніший оператор", True))
        insights_row.layout().addWidget(self._build_insight_card("⚠️ Найбільше помилок", False))
        insights_row.layout().addStretch(1)
        layout.addWidget(insights_row)

        tables_container = QHBoxLayout()
        self.scan_table = QTableWidget(0, 2, self)
        self.scan_table.setHorizontalHeaderLabels(["Користувач", "Сканування"])
        self.scan_table.horizontalHeader().setStretchLastSection(True)
        self.error_table = QTableWidget(0, 2, self)
        self.error_table.setHorizontalHeaderLabels(["Користувач", "Помилки"])
        self.error_table.horizontalHeader().setStretchLastSection(True)
        self.timeline_table = QTableWidget(0, 5, self)
        self.timeline_table.setHorizontalHeaderLabels(["Дата", "Сканування", "Помилки", "Лідер", "Найбільше помилок"])
        self.timeline_table.horizontalHeader().setStretchLastSection(True)
        tables_container.addWidget(self.scan_table)
        tables_container.addWidget(self.error_table)
        tables_container.addWidget(self.timeline_table)
        layout.addLayout(tables_container, 1)

        self.status_label = QLabel("Завантаження даних...")
        layout.addWidget(self.status_label)

        self.start_date_button.clicked.connect(self._pick_start_date)
        self.start_time_button.clicked.connect(self._pick_start_time)
        self.end_date_button.clicked.connect(self._pick_end_date)
        self.end_time_button.clicked.connect(self._pick_end_time)
        self.reset_button.clicked.connect(self._reset_period)
        self.refresh_button.clicked.connect(self.fetch_data)
        self.export_button.clicked.connect(self._export)
        self._update_period_label()

    def on_enter(self) -> None:
        self.fetch_data()

    def fetch_data(self) -> None:
        def work() -> Tuple[List[Dict[str, Any]], List[Dict[str, Any]]]:
            return self.controller.fetch_statistics_payload()

        def on_success(result: Tuple[List[Dict[str, Any]], List[Dict[str, Any]]]) -> None:
            history, errors = result
            self.history_records = history
            self.error_records = errors
            self.last_updated = datetime.now().strftime("%d.%m.%Y %H:%M:%S")
            self._refresh()

        self.status_label.setText("Завантаження даних...")
        self.runner.submit(work, on_success=on_success, on_error=self._show_error)

    def _show_error(self, exc: Exception) -> None:
        self.status_label.setText(f"Помилка завантаження: {exc}")

    def _pick_start_date(self) -> None:
        dialog = DatePickerDialog(self, self.start_date)
        self.start_date = dialog.show_dialog()
        self._ensure_order()
        self._update_period_label()
        self._refresh()

    def _pick_end_date(self) -> None:
        dialog = DatePickerDialog(self, self.end_date)
        self.end_date = dialog.show_dialog()
        self._ensure_order()
        self._update_period_label()
        self._refresh()

    def _pick_start_time(self) -> None:
        dialog = TimePickerDialog(self, title="Час початку", initial=self.start_time)
        self.start_time = dialog.show_dialog()
        self._ensure_order()
        self._update_period_label()
        self._refresh()

    def _pick_end_time(self) -> None:
        dialog = TimePickerDialog(self, title="Час завершення", initial=self.end_time)
        self.end_time = dialog.show_dialog()
        self._ensure_order()
        self._update_period_label()
        self._refresh()

    def _reset_period(self) -> None:
        today = date.today()
        self.start_date = today.replace(day=1)
        self.start_time = dtime.min
        self.end_date = today
        self.end_time = dtime(hour=23, minute=59, second=59)
        self._update_period_label()
        self._refresh()

    def _ensure_order(self) -> None:
        start = self._start_datetime()
        end = self._end_datetime()
        if start and end and start > end:
            self.start_date, self.end_date = self.end_date, self.start_date
            self.start_time, self.end_time = self.end_time, self.start_time

    def _start_datetime(self) -> Optional[datetime]:
        if not self.start_date:
            return None
        time_value = self.start_time or dtime.min
        return datetime.combine(self.start_date, time_value)

    def _end_datetime(self) -> Optional[datetime]:
        if not self.end_date:
            return None
        time_value = self.end_time or dtime(hour=23, minute=59, second=59)
        return datetime.combine(self.end_date, time_value)

    def _update_period_label(self) -> None:
        start = self._start_datetime()
        end = self._end_datetime()
        if start and end:
            text = f"Період: {start.strftime('%d.%m.%Y %H:%M')} – {end.strftime('%d.%m.%Y %H:%M')}"
        elif start:
            text = f"Період від: {start.strftime('%d.%m.%Y %H:%M')}"
        elif end:
            text = f"Період до: {end.strftime('%d.%m.%Y %H:%M')}"
        else:
            text = "Період: Усі дані"
        self.period_label.setText(text)

    def _filter_records(self, records: List[Dict[str, Any]]) -> List[Dict[str, Any]]:
        start = self._start_datetime()
        end = self._end_datetime()
        filtered: List[Dict[str, Any]] = []
        for record in records:
            dt_value = parse_api_datetime(record.get("datetime"))
            if not dt_value:
                continue
            local = dt_value.astimezone().replace(tzinfo=None)
            if start and local < start:
                continue
            if end and local > end:
                continue
            filtered.append(record)
        return filtered

    def _refresh(self) -> None:
        scans = self._filter_records(self.history_records)
        errors = self._filter_records(self.error_records)

        scan_counts: Dict[str, int] = defaultdict(int)
        error_counts: Dict[str, int] = defaultdict(int)
        for record in scans:
            name = (record.get("user_name") or "Невідомий користувач").strip() or "Невідомий користувач"
            scan_counts[name] += 1
        for record in errors:
            name = (record.get("user_name") or "Невідомий користувач").strip() or "Невідомий користувач"
            error_counts[name] += 1

        self.total_scans_label.setText(str(sum(scan_counts.values())))
        self.unique_users_label.setText(str(len(scan_counts)))
        self.total_errors_label.setText(str(sum(error_counts.values())))
        self.error_users_label.setText(str(len(error_counts)))

        top_scan_name, top_scan_count = self._top_entry(scan_counts)
        top_error_name, top_error_count = self._top_entry(error_counts)
        self.status_label.setText(
            f"Відображено {self.total_scans_label.text()} сканувань та {self.total_errors_label.text()} помилок."
            + (f" Лідер: {top_scan_name} ({top_scan_count})" if top_scan_count else "")
        )

        self._populate_table(self.scan_table, scan_counts)
        self._populate_table(self.error_table, error_counts)
        self._populate_timeline(scans, errors)

        self.top_operator_label.setText(top_scan_name)
        self.top_operator_count.setText(str(top_scan_count))
        self.top_error_label.setText(top_error_name)
        self.top_error_count.setText(str(top_error_count))

    @staticmethod
    def _top_entry(counts: Dict[str, int]) -> Tuple[str, int]:
        if not counts:
            return "—", 0
        name, count = max(counts.items(), key=lambda item: item[1])
        return name, count

    def _build_insight_card(self, title: str, is_scan: bool) -> QFrame:
        card = QFrame()
        card.setObjectName("Card")
        layout = QVBoxLayout(card)
        layout.setContentsMargins(24, 24, 24, 24)
        layout.setSpacing(8)

        header = QLabel(title)
        header.setStyleSheet("font-weight: 600; font-size: 18px;")
        layout.addWidget(header)

        if is_scan:
            name_label = self.top_operator_label
            count_label = self.top_operator_count
            suffix = "сканувань"
        else:
            name_label = self.top_error_label
            count_label = self.top_error_count
            suffix = "помилок"

        name_label.setStyleSheet("font-size: 16px; font-weight: 600;")
        count_label.setStyleSheet("font-size: 32px; font-weight: 700;")
        suffix_label = QLabel(suffix)
        suffix_label.setStyleSheet(f"color: {TEXT_SECONDARY};")
        layout.addWidget(name_label)
        layout.addWidget(count_label)
        layout.addWidget(suffix_label)
        layout.addStretch(1)
        return card

    def _populate_table(self, table: QTableWidget, counts: Dict[str, int]) -> None:
        table.setRowCount(0)
        if not counts:
            table.insertRow(0)
            table.setItem(0, 0, QTableWidgetItem("Немає даних"))
            table.setItem(0, 1, QTableWidgetItem("—"))
            return
        for name, count in sorted(counts.items(), key=lambda item: item[1], reverse=True):
            row = table.rowCount()
            table.insertRow(row)
            table.setItem(row, 0, QTableWidgetItem(name))
            table.setItem(row, 1, QTableWidgetItem(str(count)))

    def _populate_timeline(self, scans: List[Dict[str, Any]], errors: List[Dict[str, Any]]) -> None:
        daily: Dict[date, Dict[str, Any]] = {}

        def ensure(day: date) -> Dict[str, Any]:
            if day not in daily:
                daily[day] = {
                    "scans": 0,
                    "errors": 0,
                    "scan_users": defaultdict(int),
                    "error_users": defaultdict(int),
                }
            return daily[day]

        for record in scans:
            dt_value = parse_api_datetime(record.get("datetime"))
            if not dt_value:
                continue
            local = dt_value.astimezone().date()
            info = ensure(local)
            name = (record.get("user_name") or "Невідомий користувач").strip() or "Невідомий користувач"
            info["scans"] += 1
            info["scan_users"][name] += 1

        for record in errors:
            dt_value = parse_api_datetime(record.get("datetime"))
            if not dt_value:
                continue
            local = dt_value.astimezone().date()
            info = ensure(local)
            name = (record.get("user_name") or "Невідомий користувач").strip() or "Невідомий користувач"
            info["errors"] += 1
            info["error_users"][name] += 1

        self.timeline_table.setRowCount(0)
        for day, info in sorted(daily.items(), key=lambda item: item[0], reverse=True):
            row = self.timeline_table.rowCount()
            self.timeline_table.insertRow(row)
            top_scan_name, top_scan_count = self._top_entry(info["scan_users"])
            top_error_name, top_error_count = self._top_entry(info["error_users"])
            self.timeline_table.setItem(row, 0, QTableWidgetItem(day.strftime("%d.%m.%Y")))
            self.timeline_table.setItem(row, 1, QTableWidgetItem(str(info["scans"])))
            self.timeline_table.setItem(row, 2, QTableWidgetItem(str(info["errors"])))
            self.timeline_table.setItem(row, 3, QTableWidgetItem(self._format_top(top_scan_name, top_scan_count)))
            self.timeline_table.setItem(row, 4, QTableWidgetItem(self._format_top(top_error_name, top_error_count)))

    @staticmethod
    def _format_top(name: str, count: int) -> str:
        if not count or name == "—":
            return "—"
        return f"{name} ({count})"

    def _export(self) -> None:
        if not (self.history_records or self.error_records):
            QMessageBox.information(self, "Звіт", "Немає даних для експорту. Оновіть період або синхронізуйте дані.")
            return
        file_path, _ = QFileDialog.getSaveFileName(self, "Зберегти звіт", "tracking_report.csv", "CSV файли (*.csv)")
        if not file_path:
            return
        totals = {
            "scans": self.total_scans_label.text(),
            "unique": self.unique_users_label.text(),
            "errors": self.total_errors_label.text(),
            "error_users": self.error_users_label.text(),
            "top_operator": self.top_operator_label.text(),
            "top_operator_count": self.top_operator_count.text(),
            "top_error": self.top_error_label.text(),
            "top_error_count": self.top_error_count.text(),
        }
        daily_rows: List[Tuple[str, int, int, str, str]] = []
        for row in range(self.timeline_table.rowCount()):
            daily_rows.append(
                (
                    self.timeline_table.item(row, 0).text(),
                    int(self.timeline_table.item(row, 1).text()),
                    int(self.timeline_table.item(row, 2).text()),
                    self.timeline_table.item(row, 3).text(),
                    self.timeline_table.item(row, 4).text(),
                )
            )
        self.controller.export_statistics(
            file_path=file_path,
            period_text=self.period_label.text(),
            updated_text=self.last_updated or "—",
            totals=totals,
            scan_counts={self.scan_table.item(row, 0).text(): int(self.scan_table.item(row, 1).text()) for row in range(self.scan_table.rowCount()) if self.scan_table.item(row, 0) and self.scan_table.item(row, 0).text() != "Немає даних"},
            error_counts={self.error_table.item(row, 0).text(): int(self.error_table.item(row, 1).text()) for row in range(self.error_table.rowCount()) if self.error_table.item(row, 0) and self.error_table.item(row, 0).text() != "Немає даних"},
            daily_rows=daily_rows,
        )
        QMessageBox.information(self, "Звіт", "Звіт успішно збережено.")


class MainWindow(QMainWindow):
    logout_requested = Signal()

    def __init__(self, controller: TrackingAppController) -> None:
        super().__init__()
        self.controller = controller
        self.setWindowTitle("TrackingApp Desktop")
        self.resize(1360, 860)

        central = QWidget(self)
        self.setCentralWidget(central)
        self.root_layout = QVBoxLayout(central)
        self.root_layout.setContentsMargins(24, 24, 24, 24)
        self.root_layout.setSpacing(18)

        self.header_frame = QFrame()
        header_layout = QHBoxLayout(self.header_frame)
        header_layout.setContentsMargins(0, 0, 0, 0)
        title_block = QVBoxLayout()
        title_block.setSpacing(2)
        title_label = SectionTitle("TrackingApp Desktop", large=True)
        subtitle = QLabel("Сканування, історія, помилки та аналітика у сучасному інтерфейсі.")
        subtitle.setStyleSheet(f"color: {TEXT_SECONDARY};")
        title_block.addWidget(title_label)
        title_block.addWidget(subtitle)
        header_layout.addLayout(title_block)
        header_layout.addStretch(1)
        self.profile_label = QLabel("")
        self.profile_label.setStyleSheet("font-weight: 600;")
        header_layout.addWidget(self.profile_label, alignment=Qt.AlignRight)
        self.root_layout.addWidget(self.header_frame)

        self.top_nav = FlowRow()
        self.top_nav.hide()
        self.root_layout.addWidget(self.top_nav)

        self.body_layout = QHBoxLayout()
        self.body_layout.setContentsMargins(0, 0, 0, 0)
        self.body_layout.setSpacing(18)
        self.root_layout.addLayout(self.body_layout, 1)

        self.nav_panel = NavigationPanel()
        self.nav_panel.add_page(key="scanner", text="Сканування", icon="📦")
        self.nav_panel.add_page(key="history", text="Історія", icon="🗂")
        self.nav_panel.add_page(key="errors", text="Помилки", icon="⚠️")
        self.nav_panel.add_page(key="statistics", text="Статистика", icon="📊")
        self.nav_panel.page_selected.connect(self._switch_page)
        self.nav_panel.logout_button.clicked.connect(self._request_logout)
        self.body_layout.addWidget(self.nav_panel)

        self.content_stack = QStackedWidget()
        self.body_layout.addWidget(self.content_stack, 1)

        self.pages: Dict[str, BasePage] = {}
        self._add_page("scanner", ScannerPage(controller))
        self._add_page("history", HistoryPage(controller))
        self._add_page("errors", ErrorsPage(controller))
        self._add_page("statistics", StatisticsPage(controller))

        for key, icon in (
            ("scanner", "📦"),
            ("history", "🗂"),
            ("errors", "⚠️"),
            ("statistics", "📊"),
        ):
            button = QPushButton(f"{icon} {self._page_title(key)}")
            button.setCheckable(True)
            button.setProperty("class", "outline")
            button.clicked.connect(lambda checked, k=key: checked and self._switch_page(k))
            self.top_nav.layout().addWidget(button)
        self.top_nav.layout().addStretch(1)
        self._top_nav_buttons = [self.top_nav.layout().itemAt(i).widget() for i in range(self.top_nav.layout().count() - 1)]

        self.controller.offline_synced.connect(self._handle_offline_sync)
        self.controller.connectivity_changed.connect(self._handle_connectivity_change)
        self._switch_page("scanner")
        self._refresh_profile()

    def _add_page(self, key: str, page: BasePage) -> None:
        self.pages[key] = page
        self.content_stack.addWidget(page)

    def _page_title(self, key: str) -> str:
        return {
            "scanner": "Сканування",
            "history": "Історія",
            "errors": "Помилки",
            "statistics": "Статистика",
        }[key]

    def _switch_page(self, key: str) -> None:
        if key not in self.pages:
            return
        widget = self.pages[key]
        self.content_stack.setCurrentWidget(widget)
        widget.on_enter()
        self.nav_panel.set_current(key)
        for button in self._top_nav_buttons:
            if isinstance(button, QPushButton):
                button.setChecked(button.text().endswith(self._page_title(key)))

    def _handle_offline_sync(self, count: int) -> None:
        if count:
            QMessageBox.information(self, "Синхронізація", f"Синхронізовано {count} офлайн-записів")

    def _handle_connectivity_change(self, online: bool) -> None:
        scanner = self.pages.get("scanner")
        if isinstance(scanner, ScannerPage):
            scanner.set_online_state(online)

    def _refresh_profile(self) -> None:
        name = self.controller.state.user_name or "Оператор"
        role = UserRole.from_value(
            self.controller.state.user_role,
            self.controller.state.access_level,
        )
        self.profile_label.setText(f"{name} • {role.label}")

    def resizeEvent(self, event) -> None:  # noqa: D401 - Qt override
        super().resizeEvent(event)
        width = event.size().width()
        if width < 1100:
            self.nav_panel.hide()
            self.top_nav.show()
        else:
            self.nav_panel.show()
            self.top_nav.hide()

    def _request_logout(self) -> None:
        if QMessageBox.question(self, "Вийти", "Вийти з облікового запису?") != QMessageBox.Yes:
            return
        self.controller.logout()
        self.logout_requested.emit()

    def closeEvent(self, event) -> None:  # noqa: D401 - Qt override
        self.controller.stop_connectivity_checks()
        super().closeEvent(event)


def ensure_user_name(controller: TrackingAppController, parent: QWidget) -> None:
    if controller.state.user_name:
        return
    dialog = NameDialog(controller, parent)
    dialog.exec()


def main() -> None:
    import sys

    app = QApplication(sys.argv)
    apply_modern_palette(app)

    state = AppState.load()
    controller = TrackingAppController(state)
    window = MainWindow(controller)
    window.hide()

    def refresh_context() -> None:
        window._refresh_profile()
        scanner = window.pages.get("scanner")
        if isinstance(scanner, ScannerPage):
            scanner.refresh_user_info()

    def show_main() -> None:
        ensure_user_name(controller, window)
        refresh_context()
        controller.start_connectivity_checks()
        window.show()
        window.raise_()

    def open_login() -> bool:
        dialog = LoginDialog(controller)
        if dialog.exec() == QDialog.Accepted:
            show_main()
            return True
        return False

    if controller.state.token:
        show_main()
    else:
        if not open_login():
            sys.exit(0)

    def handle_logout() -> None:
        controller.stop_connectivity_checks()
        window.hide()
        if not open_login():
            app.quit()

    window.logout_requested.connect(handle_logout)
    app.exec()


if __name__ == "__main__":  # pragma: no cover
    main()