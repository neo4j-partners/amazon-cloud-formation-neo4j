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