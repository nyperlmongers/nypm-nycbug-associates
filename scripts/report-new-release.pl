#!/usr/bin/env perl
use 5.14.0;
use warnings;
use Data::Dump qw( dd pp );
use Carp;
use Perl::Download::FTP 0.05;
use Email::Sender::Simple qw(sendmail);
use Email::Simple;
use Email::Simple::Creator;
use File::Spec;
use Getopt::Long;

=head1 NAME - report-new-release.pl

Check server for new dev or RC release and download if needed.

=head1 USAGE

    perl report-new-release.pl \
        --application_dir=$HOMEDIR/var/tad \
        --host=ftp.funet.fi \
        --hostdir=/pub/languages/perl/CPAN/src/5.0 \
        --compression=gz \
        --type=dev_or_rc \
        --dev_cycle=31 \
        --email_to='"James E Keenan" <jkeenan@pobox.com>' \
        --email_from='"James E Keenan" <jkeenan@pobox.com>' \
        --email_subject='Status of Perl 5 development release' \
        --verbose \
        --download

=head1 PURPOSE

This is a program which will be run by cron once a day.

Each time it runs it will get a list of all dev or RC releases in a given
format currently available via FTP.  It will identify the most recent release
and extract a string like 'perl-5.29.x' or perl-5.30.0-RCx' from it.

It will then examine the designated F<results> directory for the presence of
subdirectories representing perl dev or RC releases which we have already
processed with F<Test::Against::Dev>.

If the most recent release has already been handled, we will send an email
that says so and C<exit 0>.  (If we don't have email working yet, it will just
print the content of the email.)

If the most recent dev or rc release has not yet been handled and if the
C<--download> option has B<not> been set, then we will and email/log that.

=head1 PREREQUISITES

=head2 CPAN Modules

=over 4

=item * Perl::Download::FTP (version 0.05 or greater)

=item * Data::Dump

=item * Once we've got email working, we'll need:

=over 4

=item * Email::Sender::Simple

=item * Email::Simple

=item * Email::Simple::Creator

=back

=back

=head2 Environmental Variables

=over 4

=item * C<$DOWNLOADS_DIR>

Full path to directory where you customarily download files from the network.

=back

=cut

my $date = qx/date/;
chomp $date;
say sprintf("%-52s%s" => ("Date:", $date));
say "Running $0";

my ($application_dir, $host, $hostdir, $compression, $type, $dev_cycle) = (undef) x 6;
my ($email_from, $email_to, $email_subject) = (undef) x 3;
my ($download, $verbose) = ('') x 2;
GetOptions(
    "application_dir=s" => \$application_dir,
    "host=s"            => \$host,
    "hostdir=s"         => \$hostdir,
    "compression=s"     => \$compression,
    "type=s"            => \$type,
    "download"          => \$download,
    "dev_cycle=i"       => \$dev_cycle,
    "email_from=s"      => \$email_from,
    "email_to=s"        => \$email_to,
    "email_subject=s"   => \$email_subject,
    "verbose"           => \$verbose,
) or croak "Unable to get options";

unless (-d $application_dir) {
    croak "Could not locate application_dir '$application_dir'";
}
else {
    say "application_dir:       $application_dir" if $verbose;
}
say "host:                  $host"          if $verbose;
say "hostdir:               $hostdir"       if $verbose;
say "compression:           $compression"   if $verbose;
say "type:                  $type"          if $verbose;

my $rc_cycle;
unless ($dev_cycle =~ m/^\d\d$/) {
    croak "Value for 'dev_cycle' must be two-digit number";
}
else {
    say "dev_cycle:             $dev_cycle" if $verbose;
    $rc_cycle = sprintf("%02d", $dev_cycle + 1);
    say "rc_cycle:              $rc_cycle" if $verbose;
}

my $self = Perl::Download::FTP->new( {
    host        => $host,
    dir         => $hostdir,
    verbose     => $verbose,
} );

