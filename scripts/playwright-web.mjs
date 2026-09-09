#!/usr/bin/env node

import { createHash } from 'node:crypto';
import { execFileSync } from 'node:child_process';
import { existsSync, mkdirSync, readFileSync, readdirSync, rmSync, statSync, writeFileSync } from 'node:fs';
import { mkdtempSync } from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';

export const PLAYWRIGHT_VERSION = '1.63.0';
export const DEFAULT_ROOT = path.join(os.homedir(), '.megabrain', 'playwright');
export const DEFAULT_USERSCRIPTS = path.join(os.homedir(), '.megabrain', 'userscripts');
export const EXTENSION_IDS = {
  ublock: 'uBlock0@raymondhill.net',
  violentmonkey: '{aecec67f-0d10-4fa7-b7c7-609a2db280cf}',
};

const REPOSITORIES = {
  ubol: 'uBlockOrigin/uBOL-home',
  violentmonkey: 'violentmonkey/violentmonkey',
  ublock: 'gorhill/uBlock',
};

const MCP_CONFIG_NAMES = { chromium: 'chromium.json', firefox: 'firefox.json' };

function chromiumPaths(root) {
  return {
    root,
    profile: path.join(root, 'profiles', 'chromium'),
    extensions: {
      ublock: path.join(root, 'extensions', 'chromium', 'ublock-origin-lite'),
      violentmonkey: path.join(root, 'extensions', 'chromium', 'violentmonkey'),
    },
  };
}

function firefoxPaths(root) {
  return {
    root,
    profile: path.join(root, 'profiles', 'firefox'),
    extensions: {
      ublockXpi: path.join(root, 'profiles', 'firefox', 'extensions', `${EXTENSION_IDS.ublock}.xpi`),
      violentmonkeyXpi: path.join(root, 'profiles', 'firefox', 'extensions', `${EXTENSION_IDS.violentmonkey}.xpi`),
    },
  };
}

export function buildBrowserConfig(browser, paths) {
  if (browser === 'chromium') {
    const extensionPaths = [paths.extensions.ublock, paths.extensions.violentmonkey].join(',');
    return {
      browser: {
        browserName: 'chromium',
        userDataDir: paths.profile,
        launchOptions: {
          channel: 'chromium',
          headless: true,
          args: [
            `--disable-extensions-except=${extensionPaths}`,
            `--load-extension=${extensionPaths}`,
          ],
        },
        contextOptions: { viewport: { width: 1280, height: 720 } },
      },
    };
  }
  if (browser === 'firefox') {
    return {
      browser: {
        browserName: 'firefox',
        userDataDir: paths.profile,
        launchOptions: {
          headless: true,
          firefoxUserPrefs: {
            'extensions.autoDisableScopes': 0,
            'extensions.enabledScopes': 15,
          },
        },
        contextOptions: { viewport: { width: 1280, height: 720 } },
      },
    };
  }
  throw new Error(`unknown browser: ${browser}`);
}

export function validateBrowserConfig(config, browser) {
  const b = config?.browser;
  if (!b || b.browserName !== browser) throw new Error(`${browser} config has the wrong browserName`);
  if (browser === 'chromium') {
    if (b.launchOptions?.channel !== 'chromium') throw new Error('chromium config must set launchOptions.channel to chromium');
    if (b.launchOptions?.headless !== true) throw new Error('chromium config must be headless');
    if (b.contextOptions?.viewport?.width !== 1280 || b.contextOptions?.viewport?.height !== 720) {
      throw new Error('chromium config must set viewport to 1280x720');
    }
    if (!b.launchOptions.args?.some(arg => arg.startsWith('--load-extension='))) throw new Error('chromium config must load extensions');
  } else {
    if (b.launchOptions?.headless !== true) throw new Error('firefox config must be headless');
    const prefs = b.launchOptions?.firefoxUserPrefs || {};
    if (prefs['extensions.autoDisableScopes'] !== 0 || prefs['extensions.enabledScopes'] !== 15) {
      throw new Error('firefox config must enable installed extensions');
    }
  }
  if (!b.userDataDir) throw new Error(`${browser} config is missing userDataDir`);
  return { valid: true };
}

