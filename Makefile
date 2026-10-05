.PHONY: up down logs test build local

up:
	docker compose up --build -d

down:
	docker compose down

logs:
	docker compose logs -f --tail=100

test:
	cd backend && ../.venv/bin/python -m pytest -q
	cd frontend && pnpm run build
	./frontend/node_modules/.bin/tsc -p native-stub/tsconfig.json

build:
	cd frontend && pnpm run build

local:
	./scripts/run-local.sh

