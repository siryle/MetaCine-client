import assert from "node:assert/strict";
import test from "node:test";
import { historyPlan, pruneHistory } from "./prune-github-history.mjs";

const repository = "example/MetaCine-client";
const run = (number, status = "completed") => ({ id: number, run_number: number, status });
const release = (id, extra = {}) => ({
  id, tag_name: `v1.0.0-build.${id}`, draft: false, prerelease: true,
  published_at: `2026-10-${String(id).padStart(2, "0")}T00:00:00Z`,
  assets: [{ name: "MetaCine-1.0.0-unsigned.ipa" }, { name: "MetaCine-1.0.0-unsigned.ipa.sha256" }],
  ...extra,
});
const silence = () => {};

function inventoryAPI(runs, releases, calls = []) {
  return (endpoint, method = "GET") => {
    calls.push({ endpoint, method });
    if (method === "DELETE") return null;
    const url = new URL(endpoint, "https://api.github.com/");
    const start = (Number(url.searchParams.get("page")) - 1) * 100;
    if (url.pathname.endsWith("/runs")) return { workflow_runs: runs.slice(start, start + 100) };
    return releases.slice(start, start + 100);
  };
}

test("retains the three latest completed runs without cancelling queued or active builds", () => {
  const plan = historyPlan([run(2), run(7, "queued"), run(5), run(1), run(6, "in_progress"), run(4), run(3)], []);
  assert.deepEqual(plan.keptRuns.map(item => item.id), [5, 4, 3]);
  assert.deepEqual(plan.deletedRuns.map(item => item.id), [2, 1]);
});

test("completed failures count as recent history so their diagnostics remain available", () => {
  const plan = historyPlan([run(4), { ...run(3), conclusion: "failure" }, run(2), run(1)], []);
  assert.deepEqual(plan.keptRuns.map(item => item.id), [4, 3, 2]);
  assert.deepEqual(plan.deletedRuns.map(item => item.id), [1]);
});

test("retains three IPA releases by publication date across stable and prerelease versions", () => {
  const plan = historyPlan([], [
    release(1, { published_at: "2026-10-10T00:00:00Z", prerelease: false }),
    release(4), release(2), release(3),
    release(5, { draft: true }), release(6, { assets: [{ name: "notes.txt" }] }),
  ]);
  assert.deepEqual(plan.keptReleases.map(item => item.id), [1, 4, 3]);
  assert.deepEqual(plan.deletedReleases.map(item => item.id), [2]);
});

test("does not delete history when fewer than three versions exist", () => {
  const calls = [];
  const plan = pruneHistory({
    repository, api: inventoryAPI([run(1), run(2)], [release(1)], calls), log: silence,
  });
  assert.equal(plan.deletedRuns.length, 0);
  assert.equal(plan.deletedReleases.length, 0);
  assert(calls.every(call => call.method === "GET"));
});

test("reads every inventory page before deleting only the selected workflow runs and releases", () => {
  const runs = Array.from({ length: 102 }, (_, index) => run(index + 1));
  const releases = Array.from({ length: 5 }, (_, index) => release(index + 1));
  const calls = [];
  pruneHistory({ repository, api: inventoryAPI(runs, releases, calls), log: silence });
  assert.deepEqual(calls.slice(0, 3).map(call => call.endpoint), [
    `repos/${repository}/actions/workflows/ios.yml/runs?per_page=100&page=1`,
    `repos/${repository}/actions/workflows/ios.yml/runs?per_page=100&page=2`,
    `repos/${repository}/releases?per_page=100&page=1`,
  ]);
  const deleted = calls.filter(call => call.method === "DELETE");
  assert.equal(deleted.length, 101);
  assert(deleted.every(call => /\/actions\/runs\/[1-9][0-9]?$|\/releases\/[12]$/.test(call.endpoint)));
});

test("dry runs report history without sending deletion requests", () => {
  const calls = [];
  const messages = [];
  pruneHistory({
    repository, dryRun: true, log: message => messages.push(message),
    api: inventoryAPI([run(1), run(2), run(3), run(4)], [release(1), release(2), release(3), release(4)], calls),
  });
  assert(calls.every(call => call.method === "GET"));
  assert(messages.some(message => message.includes("Would delete iOS workflow run #1")));
  assert(messages.some(message => message.includes("Would delete release v1.0.0-build.1")));
});

test("inventory failures stop cleanup before any deletion", () => {
  const calls = [];
  const api = (endpoint, method = "GET") => {
    calls.push({ endpoint, method });
    if (endpoint.includes("/releases")) throw new Error("Cannot list releases");
    return { workflow_runs: [run(1), run(2), run(3), run(4)] };
  };
  assert.throws(() => pruneHistory({ repository, api, log: silence }), /Cannot list releases/);
  assert(calls.every(call => call.method === "GET"));
});

test("invalid remote data and repository names cannot trigger deletion", () => {
  assert.throws(() => historyPlan([run(0)], []), /invalid ID/);
  assert.throws(() => historyPlan([{ ...run(1), run_number: null }], []), /invalid run number/);
  assert.throws(() => historyPlan([], [release(1, { published_at: null })]), /publication date/);
  assert.throws(() => pruneHistory({ repository: "example/../other", api: () => assert.fail("Unexpected API call") }));
});
