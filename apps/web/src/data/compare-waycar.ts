// Waycar's side of every comparison table: one cell per row in
// src/lib/compare-rows.mjs, as `main` behaves. A runtime App Store build 1.3.0
// lacks (Zellij, Codex, OpenCode 2) says "next update" wherever a 1.3.0 user
// would otherwise be misled. Keep the cells and the pages' wording
// together. Every competitor claim lives in its own page's front matter,
// with its sources.
//
// Cell text starts with its level's word and stays within `CELL_MAX`
// characters; src/lib/compare.ts checks both when the comparisons load.
import type { CapabilityId, Cell } from '../lib/compare-rows.mjs';

export const WAYCAR_ROWS: Record<CapabilityId, Cell> = {
  'runs-where': { level: 'info', text: 'Your Mac or Linux box: herdr, tmux, Herdr Core and more' },
  account: { level: 'info', text: 'None. Optional iCloud Keychain sync between devices' },
  path: { level: 'info', text: 'Direct mosh or SSH to your machine. No session relay' },
  mosh: { level: 'yes', text: 'Yes, with SSH fallback' },
  persistent: { level: 'yes', text: 'Yes. In herdr, tmux, Herdr Core; Zellij in next update' },
  'host-setup': { level: 'info', text: 'OpenSSH; herdr, tmux or Herdr Core (Zellij in next update)' },
  agents: { level: 'info', text: '23 launch from the app; any CLI runs in a shell' },
  status: { level: 'yes', text: 'Yes. herdr: every agent it knows. tmux: 17 agents' },
  push: { level: 'yes', text: 'Yes, Blocked or Done, encrypted. On tmux: 17 agents' },
  approve: { level: 'yes', text: 'Yes. Allow or Cancel in Chat Mode (tmux: hooks), or type' },
  chat: { level: 'yes', text: 'Yes, Chat Mode for 14 agents you start in Waycar' },
  terminal: { level: 'yes', text: 'Yes, a native terminal into the agent or a shell' },
  'live-activity': { level: 'yes', text: 'Yes, Lock Screen, Dynamic Island, CarPlay Dashboard' },
  attach: { level: 'yes', text: 'Yes, up to 10 per message; files up to 64 MiB' },
  voice: { level: 'yes', text: 'Yes, on-device dictation (iOS 26 or later)' },
  carplay: { level: 'yes', text: 'Yes, iPhone on iOS 26.4+: hear and answer agents by voice' },
  usage: { level: 'partial', text: 'Partial: plan limits via CodexBar on your Host' },
  resume: { level: 'yes', text: 'Yes, Closed Sessions are kept for 30 days' },
  ios: { level: 'yes', text: 'Yes, iPhone and iPad, iOS 18 or later' },
  android: { level: 'no', text: 'No. An Android app is coming soon' },
  desktop: { level: 'no', text: 'No native desktop app or web client' },
  source: { level: 'info', text: 'Open source app + Host Tools, Apache-2.0, on GitHub' },
  price: { level: 'info', text: 'Free' },
  'general-ssh': { level: 'no', text: 'No. Needs herdr, tmux, Herdr Core, Zellij, Codex or OpenCode' },
};
