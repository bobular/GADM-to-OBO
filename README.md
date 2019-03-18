# Script to process GADM into an OBO-format 'ontology'

This will create a simple "is_a" hierarchy of placenames in GADM.

If you maintain a separate ontology of country-continent
relationships, like we do at
https://github.com/bobular/VB-top-level-GEO then this script merge
that in and create the relevant new terms and relationships in the
ontology that it outputs.


## Data sources

Data from

* https://gadm.org/download_world.html
* https://biogeo.ucdavis.edu/data/gadm3.6/gadm36_levels_shp.zip

unzip the levels you need, e.g.

    unzip gadm36_levels_shp.zip gadm36_[012].*

Also get the "continents" ontology from https://github.com/bobular/VB-top-level-GEO


## Running the script

Assuming the script and unpacked data files are in the current
directory, and the path 'VB-top-level-GEO/VB-top-level-GEO.obo' is
also valid (otherwise, see the --continents option) run the script
like this:

    ./gadm-to-obo.pl --max-level 2 gadm36  > gadm36.obo


--max-level 2 will process levels 0 (country), 1 (ADM1) and 2 (ADM2)

More usage details at the top of the script itself.


## Limitations

The script currently does a one-shot generation of an ontology file.
It doesn't have the ability to update an existing ontology (and
deprecate any unused terms) but this should be relatively easy to add.
