# Privacy

DansWriter has no analytics or telemetry. It does not send drafts or credentials in the background.

## Local data

Automatic recovery drafts and saved research reports are stored on your Mac in `~/Library/Application Support/DansWriter/`. Files you open, save or export remain at the locations you choose. Preferences are stored in macOS preferences. AI provider credentials and the separate Valyu credential are stored in macOS Keychain; credentials are not included in project files or recovery drafts.

## Network requests

Network requests happen after you choose an action:

- AI writing actions send the text needed for that action to the provider selected in Settings. Subscription mode uses the command line tool installed and configured on your Mac. API mode sends requests to the selected provider using your own key from Keychain.
- Research sends the query you enter to Valyu using your separate Valyu key. Results and source references can be saved locally for later review.
- The Compare the Cloud footer link opens the publisher’s website only when clicked.
- “Check for Updates” checks the public GitHub release metadata when you select it. It does not download or install an update automatically.
- Sharing to X or LinkedIn opens a compose URL containing the selected text or, if no text is selected, the current draft. The text can appear in the browser address, browser history and the destination service. DansWriter also copies a backup to the clipboard. Review the compose screen before posting.

Provider services receive requests under their own terms and privacy policies. Choose whether to send text before starting an AI or research action.

## No bundled user data

Public source releases do not include a user's drafts, API keys, Keychain contents or personal configuration. Build and local checks do not call AI or research APIs.
