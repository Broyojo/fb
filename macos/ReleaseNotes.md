# fb for macOS 0.1.0

fb is a standalone local file browser for Apple Silicon Macs running macOS 26
or later. It presents documents, source code, spreadsheets, databases, and
archives in a readable interface.

- Open files and folders from Finder, the Desktop, Open With, or File → Open.
  Dropped items are opened at their original locations; multiple items open
  separate windows.
- Read Markdown with math, office documents, notebooks, EPUB books, highlighted
  source code, calendars, and supported PDF, image, audio, and video files.
- Browse spreadsheets, SQLite databases, and archives. Run read-only SQL
  queries against supported tabular formats.
- Use native Back/Forward, Reload, Find, zoom, Reveal in Finder, and Save a Copy.
  The most recent location is remembered across launches.
- The Go rendering engine and Pandoc 3.12.1 are bundled in the app. No local
  web server, listening port, Homebrew installation, or separate Pandoc setup
  is required.

Place `fb.app` in your Applications folder and open it. Browsing uses your
account's filesystem access and normal macOS privacy permissions. Local
documents and math work offline; linked remote resources and map tiles need
an internet connection. Conversion caches may use temporary files. Git
annotations are optional and require Git to be available.

The app is a viewer: browsing and SQL queries leave original documents
unchanged. Save a Copy writes to the destination you select. Some formats
have display or size limits; the interface reports limits where applicable.

Existing users of the deprecated Homebrew server can stop its login service
with `brew services stop fb`. For a service installed from a source checkout,
run `./service.sh uninstall` there. The standalone app does not need either
service, and stopping them does not remove documents.

Pandoc and other bundled components retain their respective licenses. See the
dependency notices and corresponding source materials supplied with the
distribution.
