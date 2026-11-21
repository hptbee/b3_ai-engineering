# Node threat index (pointers)

| Threat | First mitigation |
| --- | --- |
| HTTP DoS / Slowloris | Timeouts, proxy, connection limits |
| Prototype pollution | Schema parse; never recursive merge of untrusted JSON onto `Object.prototype` paths |
| Malicious deps | lockfile, audit, pin |
| Inspector DNS rebinding | Do not expose `--inspect` |

Official: https://nodejs.org/en/learn/getting-started/security-best-practices
