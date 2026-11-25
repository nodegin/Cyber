Put audio files for the login screen here.

  Artist - Title.mp3        (also .ogg .opus .flac .wav .m4a)
  Artist - Title.jpg        optional cover art with the same name
  cover.jpg                 optional cover for every track without its own

The login screen runs as the "greeter" user and cannot read your home folder,
so copy files here rather than symlinking into ~/Music. Track 1 is always the
built-in generative piece "Aurora", so the player works with this folder empty.

Autoplay is off by default; turn it on in /etc/canvasgreet/config.toml:

  [theme_options.music]
  autoplay = true
