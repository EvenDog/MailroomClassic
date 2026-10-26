# Mailroom Classic

A small, free macOS email app that looks and works like **classic Outlook**: folders on the left, a message list in the middle, a reading pane on the right, and a simple toolbar. No calendar and no clutter, just email.

It works with:

- **Any standard IMAP/SMTP account**, such as [MXroute](https://mxroute.com)
- **Gmail** (with an app password)
- **Office 365 / Exchange Online** (with "Sign in with Microsoft")

## Features

- Three-pane layout with unread mail in **bold**, unread counts on folders, and paperclip and red-flag columns
- Formatted (HTML) emails, displayed safely:
  - JavaScript is off
  - Links open in your browser
  - Pictures from the internet are blocked until you click **Download Pictures**, because senders use them to track when you read their mail
- Attachments: click to open, right-click to save, and attach files when you write. Forwarding keeps the original attachments.
- New Email, Reply, Reply All and Forward, with Outlook-style quoting of the original message
- Formatted writing (bold, italic, underline, fonts, colors) from the **Format** menu, sent as HTML with a plain-text copy
- Save Draft (⌘S) to your Drafts folder, and pick up where you left off with **Edit Draft**
- Search the current folder (sender, subject and message text), searched on the server
- **Show Older Messages** loads 50 more at a time
- Mark as read/unread (⇧⌘U), flag (⇧⌘L), and Delete. Delete moves mail to Trash; deleting from Trash removes it for good, after asking.
- Select several messages at once (⌘-click, ⇧-click) to delete, move, flag or mark them together
- Move messages by dragging them onto a folder, or right-click → **Move To**
- Checks for new mail automatically (every 1–30 minutes, or manually), with a notification for new mail and the unread count on the Dock icon
- Edit an account's settings at any time; changes are tested before they're saved
- Plain-English error messages (e.g. "Couldn't connect to … Check the server name")
- Send/Receive button and a status bar
- Keeps one connection open per account, so clicking around is quick
- Passwords and sign-in tokens are stored only in the **macOS Keychain**
- Saved attachments are marked as downloaded from the internet, so macOS checks them before they can run
- No analytics and no servers of its own: the app only talks to your mail providers

## Requirements

- macOS 15 (Sequoia) or newer
- Xcode 26 or newer, to build it

## Build and run

1. Clone this repository.
2. Open `MailroomClassic.xcodeproj` in Xcode.
3. Press **⌘R**. The first build downloads the [SwiftMail](https://github.com/Cocoanetics/SwiftMail) package, so it takes a minute or two.

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

- Search looks in one folder at a time
- Closing a compose window doesn't ask whether to save the draft first
- Opening a message downloads its attachments too, so very large attachments make it slow to open

## App icon

The icon is drawn by code. To change it, edit `scripts/make-icon.swift`, then run:

```sh
swift scripts/make-icon.swift MailroomClassic/Assets.xcassets/AppIcon.appiconset
```

## Credits

Built on [SwiftMail](https://github.com/Cocoanetics/SwiftMail) by Cocoanetics (BSD 2-Clause License).

## License

[MIT](LICENSE). Free to use, change and share.
