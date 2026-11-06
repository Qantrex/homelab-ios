# App icon

"h + LED" (owner's pick, 2026-11-06, from three directions in the design research): a white lowercase h with one
love-pink light (#EB6F92) above its right leg, on near-black. `AppIcon.svg` is the source; `Resources/AppIcon.png` is
rendered from it (1024 px, RGB without alpha):

    rsvg-convert -w 1024 -h 1024 docs/icon/AppIcon.svg -o /tmp/icon.png
    python3 -c "from PIL import Image; Image.open('/tmp/icon.png').convert('RGB').save('Resources/AppIcon.png')"

iOS makes the dark and tinted variants itself from this one image (xtool takes a single PNG).
