#!/usr/bin/env perl
use 5.14.0;
use warnings;
use Data::Dump qw( dd pp );
use Carp;
use Perl::Download::FTP 0.05;
#use Email::Sender::Simple qw(sendmail);
#use Email::Simple;
#use Email::Simple::Creator;
use File::Spec;

=head1 NAME - report-new-release.pl

Check server for new dev or RC release and download if needed.

=head1 USAGE

    perl report-new-release.pl

=head1 PURPOSE

This is a program which will be run by cron once a day.

Each time it runs it will get a list of all dev or RC releases in a given
format currently available via FTP.  It will identify the most recent release
and extract a string like 'perl-5.29.x' or perl-5.30.0-RCx' from it.

It will then examine the designated F<results> directory for the presence of subdirectories representing perl dev or RC releases which we have already processed with F<Test::Against::Dev>.

If the most recent release has already been handled, we will send an email
that says so and C<exit 0>.  (If we don't have email working yet, it will just
print the content of the email.)

If the most recent dev or rc release has not yet been handled, we will download it, and email/log that we have done so.  In real production, that will kick off the test-against-dev process.

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

my $self = Perl::Download::FTP->new( {
    host        => 'ftp.funet.fi',
    dir         => '/pub/languages/perl/CPAN/src/5.0',
    verbose     => 1,
} );

my @all_releases = $self->ls();
my @releases = $self->list_releases( {
    type            => 'dev_or_rc',
    compression     => 'gz',
    verbose         => 1,
} ) or croak "Wrong" . $self->{ftp}->message;
say "AAA: $releases[0]";
my ($latest_on_server) = $releases[0] =~ m/^(.*?)\.tar/;
say "BBB: $latest_on_server";

#dd(\@releases);

our $dev_pattern = qr/^perl-5\.(29)\.(\d{1,2})/;
our $rc_pattern  = qr/^perl-5\.(30)\.(\d{1,2})-RC(\d)/;

my $resultsdir = '/home/jkeenan/var/tad/results';
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
say "CCC: ", length($last_handled) ? $last_handled : "No versions handled yet";

my $body;
if ($last_handled eq $latest_on_server) {
    $body = "We've already seen $latest_on_server";
    say $body;
}
else {
    my $latest_release = '';
    $latest_release = $self->get_latest_release( {
        compression     => 'gz',
        type            => 'dev_or_rc',
        path            => $ENV{DOWNLOADS_DIR},
        verbose         => 1,
    } );
    $body = "We are seeing $latest_on_server for the first time;\n";
    $body .= "  downloaded $latest_release";
    say $body;
}

say "Finished!";
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

__END__

