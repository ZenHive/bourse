# test/live/

Every test here reaches a real exchange host — testnet/demo where credentials
exist, the production public host for Coinbase Exchange. A missing credential
pair is a loud RED, never a skip.

Single-venue files live in `test/live/<venue>/`; cross-venue sweeps stay at this
level (`ws/` holds the cross-venue WebSocket lanes).

    mix test.json --quiet test/live/deribit              # everything deribit
    mix bourse.verify_rest_read_contracts --venue deribit  # that venue's contract cases only
    mix bourse.verify_rest_read_contracts                  # all 409 cases, all eleven venues

`:dangerous` (mutating probes) is the only opt-in tag — add `--include dangerous`.
