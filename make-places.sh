#!/bin/sh
# Makes Diptych/Places.tsv: the towns of 15,000 people or more, with their
# region and country, from GeoNames -- what the flat view's city, state and
# country fall back on for a picture or video that has a location but no
# place names written into it. Looked up on this Mac; nothing is asked of
# any service while Diptych runs.
#
# build.sh runs it when the version changes or the list is a month old;
# commit the result. Diptych merges it into ~/.diptych/exif/places.json,
# the copy a user can correct, on the first start of each version.
# GeoNames' data is CC BY 4.0: https://www.geonames.org
set -eu

out="$(cd "$(dirname "$0")" && pwd)/Diptych/Places.tsv"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
base=https://download.geonames.org/export/dump

cd "$work"
curl -sSfLO "$base/cities15000.zip"
curl -sSfLO "$base/countryInfo.txt"
curl -sSfLO "$base/admin1CodesASCII.txt"
unzip -q cities15000.zip

{
    printf '# Towns of 15,000 people or more, from GeoNames (https://www.geonames.org), CC BY 4.0.\n'
    printf '# Made by make-places.sh on %s. C: country; R: region; P: GeoNames id, latitude, longitude, country, region, name.\n' \
        "$(date +%Y-%m-%d)"
    # Countries: ISO code and name.
    awk -F'\t' '!/^#/ && $1 != "" { printf "C\t%s\t%s\n", $1, $5 }' countryInfo.txt
    # Regions: "HU.05" and name.
    awk -F'\t' '{ split($1, code, "."); printf "R\t%s\t%s\t%s\n", code[1], code[2], $2 }' \
        admin1CodesASCII.txt
    # Places, to four decimals: about ten metres. Not the districts of a
    # city (PPLX) -- a photo from Budapest's 15th district is from Budapest
    # -- nor places that were and are no more.
    awk -F'\t' '$8 !~ /^PPL(X|H|Q|W|CH)$/ {
        printf "P\t%s\t%.4f\t%.4f\t%s\t%s\t%s\n", $1, $5, $6, $9, $11, $2 }' cities15000.txt
} > "$out"

echo "$(grep -c '^P' "$out") places written to $out"
