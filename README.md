# SleepMusic

SleepMusic is a macOS menu-bar app that turns the MacBook notch into a compact Spotify player, synchronized lyric display, Sleep Mode surface, and on-device Quick Assistant.

## Requirements

- macOS 26 or newer
- Xcode 26 or newer
- Spotify for the music controls and now-playing information
- Internet access for artwork and lyrics
- Apple Intelligence enabled on a supported Mac for general assistant questions

The built-in Spotify and Sleep Mode commands still work when Apple Intelligence is unavailable.

## Getting started

1. Open `SleepMusic.xcodeproj` in Xcode.
2. Select the `SleepMusic` scheme and `My Mac` destination.
3. Build and run the app.
4. Allow Automation access when macOS asks for permission to control Spotify.
5. Look for the moon icon in the menu bar.

The app is an accessory application, so it does not appear in the Dock.

## Keyboard shortcuts

| Shortcut | Action |
| --- | --- |
| `⌥ Space` | Open or close Quick Assistant from anywhere |
| `Return` | Submit the assistant command or question |
| `Esc` | Close Quick Assistant |
| Any key or click | Leave Sleep Mode |

## Quick Assistant

Press `⌥ Space` or choose **Open Quick Assistant** from the menu-bar menu. The assistant appears beneath the notch with its text field focused.

### Spotify commands

| Action | Accepted commands |
| --- | --- |
| Toggle playback | `play`, `pause`, `play or pause`, `toggle music`, `toggle playback` |
| Next track | `next`, `next song`, `skip`, `skip song`, `skip track` |
| Previous track | `previous`, `previous song`, `previous track`, `go back` |
| Show current track | `what song is playing?`, `what is playing?`, `now playing` |

Spotify commands are processed locally and do not require Apple Intelligence.

### Sleep Mode commands

Use a command containing `sleep mode`, such as:

- `Enter Sleep Mode`
- `Start Sleep Mode`
- `Open Sleep Mode`

Spotify must have a current track before Sleep Mode can start.

### Help commands

- `help`
- `what can you do`

### General questions

When Apple Intelligence is available, Quick Assistant uses Apple's on-device Foundation Models framework to answer general questions. Responses are intentionally kept concise for the notch-sized interface.

The assistant automatically receives limited context about:

- The current Spotify track and playback state
- The currently synchronized lyric line
- Clipboard text when the request contains the word `clipboard`

Examples:

- `Summarize my clipboard`
- `Rewrite my clipboard more professionally`
- `Explain this lyric`
- `Who is the artist currently playing?`
- `Give me three ideas for a relaxing evening`

Clipboard content is limited to the first 8,000 characters and is only read when explicitly requested.

### Conversations

Quick Assistant keeps the current conversation visible as user and assistant message bubbles, so follow-up requests such as `Make that shorter` or `Give me more detail` retain the recent conversational context. Responses include compact context chips when Spotify, the current lyric, the clipboard, or attached files contributed to an answer.

Assistant responses can be copied, saved as plain text, shared, or retried. Choose **New Conversation** from the conversation menu to clear the current thread and its attachments.

Conversation history is kept in memory for the current app session by default. To restore it after relaunching SleepMusic, enable **Keep History on This Mac** from the conversation menu. This opt-in history is stored locally and can be removed by turning the option off or starting a new conversation.

### Calendar notes

Click the calendar button in Quick Assistant, choose **Add calendar note**, or type a command such as `add dentist appointment to my calendar tomorrow at 3 PM`. Review the title, optional notes, date, time, all-day setting, and duration before saving to the default macOS calendar.

Calendar access is requested only when the first entry is saved. SleepMusic requests write-only access and cannot read existing calendar events. Creating entries works offline when the destination calendar is stored locally; cloud calendars sync when their service is available.

### Intelligent file drop

Open Quick Assistant, then drag one or more supported files anywhere onto its card. The assistant remains visible while Finder is active. You can also click the paperclip button and choose multiple files manually.

You can also drag one or more supported files directly onto the physical MacBook notch, even when Spotify is not playing. The notch expands to show **Drop to convert**; releasing shows a compact convert card where you pick an output format. Converted files are saved next to the originals, or into a folder you choose for multi-page PDFs.

Supported inputs:

- PDF documents
- Images such as PNG, JPEG, HEIC, TIFF, GIF, and BMP
- Plain-text documents
- Source-code files
- Audio files such as MP3, M4A, AAC, WAV, AIFF, CAF, and FLAC

After analysis, the attached-file toolbar provides these actions:

| Action | Result |
| --- | --- |
| **Summarize** | Creates a concise summary of the extracted file content |
| **Explain** | Explains the file's content in plain language |
| **Extract text** | Displays the locally extracted text without requiring Apple Intelligence |
| **Suggest a filename** | Suggests a descriptive filename based on the content |
| **Enhance Photo** | Improves tone, color, noise, and detail locally while keeping the original untouched |
| **Remove Background** | Isolates the foreground subject and saves it on a transparent background |
| **Open Image Editor** | Erases or restores selected areas and replaces the background with transparency, a color, blur, another photo, or an Apple Intelligence-generated scene |
| **Change Background Color** | Type `change the background color to blue` (or use a hex color) to isolate the subject and save a recolored PNG automatically |
| **Generate Background** | Type `replace the background with a quiet beach at sunset` to open Image Playground with that description, then approve a result to apply it |
| **Convert** | Converts the attachment to a compatible output format and saves it where you choose |

