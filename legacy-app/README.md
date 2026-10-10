# The legacy app. Read this first, then look at ../app/ to see what changed.

## What it is

A tiny inventory tracker: Flask + SQLite. Add items, list them, delete them.
The kind of internal tool that starts on someone's laptop, moves to "the
server under Dave's desk", and quietly becomes load-bearing.

## Why it's "legacy"

- Config is hardcoded at the top of `app.py` (port, debug flag, db path)
- SQLite lives in a file next to the code — one process, one box, no sharing
- No health endpoint, so a load balancer can't tell if it's alive
- `debug=True` in production. Yes, really. That's the point.
- Logging is whatever Flask prints to the console

## Run it (don't — this is the before picture)

```bash
cd legacy-app
pip install -r requirements.txt
python app.py
# open http://localhost:5000
```

The migration in `../app/` keeps every route and behavior, but fixes the
five problems above. Same API, cloud-ready habits.