export function compareManifest(actual, expected) {
  const mismatches = [];
  const walk = (left, right, key) => {
    if (right && typeof right === 'object' && !Array.isArray(right)) {
      for (const child of Object.keys(right)) walk(left?.[child], right[child], key ? `${key}.${child}` : child);
      return;
    }
    if (left !== right) mismatches.push(`${key}: installed ${left ?? 'missing'}, expected ${right}`);
  };
  walk(actual, expected, '');
  return mismatches;
}

export function upsertUserScriptRecord(records, record) {
  const next = records.filter(item => item.name !== record.name);
  next.push(record);
  return next;
}

function jsonWrite(file, value) {
  mkdirSync(path.dirname(file), { recursive: true });
  const temp = `${file}.tmp-${process.pid}`;
  writeFileSync(temp, `${JSON.stringify(value, null, 2)}\n`);
  writeFileSync(file, readFileSync(temp));
  rmSync(temp, { force: true });
}

function readJson(file, fallback = null) {
  try { return JSON.parse(readFileSync(file, 'utf8')); } catch { return fallback; }
}

async function githubRelease(repo) {
  const response = await fetch(`https://api.github.com/repos/${repo}/releases/latest`, {
    headers: { 'accept': 'application/vnd.github+json', 'user-agent': 'megabrain' },
  });
  if (!response.ok) throw new Error(`GitHub latest release failed for ${repo}: HTTP ${response.status}`);
  return response.json();
}

function githubAsset(release, predicate) {
  const asset = release.assets?.find(item => predicate(item.name));
  if (!asset) throw new Error(`release ${release.tag_name} has no matching extension asset`);
  return asset;
}

async function download(url, destination) {
  const response = await fetch(url, { headers: { 'user-agent': 'megabrain' } });
  if (!response.ok) throw new Error(`download failed: HTTP ${response.status} ${url}`);
  mkdirSync(path.dirname(destination), { recursive: true });
  writeFileSync(destination, Buffer.from(await response.arrayBuffer()));
}

function extensionManifest(directory) {
  const direct = path.join(directory, 'manifest.json');
  if (existsSync(direct)) return direct;
  const entries = readdirSync(directory, { withFileTypes: true });
  for (const entry of entries) {
    if (!entry.isDirectory() || entry.name === '__MACOSX') continue;
    const found = extensionManifest(path.join(directory, entry.name));
    if (found) return found;
  }
  return null;
}

function unpackExtension(archive, destination) {
  const temporary = mkdtempSync(path.join(os.tmpdir(), 'megabrain-extension-'));
  try {
    execFileSync('unzip', ['-q', archive, '-d', temporary], { stdio: 'ignore' });
    const manifest = extensionManifest(temporary);
    if (!manifest) throw new Error(`extension archive has no manifest.json: ${archive}`);
    rmSync(destination, { recursive: true, force: true });
    mkdirSync(destination, { recursive: true });
    const source = path.dirname(manifest);
    for (const entry of readdirSync(source)) {
      execFileSync('cp', ['-R', path.join(source, entry), path.join(destination, entry)]);
    }
    return JSON.parse(readFileSync(manifest, 'utf8')).version;
  } finally {
    rmSync(temporary, { recursive: true, force: true });
    rmSync(archive, { force: true });
  }
}

