# iSmith v1 acceptance runbook

The 12 checks from BUILD_PLAN.md, on your real accounts. Each step says what to do, what you
should see, and what to send back if you don't. Keep Brave installed throughout; don't delete
anything from it.

**When something fails**, send: the step number, what you saw (a screenshot helps), and the time.
For sign-in problems, also copy the last lines of Settings (⌘,) ▸ Accounts ▸ Sync log.

**Before you start**
1. Quit iSmith if it's running. In the repo: `git pull && make install`.
2. Open iSmith from /Applications. If it asks about Brave on first run, leave that for check 5.
3. Make sure your four spaces exist in the rail: Contoso, Fabrikam, Personal, Newtro Studios
   (right-click a space to edit it; "+" adds one).

---

## 1. Default browser and links from Teams and Outlook

1. Settings ▸ Links ▸ **Make Default** (or the bar at the top of a window). macOS asks "Do you
   want to change your default web browser to iSmith?": choose **Use "iSmith"**.
   - See: Settings ▸ Links says iSmith is the default. System Settings ▸ Desktop & Dock ▸ Default
     web browser shows iSmith.
   - Report if: the status still says it isn't the default, or Safari/Brave still opens links.
2. In Settings ▸ Links, add rules (Add Rule…): `dev.azure.com/contoso-dev` → Contoso, and
   Fabrikam's SharePoint host (the part before the first `/` of a SharePoint link, such as
   `<tenant>.sharepoint.com`) → Fabrikam. Set the Default space to Personal.
3. In the Teams and Outlook **desktop apps** (or Slack, Mail), click. (Links clicked inside
   iSmith stay in the space of the tab you clicked them in; only links from other apps are
   routed.)
   - an Azure DevOps work item link → opens in **Contoso**, as a new tab, signed in;
   - a Fabrikam SharePoint link → opens in **Fabrikam**, signed in;
   - an Etsy link → opens in the space you last used Etsy in;
   - any other link (a news site) → opens in **Personal**.
   - Report if: a link lands in the wrong space, opens two tabs, opens a blank tab, or asks you
     to sign in.
4. From a desktop app, click two links of the same kind that have no rule (say two
   `github.com/<org>/…` links) so they land in Personal, and move each to Contoso (right-click
   the tab ▸ Move Tab to Space).
   - See: a bar "Always open … in Contoso?". Click **Always Open in Contoso**; the next such link
     from a desktop app goes there directly.
   - Report if: no bar after the second move, or the next link still opens in Personal.

## 2. Outlook in Contoso and Fabrikam after a reboot

1. Open Outlook (outlook.office.com) in Contoso and in Fabrikam. Each shows its own
   mailbox. The tab shows a bolt (Keep alive).
2. Restart the Mac. Open iSmith.
   - See: both Outlook tabs come back on their own mailboxes, with no sign-in page or account
     picker, and the rail shows unread badges.
   - Report if: either asks you to sign in, picks the wrong account, or shows the other
     tenant's mailbox. Include the Sync log.

## 3. A new space is already signed in

1. Click "+" in the rail, name it "Test", leave every account on **Shared with all spaces**, and
   click **Create Space**.
2. In it, open gmail.com, outlook.office.com and github.com.
   - See: all three signed in. Gmail and Outlook may show their account picker once; pick the
     account and it's remembered for that space.
   - Report if: any of them asks for a password.
3. Delete the Test space afterwards (right-click it in the rail ▸ Delete Space…).

## 4. Etsy shop 1 in Personal, shop 2 in Newtro Studios

1. In Personal open etsy.com and sign in to shop 1 (if not already). In Newtro Studios, shop 2.
2. Quit iSmith, reopen it, and check both again the next day.
   - See: Personal shows shop 1 and Newtro Studios shows shop 2, both signed in, every time.
   - Report if: one space shows the other shop, or either is signed out.

## 5. Brave bookmarks and passwords; autofill on 10 sites

1. File ▸ Import from Brave… Pick your profile, the space for bookmarks (Personal), tick
   Bookmarks and Passwords, Continue. macOS asks once to let iSmith read Brave's data (Allow) and
   for your Mac password for "Brave Safe Storage" (Always Allow).
   - See: the result screen's counts. Bookmarks appear in the bar and ⌥⌘B. ⌥⌘P lists the
     passwords.
   - Check the counts: in Brave, Settings ▸ Passwords ▸ Export passwords, and count the CSV's
     rows; iSmith's "added + already there + updated + kept" should match, minus rows reported as
     skipped (Android apps, empty passwords). Brave's bookmark manager count should match too.
   - Report if: counts differ (send both numbers), or macOS's question never appears.
