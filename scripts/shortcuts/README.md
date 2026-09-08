# Dictation clipboard workflows

These editable plists are the source of the signed `.shortcut` resources bundled
in `Muesli/Resources/Shortcuts`. They invoke the matching host's dictation toggle,
copy its nonempty transcript, then invoke Muesli's post-copy notification action.
Starting capture returns no output; stopping waits for that recording's transcript.

After changing a plist, regenerate its bundled resource on a Mac:

```sh
shortcuts sign --mode anyone \
  --input 'scripts/shortcuts/MuesliDev Dictation to Clipboard.plist' \
  --output 'Muesli/Resources/Shortcuts/MuesliDev Dictation to Clipboard.shortcut'
```

Repeat for the production `Muesli` file. Preserve the correct bundle identifier
and the output UUID references in each workflow. App updates do not replace
user-imported workflows: import the updated resource in Shortcuts and replace
its earlier version, then check the Action Button assignment.

Muesli notification permission is required for the transcript banner. The copy
operation is performed by Apple's Shortcuts action and has its own permission.
