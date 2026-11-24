# Tame Player

A live TV player with a full TV guide for Xtream Codes subscriptions. Built in Flutter, so one app runs on Google TV / Android TV (Onn, NVIDIA Shield), Android phones, Windows laptops, and later iPhone and Mac.

## Getting the app

Every time code is pushed to `main`, GitHub builds the app automatically (see the **Actions** tab). When the build finishes, the files appear under **Releases**:

- **Windows:** download `TamePlayer-Windows.zip`, unzip it, and open `tame_player.exe`.
- **Android / Google TV:** install `TamePlayer.apk`.

## What's in this version (0.1)

- Sign in with Xtream Codes (server, username, password); add more than one subscription and switch between them
- All your groups and channels, with logos
- TV guide that starts at the current half hour, with a live progress bar, "minutes left", and NEXT
- Channel preview at the top; full screen with an info bar
- Groups menu, Favorites, 12/24-hour time, Focus effect (Subtle / Full / Off)
- Works with a TV remote, a keyboard (arrows, Enter, Esc, M, F, P), a mouse, or touch

## Coming next

Pause that keeps your place and Go to Live, From the beginning / catch-up, Multiview, recording, reminders, search, What's on now, hide/rename/reorder channels, parental controls, sync between devices.

## Controls

| Remote / keyboard | What it does |
|---|---|
| ▲ ▼ | Channels |
| ◀ ▶ | Earlier / later shows (◀ at the left edge opens Groups) |
| OK / Enter | Watch; OK again for full screen |
| Back / Esc | Close menus, leave full screen; twice to exit |
| ☰ / M | Groups menu |
| F | Favorite |
| ⏯ / P | Pause / play |