2. Sign out of 10 everyday sites (one at a time) and sign back in using only autofill: click the
   username field, pick the login from the popover (or press ⌘\\).
   - See: the fields fill and you're signed in. A new site's password is offered in a "Save
     password?" bar after you sign in.
   - Report if: no popover, the wrong login, or no save bar (name the site).
3. In ⌥⌘P, click Show on one password.
   - See: Touch ID or your Mac password is asked first.
   - Report if: the password shows without asking.

## 6. Ads blocked, work sites fine

1. Visit cnn.com, youtube.com (play a video), weather.com and reddit.com.
   - See: no banner ads; the shield in the address bar is filled.
   - Report if: ads appear (name the site and where), or a page is broken.
2. Use Outlook, Teams, the Azure portal, Azure DevOps, Gmail, Etsy and GitHub as normal.
   - See: everything works. If a site misbehaves, click its shield to turn blocking off for that
     site and reload. Report which site needed it.

## 7. Quit and reopen with 40 tabs

1. Have about 40 tabs across the four spaces, some in groups (right-click a tab ▸ Add Tab to New
   Group), one group collapsed, and a second window (⌘N).
2. Quit (⌘Q) and reopen iSmith.
   - See: both windows, every space's tabs in the same order, the groups with their names and
     colours (collapsed still collapsed), and Back still works in a tab you'd navigated in. Only
     the visible and Keep alive tabs load straight away; others load when you click them.
   - Report if: anything is missing or out of place.
3. Leave it running for an hour with all 40 tabs, then in the repo run `Tools/memory.py`. It
   sums iSmith and only its own WebKit processes (Activity Monitor lists those separately and
   mixes in Mail's and Safari's). The total should stay under 3 GB once you've left most tabs
   alone (background tabs are unloaded after 30 minutes, and beyond the 15 most recently shown
   after a minute). Switching spaces should feel instant.
   - Report if: the total stays above 3 GB (send the line it prints), or a space switch visibly
     lags.

## 8. Everyday browser features and a Teams call

1. Download a file (⌥⌘L shows the panel), print a page (⌘P), find text (⌘F), zoom (⌘+ / ⌘−,
   remembered for the site), open a PDF link, and upload a file to a site (an attachment in
   Outlook or Azure DevOps).
   - Report if: any of them fails (which, and on which site).
2. Join a Teams meeting in the Teams tab (with a colleague or a test meeting). Allow the camera
   and microphone when the bar asks, then share your screen.
   - See: they see and hear you, and see your shared screen.
   - Report if: the camera, microphone or screen sharing doesn't work, or the meeting asks for
     the Teams app.

## 9. Notifications in the background, and a call ringing

1. In Teams and Outlook, allow notifications when the bar asks (or Settings ▸ Websites ▸
   Notifications ▸ Allow). The first time, macOS asks to allow notifications for iSmith: Allow.
2. Switch to another app (iSmith in the background, or in another space).
   - See: a chat message and a new email each show a macOS notification with the site and space.
     Clicking it brings that tab forward.
3. Ask someone to call you on Teams while the Teams tab is in the background.
   - See: it rings, and you can answer.
   - Report if: no notification, or the call doesn't ring until you open the tab.

## 10. Links to Teams, Office apps and mail

1. Click a Teams meeting "Join" link, a Word document's "Open in Desktop App", and a `mailto:`
   link.
   - See: the first time each, a bar "… wants to open Microsoft Teams" (or Word, Mail). Click
     **Open …**: the app opens. The next click opens it straight away.
   - Report if: nothing happens, the wrong app opens, or it keeps asking.

## 11. An update through Sparkle

Needs the first signed release from P7. When it's published:
1. iSmith ▸ Check for Updates…
   - See: the new version offered; Install and Relaunch; the About box shows the new version, and
     your tabs come back.
   - Report if: an error, or the update doesn't install.

## 12. A week without Brave

Use iSmith for everything for a week. Keep a note of each time you reach for Brave and why (a
site that didn't work, a missing feature). Send the list at the end of the week, even if it's
empty.
