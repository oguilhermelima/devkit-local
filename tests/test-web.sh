#!/usr/bin/env bash

set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

node --input-type=module - "$root/scripts/playwright-web.mjs" <<'NODE'
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';

const script = process.argv[2];
const {
  buildBrowserConfig,
  validateBrowserConfig,
  compareManifest,
  upsertUserScriptRecord,
  userScriptSource,
} = await import(script);

const work = fs.mkdtempSync(path.join(os.tmpdir(), 'megabrain-web-test-'));
const paths = {
  root: work,
  profile: path.join(work, 'profiles', 'chromium'),
  extensions: {
    ublock: path.join(work, 'extensions', 'chromium', 'ublock'),
    violentmonkey: path.join(work, 'extensions', 'chromium', 'violentmonkey'),
  },
};

const chromium = buildBrowserConfig('chromium', paths);
assert.equal(chromium.browser.browserName, 'chromium');
assert.equal(chromium.browser.launchOptions.channel, 'chromium');
assert.deepEqual(chromium.browser.contextOptions.viewport, { width: 1280, height: 720 });
assert.equal(validateBrowserConfig(chromium, 'chromium').valid, true);
assert.throws(
  () => validateBrowserConfig({ browser: { browserName: 'chromium', launchOptions: {}, contextOptions: chromium.browser.contextOptions } }, 'chromium'),
  /channel/,
  'a Chromium config without channel must be rejected',
);

const firefox = buildBrowserConfig('firefox', {
  root: work,
  profile: path.join(work, 'profiles', 'firefox'),
  extensions: {
    ublockXpi: path.join(work, 'profiles', 'firefox', 'extensions', 'uBlock0@raymondhill.net.xpi'),
    violentmonkeyXpi: path.join(work, 'profiles', 'firefox', 'extensions', '{aecec67f-0d10-4fa7-b7c7-609a2db280cf}.xpi'),
  },
});
assert.equal(firefox.browser.browserName, 'firefox');
assert.equal(firefox.browser.launchOptions.firefoxUserPrefs['extensions.autoDisableScopes'], 0);
assert.equal(firefox.browser.launchOptions.firefoxUserPrefs['extensions.enabledScopes'], 15);
assert.match(firefox.browser.userDataDir, /profiles[\\/]firefox$/);
NODE

node --input-type=module - "$root/scripts/playwright-web.mjs" <<'NODE'
import assert from 'node:assert/strict';
import path from 'node:path';
const { compareManifest, upsertUserScriptRecord, userScriptSource } = await import(process.argv[2]);
const work = '/tmp/megabrain-web-test-scenarios';
const userscripts = path.join(work, 'userscripts');

const expected = {
  playwrightVersion: '1.63.0',
  extensions: {
    chromium: { ublock: '2026.907.2003', violentmonkey: '2.49.0' },
    firefox: { ublock: '1.74.0', violentmonkey: '2.49.0' },
  },
};
const current = structuredClone(expected);
assert.deepEqual(compareManifest(current, expected), []);
current.extensions.chromium.violentmonkey = '2.48.0';
assert.deepEqual(compareManifest(current, expected), ['extensions.chromium.violentmonkey: installed 2.48.0, expected 2.49.0']);

let records = upsertUserScriptRecord([], { name: 'hello.user.js', hash: 'one' });
records = upsertUserScriptRecord(records, { name: 'hello.user.js', hash: 'two' });
assert.equal(records.length, 1, 'refresh must not duplicate a userscript');
assert.equal(records[0].hash, 'two');
assert.throws(
  () => userScriptSource(userscripts, path.join(userscripts, 'hello.user.js')),
  error => error.message.includes(userscripts) && error.message.includes('file name'),
  'a userscript path must explain the expected directory and filename form',
);
console.log('ok: web profile, manifest, and userscript scenarios');
NODE

web_root="$HOME/.megabrain/playwright"
web_install='megabrain install simulator-web --browser chromium'

if [ "${MEGABRAIN_WEB_E2E:-true}" = false ]; then
  printf 'skip: web end-to-end proof disabled by MEGABRAIN_WEB_E2E=false\n'
elif [ ! -d "$web_root/node_modules/playwright" ]; then
  printf 'skip: pinned Playwright is not installed at %s; run %s\n' \
    "$web_root/node_modules/playwright" "$web_install"
elif [ ! -f "$web_root/manifest.json" ]; then
  printf 'skip: browser manifest is missing at %s; run %s\n' \
    "$web_root/manifest.json" "$web_install"
elif [ ! -d "$web_root/profiles/chromium" ]; then
  printf 'skip: Chromium profile is missing at %s; run %s\n' \
    "$web_root/profiles/chromium" "$web_install"
elif [ ! -d "$web_root/extensions/chromium/ublock-origin-lite" ]; then
  printf 'skip: uBlock Origin Lite is missing at %s; run %s\n' \
    "$web_root/extensions/chromium/ublock-origin-lite" "$web_install"
elif [ ! -d "$web_root/extensions/chromium/violentmonkey" ]; then
  printf 'skip: Violentmonkey is missing at %s; run %s\n' \
    "$web_root/extensions/chromium/violentmonkey" "$web_install"
else
  web_browser_path="$(node --input-type=module - "$web_root/node_modules/playwright/index.mjs" <<'NODE'
const { chromium } = await import(process.argv[2]);
process.stdout.write(chromium.executablePath());
NODE
)"
  if [ -z "$web_browser_path" ] || [ ! -x "$web_browser_path" ]; then
    printf 'skip: pinned Chromium binary is missing at %s; run %s\n' \
      "${web_browser_path:-<unknown path>}" "$web_install"
  else
    node "$root/scripts/playwright-web.mjs" e2e-proof
  fi
fi