async function installChromiumExtensions(root) {
  const paths = chromiumPaths(root);
  const ubol = await githubRelease(REPOSITORIES.ubol);
  const vm = await githubRelease(REPOSITORIES.violentmonkey);
  const ubolAsset = githubAsset(ubol, name => name.endsWith('.chromium.zip'));
  const vmAsset = githubAsset(vm, name => name.startsWith('Violentmonkey-mv3-') && name.endsWith('.zip'));
  const ubolArchive = path.join(root, 'downloads', ubolAsset.name);
  const vmArchive = path.join(root, 'downloads', vmAsset.name);
  await download(ubolAsset.browser_download_url, ubolArchive);
  await download(vmAsset.browser_download_url, vmArchive);
  const ublockVersion = unpackExtension(ubolArchive, paths.extensions.ublock);
  const violentmonkeyVersion = unpackExtension(vmArchive, paths.extensions.violentmonkey);
  return {
    paths,
    versions: { ublock: ubol.tag_name.replace(/^v/, ''), violentmonkey: violentmonkeyVersion || vm.tag_name.replace(/^v/, '') },
  };
}

async function installFirefoxExtensions(root) {
  const paths = firefoxPaths(root);
  mkdirSync(path.dirname(paths.extensions.ublockXpi), { recursive: true });
  const ublock = await githubRelease(REPOSITORIES.ublock);
  const vm = await githubRelease(REPOSITORIES.violentmonkey);
  const ublockAsset = githubAsset(ublock, name => name.endsWith('.firefox.signed.xpi'));
  const ublockArchive = path.join(root, 'downloads', ublockAsset.name);
  await download(ublockAsset.browser_download_url, paths.extensions.ublockXpi);
  await download('https://addons.mozilla.org/firefox/downloads/latest/violentmonkey/latest.xpi', paths.extensions.violentmonkeyXpi);
  const vmManifestArchive = path.join(root, 'downloads', 'violentmonkey-firefox.xpi');
  await download('https://addons.mozilla.org/firefox/downloads/latest/violentmonkey/latest.xpi', vmManifestArchive);
  const vmVersion = execFileSync('unzip', ['-p', vmManifestArchive, 'manifest.json'], { encoding: 'utf8' });
  rmSync(vmManifestArchive, { force: true });
  return {
    paths,
    versions: {
      ublock: ublock.tag_name.replace(/^v/, ''),
      violentmonkey: JSON.parse(vmVersion).version || vm.tag_name.replace(/^v/, ''),
    },
  };
}

function playwrightCli(root) {
  return path.join(root, 'node_modules', 'playwright', 'cli.js');
}

function ensurePlaywright(root, browsers) {
  mkdirSync(root, { recursive: true });
  const packageFile = path.join(root, 'node_modules', 'playwright', 'package.json');
  const installed = readJson(packageFile);
  if (installed?.version !== PLAYWRIGHT_VERSION) {
    execFileSync('npm', ['install', '--prefix', root, '--no-save', '--no-package-lock', '--ignore-scripts', `playwright@${PLAYWRIGHT_VERSION}`], { stdio: 'inherit' });
  }
  if (!existsSync(playwrightCli(root))) throw new Error(`Playwright ${PLAYWRIGHT_VERSION} was not installed under ${root}`);
  for (const browser of browsers) execFileSync(process.execPath, [playwrightCli(root), 'install', browser], { stdio: 'inherit' });
}

