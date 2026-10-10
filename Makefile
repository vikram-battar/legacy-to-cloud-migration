.PHONY: test lint smoke-local

test:
	python3 -m pytest tests/ -v

lint:
	python3 -m py_compile app/app.py legacy-app/app.py tests/test_app.py
	bash -n scripts/db-migrate.sh scripts/smoke-test.sh
	python3 -c "import yaml, glob; fs=[f for f in glob.glob('**/*.y*ml', recursive=True) if '.git/' not in f]+glob.glob('.github/**/*.yml', recursive=True); [list(yaml.safe_load_all(open(f))) for f in set(fs)]; print('yaml OK:', len(set(fs)), 'files')"

# Run the migrated app locally against SQLite (no Postgres needed)
smoke-local:
	cd app && SQLITE_PATH=/tmp/smoke.db PORT=5000 python3 app.py
