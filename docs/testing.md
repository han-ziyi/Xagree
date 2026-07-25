# Testing

## Matrix runner

From the app repo root (`性同意/`):

```bash
# Unit tests on the core device matrix (SE / notch / island / iPad × iOS 17–26)
./scripts/run-matrix.sh --profile unit --profile core

# Full UI suite on core matrix (slow)
./scripts/run-matrix.sh --profile ui --profile core

# Export-related UI only (fast regression)
./scripts/run-matrix.sh --profile export

# Single destination
./scripts/run-matrix.sh --destination "XAgree iPhone 16" --profile unit
```

Results land in `build/test-runs/<stamp>/REPORT.md`.

Core destinations: `scripts/matrix-core.txt`.

## Rules

- Destructive UI launch flags (`-UITestingReset`, `-UITestingSkipToHome`) are **simulator-only**.
- Physical devices: prefer non-destructive tests; see `AGENTS.md`.
