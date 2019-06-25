#!/usr/bin/env perl
use 5.14.0;
use Carp;
use Cwd;
use File::Spec;
use Getopt::Long;
use Archive::Tar;
use Data::Dump qw(dd pp);
use JSON;
use Path::Tiny;
use Text::CSV_XS;

=head1 NAME

analyze-json-files-one-run.pl - Create F<.psv> file from F<.json> files created from run of F<cpanm>

=head1 USAGE

    perl analyze-json-files-one-run.pl \
        --results_dir="$HOMEDIR/var/tad/results" \
        --perl_version=perl-5.30.0-RC2 \
        --title=cpan-river-3000 \
        --sep_char='|' \
        --verbose

=head1 DESCRIPTION

This program presumes that the user has (i) built a F<perl> from source, (ii)
installed F<cpanm> against that F<perl>, (iii) installed a set of CPAN
distributions against that F<perl> using F<cpanm> as the installer, (iv) used
a program such as F<parse-one-build-log.pl> to parse the F<cpanm> F<build.log>
into a set of F<.json> files, one per distribution installed.

The user wants to write a delimiter-separated (F<.csv> or F<.psv>) file
summarizing the results of that run in a manner similar to CPAN distribution
F<Test::Against::Dev>).

=head2 Results

The program will first, as a safety precaution, archive the F<.json> files and
place the resulting F<.json.tar.gz> file in the F<storage> subdirectory (see
below).

The program will then write a pipe- or comma-delimited file with the following
columns and place the resulting F<.psv> or F<.csv> file in the F<storage>
subdirectory (see below).

=head1 PREREQUISITES AND ASSUMPTIONS

=head2 Prerequisites

=over 4

=item *

F<perl> 5.14.0 or higher (core distribution used: F<Carp>, F<Cwd>, F<File::Spec>, F<Getopt::Long>)

=item * F<cpanm> utility installed against that F<perl>

=item * CPAN distributions: F<Archive::Tar>, F<Data::Dump>, F<JSON>, F<Path::Tiny>, F<Text::CSV_XS> 

=back

=head2 Assumptions

=over 4

=item * Environment variable: C<$HOMEDIR>

=item *

A directory structure like this:

    ../results/perl-5.30.0-RC2/
    ../results/perl-5.30.0-RC2/analysis
    ../results/perl-5.30.0-RC2/storage

The path to the F</results> directory will be specified on the command-line by
the C<results_dir> switch.  The C<perl_version> switch will hold a value like
C<perl-5.30.0-RC2> in the example above.

The F<analysis> subdirectory is the location of the already extant F<.json> files.

    analysis/AAR.Net-LDAP-Server-0.43.log.json
            /ABELTJE.V-0.13.log.json
            /ABEVERLEY.Dancer2-Plugin-Auth-Extensible-0.708.log.json
            /ABH.Mozilla-CA-20180117.log.json
            /ABIGAIL.Geography-Countries-2009041301.log.json

=back

=head1 AUTHOR

James E Keenan (jkeenan at cpan dot org).  Copyright 2019.  All rights reserved.

=cut

my ($results_dir, $perl_version, $title, $sep_char, $verbose) = ("") x 5;

GetOptions(
	"results_dir=s"	    => \$results_dir,
    "perl_version=s"    => \$perl_version,
    "title=s"           => \$title,
    "sep_char=s"        => \$sep_char,
    "verbose"           => \$verbose
) or croak("Error in command line arguments");

croak "Could not locate results directory $results_dir" unless -d $results_dir;
croak "Must specify perl_version on command-line" unless length $perl_version;
croak "Must specify title on command-line" unless length $title;
unless ($sep_char eq '|' or $sep_char eq ',') {
    carp "'sep_char must be either pipe (|) or comma (,); defaulting to pipe";
    $sep_char = '|';
}

my $vresults_dir = "$results_dir/$perl_version";
my $self = {
    title => $title,
    perl_version => $perl_version,
    vresults_dir => $vresults_dir,
    storage_dir => "$vresults_dir/storage",
    analysis_dir => "$vresults_dir/analysis",
};

for my $dir ( 'vresults_dir', 'storage_dir', 'analysis_dir' ) {
    my $d = $self->{$dir};
    croak "Could not locate $d" unless -d $d;
}

if ($verbose) {
    say "results_dir: $results_dir";
    dd($self);
}

# As a precaution, we archive the log.json files.

my $output = join('.' => (
    $self->{title},
    $self->{perl_version},
    'log',
    'json',
    'tar',
    'gz'
) );
my $foutput = File::Spec->catfile($self->{storage_dir}, $output);
say "Output will be: $foutput" if $verbose;

my $vranalysis_dir = $self->{analysis_dir};
opendir my $DIRH, $vranalysis_dir or croak "Unable to open $vranalysis_dir for reading";
my @json_log_files = sort map { File::Spec->catfile('analysis', $_) }
    grep { m/\.log\.json$/ } readdir $DIRH;
closedir $DIRH or croak "Unable to close $vranalysis_dir after reading";
dd(\@json_log_files) if $verbose;

my $versioned_results_dir = $self->{vresults_dir};
chdir $versioned_results_dir or croak "Unable to chdir to $versioned_results_dir";
my $cwd = cwd();
say "Now in $cwd" if $verbose;

my $tar = Archive::Tar->new;
$tar->add_files(@json_log_files);
$tar->write($foutput, COMPRESS_GZIP);
croak "$foutput not created" unless (-f $foutput);
say "Created $foutput" if $verbose;

# Having archived our log.json files, we now proceed to read them and to
# write a pipe- (or comma-) separated-values file summarizing the run.

my %data = ();
for my $log (@json_log_files) {
    my $flog = File::Spec->catfile($cwd, $log);
    my %this = ();
    my $f = Path::Tiny::path($flog);
    my $decoded;
    {
        local $@;
        eval { $decoded = decode_json($f->slurp_utf8); };
        if ($@) {
            say STDERR "JSON decoding problem in $flog: <$@>";
            eval { $decoded = JSON->new->decode($f->slurp_utf8); };
        }
    }
    map { $this{$_} = $decoded->{$_} } ( qw| author dist distname distversion grade | );
    $data{$decoded->{dist}} = \%this;
}
#pp(\%data);

my $cdvfile = join('.' => (
    $self->{title},
    $self->{perl_version},
    (($sep_char eq ',') ? 'csv' : 'psv'),
) );

my $fcdvfile = File::Spec->catfile($self->{storage_dir}, $cdvfile);
say "Output will be: $fcdvfile" if $verbose;

my @fields = ( qw| author distname distversion grade | );
my $perl_version = $self->{perl_version};
my $columns = [
    'dist',
    map { "$perl_version.$_" } @fields,
];
my $psv = Text::CSV_XS->new({ binary => 1, auto_diag => 1, sep_char => $sep_char, eol => $/ });
open my $OUT, ">:encoding(utf8)", $fcdvfile
    or croak "Unable to open $fcdvfile for writing";
$psv->print($OUT, $columns), "\n" or $psv->error_diag;
for my $dist (sort keys %data) {
    $psv->print($OUT, [
       $dist,
       @{$data{$dist}}{@fields},
    ]) or $psv->error_diag;
}
close $OUT or croak "Unable to close $fcdvfile after writing";
croak "$fcdvfile not created" unless (-f $fcdvfile);
say "Examine ", (($sep_char eq ',') ? 'comma' : 'pipe'), "-separated values in $fcdvfile" if $verbose;
say "Finished";
__END__


