#!/usr/bin/env perl
use 5.14.0;
use warnings;
use Data::Dump qw( dd pp );
use Carp;
use Cwd;
use Perl::Download::FTP;
use Email::Sender::Simple qw(sendmail);
use Email::Simple;
use Email::Simple::Creator;
use File::Copy;
use File::Spec;
use File::Temp qw(tempdir);
use Getopt::Long;
use Test::Against::Dev;
use Test::Against::Dev::Sort;
use Test::Against::Dev::ProcessPSV;

=head1 NAME

trigger-tad.pl - Test top of CPAN river against monthly Perl development release

=head1 OBJECTIVE

This program is intended to be run once a month during an annual Perl
development cycle.  Each time it runs:

=over 4

=item *

It will get a list of all dev releases in a given format
currently available via FTP.

=item *

It will identify the most recent release and extract a string like
'perl-5.29.N' from the name of that release.

=item *

In production, it will compare that string to the list of directories in:
~/var/tad/results/perl-5.27.*

During testing, it will compare that string to a dummy file holding a list of
all but the most recent releases.

In either case, if we have a match, that will mean that we've already handled
that particular perl release, so we send an email that says so and we exit 0.
(TODO: Email transmission not yet set up inside VM.)

If we don't have a match, then that will mean that we have NOT already handled
that perl dev release, so we download it, send an email that we have done so.
(TODO: Email transmission not yet set up inside VM.)
In real production, that will kick off the test-against-dev process.

=item *

  perl /home/jkeenan/bin/perl/trigger-tad.pl \
    --application_dir=/home/jkeenan/var/tad \
    --tdir=/home/jkeenan/tmp/scratch \
    --host=ftp.funet.fi \
    --hostdir=/pub/languages/perl/CPAN/src/5.0 \
    --minor_version=29 \
    --compression=gz \
    --river_file=/home/jkeenan/var/tad/src/modules-for-cpanm-20180626.txt \
    --cpanm_uri=http://raw.githubusercontent.com/jkeenan/cpanminus/no-exit-1.7044/cpanm \
    --title=cpan-river-3000 \
    --email_to='"James E Keenan" <jkeenan@pobox.com>' \
    --email_from='"James E Keenan" <jkeenan@pobox.com>' \
    --email_subject='Status of Perl 5 development release' \
    --verbose

    --testing

=cut

my $date = qx/date/;
chomp $date;
say sprintf("%-52s%s" => ("Date:", $date));
say "Running $0";

my ($application_dir, $tdir, $compression, $host, $hostdir,
    $river_file, $cpanm_uri, $minor_version, $title,
    $email_from, $email_to, $email_subject,
    $verbose, $testing) = (undef) x 14;
GetOptions(
    "application_dir=s" => \$application_dir,
    "tdir=s"            => \$tdir,
    "minor_version=i"   => \$minor_version,
    "compression=s"     => \$compression,
    "host=s"            => \$host,
    "hostdir=s"         => \$hostdir,
    "river_file=s"      => \$river_file,
    "cpanm_uri=s"       => \$cpanm_uri,
    "title=s"           => \$title,
    "email_from=s"      => \$email_from,
    "email_to=s"        => \$email_to,
    "email_subject=s"   => \$email_subject,
    "verbose"           => \$verbose,
    "testing"           => \$testing,
) or croak "Unable to get options";

unless (-d $application_dir) {
    croak "Could not locate application_dir '$application_dir'";
}
else {
    say "application_dir:       $application_dir" if $verbose;
}

unless ($minor_version % 2 and $minor_version > 25) {
    croak "minor_version must be odd and greater than 25";
}
else {
    say "Perl minor_version:    $minor_version" if $verbose;
}

unless (-d $tdir) { $tdir = tempdir(CLEANUP => 1); }
say "scratch directory:     $tdir" if $verbose;

$compression = 'gz';  # Only one value for now.
say "compression:           $compression" if $verbose;
say "host:                  $host" if $verbose;
say "hostdir:               $hostdir" if $verbose;
unless (-f $river_file) {
    croak "Could not locate river source file '$river_file'";
}
else {
    say "river_file (source):   $river_file" if $verbose;
}
if ($verbose) {
    if ($cpanm_uri) {
        say "Using $cpanm_uri for 'cpanm'";
    }
    else {
        say "Using Test::Against::Dev default value for 'cpanm'";
    }
}

unless (length($title) > 2) {
    croak "Title '$title' is suspiciously short";
}
else {
    say "title:                 $title" if $verbose;
}
$email_from     //= '"James E Keenan" <jkeenan@pobox.com>';
$email_to       //= '"James E Keenan" <jkeenan@pobox.com>';
$email_subject  //= 'Status of Perl 5 development release';
if ($verbose) {
    say "email_from:            $email_from";
    say "email_to:              $email_to";
    say "email_subject:         $email_subject (plus release name)";
}

