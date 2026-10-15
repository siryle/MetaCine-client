#!/usr/bin/env node
import { execFileSync } from "node:child_process";
import path from "node:path";
import { pathToFileURL } from "node:url";

const keepCount = 3;

function githubAPI(endpoint, method = "GET") {
  const result = execFileSync("gh", ["api", "--method", method, endpoint], {
    encoding: "utf8",
    maxBuffer: 16 * 1024 * 1024,
  });
  return result.trim() ? JSON.parse(result) : null;
}

function listAll(api, endpoint, key) {
  const items = [];
  for (let page = 1; ; page++) {
    const response = api(`${endpoint}?per_page=100&page=${page}`);
    const batch = key ? response?.[key] : response;
    if (!Array.isArray(batch)) throw new Error(`Invalid response from ${endpoint}`);
    items.push(...batch);
    if (batch.length < 100) return items;
  }
}

function validateID(item) {
  if (!Number.isSafeInteger(item.id) || item.id <= 0) {
    throw new Error("History entry has an invalid ID");
  }
}

export function historyPlan(runs, releases) {
  const completed = runs.filter(run => run.status === "completed");
  for (const run of completed) {
    validateID(run);
    if (!Number.isSafeInteger(run.run_number) || run.run_number <= 0) {
      throw new Error("Workflow run has an invalid run number");
    }
  }
  completed.sort((a, b) => b.run_number - a.run_number || b.id - a.id);

  const published = releases.filter(release =>
    !release.draft && release.assets?.some(asset => /\.ipa$/i.test(asset.name))
  );
  for (const release of published) {
    validateID(release);
    if (!Number.isFinite(Date.parse(release.published_at))) {
      throw new Error("Release has an invalid publication date");
    }
  }
  published.sort((a, b) => Date.parse(b.published_at) - Date.parse(a.published_at) || b.id - a.id);

  return {
    keptRuns: completed.slice(0, keepCount),
    deletedRuns: completed.slice(keepCount),
    keptReleases: published.slice(0, keepCount),
    deletedReleases: published.slice(keepCount),
  };
}

export function pruneHistory({ repository, dryRun = false, api = githubAPI, log = console.log }) {
  if (!/^[A-Za-z0-9][A-Za-z0-9-]*\/[A-Za-z0-9_.-]+$/.test(repository ?? "")
      || repository.split("/").some(part => part === "." || part === "..")) {
    throw new Error("GITHUB_REPOSITORY must identify the target owner/repository");
  }
  const base = `repos/${repository}`;
  // Finish both inventories before deleting anything; an incomplete list must not drive retention.
  const runs = listAll(api, `${base}/actions/workflows/ios.yml/runs`, "workflow_runs");
  const releases = listAll(api, `${base}/releases`);
  const plan = historyPlan(runs, releases);
  log(`Retaining ${plan.keptRuns.length} completed iOS runs and ${plan.keptReleases.length} IPA releases.`);
  const action = dryRun ? "Would delete" : "Deleting";
  for (const run of plan.deletedRuns) {
    log(`${action} iOS workflow run #${run.run_number} (${run.id}).`);
    if (!dryRun) api(`${base}/actions/runs/${run.id}`, "DELETE");
  }
  for (const release of plan.deletedReleases) {
    log(`${action} release ${release.tag_name} (${release.id}) and its assets.`);
    if (!dryRun) api(`${base}/releases/${release.id}`, "DELETE");
  }
  return plan;
}

if (process.argv[1] && import.meta.url === pathToFileURL(path.resolve(process.argv[1])).href) {
  try {
    const args = process.argv.slice(2);
    if (args.some(arg => arg !== "--dry-run")) throw new Error("Only --dry-run is supported");
    pruneHistory({ repository: process.env.GITHUB_REPOSITORY, dryRun: args.includes("--dry-run") });
  } catch (error) {
    console.error(error.message);
    process.exitCode = 1;
  }
}
