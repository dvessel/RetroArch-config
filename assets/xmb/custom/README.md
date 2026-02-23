# Automatic sans-outlines

The xmb theme "Automatic" uses a recurring 4 pixel outline. This custom theme removes those outlines for a cleaner presentation.

Source svg files converted from [baxy-retroarch-themes](https://github.com/baxysquare/baxy-retroarch-themes) pdf sources. This was done to maintain the correct canvas size. The original svg source files were inconsistent in its dimensions.

Rasterizing to png was done through `swiftdraw`. Install with `brew install swiftdraw`

```zsh
cd pathto/RetroArch/assets/xmb/custom/source

for svg in baxy-automatic/*.svg
do
        input=$svg
        output=../png/$svg:t:r.png
        if [[ -f sans-outlines/$svg:t ]]
        then
                input=sans-outlines/$svg:t
        fi
        swiftdraw $input --format png --size 500x500 --output $output
done
```

### Modifications
 * The 4 pixel outlines have been removed.
 * PNG sizing bumped to 500x500 for high density displays.
 * Font replaced with [Lilex](https://github.com/mishamyrt/Lilex), modified through Nerd Fonts.

