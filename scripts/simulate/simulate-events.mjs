#!/usr/bin/env node
// Delivers the spec's sample events over real HTTP, signed the way Orders signs them.
// Needs Node 18+ and nothing else.
//
//   node scripts/simulate/simulate-events.mjs <site-url>             in order, as in the spec
//   node scripts/simulate/simulate-events.mjs <site-url> --tamper    body changed after signing: expects 401
//   node scripts/simulate/simulate-events.mjs <site-url> --parallel  all at once, twice over: a concurrency test
//
// <site-url> is the Site's base URL, e.g. https://mydomain-dev-ed.develop.my.salesforce-sites.com
import { createHmac } from "node:crypto";
import { readFileSync } from "node:fs";

// The exercise's published fixture, not a real credential.
const SECRET = "orders-takehome-2026";
const ENDPOINT_PATH = "/services/apexrest/orders/events";

const [siteUrl, mode] = process.argv.slice(2);
if (!siteUrl) {
  console.error(
    "Usage: simulate-events.mjs <site-url> [--tamper | --parallel]"
  );
  process.exit(2);
}
const endpoint = siteUrl.replace(/\/+$/, "") + ENDPOINT_PATH;

const events = JSON.parse(
  readFileSync(new URL("./sample-events.json", import.meta.url), "utf8")
);

const sign = (body) =>
  createHmac("sha256", SECRET).update(body, "utf8").digest("hex");

async function deliver(body, signature, label) {
  const started = Date.now();
  const response = await fetch(endpoint, {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
      "Orders-Signature": signature
    },
    body
  });
  const text = await response.text();
  console.log(
    `${label.padEnd(36)} HTTP ${response.status}  ${Date.now() - started}ms  ${text}`
  );
  return response.status;
}

const labelOf = (event) => `${event.event.id} ${event.event.type}`;

if (mode === "--tamper") {
  const body = JSON.stringify(events[0]);
  const tampered = body.replace("order.inProgress", "order.returned");
  const status = await deliver(tampered, sign(body), "tampered body");
  process.exitCode = status === 401 ? 0 : 1;
} else if (mode === "--parallel") {
  // Every event twice, all in flight together: the races are concurrent first
  // inserts of one account, one order and one event ID. A 500 here is expected
  // contention, so retry as the real sender does: three times, with backoff.
  const deliverLikeSender = async (event) => {
    const body = JSON.stringify(event);
    let status;
    for (let attempt = 0; attempt <= 3; attempt++) {
      if (attempt > 0) {
        await new Promise((done) => setTimeout(done, 2000 * attempt));
      }
      status = await deliver(body, sign(body), labelOf(event));
      if (status === 200) {
        break;
      }
    }
    return status;
  };
  const statuses = await Promise.all(
    [...events, ...events].map(deliverLikeSender)
  );
  process.exitCode = statuses.every((status) => status === 200) ? 0 : 1;
} else {
  for (const event of events) {
    const body = JSON.stringify(event);
    await deliver(body, sign(body), labelOf(event));
  }
}
