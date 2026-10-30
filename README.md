# Mailroom Classic

A small, free macOS email app that looks and works like **classic Outlook**: folders on the left, a message list in the middle, a reading pane on the right, and a simple toolbar. No calendar and no clutter, just email.

It works with:

- **Any standard IMAP/SMTP account**, such as [MXroute](https://mxroute.com)
- **Gmail** (with an app password)
- **Office 365 / Exchange Online** (with "Sign in with Microsoft")
- **Proton Mail** (through the Proton Mail Bridge app, which needs a paid Proton plan)

## Download

Get the latest **MailroomClassic-x.y.dmg** from the [Releases page](https://github.com/EvenDog/MailroomClassic/releases), open it, and drag **Mailroom Classic** into **Applications**. It's signed and notarized by Apple, so it opens normally. Needs macOS 15 or newer on an Apple Silicon (M-series) Mac.

From version 0.5 on, Mailroom Classic updates itself: about once a day it checks for a new version and offers to install it (**Mailroom Classic → Check for Updates…** checks right away; Settings → General → Updates turns the daily check off).

## Features

- Three-pane layout with unread mail in **bold**, unread counts on folders, and paperclip and red-flag columns
- Click the From, Subject or Received column header to sort by it. When sorted by From or Subject, type a letter to jump to it
- Drag column headers to reorder them, drag their edges to resize, and right-click the header row to hide or show columns; the layout is remembered
- Sorted by date, messages are grouped under classic Outlook headings: Today, Yesterday, the days earlier this week, Last Week, Two Weeks Ago, Three Weeks Ago, Earlier This Month, Last Month, Older. Click the arrow next to a heading to collapse or expand its group
- **All Inboxes**: every account's Inbox in one list, newest first, with the total unread count. Search, delete, flag, Junk and Move To all work there too (Move To only offers folders in the message's own account).
- **Search Folders**, like classic Outlook's: **Unread Mail**, **Flagged** and **Has Attachments** in the sidebar under All Inboxes gather matching mail from every account and folder (except Trash, Junk, Drafts and Gmail's All Mail), with a Folder column showing where each one lives. They read the copy saved on this Mac, so they open instantly and cover the last 12 months; an email Gmail keeps under several labels shows once. A message you read in Unread Mail stays in the list until you leave the folder
- Reading pane on the right or at the bottom (**View → Reading Pane** or Settings → Reading)
- Double-click a message (or press Return, or right-click → **Open**) to open it in its own window, with Reply, Reply All, Forward and Print. Double-clicking a draft opens it for editing
- **All / Unread / Flagged** above the message list shows only the mail you want. A message you're reading stays in the list until you click another one
- Print (⌘P) with an Outlook-style header; the print dialog can also save as PDF
- **View → Message Source** (⌥⌘U) shows the complete original email: every header (the servers it passed through, spam checks), then the body. Useful for working out where an email really came from. It doesn't mark the email as read
- Make message text bigger or smaller with ⌘+ and ⌘− (or the small **A A** buttons beside the subject); the size is remembered
- Web and email addresses in plain-text emails are clickable: web pages open in your browser, and an email address starts a new email
- Formatted (HTML) emails, displayed safely:
  - JavaScript is off
  - Links open in your browser. Hovering over a link shows where it really goes, in a small bar at the bottom. If a link's text shows one web address but it goes to a different site (a common scam trick), clicking it asks before opening it
  - Pictures from the internet are blocked until you click **Load Pictures**, because senders use them to track when you read their mail. Click **Always from This Sender** to show them straight away in that sender's future emails (except in Junk); Settings → Reading lists those senders, with Remove for each
