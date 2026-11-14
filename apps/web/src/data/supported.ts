// What Waycar works with, in one place: the "Works with" strip under the home
// page hero, the Setup requirements and the Features agent list read it, so a
// version, a new runtime or a new agent changes once. The agent names match
// the table in src/content/help/supported-agents.md. src/llms/index.md repeats
// the versions in prose: change it too.

export type Runtime = {
  name: string;
  /** Oldest version Waycar supports. */
  min: string;
  /**
   * `main` has it, the App Store release does not yet (`APP_STORE_RELEASE` in
   * src/data/unreleased.ts). Shown as "next update". Drop the flag when that
   * release ships.
   */
  next?: true;
};

export const runtimes: readonly Runtime[] = [
  { name: 'herdr', min: '0.7.5' },
  { name: 'tmux', min: '3.2' },
  { name: 'Herdr Core', min: '0.1.10' },
  { name: 'Zellij', min: '0.46', next: true },
  { name: 'Codex server', min: '0.167', next: true },
  { name: 'OpenCode', min: '2.2', next: true },
];

/** The commands most visitors run, shown first. */
export const leadAgents: readonly string[] = ['claude', 'codex', 'omp', 'gemini', 'opencode', 'pi'];

/** Every other agent New Agent can start, by name. */
export const moreAgents: readonly string[] = [
  'Amp',
  'Antigravity',
  'Cline',
  'Cursor Agent',
  'Devin CLI',
  'Droid',
  'GitHub Copilot CLI',
  'Grok Build',
  'Hermes Agent',
  'Kilo Code',
  'Kimi CLI',
  'Kiro CLI',
  'Maki',
  'Mastra Code',
  'Muse',
  'Qoder CLI',
  'Qwen Code',
];

export const SOURCE_URL = 'https://github.com/waycar/waycar-app';
