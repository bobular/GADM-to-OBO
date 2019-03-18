#!/bin/env perl
#       -*- mode: Cperl -*-
#
# creates a simple "is_a" based ontology of GADM placenames and merges in high-level
# country relationships (regions, continents etc) from a separately maintained ontology
#
#
# usage: ./gadm-to-obo.pl --max-level 2 gadm36  > gadm36.obo
#
# will expect to find gadm36_0.* gadm36_1.* and gadm36_2.* in the current directory - see README
#
# option: --continents blah.obo  # needs to be an obo file that groups countries into regions, continents etc
#                                # the English country names must match the GADM country names to be any use
#                                # top level ontology maintained at: https://github.com/bobular/VB-top-level-GEO
#
#         --nodisambiguate       # don't change multiple "Santa Marias" into "Santa Maria (Argentina)", "Santa Maria (Brazil)" etc
#
# Terminology in the script:
#
# id : GADM GID
# accession : script-assigned ID like this GADM:0001234
#
#
# Limitations:
#
# Will not update a pre-existing ontology - so it's a one-shot wonder at the moment.
# However, this should be reasonably simple to add when needed.
#


use strict;
use warnings;
use Geo::ShapeFile;
use Text::Table;
use utf8::all;
use Getopt::Long;
use OBO::Core::Ontology;
use OBO::Core::Term;
use OBO::Core::Relationship;
use OBO::Core::RelationshipType;
use Encode;
use Encode::Detect::Detector;
use OBO::Parser::OBOParser;

my $max_level = 2;
my $accession_prefix = 'VBGEO';
my $continents_obofile = 'VB-top-level-GEO/VB-top-level-GEO.obo'; # get this from https://github.com/bobular/VB-top-level-GEO/
my $disambiguate = 1;

GetOptions("max-level=i"=>\$max_level,
           "continents-obofile=s"=>\$continents_obofile,
           "disambiguate!"=>\$disambiguate,
          );

my ($stem) = @ARGV;

die "can't find continents obo file '$continents_obofile'\n" unless (-s $continents_obofile);

my $obo_parser = OBO::Parser::OBOParser->new;
my $continents = $obo_parser->work($continents_obofile);
my $default_cparent = $continents->get_term_by_name('Earth');

my $ontology = OBO::Core::Ontology->new;
$ontology->name("Database of Global Administrative Areas");
$ontology->default_namespace($accession_prefix);

$ontology->add_relationship_type_as_string('is_a', 'is_a');

my %terms;      # ID (AGO.5_1) -> term object
my %accessions; # ID (AGO.5_1) -> accession string (GADM:0001234)
my $accession_counter = 1;

my %name2term_ids; # for dealing with multiple "Santa Maria"
my %name2level2parent_ids;

