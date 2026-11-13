// @ts-check
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { join } from 'node:path';
import { test } from 'node:test';
import { fileURLToPath } from 'node:url';

// The "How to reach your AI harness while you are away" page carries a copy
// button with a setup prompt for coding agents. The article itself is
// `draft: true` for now, so the built page is not exercised here; these checks
// pin the component source: the prompt text, the button, the copy path, and
// the visible prompt block.
const web = fileURLToPath(new URL('..', import.meta.url));
const page = readFileSync(join(web, 'src/pages/articles/[slug].astro'), 'utf8');

// The prompt source: the array literal between `const SETUP_PROMPT = [` and
// `].join('\n')`. Interpolated constants are pinned separately, so the raw
// source is enough for every needle below.
function setupPromptSource() {
  return page.split('const SETUP_PROMPT = [')[1].split("].join('\\n')")[0];
}

test('the setup prompt page wires its copy button to a self-contained prompt', () => {
  // The article opts in with `setupPrompt: true` in its front matter, so a
  // future rename cannot silently drop the button.
  const article = readFileSync(
    join(web, 'src/content/articles/reach-your-ai-harness-while-you-are-away.md'),
    'utf8',
  );
  assert.ok(article.includes('setupPrompt: true'), 'front-matter flag set');
  assert.ok(page.includes('article.data.setupPrompt &&'), 'flag guards the section');
  assert.ok(page.includes('Copy a setup prompt'), 'button label');
  assert.ok(page.includes('[data-setup-prompt-copy]'), 'copy wiring');
  assert.ok(page.includes("addEventListener('click'"), 'copy wiring');
  assert.ok(page.includes('document.execCommand'), 'copy command fallback path');
  assert.ok(page.includes('data-setup-prompt-copy hidden'), 'button rendered hidden');
  assert.ok(page.includes('button.hidden = false;'), 'script unhides the button');
  assert.ok(!page.includes('is:inline'), 'no inline script');
  assert.ok(!page.includes('SETUP_PROMPT_SLUG'), 'no brittle slug pin');
});

test('the page shows the prompt text in a details block, not only on the clipboard', () => {
  assert.ok(page.includes('<details class="setup-prompt-details">'), 'details block');
  assert.ok(page.includes('<summary>Show the prompt</summary>'), 'summary');
  assert.ok(page.includes('<pre>{SETUP_PROMPT}</pre>'), 'prompt rendered as text');
});

test('the setup prompt turns the machine into a subnet router, not just a Tailscale install', () => {
  const prompt = setupPromptSource();
  for (const needle of [
    // 1. OS detection and install paths.
    'Work out which operating system this machine runs (macOS, Linux or Windows)',
    'macOS: install the Tailscale app. Its command line tool lives at /Applications/Tailscale.app/Contents/MacOS/Tailscale. No sudo is needed.',
    'Linux: install the tailscale package with the system package manager.',
    'Windows: install the Tailscale app.',
    // 2. Login flow (URL handing).
    'Run tailscale up (on macOS, /Applications/Tailscale.app/Contents/MacOS/Tailscale up). It prints a login URL.',
    'Show me that URL, tell me to open it and sign in, and wait until I confirm I am signed in.',
    // 3. LAN subnet detection and explicit confirmation.
    'On Linux run: ip -4 route show default. On macOS run: ipconfig getifaddr en0, or ifconfig. On Windows run: ipconfig.',
    '192.168.1.10 means 192.168.1.0/24',
    'Show me the subnet you found and ask me to confirm that this machine should be the subnet router',
    'Do not go on until I say yes.',
    // 4. Forwarding: Linux persistent sysctl via tee -a (upstream style), grep first.
    'first check /etc/sysctl.d/99-tailscale.conf with grep for the two lines below.',
    "echo '<line>' | sudo tee -a /etc/sysctl.d/99-tailscale.conf",
    '(a rerun that appends a duplicate line is harmless)',
    'sudo sysctl -p /etc/sysctl.d/99-tailscale.conf',
    'net.ipv4.ip_forward = 1',
    'net.ipv6.conf.all.forwarding = 1',
    // 5. Windows pointed at Tailscale's own guide, no unverified command.
    'do not change IP forwarding yourself',
    'https://tailscale.com/docs/features/subnet-routers',
    // 6. Advertise with a placeholder the agent fills with the confirmed subnet.
    'tailscale set --advertise-routes=<subnet>',
    '/Applications/Tailscale.app/Contents/MacOS/Tailscale set --advertise-routes=<subnet>',
    // 7. Admin console route approval and key expiry.
    'https://login.tailscale.com/admin/machines',
    'edit its subnet routes',
    'turn off key expiry',
    "Tailscale's default is 180 days",
    // 6. Install Tailscale on the phone (step 1 of the how-to).
    'install the Tailscale app on my phone',
    // 7. Verify with status --json (Self.AllowedIPs), then the real phone test.
    'Run tailscale status --json (macOS: the full path)',
    'Self.AllowedIPs',
    'turn OFF Wi-Fi on my phone (so it runs on cellular)',
    'connect to a machine on my network by its LAN address',
    'The machine you connect to needs SSH reachable; turn on SSH on that machine or ask me first.',
    // 9. Waycar is iOS-only; the prompt must not imply installing Waycar on the machine.
    'Waycar runs on my phone. Nothing here installs Waycar on this machine.',
  ]) {
    assert.ok(prompt.includes(needle), `prompt mentions ${needle}`);
  }
  assert.ok(!prompt.includes('Set-NetIPInterface'), 'no unverified Windows forwarding command');
  assert.ok(!prompt.includes('—') && !prompt.includes('–'), 'no dashes as punctuation');
});

