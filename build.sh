#!/bin/sh

if ! [ -x "$(command -v uglifyjs)" ]
then
  echo "This build script requires uglifyjs."
  echo "You can install it with"
  echo " "
  echo "  npm -g uglifyjs"
  echo " "
  exit 1
fi
# assume perl and tr are everywhere.

perl -i -pe 's{(<script id="q">)(.*)(</script>)}{$1.`uglifyjs -b quote_style=3,beautify=0 config.js| tr -d "\n"`.$3}e' lifx_driver.be
