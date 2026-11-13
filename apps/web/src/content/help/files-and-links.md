---
title: Files and links
description: Tap a link or file path an agent prints to open it, preview images, PDFs, Markdown, and videos from your Host, and save media to Photos.
category: terminal
order: 60
keywords: [preview, quick look, image, pdf, markdown, url, save to photos, video]
related: [terminal, select-copy, send-files, chat-mode]
---

When an agent prints a web link or the path of a file on its Host, you can tap it to open it. Waycar also collects the images, PDFs, Markdown files, and links the terminal shows in a small strip under the terminal, and lists them all in **Files & Links**.

## Open a link or a file from the terminal

- **Tap a web link** to open it in your browser, including a link that wraps onto the next line. On iPad, a click with a trackpad or mouse opens it too.
- **Tap a file path** such as `~/shot.png`, `src/app.swift:12:3`, a bare `shot.png`, or `report.pdf` to preview it. Waycar fetches the file over SSH from the Host, relative to the terminal's current folder.

Previews are read-only. A tap in the terminal fetches only that file. In **Files & Links**, Waycar fetches the image or PDF you're on and may fetch the image just before or after it ahead; a PDF is fetched only when you open or swipe to it. Common images (PNG, JPEG, GIF, HEIC, WebP), PDFs, text and source, and common audio and video open as themselves, `.m4v` videos included; anything else shows as plain text. Files over 25 MB, folders, and missing files say so instead.

## The files and links strip

Waycar keeps the newest 25 files the agent printed in a small strip in the status row under the terminal. Images show as thumbnails; PDFs and Markdown files show as icons and are only fetched when you open one, or for a PDF, when you swipe to it. Web links join the strip as one link tile after the files. The terminal never changes size for the strip.

Tap the strip to open **Files & Links**:

- **Files**: every file, newest first, with its folder.
- **Links**: every link, newest first, with its host and full address.

Tap a Markdown file to read it rendered, an image or PDF to see it full screen, and a link to open it in your browser. If a link can't open, tap **Copy Link**. Touch and hold a link to copy it.

A file you open from **Files & Links** shows over the list, and closing it brings you back to the list where you left it, so you can open the next one right away.

- **Swipe through images and PDFs**: after you tap an image or PDF, swipe left or right to page through the list's other images and PDFs, in list order. Swipe down or tap the close button to return to the list.
- **Markdown opens on its own**: a Markdown file opens in its own viewer over the list and isn't part of the swipe. Links aren't either.

## Read Markdown files

A Markdown file such as `docs/plan.md` or a bare `README.md` opens rendered: headings, lists and checklists, tables, code blocks, and quotes. Tap **Show Raw Text** to see and select the plain text, and **Show Rendered** to switch back. Waycar remembers which you picked.

Inside the file, a web link asks first, then opens in your browser. A link to another file on the Host asks first, then opens it. A link to a heading scrolls to it. Images are never loaded; each shows as a placeholder with its description. A file over 1 MB opens as plain text.

## Why does Waycar ask before opening a link?

When a link's text is not where it leads, Waycar shows the real address first, with **Open** (or **Preview** for a file on the Host), **Copy**, and **Cancel**. That covers a hyperlink printed under other words, a `file:` link, a path that climbs out of a folder with `..`, and a web address hiding a user name or unusual characters in its host.

## Save to Photos

In the share menu of an image or video you opened from the terminal, **Save Image** and **Save Video** ask to add it to your photo library.