##### END OPTIONS PROCESSING #####

my @versions_handled =
    identify_versions_already_handled($application_dir, $minor_version);
if ($verbose) {
    say "\nWe have already handled:";
    dd(\@versions_handled);
}
my ($latest_handled, $overlook_latest) = ('') x 2;
unless ($testing) {
    $latest_handled = $versions_handled[-1] || '';
    if ($verbose) {
        if (length $latest_handled) {
            say "latest_handled (test): $latest_handled";
        }
        else {
            say "We have not yet handled any dev releases in this cycle";
        }
    }
}
else {
    $overlook_latest = pop @versions_handled;
    $latest_handled = $versions_handled[-1] || '';
    if ($verbose) {
        if (length $latest_handled) {
            say "latest_handled (test): $latest_handled";
        }
        else {
            say "We have not yet handled any dev releases in this cycle";
        }
    }
}

# Check the FTP server for development releases

my $pdfobj = Perl::Download::FTP->new( {
    host        => $host,
    dir         => $hostdir,
    verbose     => $verbose,
} );

my @all_releases = $pdfobj->ls();
my @releases = grep { m/5\.${minor_version}\.\d{1,2}/ }
    map { s/^(.*)\.tar\.gz$/$1/; $_ }
    $pdfobj->list_releases( {
        type            => 'dev',
        compression     => $compression,
    } ) or croak "Wrong " . $pdfobj->{ftp}->message;
if ($verbose) {
    say "\nWe can see these perl-5.${minor_version}.* dev releases on server";
    dd(\@releases);
}
my $latest_on_server = $releases[0];
say "latest_on_server:      $latest_on_server" if $verbose;

my $email_body = '';
if ($latest_on_server eq $latest_handled) {
    # compose and send email indicating no action needed
    $email_body = "We've already handled $latest_on_server; no action needed";
#    email_notify( {
#        email_to            => $email_to,
#        email_from          => $email_from,
#        email_subject       => $email_subject,
#        latest_on_server    => $latest_on_server,
#        email_body          => $email_body,
#    } );
#    say "\nFinished!";
    say "$email_body\nFinished!\n";
    exit 0;
}

## compose and send email indicating we are taking an action
## take the action
#say "Taking action to process $latest_on_server" if $verbose;
#$email_body = "We have not yet handled $latest_on_server; taking action";
#email_notify( {
#    email_to            => $email_to,
#    email_from          => $email_from,
#    email_subject       => $email_subject,
#    latest_on_server    => $latest_on_server,
#    email_body          => $email_body,
#} );

my $cwd = cwd();
my $tadobj = Test::Against::Dev->new( {
    application_dir         => $application_dir,
} );
croak "new() did not return defined value"
    unless defined $tadobj;

my ($tarball_path, $work_dir, $release_dir);
say "Performing live FTP download of Perl tarball;\n  this may take a while.";
($tarball_path, $work_dir) = $tadobj->perform_tarball_download( {
    host                => $host,
    hostdir             => $hostdir,
    perl_version        => $latest_on_server,
    compression         => $compression,
    verbose             => $verbose,
} );

croak "perform_tarball_download() failed to return true values"
    unless (-f $tarball_path and -d $work_dir);
$release_dir = $tadobj->get_release_dir();
unless (-d $release_dir) {
    croak "Could not locate release_dir ";
}
else {
    say "Located release_dir: $release_dir";
}

if ($testing) {
    say "For safe testing, exiting now" if $verbose;
    exit 0;
}

my $freebsd_configure_command =
    "sh ./Configure -des -Dusedevel  -Uversiononly -Dman1dir=none -Dman3dir=none";
$freebsd_configure_command .= qq| -Duseithreads -Doptimize="-O2 -pipe -fstack-protector -fno-strict-aliasing"|;
$freebsd_configure_command .= " -Dprefix=$release_dir";

my $this_perl = $tadobj->configure_build_install_perl({
    configure_command => $freebsd_configure_command,
    verbose => $verbose,
});
unless (-f $this_perl) {
    croak "Failed to install perl";
}
else {
    say "Installed perl: $this_perl";
}

my $this_cpanm = $tadobj->fetch_cpanm( {
    verbose => $verbose,
    uri     => $cpanm_uri,
} );
unless (-f $this_cpanm) {
    croak "Failed to install cpanm";
}
else {
    say "Installed cpanm: $this_cpanm";
}

my $bin_dir = $tadobj->get_bin_dir();
unless (-d $bin_dir) {
    croak "Failed to locate bin_dir";;
}
else {
    say "Located bin_dir: $bin_dir";
}

