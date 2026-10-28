#!/usr/bin/env node

import { intro, outro, text, select, spinner, isCancel, cancel } from '@clack/prompts';
import color from 'picocolors';
import { downloadTemplate } from 'giget';
import { replaceInFile } from 'replace-in-file';

import path from 'node:path';
import { randomInt } from 'node:crypto';
import { crc32 } from 'node:zlib';
import process from 'node:process';

const STATIC_TEMPLATES = [
  { value: 'starter', label: 'Starter', hint: 'Ziex starter app' },
  { value: 'cloudflare', label: 'Cloudflare', hint: 'Ziex on Cloudflare' },
  { value: 'vercel', label: 'Vercel', hint: 'Ziex on Vercel' },
  { value: 'node', label: 'Node', hint: 'Ziex with npm scripts' },
  { value: 'railway', label: 'Railway', hint: 'Ziex on Railway' },
  { value: 'render', label: 'Render', hint: 'Ziex on Render' },
];

function starterOrder(topics = []) {
  const tag = topics.find((t) => /^starter-\d+$/.test(t));
  return tag ? parseInt(tag.split('-')[1], 10) : Infinity;
}

async function fetchGitHubTemplates() {
  const res = await fetch('https://api.github.com/orgs/ziex-dev/repos', {
    headers: { Accept: 'application/vnd.github+json' },
  });
  const repos = await res.json();
  return repos
    .filter((r) => r.name.startsWith('template-'))
    .sort((a, b) => {
      const oa = starterOrder(a.topics);
      const ob = starterOrder(b.topics);
      if (oa !== ob) return oa - ob;
      return a.name.localeCompare(b.name);
    })
    .map((r) => {
      const name = r.name.replace('template-', '');
      return {
        value: name,
        label: name.charAt(0).toUpperCase() + name.slice(1),
        hint: r.description || '',
      };
    });
}

async function fetchLatestRelease(templateName) {
  const res = await fetch(
    `https://api.github.com/repos/ziex-dev/template-${templateName}/releases/latest`,
    { headers: { Accept: 'application/vnd.github+json' } }
  );
  if (!res.ok) return null;
  const data = await res.json();
  return data.tag_name;
}

function parseVersion(tag) {
  // Parse semantic version with pre-release: v1.2.3, v1.2.3-dev.123, etc.
  const match = tag.match(/^v?(\d+)\.(\d+)\.(\d+)(?:-(.+))?$/);
  if (!match) return { major: 0, minor: 0, patch: 0, prerelease: '', preNum: 0 };
  const [, major, minor, patch, prerelease] = match;

  // Extract numeric part from prerelease (e.g., "dev.987" -> 987)
  let preNum = 0;
  if (prerelease) {
    const numMatch = prerelease.match(/\.(\d+)$/);
    preNum = numMatch ? parseInt(numMatch[1], 10) : 0;
  }

  return {
    major: parseInt(major, 10),
    minor: parseInt(minor, 10),
    patch: parseInt(patch, 10),
    prerelease: prerelease || '',
    preNum,
  };
}

function compareVersions(a, b) {
  const va = parseVersion(a);
  const vb = parseVersion(b);

  if (va.major !== vb.major) return vb.major - va.major;
  if (va.minor !== vb.minor) return vb.minor - va.minor;
  if (va.patch !== vb.patch) return vb.patch - va.patch;

  // Both have no prerelease - stable versions are equal
  if (!va.prerelease && !vb.prerelease) return 0;
  // Stable version comes before prerelease
  if (!va.prerelease) return 1;
  if (!vb.prerelease) return -1;
  // Both have prerelease - sort by numeric part
  return vb.preNum - va.preNum;
}

async function fetchTemplateVersions(templateName) {
  const res = await fetch(
    `https://api.github.com/repos/ziex-dev/template-${templateName}/releases`,
    { headers: { Accept: 'application/vnd.github+json' } }
  );
  if (!res.ok) return [];
  const releases = await res.json();
  return releases
    .map((r) => ({
      tag: r.tag_name,
      name: r.name || r.tag_name,
      prerelease: r.prerelease,
    }))
    .sort((a, b) => compareVersions(a.tag, b.tag));
}

