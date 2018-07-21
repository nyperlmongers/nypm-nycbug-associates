#!/usr/bin/env perl
use 5.14.0;
use warnings;
use Data::Dumper;$Data::Dumper::Indent=1;
use Data::Dump ( qw| dd pp| );
use Carp;
use Cwd;
use File::Basename;
use File::Spec;
use Text::CSV;
use Text::CSV::Hashify 0.09;
use Getopt::Long;

=head1 NAME

analyze-master-psv.pl - Show which CPAN distributions failed to PASS or changed grade

=head1 USAGE

    perl analyze-master-psv.pl \
        --master_psvfile=/path/to/cpan-river-3000.perl-5.29.master.psv \
        --verbose

=head1 DESCRIPTION

Given a PSV file representing the most recent run, write a new CSV file
holding the data for distributions which either:

=over 4

=item *

Had a grade other than C<PASS> in the most recent run; or

=item *

Had a change in grade between the immediate previous run and the most recent
one.

=back

Output is written to a file in the current working directory named according to this formula:

    changes-${devcycle}.${next_to_last_release}-to-${devcycle}.${last_release}.csv

Example:

    changes-5.29.0-to-5.29.1.csv

=cut

my $cwd = cwd();
my ($psv, $verbose) = ('') x 2;

GetOptions(
    "master_psvfile=s"        => \$psv,
    "verbose"                 => \$verbose,
) or croak "Unable to get options";

unless (-f $psv) {
    croak "Could not locate master_psvfile '$psv'";
}
else {
    say "master_psvfile:        $psv" if $verbose;
}
my $basename = basename($psv);
my ($title, $perldevcycle, $devcycle) = ('') x 3;
($title, $perldevcycle, $devcycle) = $basename =~ m/^(.*?)\.(perl-(5\.\d{2}))\.master\.psv$/;
croak "Could not extract title" unless length $title;
croak "Could not extract perldevcycle" unless length $perldevcycle;
croak "Could not extract devcycle" unless length $devcycle;
if ($verbose) {
    say "Perl 5 dev cycle:      $perldevcycle";
    say "Dev cycle version:     $devcycle";
    say "Report title:          $title";
}

my $self = Text::CSV::Hashify->new( {
     file       => $psv,
     format     => 'hoh',
     key        => 'dist',
     sep_char   => '|',
} );
croak "Text::CSV::Hashify->new() did not return defined object"
    unless defined $self;

# all records requested
my $monthly_data       = $self->all;

# arrayref of fields input
my $fields_ref     = $self->fields;
my %fields_seen = map {$_ => 1} @{$fields_ref};
dd(\%fields_seen) if $verbose;

my $last_field = $fields_ref->[$#${fields_ref}];

# Since $perldevcycle by now been populated with a string like:
#     perl-5.29.1
# $last_release will be populated with the patch version of the most recent
# dev release.

my ($last_release) = $last_field =~ m/^$perldevcycle\.(\d+)\.grade$/;
my $next_to_last_release = $last_release - 1;
my $next_to_last_grade_field = "$perldevcycle.${next_to_last_release}.grade";

croak "Insufficient monthly reports"
    unless exists $fields_seen{$next_to_last_grade_field};
    #say $last_field;
    #say $next_to_last_grade_field;

my @fields_to_report = (
    "dist",
	"$perldevcycle.${next_to_last_release}.author",
	"$perldevcycle.${next_to_last_release}.distname",
	"$perldevcycle.${next_to_last_release}.distversion",
	"$perldevcycle.${next_to_last_release}.grade",
	"$perldevcycle.${last_release}.author",
	"$perldevcycle.${last_release}.distname",
	"$perldevcycle.${last_release}.distversion",
	"$perldevcycle.${last_release}.grade",
);
#dd(\@fields_to_report);

my %grade_changes = ();

for my $dist (keys %{$monthly_data}) {
    if (
        ($monthly_data->{$dist}->{$next_to_last_grade_field} ne $monthly_data->{$dist}->{$last_field}) 
            or
        ($monthly_data->{$dist}->{$last_field} ne 'PASS')
    ) {
        $grade_changes{$dist} = { map { $_ => $monthly_data->{$dist}->{$_} } @fields_to_report };
    }
}

my $csv = Text::CSV->new ( { binary => 1, sep_char => ',' } )
    or croak "Cannot use CSV: ".Text::CSV->error_diag ();

my $outfile = "$cwd/changes-${devcycle}.${next_to_last_release}-to-${devcycle}.${last_release}.csv";
say "Output will be in:     $outfile" if $verbose;

open my $OUT, ">:encoding(utf8)", $outfile
    or croak "Could not open $outfile for writing";
$csv->say($OUT, [ @fields_to_report ]);
for my $dist (sort keys %grade_changes) {
    my $aref = [ map { $grade_changes{$dist}{$_} } @fields_to_report ];
    #my $aref = [ map { $grade_changes{$dist}{$_} } @{$fields_ref} ];
    $csv->say($OUT, $aref);
}
close $OUT or croak "Unable to close $outfile after writing";

say "\nFinished!";

=head1 TODO

Make this more flexible.

=over 4

=item *

Allow user to specify on command-line a directory other than cwd() to which output is written.

=item *

Allow user to specify more than just the last two months in the output file --
even if the determination of which records to report is limited to those two
months.

This will involve populating a list to replace C<@fields_to_report> in the statement below:

    my $aref = [ map { $grade_changes{$dist}{$_} } @fields_to_report ];

=back

=cut

__END__
