# Venues

One directory per supported venue. `<venue>/authored/spec.json` is our hand-owned
runtime document; `<venue>/authority/` is the provider-owned evidence that grades it —
the pinned source manifest, the normalized error enumeration, and the venue's
REST-read contract (`rest_read_contract.json`, whose shared top-level policy keys live
in `rest-read-contracts-policy.json`).

Adding a venue needs both halves plus live proof: author the spec, list the venue in
`runtime_support.json`, add its provider-owned contract entry, and get every one of its
cases green against the venue's own host. `AUTHORITY.md` documents the authority corpus
rules.
