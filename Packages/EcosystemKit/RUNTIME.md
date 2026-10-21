# Runtime safety

A runtime owns one domain queue and authenticated local IPC endpoints.
Leases, fencing, cancellation and action receipts prevent blind replay.
Ambiguous effects require recovery review. Admission starts denied.
Power policy limits new heavy callbacks without interrupting accepted work.
See the parent repository SECURITY.md and docs/OPERATIONS.md.
