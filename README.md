# Mailroom Classic

A small, free macOS email app that looks and works like **classic Outlook**: folders on the left, a message list in the middle, a reading pane on the right, and a simple toolbar. No calendar and no clutter, just email.

It works with:

- **Any standard IMAP/SMTP account**, such as [MXroute](https://mxroute.com)
- **Gmail** (with an app password)
- **Office 365 / Exchange Online** (with "Sign in with Microsoft")

## Features

- Three-pane layout with unread mail in **bold**, unread counts on folders, and paperclip and red-flag columns
- Click the From, Subject or Received column header to sort by it. When sorted by From or Subject, type a letter to jump to it
- Drag column headers to reorder them, drag their edges to resize, and right-click the header row to hide or show columns; the layout is remembered
- Sorted by date, messages are grouped under classic Outlook headings: Today, Yesterday, the days earlier this week, Last Week, Two Weeks Ago, Three Weeks Ago, Earlier This Month, Last Month, Older. Click the arrow next to a heading to collapse or expand its group
- **All Inboxes**: every account's Inbox in one list, newest first, with the total unread count. Search, delete, flag, Junk and Move To all work there too (Move To only offers folders in the message's own account).
- Reading pane on the right or at the bottom (**View → Reading Pane**)
- Print (⌘P) with an Outlook-style header; the print dialog can also save as PDF
- Formatted (HTML) emails, displayed safely:
  - JavaScript is off
  - Links open in your browser
  - Pictures from the internet are blocked until you click **Download Pictures**, because senders use them to track when you read their mail
