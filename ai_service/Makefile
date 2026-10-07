PYTHON ?= python

.PHONY: setup test data eval seed-backend
setup:
	$(PYTHON) -m pip install -r requirements.txt
	$(PYTHON) -m eval.fetch_equipment_model

test:
	$(PYTHON) -m pytest -q tests

data:
	$(PYTHON) -m data_gen.generate

eval:
	$(PYTHON) -m eval.run

seed-backend:
	$(PYTHON) -m data_gen.seed_backend $(ARGS)
