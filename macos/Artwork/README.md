# App artwork

`fb-icon.png` is the source artwork for the macOS Dock, Finder, and About icon.
It was generated with the installed OpenAI CLI using
`gpt-image-2.5-sunburst`, quality `max`, at 1024 × 1024 with a transparent
background. The exact prompt is in `icon-prompt.txt`.

To generate another version without overwriting the current master:

```sh
openai images generate \
  --model gpt-image-2.5-sunburst --quality max --size 1024x1024 \
  --background transparent --output-format png \
  --prompt "$(cat macos/Artwork/icon-prompt.txt)" \
  --output-dir macos/Artwork --name fb-icon-v2 --inline off
```

After choosing a master, regenerate the asset catalog with:

```sh
swift macos/Scripts/make-icon.swift
```

The asset catalog contains all standard macOS sizes. Resizing preserves the
generated artwork and its alpha channel; no API access is needed to build the app.
