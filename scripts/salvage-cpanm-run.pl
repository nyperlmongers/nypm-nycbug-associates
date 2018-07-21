#!/usr/bin/env perl
use 5.14.0;
use warnings;
use Carp;
use Data::Dump ( qw| dd pp | );
use File::Copy;
use File::Spec;
use Test::Against::Dev::Salvage;
use Test::Against::Dev::Sort;
use Test::Against::Dev::ProcessPSV;
use Getopt::Long;

=pod

    perl ~/bin/perl/salvage-cpanm-run.pl \
        --path_to_cpanm_build_log=/path/to/var/tad/testing/perl-5.29.1/.cpanm/work/1532140983.58481/build.log \
        --perl_version=perl-5.29.1 \
        --title=cpan-river-3000 \
        --results_dir=/home/jkeenan/var/tad/results \
        --verbose

=cut

my $date = qx/date/;
chomp $date;
say sprintf("%-52s%s" => ("Date:", $date));
say "Running $0";

my ($build_log, $perl_version, $title, $results_dir) = (undef) x 4;
my $verbose = '';
GetOptions(
    "path_to_cpanm_build_log=s" => \$build_log,
    "perl_version=s"            => \$perl_version,
    "title=s"                   => \$title,
    "results_dir=s"             => \$results_dir,
    "verbose"                   => \$verbose,
) or croak "Unable to get options";

unless (-f $build_log) {
    croak "Could not locate build_log '$build_log'";
}
else {
    say "build_log:             $build_log" if $verbose;
}

unless (length($title) > 2) {
    croak "Title '$title' is suspiciously short";
}
else {
    say "title:                 $title" if $verbose;
}

unless (-d $results_dir) {
    croak "Could not locate results_dir '$results_dir'";
}
else {
    say "results_dir:           $results_dir" if $verbose;
}

my $self = Test::Against::Dev::Salvage->new( {
    path_to_cpanm_build_log => $build_log,
    perl_version            => $perl_version,
    title                   => $title,
    results_dir             => $results_dir,
    verbose                 => $verbose,
} );

my $gzipped_build_log = $self->gzip_cpanm_build_log();
my $ranalysis_dir = $self->analyze_cpanm_build_logs( { verbose => $verbose } );
my $fpsvfile = $self->analyze_json_logs( { verbose => $verbose } );

my $master_psvfile = consolidate_psvfiles( {
    results_dir     => $results_dir,
    perldevcycle    => '5.29',
    title           => $title,
    verbose         => $verbose,
} );

say "\nFinished\n";