async function main() {
  const args = process.argv.slice(2);
  const versionFlagIndex = args.indexOf('--version');
  const listVersionsFlag = args.includes('--list-versions');

  // --version <tag>: pin to a specific version within the normal flow
  let pinnedVersion = null;
  if (versionFlagIndex !== -1) {
    pinnedVersion = args[versionFlagIndex + 1];
    if (!pinnedVersion || pinnedVersion.startsWith('--')) {
      console.error('Error: version value required for --version (e.g. --version v0.1.0)');
      process.exit(1);
    }
  }

  console.log();
  intro(color.bgCyan(color.black(' Create Ziex App ')));

  // Start fetching templates immediately in the background
  const templatesFetch = fetchGitHubTemplates().catch(() => null);

  // 1. Gather User Input
  const project = await text({
    message: 'Where should we create your project?',
    placeholder: './my-ziex-app',
    validate: (value) => {
      if (!value) return 'Please enter a path.';
    },
  });

  if (isCancel(project)) {
    cancel('Operation cancelled.');
    process.exit(0);
  }

  // By now the user has been typing - give the fetch a short grace period
  // in case it hasn't resolved yet, then fall back to the static list.
  const dynamicTemplates = await Promise.race([
    templatesFetch,
    new Promise((resolve) => setTimeout(resolve, 500, null)),
  ]);

  const template = await select({
    message: `Pick a template${dynamicTemplates ? '' : ' (showing cached list)'}`,
    options: dynamicTemplates ?? STATIC_TEMPLATES,
  });

  if (isCancel(template)) {
    cancel('Operation cancelled.');
    process.exit(0);
  }

  let version;

  if (pinnedVersion) {
    // --version <tag>: use the explicitly pinned version
    version = pinnedVersion;
  } else if (listVersionsFlag) {
    // --list-versions: let the user pick from all releases (defaults to latest)
    const versions = await fetchTemplateVersions(template);
    if (versions.length > 0) {
      version = await select({
        message: 'Pick a version',
        options: versions.map((v) => ({
          value: v.tag,
          label: v.tag,
          hint: v.prerelease ? 'pre-release' : '',
        })),
        initialValue: versions[0].tag,
      });
      if (isCancel(version)) {
        cancel('Operation cancelled.');
        process.exit(0);
      }
    }
  } else {
    // Default: use the latest release
    version = await fetchLatestRelease(template);
  }

  const templateRef = version
    ? `github:ziex-dev/template-${template}#${version}`
    : `github:ziex-dev/template-${template}`;

  const s = spinner();
  const targetDir = path.resolve(process.cwd(), project);

  // 2. Download from GitHub
  s.start('Downloading template...');
  try {
    await downloadTemplate(templateRef, {
      dir: targetDir,
      force: true,
    });
    s.stop('Template downloaded successfully!');
  } catch (err) {
    s.stop('Failed to download template', 1);
    console.error(err);
    process.exit(1);
  }

  // 3. Perform String Replacements
  const projectName = sanitizeProjectName(path.basename(targetDir));
  s.start('Customizing project files...');
  try {
    await replaceInFile({
      files: `${targetDir}/**/*`,
      from: /ziex_app/g,
      to: projectName,
    });
    s.stop('Project customized!');
  } catch (err) {
    s.stop('Replacement failed', 1);
  }

  // 4. Fix Zig fingerprint - the fingerprint is a u64 packed struct:
  //    lower 32 bits = random id, upper 32 bits = CRC-32 of the package name.
  s.start('Updating package fingerprint...');
  try {
    const fingerprint = generateZigFingerprint(projectName);
    await replaceInFile({
      files: `${targetDir}/build.zig.zon`,
      from: /\.fingerprint = 0x[0-9a-f]+/,
      to: `.fingerprint = ${fingerprint}`,
    });
    s.stop('Package fingerprint updated!');
  } catch (err) {
    s.stop('Could not update fingerprint');
  }

  outro(`Successfully created ${color.cyan(project)}!`);
  const is_node = template === 'node';
  if (is_node) {
    console.log(`
    cd ${project}
    npm i
    npm run dev
    
    `);
  }
  else {
    console.log(`
    cd ${project}
    zig build dev
    
    `);
  }
}

// Make sure project name is suported Zig identifier
function sanitizeProjectName(name) {
  return name.replace(/[^a-zA-Z0-9_]/g, '_');
}

// Generate a Zig package fingerprint: packed u64 with
// lower 32 bits = random id in [1, 0xFFFFFFFE], upper 32 bits = CRC-32 of name
export function generateZigFingerprint(name) {
  const id = BigInt(randomInt(1, 0xfffffffe));
  const checksum = BigInt(crc32(Buffer.from(name)) >>> 0);
  const fingerprint = (checksum << 32n) | id;
  return '0x' + fingerprint.toString(16).padStart(16, '0');
}

main().catch(console.error);