# Test quality (quick)

## Strong

- Name describes behavior (`rejects empty email`)
- One risk per test when splitting is cheap
- Failure message would tell a human what broke
- Uses production types/APIs, not a parallel fake world

## Weak

- `test('works')`
- Asserts mock was called, never the result
- Passes immediately on existing code without targeting new risk
- Snapshot of entire page for a one-line logic change

## After a bug

The new test must fail on the old code (or you must state why that is impossible).
