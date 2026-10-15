# DansWriter

DansWriter is a native writing desk for macOS. It keeps a draft in the centre, with alternatives, notes, review tools and research alongside it.

## Features

- Focused editor with clean reading, light and dark themes, and optional typewriter sounds.
- Keep word, sentence and paragraph alternatives beside the original, with undo and redo.
- Dim passages or move them into an editable Overflow pane while you work.
- Native spelling and grammar, with local macOS Dictionary and Thesaurus access.
- Optional Codex or Claude suggestions, plus Lab proofreading, style marks and four trimming strengths. Review every proposed edit.
- Colour pasted material with Paste As labels that survive native saves.
- Local Markdown and HTML preview, including tables, tasks, Mermaid diagrams and charts.
- Optional Valyu research with source links, a separate journal and explicit insertion into the draft or Overflow.
- Native `.writeon` files, recovery, and Markdown or plain-text exports.
- Native sharing, X compose and LinkedIn drafts with text prefilled for review.
- Help → Check for Updates checks the public GitHub release channel when you ask.

## Download and install

[Download the latest release](https://github.com/danielctc/danswriter-mac/releases/latest). Open the DMG and drag DansWriter into Applications. Currently Mac only, for Apple silicon.

Release downloads are signed by Compare the Cloud Ltd using Developer ID. Apple notarisation status is stated in each release. The source and SHA-256 checksum are available with each release.

Want a Windows or Linux version? Open an issue describing your platform, or leave a comment wherever you found the release video.

## Requirements

- Apple silicon (arm64)
- macOS 13 or later
- Swift 5.9 or later and the Xcode Command Line Tools to build from source

The project uses native Swift and AppKit and has no Swift package dependencies.

## Build

From the repository directory, run:

```sh
bash scripts/check.sh
bash scripts/package-dmg.sh
```

The installer and its checksum are produced under `dist/`. Help → Check for Updates offers the DMG for a newer stable version. Quit DansWriter and replace the app to install it; your files stay in `~/Library/Application Support/DansWriter`. Updates do not install automatically.

## AI and research

AI features support either an installed command line wrapper that you have already configured, or your own API key saved in macOS Keychain. DansWriter does not include provider credentials. Subscription mode invokes the installed wrapper; API mode makes requests only after you choose an AI action. Building or running the checks does not make API calls.

Valyu research uses a separate key stored in Keychain. Each research task starts only when you choose to run it. Provider charges and account limits are controlled by the provider and your account.

See [PRIVACY.md](PRIVACY.md) for local storage and network behaviour, and [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md) for bundled component licences.

## Licence

DansWriter is available under the MIT licence. See [LICENSE](LICENSE).

## Signed release builds

For Developer ID distribution, set `DANSWRITER_SIGN_IDENTITY` to an installed signing identity and `DANSWRITER_NOTARY_PROFILE` to an existing notarytool Keychain profile, then run `bash scripts/notarize.sh`. The script signs with the hardened runtime, asks Apple to notarise the app and DMG, staples and validates their tickets, and generates the final checksum. Credentials stay in Keychain and are not included in the app or source.
