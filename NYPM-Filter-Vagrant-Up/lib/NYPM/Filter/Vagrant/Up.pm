package NYPM::Filter::Vagrant::Up;
use 5.14.0;
use warnings;
use parent 'Exporter';
our $VERSION     = '0.01';
our @EXPORT_OK = qw( filter_vagrant_up );
use Carp;
use Cwd;
use File::Spec::Functions qw( catfile );
use IO::Zlib;


=head1 NAME

NYPM::Filter::Vagrant::Up - Filter the output of 'vagrant up' and write it to file

=head1 SYNOPSIS

    use NYPM::Filter::Vagrant::Up qw( filter_vagrant_up );

=head1 DESCRIPTION

This module exists mainly to support a command-line executable which will call C<vagrant up>, log the output, filter out superfluous output then write it to a gzipped and appropriately named file.

=head1 SUBROUTINES

=head2 c<filter_vagrant_up()>

=over 4

=item * Purpose

Given a file holding the output of a C<vagrant up> call, filter out superflouous lines and write the remaineder to a gzipped, timestamped file.

=item * Arguments

Single hash reference.  Elements of that hash include:

=over 4

=item * C<vagrant_log>

String holding absolute path to a file holding the output (STDOUT and STDERR)
of a call to F<vagrant up>.  Required.

=item * C<output_dir>

String holding absolute path to the directory where the log file will be
written.  Defaults to the current working directory.

=back

=item * Return Value

String holding absolute path to the filtered, gzipped log file.

=back

=cut

sub filter_vagrant_up {
    my $args = shift;
    croak "filter_vagrant_up() takes hashref"
        unless ref($args) eq 'HASH';
    my %permitted_args = map {$_ => 1} qw( vagrant_log output_dir );
    my @bad_args = ();
    for my $k (keys %$args) {
        push @bad_args, $k unless $permitted_args{$k};
    }
    if (@bad_args) {
        croak "Incorrect elements in hashref passed to filter_vagrant_up(): @bad_args";
    }
    croak "Hashref passed to filter_vagrant_up() lacks 'vagrant_log' element"
        unless (exists $args->{vagrant_log});
    croak "Could not locate '$args->{vagrant_log}'" unless (-f $args->{vagrant_log});
    if (exists $args->{output_dir}) {
        croak "Could not locate output directory '$args->{output_dir}'"
            unless (-d $args->{output_dir});
    }

    my @gmtime = gmtime(time);
    my $timestamp = sprintf("%04d%02d%02d%02d%02d%02d" => (
        $gmtime[5] + 1900,
        $gmtime[4] + 1,
        $gmtime[3],
        $gmtime[2],
        $gmtime[1],
        $gmtime[0],
    ) );
    my $output_dir = $args->{output_dir} || cwd();
    my $output_file = catfile($output_dir, "vagrant-up.${timestamp}.log.gz");
    #        default: .

    open my $IN, '<', $args->{vagrant_log}
        or croak "Unable to open $args->{vagrant_log} for reading";
    my $OUT = IO::Zlib->new($output_file, "wb9");
    croak "Could not open $output_file for writing" unless defined $OUT;
    while (my $l = <$IN>) {
        chomp $l;
        next if $l =~ m/^\s+default:\s\.$/;
        $OUT->print($l, "\n");
    }
    $OUT->close or croak "Could not close $output_file after writing";
    close $IN or croak "Could not close $args->{vagrant_log} after reading";
    return $output_file;
}

=head1 AUTHOR

    James E Keenan
    New York Perlmongers
    jkeenan@pobox.com

=head1 COPYRIGHT

This program is free software licensed under the...

	The BSD License

The full text of the license can be found in the
LICENSE file included with this module.

=head1 SEE ALSO

perl(1).

=cut


1;
