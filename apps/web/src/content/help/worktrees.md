---
title: Start on a new worktree
description: Turn on New Worktree in New Agent to give an agent a fresh git checkout on its own branch, starting from the latest main.
category: agents
order: 20
keywords: [git, branch, checkout, base, latest main, origin, head, worktree details, remove worktree]
related: [new-agent, workspaces, herdr-vs-tmux]
---

New Worktree starts an agent in a clean git checkout of the Workspace's repository, on its own branch. The agent works there without touching your main checkout or any other agent's files.

Worktrees aren't available on herdr-core Hosts yet. See [Waycar with herdr-core](/help/herdr-core).

## Start an agent on a new worktree

1. Open the New Agent sheet and pick a **Host** and a **Workspace** inside a git repository.
2. Turn on **New Worktree**.
3. Type a **Branch**, or leave it empty for a generated name such as `worktree/calm-river-3f2a`.
4. Pick the agent and tap **Start**.

As you type a Branch, Waycar turns spaces and characters git doesn't allow into `-`, and fills in the agent's name to match until you type a different one.

## Where does the new branch start?

By default, **Start From Latest Main** is on: Waycar first fetches origin's default branch (usually `main`) on the Host and starts from its newest commit, so the worktree isn't built on an old local copy. If the fetch fails, nothing is created and the sheet says why.

Turn off **Start From Latest Main** to start from the Host's current checkout. A **Base** field then appears where you can type a branch or commit; empty means `HEAD`. Waycar remembers whether the switch is on.

## What you see while it starts

The status line in the sheet shows each step, such as "Getting the latest main from origin", "Creating the worktree" and "Opening the agent", with the seconds spent on a slow one.

## Good to know

- If you start on a branch that is already open in a worktree, Waycar opens that worktree instead: its running agent if it has one, otherwise a new tab in it.
- Tapping **Start** again after an error, or a slow answer from herdr, doesn't make a second worktree. Waycar finds the one it already made and continues there.
- A Workspace that isn't inside a git repository can't make a worktree.

## See a worktree's details

Open an agent that runs in a linked worktree, open the **More** menu, and tap **Worktree Details**. The item only appears for agents in a linked worktree. The **Worktree** sheet shows the **Repository**, the **Branch** (or Detached HEAD), and the **Checkout Path** on the Host. If the branch can't be read, tap **Retry**.

## Remove a worktree when you're done

1. Open **More** › **Worktree Details** on an agent in that worktree.
2. Tap **Remove Worktree**.
3. Read the confirmation "Remove <name> worktree?" and confirm.

Removing deletes the checkout on the Host and closes its whole Workspace, ending every agent and closing every pane in it. The local branch is kept, so no commits on it are lost. The confirmation warns you when an agent is still working there. This can't be undone.

When it's done, you see **Worktree Removed**. Tap **Back to Console**.

### If removal fails

Waycar shows **Couldn't Remove Worktree** with the reason:

| Message says | What to do |
| --- | --- |
| it "has modified or untracked files" | Commit or discard those changes on the Host, then retry. |
| "herdr is already changing a worktree on this Host" | Wait a moment, then retry. |
| "The Host is not connected." | Reconnect, then retry. |

If you see **Removal Unconfirmed**, the Host didn't say whether it finished. Close the sheet, wait for the Console to refresh, then open **Worktree Details** again.

## herdr and tmux

On herdr, each new worktree becomes its own Workspace, and the Console shows it under its repository. On tmux, the worktree opens as a new tmux session. Either way the Host needs git, and **Remove Worktree** works on both.
