PYTHON ?= python

.PHONY: test data eval seed-backend
test:
	$(PYTHON) -m pytest -q tests

data:
	$(PYTHON) -m data_gen.generate

eval:
	$(PYTHON) -m eval.run

seed-backend:
	$(PYTHON) -m data_gen.seed_backend $(ARGS)
