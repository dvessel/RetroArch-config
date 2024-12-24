# Automatic sans-outlines

The xmb icon theme "Automatic" uses a recurring 4 pixel outline. The modified pdf files removes them for a cleaner presentation. Only the modified files located here.

To generate png files from the pdf source, make sure you have imagemagick installed and enter the following:

```
mogrify -density 288 -resize 25% -format png *.pdf
```

If the files do not endup being 256x256 pixels, make sure the pixel density is 72ppi when editing the PDF.

Theme source files taken from [baxy-retroarch-themes](https://github.com/baxysquare/baxy-retroarch-themes).
