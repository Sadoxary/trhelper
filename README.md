# trhelper

A dialogue translator for Final Fantasy XI on **Ashita v4**, in the spirit of
[Tataru Helper](https://github.com/NightlyRevenger/TataruHelper) for FFXIV.

It shows NPC and cutscene dialogue, and the options of NPC selection menus,
translated into another language (Russian by default) in a separate on-screen box.
It is a reading aid for players who do not read English well. It does not play the
game for you in any way.

![](https://img.shields.io/badge/Ashita-v4-blue) ![](https://img.shields.io/badge/license-GPLv3-green)

## What it does NOT do

- It does **not** send, modify or block any packets.
- It does **not** write to game memory.
- It does **not** send keyboard, mouse or controller input to the game, and does not
  automate any action.
- It does **not** reveal hidden information (no mob tracking, positions, drop data, etc.).
  It only shows text that the game is already displaying to the player.
- It does **not** change any in-game text. The original dialogue box and chat stay untouched.

## How it works

### 1. Capturing dialogue
The addon registers the Ashita `text_in` event and looks only at NPC conversation /
cutscene chat modes (150 and 151 by default, configurable). The line is cleaned of FFXI
color codes, auto-translate tags are expanded with `IChatManager:ParseAutoTranslate`, and
the Shift-JIS text is converted to UTF-8. The event is never blocked or modified.

### 2. NPC selection menus (read-only memory read)
The question and options of an NPC selection menu (e.g. a gate guard's
"What is your business?") are not sent to the chat log. While the event system is
active, the addon **reads** that text from the game's static dialogue text buffer
(`FFXiMain.dll + 0x489109`), using `ffi.string` on that fixed address. Nothing is written.

To know when the menu is on screen it uses two read-only signatures that are already
used by the approved addon XIUI (`core/gamestate.lua`): the event-system flag and the
current game menu name. A menu left over from an earlier conversation is ignored.

This part can be turned off with `/tr menu`.

### 3. Translation
Each new line is written to a temporary text file and translated by a **hidden
`curl.exe` process** (bundled with Windows 10/11) started via `ashita.misc.execute`, so
the game never waits on the network. The request goes to Google Translate:

```
https://clients5.google.com/translate_a/t?client=dict-chrome-ex&sl=auto&tl=<lang>&q=<line>
```

Only the dialogue line itself is sent: no character name, account, position or any
other data. Results are cached in `cache_<lang>.txt` (plain `original<TAB>translation`
lines), so repeated dialogue is shown instantly and never requested again. The cache can
be edited by hand to fix a translation.

### 4. Display
Ashita font objects only render Latin glyphs, so the text is drawn with Windows GDI
(any installed font, full Unicode) into a 32-bit TGA in the addon's `tmp` folder and
displayed through an Ashita primitive. The texture is rebuilt only when the displayed
text changes. The settings window uses ImGui.

## Installation

1. Copy the `trhelper` folder into `Ashita/addons/`.
2. In game: `/addon load trhelper` (or add it to your startup script).

Requires Windows 10 or newer (for `curl.exe`) and an internet connection.

## Usage

`/tr` opens the settings window. The box can be moved with the mouse
(Shift + drag changes its width, Shift + wheel the font size).

| Command | Description |
|---|---|
| `/tr` | Open / close the settings window |
| `/tr box` | Show / hide the translation box |
| `/tr (on \| off)` | Enable / disable translation |
| `/tr lang <code>` | Target language (`ru`, `uk`, `de`, ...) |
| `/tr src <code>` | Source language (`auto`, `en`, `ja`) |
| `/tr orig` | Show the original text under the translation |
| `/tr menu` | Toggle translation of NPC selection menus |
| `/tr lines <n>` | Number of dialogue lines kept on screen |
| `/tr hide <sec>` | Clear the box after `<sec>` seconds without dialogue (0 = never) |
| `/tr top` / `/tr grow` | Line order / grow direction of the box |
| `/tr width <px>`, `/tr size <px>`, `/tr alpha <0-100>`, `/tr font <name>`, `/tr bold` | Appearance |
| `/tr pos <x> <y>` | Box position |
| `/tr modes`, `/tr mode (add \| del) <id>` | Chat modes that are translated |
| `/tr debug` | Log incoming lines with their chat mode to `debug.log` |
| `/tr test <text>` | Translate a test line |
| `/tr clear` | Clear the box |
| `/tr help` | List all commands |

## Files

| File | Purpose |
|---|---|
| `trhelper.lua` | The addon |
| `cache_<lang>.txt` | Translation cache (created at runtime) |
| `tmp/` | Temporary request / response / texture files (cleared on load) |
| `debug.log` | Only when `/tr debug` is on |

## License

GPLv3, see [LICENSE.md](LICENSE.md). Uses the libraries bundled with Ashita v4.
