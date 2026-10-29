# Remote directory responsiveness

The remote folder chooser and explorer share an in-memory directory cache, keyed by SSH alias and directory. It stores names, paths and directory flags only, with a 30-second freshness window, at most 128 directory keys and 50,000 entries. Canonical paths and requested aliases share results. Concurrent requests for the same directory are serialized and reuse fresh results.

Previously visited directories appear immediately. Once stale, the existing listing remains usable while a worker refreshes it. Identical results do not reload native table/outline rows. Changed results retain matching tree nodes, expanded descendants and the chooser selection. Manual Refresh bypasses freshness; creating a file invalidates cached listings for that host and refreshes the directory where it was created. Errors preserve the last listing. Closing the process clears the cache.

File contents and save-conflict digests are never served from this directory cache. The first visit to an uncached directory still needs an SSH round trip. Scrolling an already loaded directory performs no SSH request.

## Acceptance

Local native/core suite: 113 tests, 1 physical-display probe skipped, 0 failures. Includes live disposable SSH directory navigation, tree expansion, remote Git operations, and conflict-protected file writes. In the directory acceptance run, the first request took approximately 565 ms; 100 warm reads averaged approximately 0.003 ms each. Timing is specific to that run and excludes network on cache hits.

These measurements establish cached-navigation latency, not presented display frames. Existing display-link measurements alone do not prove that every UI presents at 120 FPS. Actual scrolling presentation remains a separate validation target.