- Attachments: click to open, right-click to save, and attach files when you write (with the paperclip, or by dragging files onto the compose window). Forwarding keeps the original attachments. Attachments only download when you open, save or forward them, so big ones don't slow down reading.
- New Email, Reply, Reply All and Forward, with Outlook-style quoting of the original message
- **Undo Send**: a sent email waits 10 seconds first (change it, or turn it off, in Settings → General → Sending), with a countdown and **Undo** in the status bar. Undo reopens it so you can fix it. If sending fails, the email reopens with the reason. Quitting sends any email that's still waiting
- Email links: clicking an email address on a website or in another app starts a new email here, once you click **Use Mailroom Classic** in Settings (macOS asks you to confirm)
- Formatted writing (bold, italic, underline, fonts, colors) from the **Format** menu, sent as HTML with a plain-text copy
- Spell check as you type (red underlines; right-click a word for suggestions)
- Save Draft (⌘S) to your Drafts folder, and pick up where you left off with **Edit Draft**. Closing an unsent email asks whether to save it.
- A signature for each account (Settings → Edit), added to new emails, replies and forwards. Picking a different From account swaps in that account's signature (unless you've edited it)
- The To and Cc fields suggest people you've emailed before, or whose mail you've opened, plus everyone in the Mac's **Contacts** app (including Google or iCloud contacts added under System Settings → Internet Accounts). macOS asks once for permission
- The reading pane shows the sender's photo from Contacts, and an **Add to Contacts** button (the person icon next to their address) for senders who aren't there yet
- **Unsubscribe**: newsletters that say how to leave their mailing list get an Unsubscribe button next to the sender's name. After asking, Mailroom unsubscribes in one click, sends the list's unsubscribe email for you, or opens their unsubscribe page in your browser, whichever the email offers. Not shown in Junk, since unsubscribing from spam only confirms your address
- **Send Later**: the clock menu next to Send schedules an email for in an hour, tomorrow morning, Monday morning, or a date and time you choose. It waits in the **Outbox** (in the sidebar while anything is waiting), where you can Edit, Send Now or Delete it. Mail servers can't send an email later by themselves, so Mailroom Classic must be open at that time; if it was closed (or the Mac was asleep), the email goes out as soon as the app is open again, and the status bar says so
- **Follow Up** (toolbar or right-click): flags a message with a due date (Today, Tomorrow, This Week, Next Week, or a date and time you choose) and a reminder notification at 9:00 AM that day (or the time you chose), even if the app is closed. The due date shows in the list (in red once it's due) and in the Compact list's **Due** column. Clear Flag removes it. The flag syncs to your other devices; the due date and reminder stay on this Mac
- Search: matches appear instantly from the saved copy (sender, recipients, subject, and the text of messages that have been downloaded, so nearly all of the last 12 months), then the server's results (which also cover older mail) are added
- Search **All Folders** (the choice under the search box) looks through every folder of every account at once, with a Folder column showing where each message is. It searches the saved copy only (the last 12 months, message text included), because asking every folder's server would mean dozens of requests
- **Search filters**: the filter button beside the Comfortable/Compact buttons (or any search) opens a bar with **From**, **Date** (Today, Last 7 days, Last 30 days, This year or a custom range) and **Has attachments**. They narrow down whatever the list shows, a folder, All Inboxes, a Search Folder or search results, so they work with the search box empty too. Choose **All Folders** in the bar to look through every folder at once (the mail saved on this Mac, the last 12 months). Closing the bar clears them
- Folders with unread mail show in bold with the count, like classic Outlook: **Inbox (3)**. A collapsed account shows its Inbox's count next to its name
- Folders inside folders (like Gmail's nested labels) show as a tree you can expand, and each account can be collapsed (hover over its name). Everything except Inbox, Drafts, Sent, Trash and Junk sits in a collapsible **More Folders** group under each account
- Right-click a folder for **New Folder**, **Rename Folder**, **Delete Folder** and **Mark All as Read**, plus **Empty Trash** / **Empty Junk** on those folders. Right-click an account's name to make a top-level folder. (Inbox, Drafts, Sent, Trash, Junk and All Mail can't be renamed or deleted.)
- **Rules** (Settings → Rules): "if From / Subject / To or Cc contains ___, move it to [folder]" (or mark it as read, flag it, or delete it), with Edit and Remove for each rule. Move rules work within the folder's own account; the others apply to every account's Inbox. They run on new mail in the Inbox after each check; **Run Rules Now** also applies them to what's already there.
- Trusts the server's own labels for Drafts, Sent, Trash and Junk, so a folder you named "Drafts" isn't mistaken for the real one
- **Keeps the last 12 months of mail headers on your Mac** (like Outlook's offline file), so folders open instantly. Your folder list and unread counts are saved too, so the app opens straight to your mail, even with no internet. It syncs with the server in the background: your Inboxes after every check, and every other folder at least every 30 minutes (or right away with **Mailbox → Sync All Folders Now**, ⇧⌘N). Message text is downloaded ahead of time too, in the background (newest first, with progress in the status bar), so messages open instantly and can be read offline. All Mail, Spam and Trash are skipped; their messages are saved once you open them. Attachments download when you open them.
- **Show Older Messages** fetches mail older than 12 months from the server, 50 at a time
- Settings → General → **Appearance**: Match System, Light or Dark, or one of three softer in-between themes: **Dim** (blue-grey), **Dusk** (warm charcoal) and **Mist** (muted light grey). The themes color the folder list, message list and reading pane; emails with their own white background still show white
- Two message list styles, switched with the two icons above the list or in **View → Message List**: **Comfortable** (two-line rows with the sender, time, subject and a preview, like Apple Mail, with a Sort menu) and **Compact** (one line per message in sortable, rearrangeable columns, with short Outlook-style dates such as "Sat 4:53 PM"; hover over a date to see it in full)
- **Show as Conversations** (View menu or Settings → Reading): each email's replies are tucked under the newest message of the conversation, with an arrow to show them and a count like (3), in bold if any of them are unread. Replies are matched by the emails' References header, or by subject for "Re:"/"Fwd:" emails. Works while the list is sorted by date
- **Preview Text** (View menu or Settings → Reading, on at first): the start of each message's text in grey after its subject, like classic Outlook's AutoPreview
- Messages are marked as read when you view them, or only after a few seconds (Settings → Reading), so clicking past a message leaves it unread
- **Color categories**, like classic Outlook: Categorize (toolbar or right-click) puts Red, Orange, Yellow, Green, Blue or Purple on messages, several at once if you like. They show as colored dots in the list (and a Categories column in Compact) and as named labels in the reading pane. Rename them in Settings → Categories. They're saved on the mail server as IMAP keywords (e.g. `$CategoryRed`), so they survive reinstalls and show on other Macs running Mailroom Classic; Gmail's website and the iPhone's Mail app don't display them. The names stay on this Mac
- Mark as read/unread, flag, categorize, delete and move all show on screen straight away, while the server catches up in the background; if the server refuses, the messages go back to how they were and the status bar says why
- After you delete or move a message, the next one is selected, like classic Outlook, so you can work through your mail pressing Delete. It shows in the reading pane but stays unread until you click in the reading pane. Turn this off in Settings → Reading → **After deleting or moving a message**
- Mark as read/unread (⇧⌘U), flag (⇧⌘L), and Delete. Delete moves mail to Trash; deleting from Trash removes it for good, after asking.
- **Edit → Undo (⌘Z)** after a delete, move or Junk puts the messages back where they were
- Select several messages at once (⌘-click, ⇧-click) to delete, move, flag or mark them together
- Move messages by dragging them onto a folder, or right-click → **Move To**, even into another account (the message is copied there whole, attachments included, and the original goes to the first account's Trash; these moves can't be undone with ⌘Z)
- **Junk** button (⇧⌘J) moves mail to the Junk folder; in the Junk folder it becomes **Not Junk** and moves mail back to the Inbox
- **Push**: new mail in each account's Inbox, Sent and Drafts shows up within seconds (using IMAP IDLE, with one extra connection per folder). Turn it off in Settings → General → Checking for Mail. Read/flag changes made elsewhere, and the other folders, update at the regular check
- Checks for new mail automatically (every 1–30 minutes, or manually), with a notification for new mail and the unread count on the Dock icon. Clicking a notification opens that email
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
- Scheduled emails (and copies of their attachments) are kept in `~/Library/Application Support/MailroomClassic/Outbox/`. Don't delete that folder while emails are waiting in it.

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

Microsoft only allows OAuth ("Sign in with Microsoft") for IMAP and SMTP, so there's no password field. In Settings, choose **Office 365**, enter your name and email address, and click **Sign In with Microsoft…**. Microsoft's own sign-in page opens; after you sign in and accept, Mailroom Classic stays signed in.

Personal Outlook.com, Hotmail and Live accounts work the same way.

**Using your own client ID (optional):** Mailroom Classic signs in with its own Azure app registration. If you'd rather use yours, create one in the [Microsoft Entra admin center](https://entra.microsoft.com) with **Supported account types** set to *any organizational directory and personal Microsoft accounts* and a **Public client/native (mobile & desktop)** redirect URI of `mailroomclassic://oauth`. Then paste its **Application (client) ID** into the optional client ID field.

**If your account belongs to an employer or school**, their IT department controls what's allowed:

- If sign-in says **"Need admin approval,"** your organization blocks apps it hasn't approved. Ask IT to approve the app.
- If reading mail works but **sending fails**, your mailbox may have *SMTP AUTH* turned off. IT can turn it on for your mailbox.
- Some organizations turn off IMAP entirely. In that case this app can't connect.

### Proton Mail

Proton Mail encrypts your mail, so other apps can't read it from Proton's servers directly. Proton's free **Proton Mail Bridge** app (part of paid Proton plans) runs on your Mac, decrypts your mail, and acts as a mail server on this Mac (`127.0.0.1`) that Mailroom Classic connects to.

1. Install [Proton Mail Bridge](https://proton.me/mail/bridge), sign in, and leave its connection settings at their defaults (ports 1143 and 1025, STARTTLS). Let it finish synchronizing.
2. Trust Bridge's security certificate, which it makes itself. In Bridge, choose **Settings → Advanced settings → Export TLS certificates**, double-click the exported certificate to add it to Keychain Access, then double-click it there (it's named `127.0.0.1`), open **Trust**, and set **When using this certificate** to **Always Trust**.
3. In Mailroom Classic's Settings, choose **Proton Mail (Bridge)**, and enter the username (your Proton address) and the **password Bridge shows under Mailbox details**, not your Proton password.

Bridge must be open whenever Mailroom Classic checks or sends mail.

## Current limitations

- Follow Up due dates and reminders are kept on this Mac only: IMAP has no standard place to store them, so other devices just see a flag
- Scheduled emails only go out while the app is open
- Searching All Folders doesn't find mail older than 12 months (searching one folder does), or text inside All Mail, Spam and Trash messages you haven't opened (their text isn't downloaded ahead of time)

## Making a release

`scripts/make-release.sh` builds the Release version, signs it with a Developer ID certificate, packs it into a DMG in `build/dmg/`, sends it to Apple for notarization, attaches Apple's approval, and adds the new version to `appcast.xml` (the list the built-in updater checks). It needs a one-time `xcrun notarytool store-credentials` (see the top of the script) and the Sparkle signing key in the login Keychain. Before running it, raise `MARKETING_VERSION` in the Xcode project: the updater compares version numbers. Then attach the DMG to a new release on GitHub, and only after that commit and push `appcast.xml`, so the updater never offers a download that isn't there yet.

`scripts/sign-sparkle.sh` (run by the release script) signs Sparkle's helper programs inside the app with the Developer ID certificate; Apple's notarization rejects them otherwise.

## App icon

The icon is drawn by code. To change it, edit `scripts/make-icon.swift`, then run:

```sh
swift scripts/make-icon.swift MailroomClassic/Assets.xcassets/AppIcon.appiconset
```

## Credits

Built on [SwiftMail](https://github.com/Cocoanetics/SwiftMail) by Cocoanetics (BSD 2-Clause License) [GRDB](https://github.com/groue/GRDB.swift) by Gwendal Roué (MIT License), and [Sparkle](https://github.com/sparkle-project/Sparkle) (MIT License) for updates.

## License

[MIT](LICENSE). Free to use, change and share.
