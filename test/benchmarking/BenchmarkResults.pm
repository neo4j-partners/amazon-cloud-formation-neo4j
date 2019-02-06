# Takes a hashref of extracted results, and sorts them out.
# Three sections: overview metadata, benchmark specific outputs,
# and benchmark settings.
sub organizeResults {
    my $href = shift(@_);

    # Fields that all benchmarks should output.
    my %required = (
        "BENCHMARK" => "missing",
        "DATE" => "missing",
        "TAG" => "missing",
        "ELAPSED" => "missing",
        "EXECUTION_TIME" => "missing",
        "LOG_FILE" => "missing",
        "PROVIDER" => "missing",
        "EXIT_CODE" => "missing"
    );
    my %settings = ();
    my %benchmarkSpecific = ();

    foreach my $key (keys %{$href}) {
        print "Key $key\n";
        my $val = $href->{$key};

        if (exists($required{$key})) {
            $required{$key} = $val;
        } elsif ($key =~ m/^SETTING_/i) {
            $settings{$key} = $val;
        } else {
            $benchmarkSpecific{$key} = $val;
        }
    }

    return (
        "required" => \%required,
        "settings" => \%settings,
        "benchmark" => \%benchmarkSpecific
    );
}

sub extractResults {
    my $log = shift(@_);
    local $/ = undef;

    if (!(-f $log)) {
        warn "Cannot extract results from non-existant file $log\n";
        return undef;
    }

    my $data = `cat "$log" | grep "^BENCHMARK_"`;
    my @lines = split(/\n/, $data);

    my %benchmarkOutputs = ();

    for my $line (@lines) {
        chomp($line);
        $line =~ m/^BENCHMARK_(.*?)=(.*)?$/;
        my $key = $1;
        my $value = $2;
        $benchmarkOutputs{$key} = $value;
    }

    return %benchmarkOutputs;
}

sub writeResults {
    my $logfile = shift(@_);
    my $href = shift(@_);  # hashref

    open(FH, ">>$logfile") or warn "Couldn't append to $logfile: $!\n";

    for my $key (keys %{$href}) {
        print FH "BENCHMARK_$key=" . $href->{$key} . "\n";
    }

    close(FH);
}

1;