sub consolidate_psvfiles {
    my $args = shift;
    croak "Argument to consolidate_psvfiles() must be hashref"
        unless ref($args) eq 'HASH';
    my %required_args = map { $_ => 1 } ( qw| results_dir perldevcycle title | );
    for my $key (keys %required_args) {
        croak "Hashref element '$key' missing" unless exists $args->{$key};
    }
    my $verbose = $args->{verbose} || '';

    my ($dev_minor) = $args->{perldevcycle} =~ m/5\.(\d{1,2})$/;
    my $rc_minor = $dev_minor + 1;
    my $dev_pattern = qr/^perl-5\.($dev_minor)\.(\d{1,2})/;
    my $rc_pattern  = qr/^perl-5\.($rc_minor)\.(\d{1,2})-RC(\d)/;

    # Detect the Perl dev or RC releases which have been processed already
    # by test-against-dev

    my %versions = ();
    opendir my $DIRH, $args->{results_dir} or croak "Unable to open $args->{results_dir} for reading";
    my @seen = grep { ! m/^\.{1,2}$/ } readdir $DIRH;
    closedir $DIRH or croak "Unable to close $args->{results_dir} after reading";
    #dd(\@seen);

    for my $e (@seen) {
        if ($e =~ m/($dev_pattern|$rc_pattern)$/) {
            my $perl_version = $1;
            my $version_dir = File::Spec->catdir($args->{results_dir}, $perl_version);
            croak "Could not locate directory '$version_dir'" unless -d $version_dir;
            my $version_storage_dir = File::Spec->catdir($version_dir, 'storage');
            croak "Could not locate directory '$version_storage_dir'" unless -d $version_storage_dir;
            my $psvfile = File::Spec->catfile($version_storage_dir,
                "$args->{title}.${perl_version}.psv"
            );
            croak "Could not locate file '$psvfile'" unless -f $psvfile;
            say join('|' => $perl_version, $version_dir, $version_storage_dir, $psvfile);
            $versions{$perl_version}{version_dir} = $version_dir;
            $versions{$perl_version}{version_storage_dir} = $version_storage_dir;
            $versions{$perl_version}{psvfile} = $psvfile;
        }
    }
    if ($verbose) {
        say "Observed this structure in \%versions:";
        dd(\%versions);
    }

    # See if we already have a master PSV file

    my $master_file = File::Spec->catfile(
        $args->{results_dir},
        "$args->{title}.perl-$args->{perldevcycle}.master.psv"
    );
    say "master_file will be $master_file" if $verbose;
    if (! -f $master_file) {
        say "$master_file does not yet exist" if $verbose;
        my $key = "$args->{perldevcycle}.0";
        if (
            (scalar keys %versions == 1) and
            (exists $versions{$key})
        ) {
            say "Copying $versions{$key}{psvfile} to $master_file"
                if $verbose;
            copy $versions{$key}{psvfile} => $master_file
                or croak "Unable to copy $versions{$key}{psvfile} to $master_file";
            say "\nFinished!";
            exit 0;
        }
        else {
            croak "Don't know how to handles this situation";
        }
    } # This block either exit 0 or croak.

    say "$master_file exists" if $verbose;
    # As precaution, backup the master file and work from it.
    my $backup_master = "$master_file.bak";
    copy $master_file => $backup_master
        or croak "Unable to copy $master_file to $backup_master";

    my $ppsv = Test::Against::Dev::ProcessPSV->new( { verbose => 1 } );
    my $columns_seen = $ppsv->read_one_psv( { psvfile => $backup_master } );
    croak "read_one_psv() did not return populated array ref"
        unless ( (ref($columns_seen) eq 'ARRAY') and (scalar(@{$columns_seen}) >= 5) );
    my ($highest_version_in_master) = $columns_seen->[-1] =~ m/^(.*?)\.grade$/;
    croak "Unable to get highest version in master psv file"
        unless (
            $highest_version_in_master and
            ($highest_version_in_master =~ m/^($dev_pattern|$rc_pattern)$/ )
        );
    say "Highest perl version found in master psv: $highest_version_in_master" if $verbose;

    my $tads_object = Test::Against::Dev::Sort->new($dev_minor);
    my $sorted_versions_ref = $tads_object->sort_dev_and_rc_versions([ keys %versions ]);
    dd($sorted_versions_ref);
    my $most_recent_version = $sorted_versions_ref->[-1];
    say "Most recent Perl version processed:       ", $most_recent_version if $verbose;
    my $most_recent_psvfile = $versions{$most_recent_version}{psvfile};
    say "Most recent psvfile:                      ", $most_recent_psvfile if $verbose;

    my $columns_seen2 = $ppsv->read_one_psv( { psvfile => $most_recent_psvfile } );
    croak "read_one_psv() did not return populated array ref"
        unless ( (ref($columns_seen2) eq 'ARRAY') and (scalar(@{$columns_seen2}) >= 5) );


    say scalar keys %{$ppsv->{master_data}}, " elements in master_data" if $verbose;

    my $master_columns_ref = ['dist'];
    my @fields = ( qw| author distname distversion grade | );
    for my $pv (@{$sorted_versions_ref}) {
        for my $f (@fields) {
            push @{$master_columns_ref}, "$pv.$f";
        }
    }

    my $rv = $ppsv->write_master_psv( {
        master_columns  => $master_columns_ref,
        master_psvfile  => $master_file,
    } );

    croak "$master_file not created" unless (-f $master_file);
    say "Created $master_file" if $verbose;

    return $master_file;
}
