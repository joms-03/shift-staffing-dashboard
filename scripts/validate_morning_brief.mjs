#!/usr/bin/env node

import fs from "node:fs";

const briefPath = "morning-brief/index.html";
const dashboardPath = "index.html";
const brief = fs.readFileSync(briefPath, "utf8");
const dashboard = fs.readFileSync(dashboardPath, "utf8");

function assert(condition, message) {
  if (!condition) throw new Error(message);
}

const expectedAgents = [
  "love-chand",
  "audrey-de-leon",
  "cyrus-jedwin",
  "marc-bryan-caras",
  "marvie-mavis-de-jesus",
  "rhys-cruz",
  "angelo-gelo-bartolome",
  "mark-camillo",
];
const actualAgents = [...brief.matchAll(/data-agent="([^"]+)"/g)].map((match) => match[1]);
assert(actualAgents.length === expectedAgents.length, `Expected eight agent tables; found ${actualAgents.length}`);
assert(expectedAgents.every((agent) => actualAgents.includes(agent)), "One or more required agent tables are missing");

const permanentKeys = [...brief.matchAll(/data-permanent-key="([^"]+)"/g)].map((match) => match[1]);
const duplicateKeys = permanentKeys.filter((key, index) => permanentKeys.indexOf(key) !== index);
assert(duplicateKeys.length === 0, `Duplicate permanent keys: ${[...new Set(duplicateKeys)].join(", ")}`);
assert(
  permanentKeys.every((key) => /^mb-[0-9a-f]{24}$/.test(key)),
  "Public permanent keys must use opaque mb-<24 hex> identifiers",
);
const supportCards = [...brief.matchAll(/<article class="support-open"[^>]*>/g)].map((match) => match[0]);
assert(
  supportCards.every((card) => /data-permanent-key="mb-[0-9a-f]{24}"/.test(card)),
  "Every support card must include an explicit opaque permanent key",
);
assert(
  supportCards.every((card) => /data-support-count="\d+"/.test(card)),
  "Every support card must declare how many live requests it represents",
);
const supportPanelTag = brief.match(/<section class="support-panel"[^>]*>/)?.[0];
assert(supportPanelTag, "Magic Pro Support panel is missing");
const liveOpen = Number(supportPanelTag.match(/data-live-open="(\d+)"/)?.[1]);
const representedOpen = supportCards.reduce(
  (total, card) => total + Number(card.match(/data-support-count="(\d+)"/)?.[1] ?? 0),
  0,
);
assert(
  representedOpen === liveOpen,
  `Support-card counts (${representedOpen}) must equal the live open count (${liveOpen})`,
);

const recordedBlock = brief.match(/const recordedPermanentRemovalKeys=new Set\(\[([\s\S]*?)\]\);/);
assert(recordedBlock, "The embedded permanent-removal registry is missing");
const recordedKeys = [...recordedBlock[1].matchAll(/'([^']+)'/g)].map((match) => match[1]);
assert(recordedKeys.length === new Set(recordedKeys).size, "The embedded permanent-removal registry contains duplicate keys");
assert(
  recordedKeys.every((key) => /^mb-[0-9a-f]{24}$/.test(key)),
  "Recorded removal keys must use opaque mb-<24 hex> identifiers",
);

const phonePattern = /\+1\d{10}/g;
const emailPattern = /[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}/gi;
assert(!(brief.match(phonePattern) || []).length, "Phone-like data found in Morning Brief HTML");
assert(!(brief.match(emailPattern) || []).length, "Email-like data found in Morning Brief HTML");
assert(!(dashboard.match(phonePattern) || []).length, "Phone-like data found in public dashboard HTML");
assert(!(dashboard.match(emailPattern) || []).length, "Email-like data found in public dashboard HTML");
assert(/const REVIEW_ROWS = \[\];/.test(dashboard), "REVIEW_ROWS must remain empty in the public build");
assert(/const OUTREACH_ROWS = \[\];/.test(dashboard), "OUTREACH_ROWS must remain empty in the public build");

assert(!brief.includes("localhost:3000"), "Published Morning Brief points to localhost");
assert(!brief.includes("/api/removals"), "Published Morning Brief uses the retired local removal API");
assert(!/catch-up mode/i.test(brief), "Retired Catch-up mode returned");
assert(!/meeting memory/i.test(brief), "Raw historical meeting-card section returned");

const inlineScripts = [...brief.matchAll(/<script(?![^>]*\bsrc=)[^>]*>([\s\S]*?)<\/script>/gi)]
  .map((match) => match[1])
  .filter((script) => !script.trim().startsWith("{"));
for (const [index, script] of inlineScripts.entries()) {
  try {
    new Function(script);
  } catch (error) {
    throw new Error(`Morning Brief inline script ${index + 1} does not parse: ${error.message}`);
  }
}

console.log(
  `Morning Brief valid: ${actualAgents.length} agent tables, ${permanentKeys.length} stable items, ` +
    `${recordedKeys.length} recorded removals, ${inlineScripts.length} inline scripts`,
);
