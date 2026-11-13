---
title: Send photos and files
description: Attach up to 10 photos or files to a message. Waycar uploads them to your Host and adds their paths so the agent can open them.
category: agents
order: 80
keywords: [attach, upload, image, screenshot, paste, picture, add file, path, sftp, upload failed]
related: [composer, queued-messages, files-and-links, chat-mode]
---

You can send photos and files from your phone to an agent. Waycar uploads each one to your Host, then adds its path on the Host to your message, so the agent can open it like any other file.

## Attach photos or files

1. Open an agent and tap **Message Agent** to open the [Composer](/help/composer).
2. Tap **Add**, then choose **Add Image** or **Add File**.
3. Pick up to 10 per message.
4. Type a message if you like, then tap **Send**.

Each item shows as a chip above your message, a thumbnail for images, with its upload progress. When you tap **Send**, Waycar adds their Host paths after your text. You can send images with no text at all.

You can also paste: copy a screenshot, photo or file, then touch and hold in the Composer and tap **Paste** (or press ⌘V on a keyboard). Images and files join the same row of chips; text pastes into your message as usual. On iPad, you can also drag images into the Composer.

## Manage what you attached

- **Remove one**: tap its X.
- **A failed upload**: tap **Retry** on its chip.
- **Copy a path**: touch and hold a ready chip and tap **Copy Path**.

While the Composer is closed, the **Message Agent** button shows a badge with how many items are attached. The badge is red if one failed.

## How big can a file be?

Files can be up to 64 MiB each. Images are re-encoded as JPEG, or PNG when they have transparency, to fit under 16 MiB. If you pick more than 10 items, Waycar tells you the extras weren't added instead of dropping them silently.

## On a shell

On a plain shell, the uploaded file's path goes in at the cursor instead of after your text.

## What if the Host is offline?

If you send while the Host isn't connected, the message waits on your phone as Queued with its files copied onto the phone. The files upload before the message goes out. See [Queued messages](/help/queued-messages).

## Going the other way

Images, PDFs and Markdown files the agent prints show up in the preview strip under the terminal. See [Files and links](/help/files-and-links).

## Troubleshooting

Tap a failed chip (it shows a red exclamation mark) to see why it failed. Waycar offers **Retry** when the upload can be retried, and **Remove**:

| Message | What to do |
| --- | --- |
| "SFTP is unavailable on this Host. Enable its SSH SFTP subsystem." | Uploads use SFTP. Turn on the SFTP subsystem in the Host's SSH server, then attach the file again. |
| "The Host is not connected. Reconnect, then retry the upload." | Reconnect to the Host, then tap **Retry**. |
| "The image could not be reduced below the 16 MiB upload limit." | Send a smaller or cropped image. |
| "The selected file exceeds the 64 MiB upload limit." | Send a smaller file. |
| "The selected item is not a readable image." | Pick a different image. |
| "The selected photo is no longer available." | Remove the chip and pick the photo again. |