async function install(root, browser) {
  const browsers = browser === 'both' ? ['chromium', 'firefox'] : [browser];
  if (!browsers.every(item => ['chromium', 'firefox'].includes(item))) throw new Error(`browser must be chromium, firefox, or both`);
  ensurePlaywright(root, browsers);
  const manifestFile = path.join(root, 'manifest.json');
  const previous = readJson(manifestFile, { extensions: {}, profiles: {}, userscripts: [] });
  const manifest = {
    ...previous,
    playwrightVersion: PLAYWRIGHT_VERSION,
    installedAt: new Date().toISOString(),
    profiles: { ...(previous.profiles || {}) },
    extensions: { ...(previous.extensions || {}) },
    userscripts: previous.userscripts || [],
  };
  for (const selected of browsers) {
    if (selected === 'chromium') {
      const installed = await installChromiumExtensions(root);
      const config = buildBrowserConfig(selected, installed.paths);
      validateBrowserConfig(config, selected);
      const configPath = path.join(root, MCP_CONFIG_NAMES[selected]);
      jsonWrite(configPath, config);
      manifest.extensions.chromium = installed.versions;
      manifest.profiles.chromium = { configPath, userDataDir: installed.paths.profile };
    } else {
      const installed = await installFirefoxExtensions(root);
      const config = buildBrowserConfig(selected, installed.paths);
      validateBrowserConfig(config, selected);
      const configPath = path.join(root, MCP_CONFIG_NAMES[selected]);
      jsonWrite(configPath, config);
      manifest.extensions.firefox = installed.versions;
      manifest.profiles.firefox = { configPath, userDataDir: installed.paths.profile };
    }
  }
  manifest.activeBrowser = browser === 'firefox' ? 'firefox' : 'chromium';
  jsonWrite(manifestFile, manifest);
  return manifest;
}

function manifestFor(root) {
  const manifest = readJson(path.join(root, 'manifest.json'));
  if (!manifest) throw new Error(`browser module is not installed under ${root}`);
  return manifest;
}

async function loadChromium(root, manifest, { chromeUrls = false } = {}) {
  const playwright = await import(pathToFileURL(path.join(root, 'node_modules', 'playwright', 'index.mjs')).href);
  const config = readJson(manifest.profiles.chromium.configPath);
  const args = [...config.browser.launchOptions.args];
  if (chromeUrls) args.push('--extensions-on-chrome-urls');
  const context = await playwright.chromium.launchPersistentContext(config.browser.userDataDir, {
    ...config.browser.launchOptions,
    args,
    ...config.browser.contextOptions,
  });
  return { context, config };
}

async function extensionWorker(context, name) {
  const find = async () => {
    for (const worker of context.serviceWorkers()) {
      try {
        const found = await worker.evaluate(expected => chrome.runtime.getManifest().name.toLowerCase().includes(expected), name.toLowerCase());
        if (found) return worker;
      } catch {}
    }
    return null;
  };
  let worker = await find();
  if (!worker) {
    const candidate = await context.waitForEvent('serviceworker', { timeout: 20000 }).catch(() => null);
    worker = candidate || await find();
  }
  if (!worker) throw new Error(`could not find the ${name} extension service worker`);
  return worker;
}

async function toggleUserScripts(context, extensionId) {
  const page = await context.newPage();
  await page.goto(`chrome://extensions/?id=${extensionId}`);
  const state = await page.evaluate(() => {
    const find = (root, depth) => {
      if (!root || depth > 14) return null;
      for (const element of root.querySelectorAll('*')) {
        if (element.id === 'allow-user-scripts') return element;
        if (element.shadowRoot) {
          const found = find(element.shadowRoot, depth + 1);
          if (found) return found;
        }
      }
      return null;
    };
    const row = find(document, 0);
    if (!row) return { found: false };
    if (row.checked) return { found: true, checked: true };
    const toggle = row.shadowRoot?.querySelector('cr-toggle') || row.shadowRoot?.querySelector('#crToggle');
    if (!toggle) return { found: true, checked: false, toggle: false };
    toggle.click();
    return { found: true, checked: false, toggle: true };
  });
  if (!state.found || !state.toggle && !state.checked) throw new Error('Chrome user scripts toggle was not found');
  await page.waitForTimeout(1200);
  await page.close();
}

async function sendToOptions(context, extensionId, message) {
  const page = await context.newPage();
  await page.goto(`chrome-extension://${extensionId}/options/index.html`);
  const result = await page.evaluate(async payload => {
    try {
      return await chrome.runtime.sendMessage(payload);
    } catch (error) {
      return { error: String(error) };
    }
  }, message);
  await page.close();
  return result;
}

