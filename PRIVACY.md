# Privacy

MusicOrganizer is a local-first tool. It does not require an account, a login or an API key.

## What stays local

- Music files, file names, folder paths and embedded tags are read/written only inside the
  folders you explicitly authorize.
- The library index cache and the write/undo journal are stored in the app's private data
  directory.
- Settings are stored locally on the device.

## What may be sent when you use online features

Only when you explicitly run **match tags**, **find cover** or **find lyrics**, the app sends the
minimum query needed to the enabled public sources:

- title / artist / album / duration (taken from the file or its file name)
- no file path, no file content, no device identifier, no account information

Sources: MusicBrainz, Deezer, iTunes, NetEase Cloud Music, QQ Music, Kugou, Kuwo, Migu
(tags); LRCLIB, NetEase Cloud Music, QQ Music, lyrics.ovh (lyrics). You can disable any
source in **Settings → Data sources**.

## Logs

Logs are local. Before being written or exported they are sanitized: local paths,
`content://` / `file://` URIs, UNC paths and credential-like `key=value` pairs are removed.
You can view, export or clear logs in **Settings → Logs**.

## Contact

For privacy questions, open a regular issue. For security-sensitive reports, use the private
channel described in [SECURITY.md](SECURITY.md).