For an attached image, open the **Image** menu. Choose **Open Image Editor** (or type `edit image`) for background and object edits, or choose **Enhance Photo** (or type `enhance photo`) for an automatic cleanup. The editor and its automatic foreground detection work entirely on-device.

Conversion formats:

- Images → PNG, JPEG, TIFF, or PDF
- PDFs → PNG, JPEG, TIFF, or plain text
- Text and source code → PDF
- Audio → WAV, AIFF, or CAF

Use the **Convert** menu or a command such as `convert to PNG`, `convert to PDF`, `convert to text`, or `convert to WAV`. Multi-page PDFs are exported as numbered images into a folder you choose. Audio conversion happens locally with macOS Core Audio. MP3, M4A, AAC, and FLAC can be accepted as inputs when their codec is available on the Mac; native MP3/AAC encoding is not offered. After conversion, use the overflow menu to reveal the output in Finder.

When multiple files are attached, the Convert menu shows only formats supported by the entire batch. Choose a destination folder once; converted files are named from their sources, and multi-page PDF images are organized into per-document subfolders.

### Converted-file actions

After a conversion, open the attachment toolbar's overflow menu to:

- Reveal converted outputs in Finder
- Copy one or more converted files to the clipboard
- Compress converted outputs into a ZIP archive
- Rename a single converted output without changing the original attachment

The **After Conversion** submenu can automatically reveal, copy, or compress every successful conversion. The selected action is remembered between launches. Choose **Do Nothing** to turn automation off.

These actions also accept Quick Assistant commands:

- `copy converted files`
- `compress converted files`
- `rename converted file`
- `after conversion reveal in Finder`
- `after conversion copy to clipboard`
- `after conversion compress to ZIP`
- `turn after conversion actions off`

Images use Apple's local Vision OCR. PDFs use their embedded text when available and OCR for up to the first five scanned pages. The assistant reads up to 20 PDF pages, stores at most 40,000 extracted characters, and sends at most 12,000 characters into an individual on-device assistant prompt.

You can also ask your own questions while a file is attached, for example:

- `What are the important dates in this PDF?`
- `Turn this document into a checklist`
- `Find spelling mistakes in this file`
- `Explain this source code`

Remove all attached files with the close button in the attachment toolbar.

## Notch player

When Spotify opens, SleepMusic displays a compact indicator around the physical MacBook notch. Hover over it to expand the full player.

The expanded player includes:

- Album artwork
- Track title and artist
- Live playback progress and remaining time
- Shuffle
- Previous track
- Play or pause
- Next track
- Repeat
- Current synchronized lyric line

The notch automatically hides when Spotify closes.

## Lyrics

SleepMusic fetches synchronized lyrics from LRCLIB and follows Spotify's estimated playback position. The current line appears in the expanded notch player and in Sleep Mode.

Lyrics depend on a matching synchronized entry being available for the current track.

## Sleep Mode

Sleep Mode presents a fullscreen music surface containing the current track and synchronized lyrics.

You can start it from:

- The menu-bar command **Enter Sleep Mode**
- Quick Assistant using a command containing `sleep mode`

SleepMusic also observes screen lock, unlock, sleep, and wake events while music is playing. While locked, it presents a click-through player that does not intercept password input and temporarily prevents idle display/system sleep. Forced sleep from closing the lid, choosing Sleep, low battery, or thermal protection is always respected.

Lock-screen placement uses the private SkyLight window-space API through the pinned SkyLightWindow package. This is the same class of mechanism used by dedicated macOS lock-screen widget apps, but it can require maintenance after major macOS updates.

Press any key or click to dismiss Sleep Mode.

## Menu-bar commands

- Current Spotify track and artist, or `Not Playing`
- **Enter Sleep Mode**
- **Open Quick Assistant**
- **Launch at Login**
- **Quit SleepMusic**

## Privacy and permissions

- Spotify control uses Apple Events and requires macOS Automation permission.
- Calendar notes use write-only EventKit access and cannot read existing events.
- General assistant responses use Apple's on-device model when available.
- Conversation history is not persisted unless **Keep History on This Mac** is enabled; saved history remains local.
- Clipboard text is read only for assistant requests that mention `clipboard`.
- Lyrics and artwork require network access.
- SleepMusic's lock-screen surface never reads or intercepts password input.

## Project structure

```text
SleepMusic/
├── App/          App entry point and service coordinator
├── Models/       Audio and lyric data types
├── Services/     Spotify, lyrics, assistant, hotkey, audio, and window services
├── ViewModels/   Player and lyric state
└── Views/        Menu-bar, notch, assistant, and Sleep Mode interfaces
```

The Xcode project is generated from `project.yml` with XcodeGen:

```sh
xcodegen generate
```

Command-line build:

```sh
xcodebuild \
  -project SleepMusic.xcodeproj \
  -scheme SleepMusic \
  -configuration Debug \
  -destination 'platform=macOS' \
  CODE_SIGNING_ALLOWED=NO \
  build
```
