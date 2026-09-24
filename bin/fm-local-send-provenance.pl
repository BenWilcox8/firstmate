#!/usr/bin/env perl
# Fork writer for typed-send provenance.
# Usage: record <state> <backend> <target> <pane> <task> <remote-host> <sender-home> <kind>
#        prune <state>
# record hashes exact stdin bytes and appends one JSON object under an exclusive
# lock. Shards live at <state>/local-send-provenance/YYYY-MM-DD.jsonl.
# prune removes shards older than seven full UTC days plus the current day.
# Both operations prune. A quiet home expires records on its next operation.
# No prompt text is persisted. The schema owns the public fields and semantics.
use strict;
use warnings;
use Digest::SHA qw(sha256_hex);
use Encode qw(decode FB_CROAK);
use Fcntl qw(:DEFAULT :flock O_NOFOLLOW);
use JSON::PP;
use POSIX qw(strftime);

my ($op, $state, @fields) = @ARGV;
die "usage: record <state> <backend> <target> <pane> <task> <remote-host> <sender-home> <kind>, or prune <state>\n"
    unless defined($state) && (($op eq 'record' && @fields == 7) || ($op eq 'prune' && !@fields));
my $dir = "$state/local-send-provenance";
exit 0 if $op eq 'prune' && !-e $dir && !-l $dir;
umask 0077;
if (!-e $dir && !-l $dir) {
    mkdir($dir, 0700) or -d $dir or die "cannot create provenance directory: $!\n";
}
die "unsafe provenance directory\n" unless -d $dir && !-l $dir;
sysopen(my $lock, "$dir/.lock", O_CREAT | O_RDWR | O_NOFOLLOW, 0600) or die "cannot open provenance lock: $!\n";
flock($lock, LOCK_EX) or die "cannot lock provenance: $!\n";
my $now = time;
my $cutoff = strftime('%Y-%m-%d', gmtime($now - 7 * 86400));
opendir(my $entries, $dir) or die "cannot read provenance directory: $!\n";
while (my $name = readdir($entries)) {
    next unless $name =~ /\A(\d{4}-\d{2}-\d{2})\.jsonl\z/ && $1 lt $cutoff;
    next unless -f "$dir/$name" && !-l "$dir/$name";
    unlink("$dir/$name") or die "cannot remove expired provenance: $!\n";
}
closedir($entries);
if ($op eq 'record') {
    binmode(STDIN);
    my $bytes = do { local $/; <STDIN> } // '';
    my ($backend, $target, $pane, $task, $host, $sender, $kind) = map { decode('UTF-8', $_, FB_CROAK) } @fields;
    my $endpoint = {backend => $backend, target => $target, pane_id => length($pane) ? $pane : undef, task_id => length($task) ? $task : undef};
    $endpoint->{remote_host} = $host if length($host);
    my $record = {
        version => 1,
        endpoint => $endpoint,
        sha256 => sha256_hex($bytes),
        time => strftime('%Y-%m-%dT%H:%M:%SZ', gmtime($now)),
        sender_home => $sender,
        delivery_kind => $kind,
    };
    my $path = "$dir/" . strftime('%Y-%m-%d', gmtime($now)) . '.jsonl';
    sysopen(my $out, $path, O_WRONLY | O_APPEND | O_CREAT | O_NOFOLLOW, 0600) or die "cannot open provenance shard: $!\n";
    my $line = JSON::PP->new->ascii->canonical->encode($record) . "\n";
    print {$out} $line or die "cannot append provenance: $!\n";
    close($out) or die "cannot close provenance shard: $!\n";
}