function userScriptSource(userscripts, name) {
  if (path.basename(name) !== name || !name.endsWith('.user.js')) throw new Error('userscript must be a .user.js file name');
  const file = path.join(userscripts, name);
  if (!existsSync(file) || !statSync(file).isFile()) throw new Error(`userscript not found: ${file}`);
  return { file, code: readFileSync(file, 'utf8') };
}

async function installUserScript(root, userscripts, name) {
  const manifest = manifestFor(root);
  if (!manifest.profiles?.chromium) throw new Error('Chromium profile is not installed; userscripts require Chromium');
  const source = userScriptSource(userscripts, name);
  const { context } = await loadChromium(root, manifest, { chromeUrls: true });
  try {
    const worker = await extensionWorker(context, 'Violentmonkey');
    const extensionId = new URL(worker.url()).hostname;
    await toggleUserScripts(context, extensionId);
    const response = await sendToOptions(context, extensionId, {
      cmd: 'ParseScript',
      data: { code: source.code, url: `https://megabrain.local/userscripts/${name}`, update: true, isNew: true },
    });
    const message = response?.update?.message || '';
    if (response?.error || !/Script instalado|installed/i.test(message)) throw new Error(`Violentmonkey rejected ${name}: ${response?.error || message || JSON.stringify(response)}`);
    const data = await sendToOptions(context, extensionId, { cmd: 'GetData', data: { sizes: true } });
    const installed = data?.scripts?.find(item => item.meta?.name === name.replace(/\.user\.js$/, '') || item.meta?.name === name);
    manifest.userscripts = upsertUserScriptRecord(manifest.userscripts || [], {
      name,
      hash: createHash('sha256').update(source.code).digest('hex'),
      id: installed?.props?.id,
      installedAt: new Date().toISOString(),
    });
    jsonWrite(path.join(root, 'manifest.json'), manifest);
    return { name, message: message || 'Script instalado.' };
  } finally {
    await context.close();
  }
}

async function listUserScripts(root) {
  const manifest = manifestFor(root);
  for (const item of manifest.userscripts || []) console.log(`${item.name}\t${item.installedAt || ''}`);
}

async function removeUserScript(root, name) {
  const manifest = manifestFor(root);
  const record = (manifest.userscripts || []).find(item => item.name === name);
  if (!record) return;
  const { context } = await loadChromium(root, manifest);
  try {
    const worker = await extensionWorker(context, 'Violentmonkey');
    const extensionId = new URL(worker.url()).hostname;
    const data = await sendToOptions(context, extensionId, { cmd: 'GetData', data: { sizes: true } });
    const target = data?.scripts?.find(item => item.props?.id === record.id || item.meta?.name === name.replace(/\.user\.js$/, '') || item.meta?.name === name);
    if (target?.props?.id != null) await sendToOptions(context, extensionId, { cmd: 'RemoveScripts', data: [target.props.id] });
    manifest.userscripts = (manifest.userscripts || []).filter(item => item.name !== name);
    jsonWrite(path.join(root, 'manifest.json'), manifest);
  } finally {
    await context.close();
  }
}

async function e2eProof(root) {
  const manifest = manifestFor(root);
  const { context } = await loadChromium(root, manifest);
  try {
    const worker = await extensionWorker(context, 'Violentmonkey');
    console.log(`chrome.userScripts apos relaunch: ${await worker.evaluate(() => typeof chrome.userScripts)}`);
    const page = await context.newPage();
    await page.goto('https://example.com', { waitUntil: 'domcontentloaded', timeout: 30000 });
    await page.waitForTimeout(2500);
    console.log(`title example.com: ${await page.title()}`);
  } finally {
    await context.close();
  }
}

