# Housefull load test

**Tested:** 2 November 2026, on the live site at https://housefull.jeneeldumasia.dev

## Result

Housefull handled **100 requests a second with no failures** and a 95th percentile response time of 181 ms, on 1 to 3 small Cloud Run instances and the smallest Cloud SQL database.

Past that, it failed the way it was designed to. Cloud Run turned extra traffic away with `429` responses once it hit the instance limit. The database stayed healthy, and **no seat was double-booked**.

| Target load (requests a second) | Requests sent | Failed | Median | 95th percentile | 99th percentile |
|---:|---:|---:|---:|---:|---:|
| 10 | 600 | 0 | 35 ms | 81 ms | 116 ms |
| 25 | 1,500 | 0 | 34 ms | 74 ms | 108 ms |
| 50 | 3,001 | 0 | 37 ms | 85 ms | 116 ms |
| **100** | **6,001** | **0** | **62 ms** | **181 ms** | **562 ms** |
| 200 | 11,266 | 362 (3.2%) | 63 ms | 10.2 s | 11.5 s |
| 400 | 12,283 | 9,031 (73.5%) | 33 ms | 11.6 s | 12.7 s |

The median falls at 400 because a refused request returns quickly, so response times at that level aren't a sign of good performance.

## What held up

| Check | Result |
|---|---|
| Double-bookings | **0.** 1,732 bookings were accepted, and exactly 1,732 seats ended up `booked`, with none stuck as `held`. |
| Seat clashes | 824 requests for a taken seat were correctly refused. |
| Failure type | `429` from Cloud Run's instance limit. Google's metrics showed no 500 responses. |
| Database CPU | Peaked at about 50%. |
| Database connections | Peaked at 18, under the calculated limit of 20 and the database's limit of about 25. |
| Recovery | Health checks were back to 0.14 seconds right after the test. |

## What the bottleneck was

The limit was the Cloud Run instance cap, not the database. It's set at 3 instances with 20 requests each, so that the app can't open more connections than the database allows. Cloud Run logged requests being "aborted after waiting too long for an available instance".

That's a deliberate trade-off: during a rush, some users are told to try again, but the database that protects seat data stays up. To go higher, the next step is a larger database, then a higher instance limit.

## Limits of this test

- It ran from one laptop, which hit its limit of 800 virtual users. The 200 and 400 steps were partly limited by the laptop, so they never fully reached their targets, and 12,452 planned requests were never sent.
- Each step lasted 60 seconds, so this doesn't show how it behaves over hours.
- Load was 70% event list, 20% seat maps, and 10% bookings. Login wasn't included, because login limits would block it.
- The seat map had 3,000 seats.

## Run it yourself

The script is [`load-test/housefull.js`](../load-test/housefull.js), and the raw results are in [`load-test/results-2026-11-02.json`](../load-test/results-2026-11-02.json).

1. Create an event, and some test accounts.
2. Put their `housefull_session` cookie values in `cookies.json`, as a JSON list.
3. Run it:

```bash
docker run --rm --network host -v "$PWD":/load -e BASE_URL=http://localhost:8080 -e EVENT_ID=1 grafana/k6:0.54.0 run /load/housefull.js
```

Only run this against your own site.
