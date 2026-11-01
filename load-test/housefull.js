import http from 'k6/http';
import { Counter } from 'k6/metrics';
import exec from 'k6/execution';

const BASE = __ENV.BASE_URL || 'http://localhost:8080';
// A JSON list of housefull_session cookie values for test accounts.
const cookies = JSON.parse(open('/load/cookies.json'));
const EVENT = __ENV.EVENT_ID;
const booked = new Counter('booked');
const conflicts = new Counter('seat_conflicts');
const rates = [10, 25, 50, 100, 200, 400];
const STEP = 60, GAP = 15;

http.setResponseCallback(http.expectedStatuses(200, 202, 409));

const scenarios = {}, thresholds = { http_req_failed: [{ threshold: 'rate<0.5', abortOnFail: true, delayAbortEval: '30s' }] };
rates.forEach((rate, i) => {
  const name = `r${rate}`;
  scenarios[name] = {
    executor: 'constant-arrival-rate', rate, timeUnit: '1s', duration: `${STEP}s`,
    startTime: `${i * (STEP + GAP)}s`, preAllocatedVUs: Math.max(20, rate), maxVUs: 800,
    tags: { step: name }, gracefulStop: '15s',
  };
  thresholds[`http_req_duration{step:${name}}`] = ['max>=0'];
  thresholds[`http_req_failed{step:${name}}`] = ['rate>=0'];
  thresholds[`dropped_iterations{step:${name}}`] = ['count>=0'];
});
export const options = { scenarios, thresholds, summaryTrendStats: ['avg', 'med', 'p(95)', 'p(99)', 'max'], discardResponseBodies: true };

export default function () {
  const roll = Math.random();
  if (roll < 0.7) { http.get(`${BASE}/events`, { tags: { name: 'events' } }); return; }
  if (roll < 0.9) { http.get(`${BASE}/events/${EVENT}/seats`, { tags: { name: 'seats' } }); return; }
  const seat = `S${1 + Math.floor(Math.random() * 3000)}`;
  const res = http.post(`${BASE}/events/${EVENT}/bookings`, JSON.stringify({ seat_labels: [seat] }), {
    tags: { name: 'book' },
    headers: { 'Content-Type': 'application/json', Cookie: `housefull_session=${cookies[exec.vu.idInTest % cookies.length]}` },
  });
  if (res.status === 202) booked.add(1);
  if (res.status === 409) conflicts.add(1);
}

export function handleSummary(data) {
  return { '/load/summary.json': JSON.stringify(data, null, 2) };
}
