# Assets

Files Cyber uses that were not made in this repo. They are here so the desktop can be recreated
from the repo alone. **Check each licence before making the repo public or passing it on.**

| what | where | from | licence |
|---|---|---|---|
| Cursor set (48 Windows `.cur` files) | `assets/cursor/Yellow/` | the "Yellow" set of "Cyberpunk 2077 Cursor Set Pack" by NeonKatVT, downloaded from itch.io (fan-made) | the pack's own terms on its itch.io page; not an open licence as far as known |
| Wallpaper | `assets/wallpaper/neon-district.png`, the same picture as `greeter/themes/cyberpunk/wallpaper.png` | your own download | unknown: check its source |
| Live wallpaper "Cyberpunk City Rainy effect (V room)" | `assets/wallpaper/rainy-city/` (the web page) and `assets/wallpaper/rainy-city.mp4` (the loop rendered from it by `webpaper/render-video.sh`) | Steam Workshop item 3520089907 for Wallpaper Engine; the rain code is Codrops' RainEffect demo | the Workshop item's and Codrops' terms; the picture is game artwork |
| Kleemax (demo) font, the big clock digits | `greeter/themes/cyberpunk/fonts/kleemaxdemo.otf` | the font's demo download | personal use only |
| Oxanium, JetBrains Mono | `greeter/themes/cyberpunk/fonts/` | Google Fonts / JetBrains | SIL Open Font License (texts next to the files) |

Not in the repo, installed as packages: Share Tech Mono Nerd Font (`ttf-sharetech-mono-nerd`, OFL),
JetBrains Mono Nerd Font (`ttf-jetbrains-mono-nerd`, OFL), Bibata cursors (fallback shapes; they come
with end-4's installer).

To leave the restricted files out of a public copy, remove `assets/cursor/Yellow`, everything in
`assets/wallpaper`, the greeter's `wallpaper.png` and `kleemaxdemo.otf`: the cursor falls back to Bibata, the clock to Oxanium, and the
wallpaper path is in `cyber/config.json`.