foreach my $level (0 .. $max_level) {

  my $shapefile = Geo::ShapeFile->new(join '_', $stem, $level);
  my $num_shapes = $shapefile->shapes;
  my $parent_level = $level-1;

  foreach my $index (1 .. $num_shapes) {
    my $dbf = $shapefile->get_dbf_record($index);

    my $term = OBO::Core::Term->new();
    my $id = $dbf->{"GID_$level"};
    my $name = cleanup($dbf->{"NAME_$level"} || "Unnamed ($id)");
    my $accession = sprintf "%s:%07d", $accession_prefix, $accession_counter++;

    $term->id($accession);
    $term->alt_id("GADM:$id");
    $term->name($name);

    my $synonyms = cleanup($dbf->{"VARNAME_$level"} // '');
    foreach my $synonym (split /\s*\|\s*/, $synonyms) {
      $term->synonym_as_string($synonym, "[GADM:$id]", "EXACT");
    }
    $ontology->add_term($term);


    $terms{$id} = $term; # cache it for adding relationships later
    $accessions{$id} = $accession;

    if ($parent_level >= 0) {
      my $parent_id = $dbf->{"GID_$parent_level"};
      if (my $parent_term = $terms{$parent_id}) {
        $ontology->create_rel($term, 'is_a', $terms{$parent_id});

        my $engtype = $dbf->{"ENGTYPE_$level"};
        my $parent_name = $parent_term->name;
        $term->def_as_string("$engtype in $parent_name", "[GADM:$id]");
      } else {
        die "Fatal error: parent term $parent_id does not exist!?...\n";
      }
    } else {
      $term->def_as_string("Country", "[GADM:$id]");

      # now look up higher level continent terms
      my $cterm = $continents->get_term_by_name($name);
      if ($cterm) {
        # great, let's recursively find the parents of $cterm in $continents
        # and make parallel new terms in the new $ontology
        link_to_continent_parents($continents, $cterm, $ontology, $term);
      } else {
        # OK let's just link it to "Earth"
        my $new_earth = find_or_copy_term($continents, $default_cparent, $ontology);
        $ontology->create_rel($term, 'is_a', $new_earth);
      }
    }

    # next unless ($name eq 'Magdalena'); # for debugging - see Data::Dumper below
    # record multiple name uses
    $name2term_ids{$name}{$id} = $level;
    # record multiple name uses at different parent levels
    for (my $l=0; $l<$level; $l++) {
      my $parent_id = $dbf->{"GID_$l"};
      $name2level2parent_ids{$name}[$l]{$parent_id}{$id} = $level;
    }
  }
}

#use Data::Dumper;
#print Dumper(values %name2level2parent_ids);
#exit;

#
# disambiguate 'Santa Maria' names
# by putting the highest level parent term possible in paretheses after it
# then adding the original name as a synonym
#

if ($disambiguate) {
  my %fixed_term_ids; # term_id => 1 if already processed

  foreach my $name (keys %name2term_ids) {
    my $ndupes = scalar keys %{$name2term_ids{$name}};
    if ($ndupes > 1) {
      warn "$ndupes dupes of $name\n";
      if ($ndupes < 3) {
        # first "mark as fixed" the highest level (e.g. country, adm1) term
        # without actually processing its name
        # this means that New York becomes "New York" and "New York (New York)"
        # instead of "New York (United States)" and "New York (New York (United States))"
        my %level2term_ids; # invert the hash
        while (my ($term_id, $level) = each %{$name2term_ids{$name}}) {
          $level2term_ids{$level}{$term_id} = 1;
        }
        my @levels = sort { $a<=>$b } keys %level2term_ids;
        my $highest_level = $levels[0];
        my @highest_level_term_ids = keys %{$level2term_ids{$highest_level}};
        if (@highest_level_term_ids == 1) {
          # finally mark it as "done"
          warn "not processing $name for $highest_level_term_ids[0] at level $highest_level\n";
          $fixed_term_ids{$highest_level_term_ids[0]} = $highest_level;
        }
      }

      # then process the remaining terms
      for (my $l=0; $l<$max_level; $l++) {
        foreach my $parent_id (keys %{$name2level2parent_ids{$name}[$l]}) {
          # find out which level terms are the children of this parent
          my @levels = sort { $a <=> $b } values %{$name2level2parent_ids{$name}[$l]{$parent_id}};
          # and make sure we only process the highest level (if mixed, like San Miguel in El Salvador)
          my $level = $levels[0];
          my @term_ids = grep { !exists $fixed_term_ids{$_} &&
                                  $name2level2parent_ids{$name}[$l]{$parent_id}{$_} == $level }
            keys %{$name2level2parent_ids{$name}[$l]{$parent_id}};
          if (@term_ids == 1) {
            my $term_id = $term_ids[0];
            my $term = $terms{$term_id};
            $term->name(sprintf "$name (%s)", $parent_id);
            warn sprintf "$l processed level %d term %s to %s\n", $name2term_ids{$name}{$term_id}, $name, $term->name;
            $term->synonym_as_string($name, "[GADM:$term_id]", "EXACT");
            $fixed_term_ids{$term_id} = $level; # so we don't fix this term again
          }
        }
      }
    }
  }

  # now replace all the GADM IDs with term names in the disambiguated names
  # start with the country terms (sort keys on level value)
  foreach my $term_id (sort { $fixed_term_ids{$a} <=> $fixed_term_ids{$b} } keys %fixed_term_ids) {
    my $term = $terms{$term_id};
    my $name = $term->name;
    $name =~ s/\((.+)\)$/'('.$terms{$1}->name().')'/e;
    $term->name($name);
  }

}

$ontology->export('obo', \*STDOUT);



sub cleanup {
  my $string = shift;
  my $charset = detect($string);
  if ($charset) {
    # if anything non-standard, use UTF-8
    $string = decode("UTF-8", $string);
  }
  # remove leading and trailing whitespace
  $string =~ s/^\s+//;
  $string =~ s/\s+$//;
  return $string;
}


#
# find_or_copy_term
#
# looks for $term in $destination_ontology
#
# if not found, create a new copy of that term in $destination_ontology
#
# returns the term from $destination_ontology (either the existing or newly created one)
#

sub find_or_copy_term {
  my ($source_ontology, $term, $destination_ontology) = @_;

  my $name = $term->name;

  if (my $existingterm = $destination_ontology->get_term_by_name($name)) {
    return $existingterm;
  } else {
    my $newterm = OBO::Core::Term->new();
    $newterm->name($name);
    my $accession = sprintf "%s:%07d", $accession_prefix, $accession_counter++;
    $newterm->id($accession);
    #    $newterm->def_as_string("Country/continent grouping term", "");
    $destination_ontology->add_term($newterm);
    return $newterm;
  }
}

#
# link_to_continent_parents
#
# for each parent term of $cterm in $continents
#   create that term in $ontology if required
#   link it to the
#

sub link_to_continent_parents {
  my ($continents, $cterm, $ontology, $term) = @_;

  foreach my $cparent (@{ $continents->get_parent_terms($cterm) }) {

    my $oparent = find_or_copy_term($continents, $cparent, $ontology);
    $ontology->create_rel($term, 'is_a', $oparent);

    # and recurse back up to the root of $continents
    link_to_continent_parents($continents, $cparent, $ontology, $oparent);
  }


}
