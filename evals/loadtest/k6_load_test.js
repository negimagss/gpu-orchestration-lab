import http from 'k6/http';
import { check, sleep } from 'k6';
import { Trend, Counter, Rate } from 'k6/metrics';

// ── Custom Metrics ──────────────────────────────
const ttft = new Trend('time_to_first_token', true);
const totalLatency = new Trend('total_latency', true);
const tokensPerSecond = new Trend('tokens_per_second', true);
const successRate = new Rate('success_rate');
const errorCount = new Counter('errors');

// ── Test Configuration ──────────────────────────
const BASE_URL = __ENV.BASE_URL || 'http://localhost:8080';

// Test scenarios: ramp up load to observe HPA and Karpenter scaling
export const options = {
  scenarios: {
    // Scenario 1: Baseline — steady low load
    baseline: {
      executor: 'constant-arrival-rate',
      rate: 1,          // 1 request per second
      timeUnit: '1s',
      duration: '2m',
      preAllocatedVUs: 5,
      maxVUs: 10,
      startTime: '0s',
      tags: { scenario: 'baseline' },
    },

    // Scenario 2: Ramp up — increase load
    ramp_up: {
      executor: 'ramping-arrival-rate',
      startRate: 2,
      timeUnit: '1s',
      stages: [
        { target: 5, duration: '1m' },   // Ramp to 5 rps
        { target: 10, duration: '1m' },  // Ramp to 10 rps
        { target: 5, duration: '30s' },  // Cool down
      ],
      preAllocatedVUs: 20,
      maxVUs: 50,
      startTime: '2m',
      tags: { scenario: 'ramp_up' },
    },

    // Scenario 3: Spike — sudden burst
    spike: {
      executor: 'constant-arrival-rate',
      rate: 20,         // 20 requests per second
      timeUnit: '1s',
      duration: '30s',
      preAllocatedVUs: 30,
      maxVUs: 60,
      startTime: '5m',
      tags: { scenario: 'spike' },
    },
  },

  thresholds: {
    'total_latency': ['p(95)<5000'],       // P95 under 5 seconds
    'time_to_first_token': ['p(95)<2000'], // TTFT P95 under 2 seconds
    'success_rate': ['rate>0.90'],          // 90%+ success rate
  },
};

// ── Test Queries ────────────────────────────────
const queries = [
  "What was Apple's total revenue in 2023?",
  "What are Tesla's main risk factors?",
  "How much did Microsoft spend on R&D?",
  "What is Amazon's largest revenue segment?",
  "What were Alphabet's advertising revenues?",
  "What is Apple's gross profit margin?",
  "How many employees does Tesla have?",
  "What is Microsoft's cloud revenue growth?",
  "What are Amazon's operating expenses?",
  "What is Google's revenue from YouTube?",
];

// ── Main Test Function ──────────────────────────
export default function () {
  const query = queries[Math.floor(Math.random() * queries.length)];
  const clientId = `k6-${__VU}-${__ITER}`;

  const startTime = Date.now();
  let firstTokenTime = null;
  let tokenCount = 0;

  // Send chat request
  const chatPayload = JSON.stringify({
    message: query,
    client_id: clientId,
  });

  const chatRes = http.post(`${BASE_URL}/api/chat`, chatPayload, {
    headers: { 'Content-Type': 'application/json' },
    timeout: '30s',
  });

  const chatSuccess = check(chatRes, {
    'chat request accepted': (r) => r.status === 200,
  });

  if (!chatSuccess) {
    errorCount.add(1);
    successRate.add(0);
    return;
  }

  // Poll SSE stream for response (simplified — in real test, use WebSocket/SSE client)
  // For K6, we measure the direct vLLM endpoint latency
  const directPayload = JSON.stringify({
    model: 'Qwen/Qwen2.5-1.5B-Instruct',
    messages: [
      { role: 'system', content: 'You are a financial analyst.' },
      { role: 'user', content: query },
    ],
    max_tokens: 256,
    temperature: 0.1,
    stream: false, // Non-streaming for K6 latency measurement
  });

  const vllmUrl = __ENV.VLLM_URL || `${BASE_URL}/api/query`;

  const inferRes = http.post(vllmUrl, directPayload, {
    headers: { 'Content-Type': 'application/json' },
    timeout: '60s',
  });

  const endTime = Date.now();
  const totalTime = endTime - startTime;

  const inferSuccess = check(inferRes, {
    'inference completed': (r) => r.status === 200,
  });

  if (inferSuccess) {
    successRate.add(1);
    totalLatency.add(totalTime);

    try {
      const body = JSON.parse(inferRes.body);
      const tokens = body.usage ? body.usage.completion_tokens : 0;
      if (tokens > 0 && totalTime > 0) {
        tokensPerSecond.add((tokens / totalTime) * 1000);
      }
    } catch (e) {
      // Ignore parse errors
    }
  } else {
    errorCount.add(1);
    successRate.add(0);
  }

  sleep(0.1); // Small pause between iterations
}

// ── Summary Report ──────────────────────────────
export function handleSummary(data) {
  const summary = {
    timestamp: new Date().toISOString(),
    test_name: 'InferOps Load Test',
    metrics: {
      total_requests: data.metrics.http_reqs ? data.metrics.http_reqs.values.count : 0,
      success_rate: data.metrics.success_rate ? data.metrics.success_rate.values.rate : 0,
      latency: {
        p50: data.metrics.total_latency ? data.metrics.total_latency.values['p(50)'] : 0,
        p95: data.metrics.total_latency ? data.metrics.total_latency.values['p(95)'] : 0,
        p99: data.metrics.total_latency ? data.metrics.total_latency.values['p(99)'] : 0,
        avg: data.metrics.total_latency ? data.metrics.total_latency.values.avg : 0,
      },
      tokens_per_second: {
        avg: data.metrics.tokens_per_second ? data.metrics.tokens_per_second.values.avg : 0,
        p95: data.metrics.tokens_per_second ? data.metrics.tokens_per_second.values['p(95)'] : 0,
      },
      errors: data.metrics.errors ? data.metrics.errors.values.count : 0,
    },
  };

  return {
    'evals/loadtest/results.json': JSON.stringify(summary, null, 2),
    stdout: JSON.stringify(summary, null, 2),
  };
}
