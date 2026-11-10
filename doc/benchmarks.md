# Benchmarks

`bench/` (dub subpackage `:bench`) times the client's own work against an
in-memory fake server (`bench/source/benchmarks/fakeserver.d`): a `Transport`
that answers the listener handshake, the protocol and data-type negotiation
and the O5LOGON exchange (the 12c verifier, computed with dbwire's crypto, so
a real `Connection` logs in), then hands out scripted responses at TTC field
version 13, one per request. Neither the network nor a real server is
measured. The value, OSON, VECTOR and long-value cases call the decoders and
encoders directly. Each case is prepared once, then run at least 5 times and
for at least the minimum time; the runner reports the median and minimum time
and the bytes allocated per row (per call, per value or per document for
the cases that have no rows).

```sh
dub run :bench -b release                       # all cases
dub run :bench -b release -- --filter value/    # the cases whose name contains the text
dub run :bench -b release -- --rows 10000 --min-time 2 --csv results.csv
```

On a busy machine compare the `min ms` column; the median moves with
background load. `GC.allocatedInCurrentThread` doesn't count arrays the GC
extends in place, which is why the 1 MB cases show fewer bytes than they
move.

## Results

Issue #48 (allocation and performance fixes from the code review), LDC 1.36
`-b release`, WSL2 on a shared machine: `main` and the branch run
alternately, twice each, the minimum of the runs kept (approximate: compare
ratios, not absolute numbers). Minimum time in ms, allocated bytes per row.

| case | rows | before ms | after ms | speed-up | before B/row | after B/row |
|---|---:|---:|---:|---:|---:|---:|
| query/rows | 200000 | 98.73 | 36.20 | 2.7× | 456 | 252 |
| query/rows+getters | 200000 | 579.86 | 116.52 | 5.0× | 824 | 332 |
| exec/5 binds | 100000 | 378.03 | 341.08 | 1.1× | 1789 | 1501 |
| insert/structs (1000 per round trip) | 200000 | 304.67 | 129.62 | 2.4× | 1518 | 559 |
| params/Parameter.of int, long, string, double | 1000000 | 360.22 | 398.89 | 0.9× | 129 | 129 |
| params/Parameter.of Variant (int, Date) | 1000000 | 533.50 | 101.70 | 5.2× | 144 | 32 |
| value/NUMBER getLong | 2000000 | 198.19 | 43.75 | 4.5× | 32 | 0 |
| value/NUMBER getString | 2000000 | 434.10 | 154.81 | 2.8× | 64 | 16 |
| value/NUMBER getDouble | 2000000 | 463.03 | 36.29 | 12.8× | 64 | 0 |
| value/NUMBER getDecimal | 2000000 | 318.59 | 52.66 | 6.0× | 48 | 0 |
| value/DATE getString | 2000000 | 1547.19 | 165.95 | 9.3× | 80 | 32 |
| value/TIMESTAMP getString | 2000000 | 2071.30 | 177.20 | 11.7× | 176 | 32 |
| value/BINARY_DOUBLE getString | 2000000 | 700.50 | 709.74 | 1.0× | 16 | 16 |
| value/INTERVAL DS getString | 2000000 | 1667.95 | 151.85 | 11.0× | 144 | 32 |
| long value/1 MB chunked CLR | 100 | 36.09 | 6.69 | 5.4× | 4546813 | 37561 |
| OSON/to text (180 B document) | 200000 | 920.79 | 510.34 | 1.8× | 944 | 800 |
| OSON/from text (180 B document) | 200000 | 2444.78 | 1437.07 | 1.7× | 8576 | 8240 |
| VECTOR/encode FLOAT32[1024] | 20000 | 1286.97 | 286.12 | 4.5× | 27440 | 8192 |
| VECTOR/decode FLOAT32[1024] | 20000 | 291.46 | 94.46 | 3.1× | 8192 | 8192 |
| VECTOR/text FLOAT32[1024] | 2000 | 730.32 | 644.46 | 1.1× | 60144 | 20480 |
| LOB/write request 1 MB | 200 | 7.45 | 6.95 | 1.1× | 64212 | 1053088 |

Not changed by #48: `Parameter.of` of plain values and BINARY_DOUBLE text
(dbwire's `shortestDigits`, #46) are within the noise. VECTOR text is
dominated by `snprintf` (9 or 17 digits per element, as `FROM_VECTOR`
writes them). `queryRow` and `queryValue` now prefetch one row instead of
`fetchSize`; the fake server can't show that (it answers what is scripted).
