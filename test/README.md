# test/

- `bourse/` — offline: our own code (signing vectors, encoders, decimal math, URL building, rate limiter, WS dialect parsing, response types, spec/schema validation, repo guards).
- `live/` — provider-live: every test here calls a real venue. See `live/README.md`.
- `reference_slice/` — frozen CCXT-derived reference input, never loaded at runtime.
- `support/` — shared helpers and test generators, compiled via `elixirc_paths(:test)`.