async function latestVersions() {
  const [ubol, vm, ublock] = await Promise.all([
    githubRelease(REPOSITORIES.ubol), githubRelease(REPOSITORIES.violentmonkey), githubRelease(REPOSITORIES.ublock),
  ]);
  const response = await fetch('https://addons.mozilla.org/firefox/downloads/latest/violentmonkey/latest.xpi', { headers: { 'user-agent': 'megabrain' } });
  if (!response.ok) throw new Error(`AMO latest Violentmonkey failed: HTTP ${response.status}`);
  const temp = path.join(os.tmpdir(), `megabrain-vm-${process.pid}.xpi`);
  writeFileSync(temp, Buffer.from(await response.arrayBuffer()));
  const vmManifest = JSON.parse(execFileSync('unzip', ['-p', temp, 'manifest.json'], { encoding: 'utf8' }));
  rmSync(temp, { force: true });
  return {
    chromium: { ublock: ubol.tag_name.replace(/^v/, ''), violentmonkey: vm.tag_name.replace(/^v/, '') },
    firefox: { ublock: ublock.tag_name.replace(/^v/, ''), violentmonkey: vmManifest.version },
  };
}

async function doctor(root) {
  const manifest = readJson(path.join(root, 'manifest.json'));
  if (!manifest) return { status: 'missing', reason: `browser manifest is missing under ${root}`, mismatches: [] };
  const mismatches = [];
  const installedPlaywright = readJson(path.join(root, 'node_modules', 'playwright', 'package.json'));
  if (installedPlaywright?.version !== PLAYWRIGHT_VERSION) {
    mismatches.push(`playwright: installed ${installedPlaywright?.version || 'missing'}, expected ${PLAYWRIGHT_VERSION}`);
  }
  for (const browser of ['chromium', 'firefox']) {
    const profile = manifest.profiles?.[browser];
    if (!profile) continue;
    const config = readJson(profile.configPath);
    try { validateBrowserConfig(config, browser); } catch (error) { mismatches.push(`${browser}: ${error.message}`); }
    if (!existsSync(profile.userDataDir)) mismatches.push(`${browser}: profile directory is missing`);
  }
  let aged = [];
  try {
    const current = await latestVersions();
    aged = compareManifest(manifest.extensions || {}, current);
  } catch (error) {
    aged = [`latest extension versions unavailable: ${error.message}`];
  }
  if (mismatches.length) return { status: 'misconfigured', reason: mismatches.join('; '), mismatches, aged };
  if (aged.some(item => item.startsWith('extensions.'))) return { status: 'misconfigured', reason: aged.join('; '), mismatches, aged };
  if (aged.length) return { status: 'unknown', reason: aged[0], mismatches, aged };
  return { status: 'ok', reason: `Playwright ${manifest.playwrightVersion} and browser profiles are current`, mismatches, aged };
}

function argumentValue(args, flag, fallback) {
  const index = args.indexOf(flag);
  return index >= 0 ? args[index + 1] : fallback;
}

async function main(args) {
  const command = args[0];
  const root = argumentValue(args, '--root', DEFAULT_ROOT);
  switch (command) {
    case 'install': {
      const manifest = await install(root, argumentValue(args, '--browser', 'both'));
      console.log(`configured ${manifest.activeBrowser} browser profile with Playwright ${manifest.playwrightVersion}`);
      return;
    }
    case 'userscript-install': {
      const result = await installUserScript(root, argumentValue(args, '--userscripts', DEFAULT_USERSCRIPTS), argumentValue(args, '--file', ''));
      console.log(result.message);
      return;
    }
    case 'userscript-list': await listUserScripts(root); return;
    case 'userscript-remove': await removeUserScript(root, argumentValue(args, '--file', '')); return;
    case 'doctor': console.log(JSON.stringify(await doctor(root))); return;
    case 'e2e-proof': await e2eProof(root); return;
    default: throw new Error('usage: playwright-web.mjs install|userscript-install|userscript-list|userscript-remove|doctor|e2e-proof');
  }
}

if (process.argv[1] && pathToFileURL(path.resolve(process.argv[1])).href === import.meta.url) {
  main(process.argv.slice(2)).catch(error => {
    console.error(`megabrain web: ${error.message}`);
    process.exitCode = 1;
  });
}
