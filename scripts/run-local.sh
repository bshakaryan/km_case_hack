#!/usr/bin/env bash
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PYTHON_BIN="${PYTHON_BIN:-$PROJECT_DIR/.venv/bin/python}"
if [[ ! -x "$PYTHON_BIN" ]]; then
  echo 'Не найден .venv/bin/python. Установите зависимости по инструкции README.md.' >&2
  exit 1
fi
if [[ ! -f "$PROJECT_DIR/frontend/node_modules/vite/bin/vite.js" ]]; then
  echo 'Не установлены зависимости веб-панели. Выполните: cd frontend && pnpm install --frozen-lockfile' >&2
  exit 1
fi
command -v node >/dev/null || { echo 'Требуется Node.js.' >&2; exit 1; }

mkdir -p "$PROJECT_DIR/data"
export DATABASE_URL="${DATABASE_URL:-sqlite:///$PROJECT_DIR/data/naryad.db}"
export SEED_DEMO="${SEED_DEMO:-true}"
export CORS_ORIGINS="${CORS_ORIGINS:-http://localhost:5173,http://127.0.0.1:5173}"
export TZ=Asia/Almaty

# FCM push: если учётные данные заданы неявно, берём первый ключ из backend/secrets/*.json.
if [[ -z "${FIREBASE_CREDENTIALS:-}" && -z "${FIREBASE_CREDENTIALS_JSON:-}" ]]; then
  CRED_FILE=""
  for f in "$PROJECT_DIR"/backend/secrets/*.json; do
    [[ -f "$f" ]] || continue
    CRED_FILE="$f"
    break
  done
  if [[ -n "$CRED_FILE" ]]; then
    export FIREBASE_CREDENTIALS="$CRED_FILE"
    echo "FCM: использован ключ сервисного аккаунта ${CRED_FILE#"$PROJECT_DIR"/}."
  fi
fi
export FIREBASE_PROJECT_ID="${FIREBASE_PROJECT_ID:-km-case-hack}"
export PUSH_ENABLED="${PUSH_ENABLED:-true}"

cd "$PROJECT_DIR/backend"
"$PYTHON_BIN" -m uvicorn app.main:app --host 0.0.0.0 --port 8000 &
BACKEND_PID=$!
cd "$PROJECT_DIR/frontend"
node node_modules/vite/bin/vite.js --host 127.0.0.1 --port 5173 --strictPort &
FRONTEND_PID=$!

cleanup() {
  trap - EXIT INT TERM
  kill "$BACKEND_PID" "$FRONTEND_PID" 2>/dev/null || true
  wait "$BACKEND_PID" "$FRONTEND_PID" 2>/dev/null || true
}
trap cleanup EXIT INT TERM

echo 'НарядAI: http://localhost:5173 | API: http://localhost:8000/docs'
echo 'Демонстрационный вход: master / PIN 1234. Ctrl+C останавливает оба процесса.'
while kill -0 "$BACKEND_PID" 2>/dev/null && kill -0 "$FRONTEND_PID" 2>/dev/null; do
  sleep 1
done
echo 'Один из процессов завершился; второй будет остановлен.' >&2
exit 1