test('the prompt keeps tee -a for the sysctl file, matching upstream and the article', () => {
  const prompt = setupPromptSource();
  // The agent greps the file first and only appends the lines it is missing,
  // with `tee -a`. Plain `tee` would truncate a file another config owns.
  assert.ok(prompt.includes('check /etc/sysctl.d/99-tailscale.conf with grep'), 'grep check before writing');
  assert.ok(prompt.includes('sudo tee -a /etc/sysctl.d/99-tailscale.conf'), 'append with tee -a');
  assert.ok(!prompt.includes('| sudo tee /etc/sysctl.d/'), 'no truncating write');
});

test('the prompt ends with the campaign-tagged App Store URL and a terminal QR code', () => {
  const prompt = setupPromptSource();
  assert.ok(prompt.includes('Give me the Waycar install link for my phone: ${SETUP_PROMPT_APP_URL}.'), 'campaign-tagged URL');
  assert.ok(prompt.includes('qrencode -t ansiutf8'), 'terminal QR code type');
  assert.ok(prompt.includes('Offer to open the link in my browser.'), 'browser open on any machine');
  assert.ok(!prompt.includes('On a Mac only'), 'no Mac-only restriction on the browser link');
  assert.ok(prompt.includes('Do not install anything else on this machine.'), 'nothing else installed');
});

test('the prompt never claims done before the user confirms it works from the phone', () => {
  const prompt = setupPromptSource();
  assert.ok(prompt.includes('Never tell me the setup is done before I confirm it works from my phone.'), 'no premature done');
  assert.ok(prompt.includes('When the route works from my phone, tell me what you set up and what still needs my attention.'), 'summary after confirmation');
});

test('the prompt links the App Store listing with its own campaign tag', () => {
  assert.ok(page.includes("import { appStoreCampaignUrl } from '../../lib/ad-links.mjs';"), 'campaign helper import');
  assert.ok(page.includes("appStoreCampaignUrl(APP_STORE_LISTING_URL, 'setup-prompt')"), 'own ct label');
  assert.ok(page.includes('const SETUP_PROMPT_APP_URL = ON_APP_STORE'), 'prompt URL only when the switch is on');
  assert.ok(page.includes('${SETUP_PROMPT_APP_URL}'), 'prompt carries the tagged URL');
});

test('the next steps URL stays the article how-to', () => {
  assert.ok(page.includes("'https://waycar.dev/articles/reach-your-local-network-with-tailscale'"), 'next steps URL');
  assert.ok(setupPromptSource().includes('${NEXT_STEPS_URL}'), 'how-to referenced in the prompt');
});