my @all_releases = $self->ls();
my @releases = $self->list_releases( {
    type            => $type,
    compression     => $compression,
    verbose         => $verbose,
} ) or croak "Wrong" . $self->{ftp}->message;
say sprintf("%-52s%s" => ("Most recent $type tarball observed on server:", $releases[0]));
my ($latest_on_server) = $releases[0] =~ m/^(.*?)\.tar/;
say sprintf("%-52s%s" => ("Most recent $type version observed on server:", $latest_on_server));

#dd(\@releases);

our $dev_pattern = qr/^perl-5\.($dev_cycle)\.(\d{1,2})/;
our $rc_pattern  = qr/^perl-5\.($rc_cycle)\.(\d{1,2})-RC(\d)/;

my $resultsdir = File::Spec->catdir($application_dir, 'results');
croak "Could not locate $resultsdir" unless -d $resultsdir;

opendir my $DIRH, $resultsdir or croak "Unable to opendir";
my @lines = grep { m/$dev_pattern|$rc_pattern/ } readdir $DIRH;
closedir $DIRH or croak "Unable to closedir";
#dd(\@lines);

my @versions_handled = sort_by_patch_version(\@lines);
for my $v (@versions_handled) {
    my $dv = File::Spec->catdir($resultsdir, $v);
    croak qq|$dv is not a directory"| unless (-d $dv);
}
my $last_handled = $versions_handled[-1] || '';

say sprintf("%-52s%s" => (
    "Most recent Perl version processed:",
    length($last_handled) ? $last_handled : "No versions handled yet",
));

my $email_body;
if ($last_handled eq $latest_on_server) {
    # compose and send email indicating no action needed
    $email_body = "We've already handled $latest_on_server; no action needed";
    email_notify( {
        email_to            => $email_to,
        email_from          => $email_from,
        email_subject       => $email_subject,
        latest_on_server    => $latest_on_server,
        email_body          => $email_body,
    } );
    say "\nFinished!";
    exit 0;
}
else {
    if ($download) {
        my $latest_release = '';
        $latest_release = $self->get_latest_release( {
            compression     => $compression,
            type            => $type,
            path            => $ENV{DOWNLOADS_DIR},
            verbose         => $verbose,
        } );
        $email_body = "We are seeing $latest_on_server for the first time;\n";
        $email_body .= "  downloaded $latest_release";
    }
    else {
        $email_body = "We are seeing $latest_on_server for the first time;\n";
        $email_body .= "  but are not downloading it";
    }
    email_notify( {
        email_to            => $email_to,
        email_from          => $email_from,
        email_subject       => $email_subject,
        latest_on_server    => $latest_on_server,
        email_body          => $email_body,
    } );
}

say "Finished!\n";
exit 0;

#################### SUBROUTINES ####################

sub match {
    my $version = shift;
    my ($minor, $patch, $rc) = ('') x 3;
    if ($version =~ m/$dev_pattern/) {
        ($minor, $patch) = ($1,$2);
    }
    elsif ($version =~ m/$rc_pattern/) {
        ($minor, $patch, $rc) = ($1,$2,$3);
    }
    if (! $minor) {
        #        say "no match: $version";
    }
    else {
        #        say join '|' => ($minor, $patch, $rc || '');
    }
    return ($minor, $patch, $rc);
}

sub sort_by_patch_version {
    my $linesref = shift;
    my %lines;
    for my $l (@$linesref) {
        my %this;
        ($this{minor}, $this{patch}, $this{rc}) = match($l);
        $lines{$l} = \%this;
    }
    #dd(\%lines);
    return sort {
        $lines{$a}{minor} <=> $lines{$b}{minor} ||
        $lines{$a}{patch} <=> $lines{$b}{patch} ||
        $lines{$a}{rc}    cmp $lines{$b}{rc}
    } keys %lines;
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

__END__