- Attachments: click to open, right-click to save, and attach files when you write. Forwarding keeps the original attachments. Attachments only download when you open, save or forward them, so big ones don't slow down reading.
- New Email, Reply, Reply All and Forward, with Outlook-style quoting of the original message
- Formatted writing (bold, italic, underline, fonts, colors) from the **Format** menu, sent as HTML with a plain-text copy
- Save Draft (⌘S) to your Drafts folder, and pick up where you left off with **Edit Draft**. Closing an unsent email asks whether to save it.
- A signature for each account (Settings → Edit), added to new emails, replies and forwards
- The To and Cc fields suggest people you've emailed before, or whose mail you've opened
- Search: matches in sender, recipients and subject appear instantly from the saved copy, then the server's results (which also search the message text, and older mail) are added
- Folders inside folders (like Gmail's nested labels) show as a tree you can expand, and each account can be collapsed (hover over its name). Everything except Inbox, Drafts, Sent, Trash and Junk sits in a collapsible **More Folders** group under each account
- Right-click a folder for **New Folder**, **Rename Folder**, **Delete Folder** and **Mark All as Read**, plus **Empty Trash** / **Empty Junk** on those folders. Right-click an account's name to make a top-level folder. (Inbox, Drafts, Sent, Trash, Junk and All Mail can't be renamed or deleted.)
- **Rules** (Settings → Rules): "if From / Subject / To or Cc contains ___, move it to [folder]", with Edit and Remove for each rule. They run on new mail in the Inbox after each check; **Run Rules Now** also applies them to what's already there.
- Trusts the server's own labels for Drafts, Sent, Trash and Junk, so a folder you named "Drafts" isn't mistaken for the real one
- **Keeps the last 12 months of mail headers on your Mac** (like Outlook's offline file), so folders open instantly. Your folder list and unread counts are saved too, so the app opens straight to your mail, even with no internet. It syncs with the server in the background: your Inboxes after every check, and every other folder at least every 30 minutes. Message text is downloaded ahead of time too, in the background (newest first, with progress in the status bar), so messages open instantly and can be read offline. All Mail, Spam and Trash are skipped; their messages are saved once you open them. Attachments download when you open them.
- **Show Older Messages** fetches mail older than 12 months from the server, 50 at a time
- Mark as read/unread (⇧⌘U), flag (⇧⌘L), and Delete. Delete moves mail to Trash; deleting from Trash removes it for good, after asking.
- Select several messages at once (⌘-click, ⇧-click) to delete, move, flag or mark them together
- Move messages by dragging them onto a folder, or right-click → **Move To**
- **Junk** button (⇧⌘J) moves mail to the Junk folder; in the Junk folder it becomes **Not Junk** and moves mail back to the Inbox
- Checks for new mail automatically (every 1–30 minutes, or manually), with a notification for new mail and the unread count on the Dock icon
- Edit an account's settings at any time; changes are tested before they're saved
- Closing a compose window, or quitting (⌘Q), with an unsent email asks before anything is lost
- Plain-English error messages (e.g. "Couldn't connect to … Check the server name")
- If logging in keeps failing, the app waits longer between tries (1, then 5, then 15 minutes) instead of retrying every few seconds, so a busy server (like Gmail slowing down an account) gets a rest and a wrong password doesn't get your IP address blocked
- Send/Receive button and a status bar
- Keeps connections open to each account, so clicking around is quick: one for opening messages, and one for everything else (checking, syncing, moving), so a message never waits behind background work
- Passwords and sign-in tokens are stored only in the **macOS Keychain**
- Saved attachments are marked as downloaded from the internet, so macOS checks them before they can run
- No analytics and no servers of its own: the app only talks to your mail providers
- The saved copy is at `~/Library/Application Support/MailroomClassic/MailCache.sqlite`. Deleting that file is safe: the app downloads everything again.

## Requirements

- macOS 15 (Sequoia) or newer
- Xcode 26 or newer, to build it

## Build and run

1. Clone this repository.
2. Open `MailroomClassic.xcodeproj` in Xcode.
3. Choose your own signing team: click the project → **MailroomClassic** target → **Signing & Capabilities** → **Team**. (A free Apple account works. Signing with a real certificate means macOS recognizes each new build as the same app, so it doesn't ask for your Keychain password every time you rebuild.)
4. Press **⌘R**. The first build downloads the [SwiftMail](https://github.com/Cocoanetics/SwiftMail) package, so it takes a minute or two.

## Adding accounts

Open **Mailroom Classic → Settings…** (⌘,) and choose an account type.

**Have a setup file?** Many providers (MXroute included) offer an Apple configuration profile (a `.mobileconfig` file). Click **Import Profile…** and the form fills itself in; usually you only need to type your password. If the profile names a server that doesn't exist, Mailroom Classic warns you.

### Other (IMAP/SMTP), e.g. MXroute

Enter your incoming (IMAP) server, which is usually port 993, and your password. The outgoing (SMTP) server defaults to the same host on port 465. For MXroute, use your MXroute server name (something like `xxx.mxrouting.net`), which is in your welcome email or control panel. A name like `mail.yourdomain.com` only works if you've set that up in your domain's DNS.

### Gmail

Gmail won't accept your normal password from apps like this one. Instead:

1. Turn on [2-Step Verification](https://myaccount.google.com/security) for your Google account.
2. Create an app password at [myaccount.google.com/apppasswords](https://myaccount.google.com/apppasswords).
3. Paste that 16-character password into the **App password** field.

### Office 365 / Exchange Online

Microsoft only allows OAuth ("Sign in with Microsoft") for IMAP and SMTP. That means each copy of the app needs a **client ID** from a free app registration in Microsoft's Azure portal. You create the registration once.

> These steps reflect Microsoft's portal as of late 2026. Microsoft rearranges it often, so labels may differ slightly.

1. Sign in to the [Microsoft Entra admin center](https://entra.microsoft.com) or the [Azure portal](https://portal.azure.com). A free Azure account works.
2. Go to **App registrations → New registration**.
   - **Name:** Mailroom Classic
   - **Supported account types:** *Accounts in any organizational directory and personal Microsoft accounts*
   - **Redirect URI:** choose **Public client/native (mobile & desktop)** and enter `mailroomclassic://oauth`
3. Click **Register**, then copy the **Application (client) ID** from the Overview page.
4. Optional: under **API permissions → Add a permission → Microsoft Graph → Delegated permissions**, add `IMAP.AccessAsUser.All`, `SMTP.Send` and `offline_access`. The app also asks for these when you sign in.
5. In Mailroom Classic's Settings, choose **Office 365**, paste the client ID, and click **Sign In with Microsoft…**.

**If your account belongs to an employer or school**, their IT department controls what's allowed:

- If sign-in says **"Need admin approval,"** your organization blocks apps it hasn't approved. Ask IT to approve the app.
- If reading mail works but **sending fails**, your mailbox may have *SMTP AUTH* turned off. IT can turn it on for your mailbox.
- Some organizations turn off IMAP entirely. In that case this app can't connect.

## Current limitations

- Search looks in one folder at a time (or every Inbox, from All Inboxes)
- Messages can't be moved between accounts
- A signature is added when the compose window opens, so switching the From account doesn't swap it

## App icon

The icon is drawn by code. To change it, edit `scripts/make-icon.swift`, then run:

```sh
swift scripts/make-icon.swift MailroomClassic/Assets.xcassets/AppIcon.appiconset
```

## Credits

Built on [SwiftMail](https://github.com/Cocoanetics/SwiftMail) by Cocoanetics (BSD 2-Clause License) and [GRDB](https://github.com/groue/GRDB.swift) by Gwendal Roué (MIT License).

## License

[MIT](LICENSE). Free to use, change and share.