my $lib_dir = $tadobj->get_lib_dir();
unless (-d $lib_dir) {
    croak "Failed to locate lib_dir";;
}
else {
    say "Located lib_dir: $lib_dir";
}

my $cpanm_dir = $tadobj->get_cpanm_dir();
unless (-d $cpanm_dir) {
    croak "Failed to locate cpanm_dir";;
}
else {
    say "Located cpanm_dir: $cpanm_dir";
}

pp({ %{$tadobj} });

my $expected_log = File::Spec->catfile($release_dir, '.cpanm', 'build.log');
my $gzipped_build_log;
say "Expecting to log cpanm in $expected_log";

{
    local $@;
    eval {
        $gzipped_build_log = $tadobj->run_cpanm( {
            module_file => $river_file,
            title       => $title,
            verbose     => $verbose,
        } );
    };
    unless ($@) {
        say "run_cpanm operated as intended; see $expected_log for PASS/FAIL/etc.";
    }
    else {
        say "run_cpanm did not operate as intended";
    }
    croak "Could not locate gzipped build.log at $gzipped_build_log"
        unless (-f $gzipped_build_log);
}

my $ranalysis_dir = $tadobj->analyze_cpanm_build_logs( { verbose => $verbose } );
unless (-d $ranalysis_dir) {
    croak "analyze_cpanm_build_logs failed";
}
else {
    say "analyze_cpanm_build_logs() returned path to version-specific analysis directory '$ranalysis_dir'";
}

my $fpsvfile = $tadobj->analyze_json_logs( { run => 1, verbose => $verbose } );
unless ($fpsvfile) {
    croak "analyze_json_logs failed";
}
else {
    say "analyze_json_logs() returned $fpsvfile";
}

chdir $cwd;

my $master_psvfile = consolidate_psvfiles( {
    results_dir     => $tadobj->get_results_dir(),
    perldevcycle    => "perl-5.$minor_version",
    title           => $title,
    verbose         => $verbose,
} );
say "See master psvfile in: $master_psvfile";

#$email_body = "Completed run of $0 for $latest_on_server";
#email_notify( {
#    email_to            => $email_to,
#    email_from          => $email_from,
#    email_subject       => $email_subject,
#    latest_on_server    => $latest_on_server,
#    email_body          => $email_body,
#} );

say "\nFinished!\n";
exit 0;

##### SUBROUTINES #####

sub identify_versions_already_handled {
    my ($application_dir, $minor_version) = @_;
    my $resultsdir = File::Spec->catdir($application_dir, 'results');
    croak "Could not locate $resultsdir" unless (-d $resultsdir);
    opendir my $DIRH, $resultsdir or croak "Unable to opendir";
    my @lines = grep { /^perl-5\.$minor_version\.\d{1,2}$/ } readdir $DIRH;
    closedir $DIRH or croak "Unable to closedir";
    my @versions_handled = sort_by_patch_version(\@lines, $minor_version);
    for my $v (@versions_handled) {
        my $dv = File::Spec->catdir($resultsdir, $v);
        croak qq|$dv is not a directory"| unless (-d $dv);
    }
    return @versions_handled;
}

sub sort_by_patch_version {
    my $linesref = shift;
    my %lines;
    for my $l (@$linesref) {
        my ($patch_version) = $l =~ m/^perl-5\.$minor_version\.(\d{1,2})$/;
        if (! defined $patch_version) {
            croak "Unable to extract patch_version from $l";
        }
        else {
            $lines{$patch_version} = $l;
        }
    }
    return map { $lines{$_} } sort { $a <=> $b } keys %lines;
}

=pod

    email_notify( {
        email_to => $email_to,
        email_from => $email_from,
        email_subject => $email_subject,
        latest_on_server => $latest_on_server,
        email_body => $email_body,
    } );

=cut

sub email_notify {
    my $args = shift;
    croak "email_notify() takes hash reference" unless ref($args) eq 'HASH';
    my $email = Email::Simple->create(
      header => [
        To      => $args->{email_to},
        From    => $args->{email_from},,
        Subject => join(' ' => ($args->{email_subject}, $args->{latest_on_server})),
      ],
      body => $args->{email_body},
    );

    local $@;
    eval { sendmail($email); };
    if ($@) { say "Problem in sending email: <$@>"; exit 1; }
    else { return 1 };
}

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
    our $dev_pattern = qr/^perl-5\.($dev_minor)\.(\d{1,2})/;
    our $rc_pattern  = qr/^perl-5\.($rc_minor)\.(\d{1,2})-RC(\d)/;

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
        "$args->{title}.$args->{perldevcycle}.master.psv"
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
__END__
